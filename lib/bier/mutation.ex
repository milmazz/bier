defmodule Bier.Mutation do
  @moduledoc """
  Write pipeline for `POST` / `PATCH` / `PUT` / `DELETE` on a relation.

  Mirrors PostgREST's mutation semantics:

    * `POST`   — `INSERT ... RETURNING`, optionally `ON CONFLICT` for upsert
      (`Prefer: resolution=merge-duplicates|ignore-duplicates`,
      `?on_conflict=`).
    * `PATCH`  — `UPDATE ... WHERE <filters> RETURNING`, honoring the request's
      column filters.
    * `DELETE` — `DELETE ... WHERE <filters> RETURNING`.
    * `PUT`    — single-row upsert keyed by the request's PK filter
      (`INSERT ... ON CONFLICT (<pk>) DO UPDATE`).

  Row values arrive as a JSON payload and are expanded into typed columns
  through Postgres' `jsonb_array_elements` (one bound `jsonb` parameter), so a
  string like `"{1,2,3}"` coerces to `integer[]` exactly as PostgREST does;
  user data is never interpolated. The `?columns=` param selects which payload
  keys become target columns (others are ignored); `Prefer: missing=default`
  fills the column DEFAULT for keys a row omits.

  The `Prefer: return=` token selects the response shape; `Preference-Applied`
  echoes the honored tokens in PostgREST's canonical order.
  """

  import Plug.Conn

  alias Bier.MediaType
  alias Bier.Plugs.ActionController
  alias Bier.Plugs.Warning
  alias Bier.QueryExecutor
  alias Bier.Render

  defmodule Write do
    @moduledoc false
    # Everything the execution/response pipeline needs to know about one write
    # request, bundled so it can be threaded as a single value instead of a
    # dozen positional arguments.
    #
    #   * `mutation`  — `:insert | :update | :delete`, or the tagged forms
    #     `{:put, row, pk}` / `{:upsert, conflict_cols, rows}` used to decide
    #     200-vs-201 by pre-existence.
    #   * `ok_status` — the success status before GUC/pre-existence overrides.
    defstruct [:config, :relation, :plan, :media, :pref, :mutation, :ok_status]
  end

  @doc "Handle a mutation request after media negotiation."
  def handle(conn, config, relation, media) do
    case conn.method do
      "POST" -> insert(conn, config, relation, media)
      "PATCH" -> update(conn, config, relation, media)
      "PUT" -> put(conn, config, relation, media)
      "DELETE" -> delete(conn, config, relation, media)
      _ -> {:error, :method_not_allowed}
    end
  end

  # ---- INSERT --------------------------------------------------------------

  defp insert(conn, config, relation, media) do
    with {:ok, plan} <- ActionController.parse(conn, config),
         {:ok, rows} <- parse_body(conn, plan),
         {:ok, columns} <- resolve_columns(plan, rows, relation) do
      pref = preferences(conn, relation, plan)

      if rows == [] do
        # Empty payload: insert nothing. `isInsertIfGTZero` only degrades to 200
        # for a merge-duplicates upsert (Response.hs#L104-L109); every other
        # zero-row insert — plain or ignore-duplicates — stays 201.
        respond_empty_set(conn, media, pref, insert_status(pref, true))
      else
        {sql, params} = insert_sql(relation, columns, rows, plan, pref)
        mutation = insert_mutation(relation, plan, pref, rows)
        write = write(config, relation, plan, media, pref, mutation, 201)
        run(conn, write, sql, params)
      end
    end
  end

  # A plain insert is tagged `:insert`. An upsert (resolution honored) is tagged
  # `{:upsert, conflict_cols, rows}` so `run/10` can detect whether every row
  # already existed (=> 200 instead of 201).
  defp insert_mutation(relation, plan, %{resolution: res}, rows) when res != nil do
    {:upsert, conflict_columns(relation, plan), rows}
  end

  defp insert_mutation(_relation, _plan, _pref, _rows), do: :insert

  # ---- UPDATE --------------------------------------------------------------

  defp update(conn, config, relation, media) do
    with {:ok, plan} <- ActionController.parse(conn, config),
         {:ok, rows} <- parse_body(conn, plan),
         {:ok, columns} <- resolve_columns(plan, rows, relation) do
      pref = preferences(conn, relation, plan)
      row = single_row(rows)

      # An empty object body (no columns) is a no-op: PostgREST returns 204 with
      # Content-Range */* and runs no UPDATE.
      if columns == [] do
        respond_empty_update(conn, pref)
      else
        {set_sql, params} = set_clause(columns, row, relation, pref.missing)
        {where_sql, params} = where_clause(plan.filters, relation, params)

        sql = "UPDATE #{qrel(relation)} SET #{set_sql}#{where_sql} RETURNING *"
        run(conn, write(config, relation, plan, media, pref, :update, 200), sql, params)
      end
    end
  end

  # ---- DELETE --------------------------------------------------------------

  defp delete(conn, config, relation, media) do
    with {:ok, plan} <- ActionController.parse(conn, config) do
      pref = preferences(conn, relation, plan)
      {where_sql, params} = where_clause(plan.filters, relation, [])
      sql = "DELETE FROM #{qrel(relation)}#{where_sql} RETURNING *"
      run(conn, write(config, relation, plan, media, pref, :delete, 200), sql, params)
    end
  end

  # ---- PUT (single-row upsert) ---------------------------------------------

  defp put(conn, config, relation, media) do
    with {:ok, plan} <- ActionController.parse(conn, config),
         :ok <- validate_put(plan, relation),
         {:ok, rows} <- parse_body(conn, plan),
         {:ok, columns} <- resolve_columns(plan, rows, relation),
         {:ok, row} <- put_row(plan, rows, relation) do
      pref = preferences(conn, relation, plan)
      pk = relation.primary_key

      {sql, params} = upsert_sql(relation, columns, [row], pk, pref)
      write = write(config, relation, plan, media, pref, {:put, row, pk}, 200)
      run(conn, write, sql, params)
    end
  end

  # PUT requires the filter to be exactly the PK columns with `eq`, no
  # limit/offset, and the table must have a PK.
  defp validate_put(plan, _relation) when plan.has_limit or plan.has_offset,
    do: {:error, :put_limit_offset}

  defp validate_put(_plan, %{primary_key: []}), do: {:error, :put_pk_filter}

  defp validate_put(plan, %{primary_key: pk}) do
    filter_cols =
      Enum.map(plan.filters, fn
        %{column: col, op: "eq", negate: false, json_path: []} -> col
        _ -> :__bad__
      end)

    if :__bad__ in filter_cols or Enum.sort(filter_cols) != Enum.sort(pk) do
      {:error, :put_pk_filter}
    else
      :ok
    end
  end

  # The row a PUT actually writes.
  #
  # PostgREST does not reject a multi-element payload: `mutatePlanToQuery` hangs
  # the URL's primary-key `eq` filters off the INSERT's own SELECT as
  # `putConditions` (`QueryBuilder.hs#L125`), so payload elements whose key does
  # not match the URL are simply never written. It then requires the statement to
  # have affected exactly one row — `failPut` raises `PutMatchingPkError`
  # (PGRST115) for any other count (`MainTx.hs#L205-L214`). Selecting the single
  # matching element here reproduces both halves: a trailing element for a
  # different key is ignored, while a payload that matches the URL zero times (or
  # more than once) is the PK-mismatch error.
  defp put_row(plan, rows, relation) do
    url_pk = Map.new(plan.filters, fn %{column: col, value: v} -> {col, v} end)

    case Enum.filter(rows, &put_row_matches?(&1, relation.primary_key, url_pk)) do
      [row] -> {:ok, row}
      _none_or_many -> {:error, :put_pk_mismatch}
    end
  end

  defp put_row_matches?(row, pk, url_pk) when is_map(row) do
    Enum.all?(pk, fn col -> same_value?(Map.get(row, col), Map.get(url_pk, col)) end)
  end

  defp put_row_matches?(_row, _pk, _url_pk), do: false

  # The URL filter value is always a string; the payload value is whatever JSON
  # carried, so compare on the rendered text (as the SQL comparison does after
  # the body column is coerced to the PK's type).
  defp same_value?(payload, url), do: text_value(payload) == text_value(url)

  defp text_value(nil), do: ""
  defp text_value(value) when is_binary(value), do: value
  defp text_value(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp text_value(value), do: Bier.json_library().encode!(value)

  # ---- shared execution ----------------------------------------------------

  defp write(config, relation, plan, media, pref, mutation, ok_status) do
    %Write{
      config: config,
      relation: relation,
      plan: plan,
      media: media,
      pref: pref,
      mutation: mutation,
      ok_status: ok_status
    }
  end

  # Run the mutation. We always wrap the RETURNING in a representation query so
  # we can (a) shape the body by &select / embedding and (b) count the mutated
  # rows for Content-Range and the Location header, even for minimal responses.
  #
  # The per-request auth context (role switch + request GUCs + db-pre-request)
  # is applied here exactly as it is for reads (`Bier.QueryExecutor.query_read/5`)
  # and RPC (`Bier.Rpc.exec/4`) — otherwise a write runs as the connecting role
  # with no `request.*` GUCs and no privilege check, a security gap (#73).
  defp run(conn, %Write{} = write, sql, params) do
    conn = Warning.record(conn, write.config, write.plan)
    pool = Bier.Registry.via(write.config.name, Postgrex)
    relations = Bier.SchemaCache.relations(write.config.name)
    context = conn.assigns[:bier_auth]

    {:ok, wrapped, wparams} =
      Bier.ServerTiming.measure(:plan, fn ->
        QueryExecutor.build_representation(write.relation, write.plan, relations, {sql, params},
          format: MediaType.executor_format(write.media)
        )
      end)

    result =
      Bier.Cancellation.run(conn, write.config, fn ->
        Bier.ServerTiming.measure(:transaction, fn ->
          Postgrex.transaction(pool, fn tx ->
            run_execute(tx, context, write, wrapped, wparams)
          end)
        end)
      end)

    case result do
      {:ok, outcome} -> respond(conn, write, outcome)
      {:error, {:bier_rollback_ok, outcome}} -> respond(conn, write, outcome)
      {:error, :client_disconnected} = err -> err
      {:error, reason} -> map_write_error(context, reason)
    end
  end

  # No auth configured for this request's schema: run the write as the
  # connecting role, unchanged.
  defp run_execute(tx, nil, write, wrapped, wparams),
    do: execute(tx, write, wrapped, wparams)

  # Auth configured: apply the role switch, request GUCs, and db-pre-request
  # hook before the write (mirrors `Bier.Auth.with_context/4` on the read/RPC
  # paths).
  defp run_execute(tx, context, write, wrapped, wparams) do
    Bier.Auth.with_context(tx, context, write.config, fn tx ->
      execute(tx, write, wrapped, wparams)
    end)
  end

  # `execute/4` threads the FULL `{:error, _}` tuple into `Postgrex.rollback/2`
  # (so the no-context path below can return `reason` unchanged as an
  # already-correctly-shaped `{:error, …}` term for `FallbackController`), so a
  # write-query failure surfaces here double-wrapped: `{:error,
  # %Postgrex.Error{}}`. A failure during the auth-context setup itself (role
  # switch / db-pre-request, raised from `Bier.Auth.with_context/4`) is NOT
  # double-wrapped. Match both shapes so an anonymous `42501` maps to 401
  # (mirroring the read/RPC paths) regardless of where in the transaction it
  # originated; anything else (including a Postgrex error with no auth
  # context) passes through unchanged.
  defp map_write_error(context, {:error, %Postgrex.Error{} = err}) when context != nil,
    do: Bier.Auth.map_error(context, err)

  defp map_write_error(context, %Postgrex.Error{} = err) when context != nil,
    do: Bier.Auth.map_error(context, err)

  defp map_write_error(_context, reason), do: reason

  # Run the wrapped representation query inside the per-request transaction and
  # collect the response payload: body/count/meta from the CTE, the PUT/upsert
  # pre-existence flag, and the response GUCs.
  defp execute(tx, %Write{} = write, wrapped, wparams) do
    # pg-safeupdate parity: when this table is configured "safe", an UPDATE
    # or DELETE without a filter must raise 21000.
    maybe_enable_safeupdate(tx, write)

    # For PUT, distinguish insert (201) from replace (200) by whether the PK
    # already existed before the upsert.
    existed = put_existed?(tx, write.relation, write.mutation)

    # The request's main statement (log-query); the safeupdate guard and the
    # PUT-existence probe above are internal bookkeeping and stay unlogged.
    Bier.RequestLog.record(wrapped)

    case Postgrex.query(tx, wrapped, wparams) do
      {:ok, %Postgrex.Result{rows: [[body, count, meta]]}} ->
        count = count || 0

        with :ok <- enforce_max_affected(write.pref, count),
             :ok <- enforce_singular(write.media, body),
             # Read any response.headers / response.status GUC an INSTEAD OF
             # trigger set during the write, BEFORE the transaction ends
             # (the GUCs are transaction-local; a rollback would discard them).
             {:ok, guc} <- Bier.Guc.read(tx) do
          # The response is fully computed inside the transaction (the CTE's
          # RETURNING is already serialized into `body`). Under db-tx-end
          # :rollback we abort the transaction here, discarding the write but
          # returning the same response — see the conformance harness's
          # base_opts/0 (db_tx_end: :rollback) for why.
          outcome = %{body: body, count: count, meta: meta, existed: existed, guc: guc}
          finish_tx(tx, write.config, outcome)
        else
          {:error, _} = err -> Postgrex.rollback(tx, err)
        end

      {:error, _} = err ->
        Postgrex.rollback(tx, err)
    end
  end

  # End the per-request transaction. Under db-tx-end :rollback we abort it (the
  # response is already computed), so the write never persists; the transaction
  # then returns `{:error, {:bier_rollback_ok, payload}}`, handled above. Under
  # :commit we return the payload normally and the transaction commits.
  defp finish_tx(tx, %{db_tx_end: :rollback}, payload),
    do: Postgrex.rollback(tx, {:bier_rollback_ok, payload})

  defp finish_tx(_tx, _config, payload), do: payload

  # pg-safeupdate: tables whose name is in `config.db_safe_update_tables` get the
  # safeupdate guard for this transaction, so a filterless UPDATE/DELETE raises
  # SQLSTATE 21000 ("UPDATE/DELETE requires a WHERE clause"). We emulate the
  # extension with a session GUC check rather than loading it.
  defp maybe_enable_safeupdate(tx, %Write{config: config, relation: relation, plan: plan} = write) do
    kind = mutation_kind(write.mutation)

    if kind in [:update, :delete] and relation.name in safe_tables(config) and
         plan.filters == [] do
      verb = if kind == :delete, do: "DELETE", else: "UPDATE"
      raise_safeupdate(tx, verb)
    end

    :ok
  end

  defp raise_safeupdate(tx, verb) do
    sql = """
    DO $$ BEGIN
      RAISE SQLSTATE '21000' USING MESSAGE = '#{verb} requires a WHERE clause';
    END $$;
    """

    case Postgrex.query(tx, sql, []) do
      {:error, err} -> Postgrex.rollback(tx, {:error, err})
      _ -> :ok
    end
  end

  defp safe_tables(%{db_safe_update_tables: tables}) when is_list(tables), do: tables
  defp safe_tables(_config), do: []

  # Pre-existence check for PUT: the single-row case of the upsert check.
  defp put_existed?(tx, relation, {:put, row, pk}), do: all_rows_exist?(tx, relation, pk, [row])

  # Pre-existence check for a POST upsert: true only when EVERY row's conflict
  # key already exists (so nothing is inserted and the status is 200).
  defp put_existed?(_tx, _relation, {:upsert, [], _rows}), do: false

  defp put_existed?(tx, relation, {:upsert, conflict_cols, rows}) do
    all_rows_exist?(tx, relation, conflict_cols, rows)
  end

  defp put_existed?(_tx, _relation, _mutation), do: false

  # One round-trip regardless of payload size: expand the payload rows through
  # the same bound-jsonb + typed-extraction path the INSERT uses (so key values
  # coerce exactly as they will on insert) and AND a correlated EXISTS per row.
  # The table gets an explicit alias so `_p._e` can never resolve to it.
  defp all_rows_exist?(tx, relation, cols, rows) do
    predicate =
      Enum.map_join(cols, " AND ", fn col ->
        coltype = column_type(relation, col)
        "_t.#{q(col)} = #{extract_expr(col, coltype, relation, "_p._e")}"
      end)

    sql =
      "SELECT COALESCE(bool_and(EXISTS(" <>
        "SELECT 1 FROM #{qrel(relation)} AS _t WHERE #{predicate}" <>
        ")), false) FROM jsonb_array_elements($1::text::jsonb) AS _p(_e)"

    case Postgrex.query(tx, sql, [Bier.json_library().encode!(rows)]) do
      {:ok, %Postgrex.Result{rows: [[exists]]}} -> exists
      _ -> false
    end
  end

  # Normalize the mutation tag to its base kind.
  defp mutation_kind({:put, _row, _pk}), do: :put
  defp mutation_kind({:upsert, _cols, _rows}), do: :insert
  defp mutation_kind(kind), do: kind

  # max-affected (PGRST124): with handling=strict and a max-affected cap, a
  # mutation affecting more rows than the cap is rejected (transaction rolled
  # back). handling=lenient (or no handling) ignores the cap.
  defp enforce_max_affected(%{handling: :strict, max_affected: cap}, count)
       when is_integer(cap) and count > cap do
    {:error, {:max_affected, count}}
  end

  defp enforce_max_affected(_pref, _count), do: :ok

  # Zero-row response without running SQL (empty payload). PostgREST still
  # emits the insert-style Content-Range (`*/*`, or `*/0` under count=exact) on
  # this short-circuit — live-verified against 14.12.
  defp respond_empty_set(conn, media, pref, status) do
    conn
    |> put_pref_applied(pref)
    |> put_resp_header("content-type", MediaType.content_type(media))
    |> put_resp_header("content-range", "*/#{total_part(pref, 0)}")
    |> send_resp(status, empty_set_body(media))
  end

  # PostgREST renders geo+json bodies in SQL via json_build_object, whose
  # spaced output is part of the wire format; the empty-set short-circuit
  # must emit the same bytes (verified against live PostgREST 14.12).
  defp empty_set_body(%MediaType{symbol: :geojson}),
    do: ~s({"type" : "FeatureCollection", "features" : []})

  defp empty_set_body(_media), do: "[]"

  # Empty-object PATCH: no-op, 204, Content-Range */*, no body.
  defp respond_empty_update(conn, pref) do
    conn
    |> put_pref_applied(pref)
    |> put_resp_header("content-range", "*/*")
    |> send_resp(204, "")
  end

  defp enforce_singular(%MediaType{symbol: :singular}, body) do
    case Bier.json_library().decode(body) do
      {:ok, [_one]} -> :ok
      {:ok, list} when is_list(list) -> {:error, {:not_singular, length(list)}}
      _ -> :ok
    end
  end

  defp enforce_singular(_media, _body), do: :ok

  # ---- response shaping ----------------------------------------------------

  # PostgREST has ONE `actionResponse` clause per mutation kind
  # (`Response.hs#L85-L173`) and they differ in more than the body:
  #
  #   * only `MutationCreate` can emit a Location, and it prepends
  #     `Content-Length` to EVERY arm, including the empty ones (#L116);
  #   * `MutationSingleUpsert` (PUT) emits no `Content-Range` at all and its
  #     empty arm carries the `Preference-Applied` header ALONE (#L153-L154);
  #   * `MutationUpdate` / `MutationDelete` keep `Content-Range` on every arm but
  #     add `Content-Length` only on `Just Full` (#L133, #L167).
  #
  # Mirror that split rather than folding the four kinds into one builder.
  defp respond(conn, %Write{} = write, outcome) do
    case mutation_kind(write.mutation) do
      :insert -> respond_insert(conn, write, outcome)
      :update -> respond_update(conn, write, outcome)
      :delete -> respond_delete(conn, write, outcome)
      :put -> respond_put(conn, write, outcome)
    end
  end

  defp respond_insert(conn, %Write{pref: pref} = write, outcome) do
    %{count: count, meta: meta, existed: existed, guc: guc} = outcome

    conn
    |> Bier.Guc.put_headers(guc)
    |> put_insert_location(write.relation, pref, count, meta, guc)
    |> put_resp_header("content-range", "*/#{total_part(pref, count)}")
    |> put_pref_applied(pref)
    |> finish(write, outcome, Bier.Guc.status(guc, insert_status(pref, existed)), :always)
  end

  defp respond_update(conn, %Write{pref: pref} = write, outcome) do
    %{count: count, guc: guc} = outcome

    conn
    |> Bier.Guc.put_headers(guc)
    |> put_resp_header("content-range", update_range(count, pref))
    |> put_pref_applied(pref)
    |> finish(write, outcome, Bier.Guc.status(guc, full_or_204(pref, 200)), :full_only)
  end

  defp respond_delete(conn, %Write{pref: pref} = write, outcome) do
    %{count: count, guc: guc} = outcome

    conn
    |> Bier.Guc.put_headers(guc)
    |> put_resp_header("content-range", "*/#{total_part(pref, count)}")
    |> put_pref_applied(pref)
    |> finish(write, outcome, Bier.Guc.status(guc, full_or_204(pref, 200)), :full_only)
  end

  defp respond_put(conn, %Write{pref: pref} = write, outcome) do
    %{existed: existed, guc: guc} = outcome
    full_status = if existed, do: 200, else: 201

    conn
    |> Bier.Guc.put_headers(guc)
    |> put_pref_applied(pref)
    |> finish(write, outcome, Bier.Guc.status(guc, full_or_204(pref, full_status)), :full_only)
  end

  # The shared tail of all four clauses: `Just Full` renders the (shaped) rows
  # and adds Content-Type + Content-Length; every other representation sends an
  # empty body. `content_length` says whether the EMPTY arms still carry
  # `Content-Length: 0` — only `MutationCreate` does.
  defp finish(conn, %Write{pref: %{return: :representation}} = write, outcome, status, _cl) do
    columns = ActionController.csv_columns(write.plan, write.relation)

    case Render.render(write.media, outcome.body, columns: columns) do
      {:ok, payload} ->
        conn
        |> put_resp_header("content-type", MediaType.content_type(write.media))
        |> put_resp_header("content-length", Integer.to_string(:erlang.iolist_size(payload)))
        |> send_resp(status, payload)

      {:error, _} = err ->
        err
    end
  end

  defp finish(conn, _write, _outcome, status, :always) do
    conn
    |> put_resp_header("content-length", "0")
    |> send_resp(status, "")
  end

  defp finish(conn, _write, _outcome, status, :full_only), do: send_resp(conn, status, "")

  # `MutationCreate` degrades to 200 in exactly ONE case: a merge-duplicates
  # upsert that inserted nothing. `isInsertIfGTZero` tests
  # `preferResolution == Just MergeDuplicates` (`Response.hs#L104-L109`), so an
  # ignore-duplicates upsert stays 201 even when every row conflicted, and so
  # does a plain insert of zero rows.
  defp insert_status(%{resolution: :merge}, true), do: 200
  defp insert_status(_pref, _nothing_inserted?), do: 201

  # PATCH/PUT/DELETE answer 204 on every arm but `Just Full`
  # (`Response.hs#L134-L135`, #L153-L154, #L168-L169) — `return=headers-only` is
  # NOT special-cased there, it falls into the same catch-all as `return=minimal`.
  defp full_or_204(%{return: :representation}, full_status), do: full_status
  defp full_or_204(_pref, _full_status), do: 204

  # Content-Range: `MutationUpdate` reports a read-style range over the mutated
  # rows (`contentRangeH 0 (rsQueryTotal - 1)`, `Response.hs#L123`); insert and
  # delete use the `1 0` base, which always renders as `*` (#L100, #L161).
  defp update_range(count, pref) when count > 0,
    do: "0-#{count - 1}/#{total_part(pref, count)}"

  defp update_range(count, pref), do: "*/#{total_part(pref, count)}"

  defp total_part(%{count: :exact}, count), do: Integer.to_string(count)
  defp total_part(_pref, _count), do: "*"

  # Location, from the mutated row's PK. `locF` builds one only for an INSERT
  # with `return=headers-only`, and wraps it in
  # `CASE WHEN pg_catalog.count(_postgrest_t) = 1 THEN … ELSE <no location> END`
  # (`Statements.hs#L45-L52`) — a bulk insert evaluates the ELSE arm, so no
  # Location is emitted for anything but a single created row. A
  # trigger-supplied `response.headers` Location (already on `conn`) wins.
  defp put_insert_location(conn, relation, %{return: :headers_only}, 1, meta, guc) do
    with false <- guc_location?(guc),
         values when is_map(values) <- pk_values(meta) do
      query =
        Enum.map_join(relation.primary_key, "&", fn col ->
          "#{col}=eq.#{Map.get(values, col)}"
        end)

      put_resp_header(conn, "location", "/#{relation.name}?#{query}")
    else
      _ -> conn
    end
  end

  defp put_insert_location(conn, _relation, _pref, _count, _meta, _guc), do: conn

  # True when the response.headers GUC supplied a Location header.
  defp guc_location?(%{headers: headers}) when is_list(headers) do
    Enum.any?(headers, fn {name, _v} -> String.downcase(name) == "location" end)
  end

  defp guc_location?(_), do: false

  defp pk_values(nil), do: nil

  defp pk_values(meta) when is_binary(meta) do
    case Bier.json_library().decode(meta) do
      {:ok, map} when is_map(map) -> map
      _ -> nil
    end
  end

  defp pk_values(_), do: nil

  # Echo the recognized Prefer tokens that were honored, in PostgREST's canonical
  # order (not request order).
  defp put_pref_applied(conn, %{applied: []}), do: conn

  defp put_pref_applied(conn, %{applied: tokens}) do
    put_resp_header(conn, "preference-applied", Enum.join(tokens, ", "))
  end

  # ---- preferences ---------------------------------------------------------

  # Each recognized `Prefer` token, keyed by the internal value it parses to.
  # The same tables drive both parsing (token -> value) and the
  # `Preference-Applied` echo (value -> token).
  @handling_tokens [strict: "handling=strict", lenient: "handling=lenient"]
  @resolution_tokens [
    merge: "resolution=merge-duplicates",
    ignore: "resolution=ignore-duplicates"
  ]
  @missing_tokens [default: "missing=default", null: "missing=null"]
  @count_tokens [exact: "count=exact", planned: "count=planned", estimated: "count=estimated"]
  @return_tokens [
    representation: "return=representation",
    headers_only: "return=headers-only",
    minimal: "return=minimal"
  ]

  # Parse `Prefer` into the response-affecting bits plus the ordered list of
  # honored tokens to echo via Preference-Applied. `relation` is needed to decide
  # whether an upsert resolution is honored (only when the table has a PK).
  defp preferences(conn, relation, plan) do
    raw = conn |> get_req_header("prefer") |> Enum.flat_map(&split_prefer/1)

    # A table with no PK (and no explicit `?on_conflict=`) silently ignores the
    # resolution preference — there is no conflict target to upsert on.
    has_conflict_target? =
      relation.primary_key != [] or is_list(plan[:on_conflict])

    resolution =
      if has_conflict_target?, do: parse_pref(raw, @resolution_tokens)

    pref = %{
      return: parse_pref(raw, @return_tokens) || :none,
      resolution: resolution,
      count: parse_pref(raw, @count_tokens),
      handling: parse_pref(raw, @handling_tokens),
      missing: parse_pref(raw, @missing_tokens),
      max_affected: parse_max_affected(raw)
    }

    Map.put(pref, :applied, applied_tokens(pref))
  end

  # `parsePrefs` walks the REQUEST tokens in order and returns the first that is
  # a known value for this preference — `head $ mapMaybe (flip Map.lookup $
  # prefMap vals) prefs` (`Preferences.hs#L165-L167`). So when a client repeats a
  # key the FIRST occurrence in the header wins ("If a preference is set more
  # than once, only the first is used", `Preferences.hs#L98-L111`), never the
  # order of the internal constructor list: `return=minimal, return=representation`
  # resolves to minimal even though `Full` is listed first upstream.
  defp parse_pref(raw, tokens) do
    values = Map.new(tokens, fn {value, token} -> {token, value} end)
    Enum.find_value(raw, &Map.get(values, &1))
  end

  defp parse_max_affected(raw) do
    Enum.find_value(raw, fn token ->
      with "max-affected=" <> n <- token,
           {v, ""} <- Integer.parse(n) do
        v
      else
        _ -> nil
      end
    end)
  end

  # Build the Preference-Applied token list in PostgREST's canonical `prefsVals`
  # order — resolution, missing, representation, count, transaction, handling,
  # timezone, max-affected (`Preferences.hs#L179-L188`) — never request order.
  # max-affected is echoed only with handling=strict (lenient drops it).
  defp applied_tokens(pref) do
    [
      applied_token(@resolution_tokens, pref.resolution),
      applied_token(@missing_tokens, pref.missing),
      applied_token(@return_tokens, pref.return),
      applied_token(@count_tokens, pref.count),
      applied_token(@handling_tokens, pref.handling),
      max_affected_token(pref.handling, pref.max_affected)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp applied_token(_tokens, nil), do: nil
  defp applied_token(tokens, value), do: Keyword.get(tokens, value)

  defp max_affected_token(:strict, n) when is_integer(n), do: "max-affected=#{n}"
  defp max_affected_token(_handling, _n), do: nil

  defp split_prefer(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # ---- body parsing --------------------------------------------------------

  # Returns `{:ok, rows}` (a list of JSON objects) or an error tagging the kind
  # of parse failure (PGRST102 family). With an explicit `?columns=` the payload
  # keys are not validated for uniformity (extra/missing keys are ignored).
  defp parse_body(conn, plan) do
    raw = conn.assigns[:bier_raw_body] || ""

    cond do
      content_type?(conn, "text/csv") -> parse_csv(raw)
      content_type?(conn, "application/x-www-form-urlencoded") -> parse_form_body(raw)
      true -> parse_json_body(raw, is_list(plan[:columns]))
    end
  end

  defp content_type?(conn, mime) do
    case get_req_header(conn, "content-type") do
      [value | _] -> String.contains?(String.downcase(value), mime)
      [] -> false
    end
  end

  # An `application/x-www-form-urlencoded` body (an HTML form POST) is ONE row
  # whose field names are the column names and whose values are all JSON strings:
  # `getPayload`'s MTUrlEncoded arm builds `HM.fromList $ (identity *** JSON.String)
  # <$> parseSimpleQuery reqBody` and takes the map's keys as the target columns
  # (`Payload.hs`). `parseSimpleQuery` decodes `+` to a space and resolves percent
  # escapes, and the HashMap keeps the last value of a repeated field — which is
  # exactly `URI.decode_query/1`.
  defp parse_form_body(raw) do
    {:ok, [URI.decode_query(raw)]}
  rescue
    ArgumentError -> {:error, :invalid_json}
  end

  defp parse_csv(""), do: {:error, :invalid_json}

  defp parse_csv(raw) do
    lines =
      raw
      |> String.replace("\r\n", "\n")
      |> String.trim_trailing("\n")
      |> String.split("\n")

    case lines do
      [header | data] -> csv_rows(split_csv_line(header), Enum.map(data, &split_csv_line/1))
      [] -> {:error, :ragged_csv}
    end
  end

  # Zip each data line against the header columns; every line must have exactly
  # as many fields as the header (PGRST102 otherwise).
  defp csv_rows(columns, lines) do
    width = length(columns)

    if Enum.all?(lines, &(length(&1) == width)) do
      {:ok, Enum.map(lines, &csv_row(columns, &1))}
    else
      {:error, :ragged_csv}
    end
  end

  defp csv_row(columns, fields) do
    columns
    |> Enum.zip(fields)
    |> Map.new(fn {c, v} -> {c, csv_value(v)} end)
  end

  defp csv_value("NULL"), do: nil
  defp csv_value(v), do: v

  defp split_csv_line(line), do: line |> String.split(",") |> Enum.map(&String.trim/1)

  # An EMPTY body is not an empty object: `getPayload` runs the raw bytes through
  # `JSON.decode`, and `maybe (Left "Empty or invalid json") Right $ JSON.decode
  # reqBody` (`Payload.hs`) turns the failure into the same generic PGRST102 a
  # malformed body gets. Only an RPC invocation substitutes `{}` for an empty
  # body (the `LBS.null reqBody && isProc` guard), and that path lives in
  # `Bier.Rpc`.
  defp parse_json_body("", _has_columns?), do: {:error, :invalid_json}

  defp parse_json_body(raw, has_columns?) do
    case Bier.json_library().decode(raw) do
      {:ok, obj} when is_map(obj) ->
        {:ok, [obj]}

      {:ok, list} when is_list(list) ->
        if has_columns? or uniform_keys?(list) do
          {:ok, list}
        else
          {:error, :non_uniform}
        end

      _ ->
        {:error, :invalid_json}
    end
  end

  # Every object in a bulk array must share the same set of keys (PGRST102).
  defp uniform_keys?([]), do: true
  defp uniform_keys?([_one]), do: true

  defp uniform_keys?([first | rest]) do
    keys = first |> Map.keys() |> MapSet.new()
    Enum.all?(rest, fn row -> is_map(row) and MapSet.new(Map.keys(row)) == keys end)
  end

  defp single_row([row | _]), do: row
  defp single_row(_), do: %{}

  # ---- column resolution ---------------------------------------------------

  # Determine the target columns for a write. With `?columns=` the listed
  # columns are used (payload keys not listed are ignored); each must exist on
  # the relation or it is a PGRST204 error. Without it, the payload keys are the
  # columns (and each must exist).
  defp resolve_columns(%{columns: cols}, _rows, relation) when is_list(cols) do
    validate_columns(cols, relation)
  end

  defp resolve_columns(_plan, [], _relation), do: {:ok, []}

  defp resolve_columns(_plan, rows, relation) do
    cols =
      rows
      |> Enum.reduce([], fn row, acc ->
        keys = if is_map(row), do: Map.keys(row), else: []
        acc ++ Enum.reject(keys, &(&1 in acc))
      end)

    validate_columns(cols, relation)
  end

  defp validate_columns(cols, relation) do
    known = MapSet.new(relation.columns, & &1.name)

    case Enum.find(cols, &(not MapSet.member?(known, &1))) do
      nil -> {:ok, cols}
      bad -> {:error, {:unknown_column, bad, relation.name}}
    end
  end

  # ---- SQL building --------------------------------------------------------

  # INSERT from a JSON payload. Values flow through one bound `jsonb` parameter
  # expanded per-row, so text like `"{1,2,3}"` coerces to typed columns.
  defp insert_sql(relation, [], _rows, _plan, _pref) do
    {"INSERT INTO #{qrel(relation)} DEFAULT VALUES RETURNING *", []}
  end

  defp insert_sql(relation, columns, rows, plan, pref) do
    cols = Enum.map_join(columns, ", ", &q/1)
    select_exprs = row_select_exprs(columns, relation, pref.missing)

    source = "jsonb_array_elements($1::text::jsonb) AS _e"
    payload = Bier.json_library().encode!(rows)

    conflict = on_conflict(relation, columns, plan, pref.resolution)

    sql =
      "INSERT INTO #{qrel(relation)} (#{cols}) " <>
        "SELECT #{select_exprs} FROM #{source}#{conflict} RETURNING *"

    {sql, [payload]}
  end

  # PUT / multi-row keyed upsert from a JSON payload.
  defp upsert_sql(relation, columns, rows, pk, pref) do
    cols = Enum.map_join(columns, ", ", &q/1)
    select_exprs = row_select_exprs(columns, relation, pref.missing)
    payload = Bier.json_library().encode!(rows)

    target = Enum.map_join(pk, ", ", &q/1)
    updates = update_set_excluded(columns, pk)

    sql =
      "INSERT INTO #{qrel(relation)} (#{cols}) " <>
        "SELECT #{select_exprs} FROM jsonb_array_elements($1::text::jsonb) AS _e " <>
        "ON CONFLICT (#{target}) DO UPDATE SET #{updates} RETURNING *"

    {sql, [payload]}
  end

  # The SELECT-list extracting each target column from the jsonb element `_e`.
  defp row_select_exprs(columns, relation, missing) do
    Enum.map_join(columns, ", ", &column_value_expr(&1, relation, missing, "_e"))
  end

  # The value written to `col`, read out of the jsonb source `src`. json/jsonb
  # columns keep their JSON structure (`->`); everything else is pulled as text
  # (`->>`) and cast to the column type so Postgres parses arrays/numbers/etc.
  #
  # `missing=default` substitutes the column DEFAULT for a key the payload omits.
  # `applyDefaults` is threaded into `fromJsonBodyF` for the Update plan exactly
  # as it is for Insert (`QueryBuilder.hs#L123` vs #L153), so the preference is
  # not insert-only: a PATCH whose `?columns=` names a column the JSON object
  # leaves out writes that column's DEFAULT rather than NULL.
  defp column_value_expr(col, relation, missing, src) do
    value_expr = extract_expr(col, column_type(relation, col), relation, src)

    case missing do
      :default ->
        default = column_default(relation, col) || "NULL"
        "CASE WHEN #{src} ? #{pg_literal(col)} THEN #{value_expr} ELSE #{default} END"

      _ ->
        value_expr
    end
  end

  # The expression pulling `col` out of the jsonb source `src` (the per-row
  # element `_e` on INSERT/upsert, the bound payload on UPDATE).
  defp extract_expr(col, type, relation, src) do
    case QueryExecutor.write_rep_fn(relation, col) do
      # A DOMAIN with a `json AS <domain>` cast parses the raw JSON body value
      # through its cast function (cases 1811-1813); a plain `::<domain>` cast
      # would strip the domain to its base type and bypass the parser.
      {schema, name} ->
        "#{q(schema)}.#{q(name)}((#{src} -> #{pg_literal(col)})::json)"

      nil ->
        if json_type?(type) do
          "(#{src} -> #{pg_literal(col)})"
        else
          "(#{src} ->> #{pg_literal(col)})::#{type_cast(type)}"
        end
    end
  end

  defp json_type?(type) when is_binary(type), do: type in ["json", "jsonb"]
  defp json_type?(_), do: false

  defp on_conflict(_relation, _columns, _plan, nil), do: ""

  defp on_conflict(relation, _columns, plan, :ignore) do
    target = conflict_target(relation, plan)
    if target == "", do: " ON CONFLICT DO NOTHING", else: " ON CONFLICT (#{target}) DO NOTHING"
  end

  defp on_conflict(relation, columns, plan, :merge) do
    case conflict_target(relation, plan) do
      "" ->
        ""

      target ->
        target_cols = conflict_columns(relation, plan)
        " ON CONFLICT (#{target}) DO UPDATE SET #{update_set_excluded(columns, target_cols)}"
    end
  end

  # The conflict-target column list: `?on_conflict=` columns when given, else the
  # relation's PK.
  defp conflict_target(relation, plan) do
    conflict_columns(relation, plan) |> Enum.map_join(", ", &q/1)
  end

  defp conflict_columns(_relation, %{on_conflict: cols}) when is_list(cols) and cols != [],
    do: cols

  defp conflict_columns(relation, _plan), do: relation.primary_key

  # SET col = EXCLUDED.col for every inserted column not in the conflict target
  # (or for the target columns themselves when nothing else was inserted).
  defp update_set_excluded(columns, target_cols) do
    columns
    |> Enum.reject(&(&1 in target_cols))
    |> case do
      [] -> target_cols
      cols -> cols
    end
    |> Enum.map_join(", ", fn c -> "#{q(c)} = EXCLUDED.#{q(c)}" end)
  end

  # SET col = <typed value> list for UPDATE; single-object body extracted from
  # one bound jsonb parameter.
  defp set_clause(columns, row, relation, missing) do
    payload = Bier.json_library().encode!(row)

    parts =
      Enum.map_join(columns, ", ", fn col ->
        "#{q(col)} = #{column_value_expr(col, relation, missing, "($1::text::jsonb)")}"
      end)

    {parts, [payload]}
  end

  # WHERE built from the request's column filters, appended after `params`.
  defp where_clause([], _relation, params), do: {"", params}

  defp where_clause(filters, relation, params) do
    state = %QueryExecutor.State{
      relation: relation,
      alias_name: nil,
      params: Enum.reverse(params),
      count: length(params)
    }

    {clauses, state} =
      Enum.map_reduce(filters, state, fn node, st -> QueryExecutor.render_node(node, st) end)

    {" WHERE " <> Enum.join(clauses, " AND "), Enum.reverse(state.params)}
  end

  # ---- helpers -------------------------------------------------------------

  defp column_type(relation, col) do
    case Enum.find(relation.columns, &(&1.name == col)) do
      %{type: type} -> type
      _ -> "text"
    end
  end

  defp column_default(relation, col) do
    case Enum.find(relation.columns, &(&1.name == col)) do
      %{default: default} when is_binary(default) -> default
      _ -> nil
    end
  end

  # A column type validated for use in a `::cast`. Types come from introspection
  # (`format_type(atttypid, atttypmod)`), so they are trusted (never
  # user-supplied), but we still constrain the charset defensively. Unlike
  # `QueryExecutor.quote_type/1` — which guards the *user-controlled*
  # `?select=col::type` cast (case 1805) and must reject `(`/`)`/`,` to stay
  # injection-safe — introspected types legitimately carry typmod syntax
  # (`numeric(10,2)`, `geometry(Point,4326)`), so those characters are allowed
  # here.
  defp type_cast(type) do
    if Regex.match?(~r/^[A-Za-z0-9_ \[\]\".,()]+$/, type) do
      type
    else
      throw({:bad_request, :bad_cast})
    end
  end

  defp qrel(relation), do: QueryExecutor.qrel(relation)
  defp q(ident), do: QueryExecutor.quote_ident(ident)
  defp pg_literal(str), do: QueryExecutor.pg_literal(str)
end
