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
  alias Bier.QueryExecutor
  alias Bier.Render

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

      cond do
        rows == [] ->
          # Empty payload: insert nothing. Status 200 when an upsert resolution
          # was requested, 201 otherwise (a plain bulk insert of zero rows).
          status = if pref.resolution != nil, do: 200, else: 201
          respond_empty_set(conn, media, pref, status)

        true ->
          {sql, params} = insert_sql(relation, columns, rows, plan, pref)
          mutation = insert_mutation(relation, plan, pref, rows)
          run(conn, config, relation, plan, media, pref, sql, params, mutation, 201)
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
        {set_sql, params} = set_clause(columns, row, relation)
        {where_sql, params} = where_clause(plan.filters, relation, params)

        sql = "UPDATE #{qrel(relation)} SET #{set_sql}#{where_sql} RETURNING *"
        run(conn, config, relation, plan, media, pref, sql, params, :update, 200)
      end
    end
  end

  # ---- DELETE --------------------------------------------------------------

  defp delete(conn, config, relation, media) do
    with {:ok, plan} <- ActionController.parse(conn, config) do
      pref = preferences(conn, relation, plan)
      {where_sql, params} = where_clause(plan.filters, relation, [])
      sql = "DELETE FROM #{qrel(relation)}#{where_sql} RETURNING *"
      run(conn, config, relation, plan, media, pref, sql, params, :delete, 200)
    end
  end

  # ---- PUT (single-row upsert) ---------------------------------------------

  defp put(conn, config, relation, media) do
    with {:ok, plan} <- ActionController.parse(conn, config),
         :ok <- validate_put(plan, relation),
         {:ok, rows} <- parse_body(conn, plan),
         {:ok, columns} <- resolve_columns(plan, rows, relation),
         :ok <- validate_put_payload(plan, rows, relation) do
      pref = preferences(conn, relation, plan)
      pk = relation.primary_key
      [row] = rows

      {sql, params} = upsert_sql(relation, columns, [row], pk, pref)
      run(conn, config, relation, plan, media, pref, sql, params, {:put, row, pk}, 200)
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

  # The payload's PK values must equal the URL's PK filter values.
  defp validate_put_payload(plan, [row], relation) do
    url_pk =
      Map.new(plan.filters, fn %{column: col, value: v} -> {col, v} end)

    matches? =
      Enum.all?(relation.primary_key, fn col ->
        to_string(Map.get(row, col)) == to_string(Map.get(url_pk, col))
      end)

    if matches?, do: :ok, else: {:error, :put_pk_mismatch}
  end

  defp validate_put_payload(_plan, _rows, _relation), do: :ok

  # ---- shared execution ----------------------------------------------------

  # Run the mutation. We always wrap the RETURNING in a representation query so
  # we can (a) shape the body by &select / embedding and (b) count the mutated
  # rows for Content-Range and the Location header, even for minimal responses.
  defp run(conn, config, relation, plan, media, pref, sql, params, mutation, ok_status) do
    pool = Bier.Registry.via(config.name, Postgrex)
    relations = :persistent_term.get({Bier, :relations, config.name}, %{})

    {:ok, wrapped, wparams} =
      Bier.ServerTiming.measure(:plan, fn ->
        QueryExecutor.build_representation(relation, plan, relations, {sql, params})
      end)

    result =
      Bier.ServerTiming.measure(:transaction, fn ->
        Postgrex.transaction(pool, fn tx ->
          # pg-safeupdate parity: when this table is configured "safe", an UPDATE
          # or DELETE without a filter must raise 21000.
          maybe_enable_safeupdate(tx, config, relation, mutation, plan)

          # For PUT, distinguish insert (201) from replace (200) by whether the PK
          # already existed before the upsert.
          existed = put_existed?(tx, relation, mutation)

          case Postgrex.query(tx, wrapped, wparams) do
            {:ok, %Postgrex.Result{rows: [[body, count, meta]]}} ->
              count = count || 0

              with :ok <- enforce_max_affected(pref, count),
                   :ok <- enforce_singular(media, body),
                   # Read any response.headers / response.status GUC an INSTEAD OF
                   # trigger set during the write, BEFORE the transaction ends
                   # (the GUCs are transaction-local; a rollback would discard them).
                   {:ok, guc} <- Bier.Guc.read(tx) do
                # The response is fully computed inside the transaction (the CTE's
                # RETURNING is already serialized into `body`). Under db-tx-end
                # :rollback we abort the transaction here, discarding the write but
                # returning the same response — see the conformance harness's
                # base_opts/0 (db_tx_end: :rollback) for why.
                finish_tx(tx, config, {body, count, meta, existed, guc})
              else
                {:error, _} = err -> Postgrex.rollback(tx, err)
              end

            {:error, _} = err ->
              Postgrex.rollback(tx, err)
          end
        end)
      end)

    case result do
      {:ok, payload} ->
        respond_payload(conn, payload, relation, plan, media, pref, mutation, ok_status)

      {:error, {:bier_rollback_ok, payload}} ->
        respond_payload(conn, payload, relation, plan, media, pref, mutation, ok_status)

      {:error, reason} ->
        reason
    end
  end

  defp respond_payload(
         conn,
         {body, count, meta, existed, guc},
         relation,
         plan,
         media,
         pref,
         mutation,
         ok
       ) do
    conn = Bier.Guc.put_headers(conn, guc)
    respond(conn, body, count, meta, existed, relation, plan, media, pref, mutation, ok, guc)
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
  defp maybe_enable_safeupdate(tx, config, relation, mutation, plan) do
    kind = mutation_kind(mutation)

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

  # Pre-existence check for PUT: SELECT EXISTS over the PK predicate.
  defp put_existed?(tx, relation, {:put, row, pk}) do
    {where, params} =
      pk
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {col, i}, {ws, ps} ->
        {["#{q(col)} = $#{i}" | ws], [Map.get(row, col) | ps]}
      end)

    sql =
      "SELECT EXISTS(SELECT 1 FROM #{qrel(relation)} WHERE #{Enum.join(Enum.reverse(where), " AND ")})"

    case Postgrex.query(tx, sql, Enum.reverse(params)) do
      {:ok, %Postgrex.Result{rows: [[exists]]}} -> exists
      _ -> false
    end
  end

  # Pre-existence check for a POST upsert: true only when EVERY row's conflict
  # key already exists (so nothing is inserted and the status is 200).
  defp put_existed?(_tx, _relation, {:upsert, [], _rows}), do: false

  defp put_existed?(tx, relation, {:upsert, conflict_cols, rows}) do
    Enum.all?(rows, fn row ->
      {where, params} =
        conflict_cols
        |> Enum.with_index(1)
        |> Enum.reduce({[], []}, fn {col, i}, {ws, ps} ->
          {["#{q(col)} = $#{i}" | ws], [Map.get(row, col) | ps]}
        end)

      sql =
        "SELECT EXISTS(SELECT 1 FROM #{qrel(relation)} WHERE " <>
          "#{Enum.join(Enum.reverse(where), " AND ")})"

      case Postgrex.query(tx, sql, Enum.reverse(params)) do
        {:ok, %Postgrex.Result{rows: [[exists]]}} -> exists
        _ -> false
      end
    end)
  end

  defp put_existed?(_tx, _relation, _mutation), do: false

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

  # Zero-row response without running SQL (empty payload).
  defp respond_empty_set(conn, media, pref, status) do
    conn
    |> put_pref_applied(pref)
    |> put_resp_header("content-type", MediaType.content_type(media))
    |> send_resp(status, "[]")
  end

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

  # return=representation: emit the (shaped) rows as a body.
  defp respond(
         conn,
         body,
         count,
         meta,
         existed,
         relation,
         plan,
         media,
         %{return: :representation} = pref,
         mutation,
         ok_status,
         guc
       ) do
    kind = mutation_kind(mutation)
    columns = ActionController.csv_columns(plan, relation)

    case Render.render(media, body, columns: columns) do
      {:ok, payload} ->
        status =
          Bier.Guc.status(guc, representation_status(kind, count, existed, ok_status, pref))

        conn
        |> put_pref_applied(pref)
        |> put_resp_header("content-type", MediaType.content_type(media))
        |> maybe_location(kind, relation, plan, meta, guc)
        |> put_content_range(kind, count, pref)
        |> put_resp_header("content-length", Integer.to_string(:erlang.iolist_size(payload)))
        |> send_resp(status, payload)

      {:error, _} = err ->
        err
    end
  end

  # return=headers-only: empty body, but Location header pointing at the row.
  defp respond(
         conn,
         _body,
         count,
         meta,
         existed,
         relation,
         _plan,
         _media,
         %{return: :headers_only} = pref,
         mutation,
         ok_status,
         guc
       ) do
    kind = mutation_kind(mutation)
    status = Bier.Guc.status(guc, empty_status(kind, count, existed, ok_status, pref))

    conn
    |> put_pref_applied(pref)
    |> force_location(kind, relation, meta, guc)
    |> put_content_range(kind, count, pref)
    |> put_resp_header("content-length", "0")
    |> send_resp(status, "")
  end

  # return=minimal / no token: empty body.
  defp respond(
         conn,
         _body,
         count,
         meta,
         existed,
         relation,
         plan,
         _media,
         pref,
         mutation,
         ok_status,
         guc
       ) do
    kind = mutation_kind(mutation)
    status = Bier.Guc.status(guc, empty_status(kind, count, existed, ok_status, pref))

    conn
    |> put_pref_applied(pref)
    |> maybe_location(kind, relation, plan, meta, guc)
    |> put_content_range(kind, count, pref)
    |> put_content_length_for_empty(status)
    |> send_resp(status, "")
  end

  # Status for representation responses: inserts are 201 when at least one row
  # was created (200 for a zero-row upsert); put depends on insert vs replace;
  # updates/deletes are 200.
  # An upsert where every row already existed (nothing inserted) is 200; an
  # upsert/insert that created at least one row is 201.
  defp representation_status(:insert, _count, true, _ok, %{resolution: res}) when res != nil,
    do: 200

  defp representation_status(:insert, count, _existed, _ok, %{resolution: res})
       when count == 0 and res != nil,
       do: 200

  defp representation_status(:insert, _count, _existed, ok, _pref), do: ok

  defp representation_status(:put, _count, existed, _ok, _pref),
    do: if(existed, do: 200, else: 201)

  defp representation_status(_kind, _count, _existed, _ok, _pref), do: 200

  # Status for empty-body responses: inserts are 201; minimal PUT is always 204;
  # other PUT depends on insert vs replace; updates/deletes are 204.
  defp empty_status(:insert, _count, true, _ok, %{resolution: res}) when res != nil, do: 200
  defp empty_status(:insert, _count, _existed, _ok, _pref), do: 201
  defp empty_status(:put, _count, _existed, _ok, %{return: :minimal}), do: 204
  defp empty_status(:put, _count, existed, _ok, _pref), do: if(existed, do: 200, else: 201)
  defp empty_status(_kind, _count, _existed, _ok, _pref), do: 204

  # Content-Range:
  #   * insert / delete / put -> `*/<total>` (total only with count=exact).
  #   * update -> `0-<rows-1>/<total>` (read-style range over mutated rows).
  defp put_content_range(conn, :update, count, pref) do
    range =
      if count > 0 do
        "0-#{count - 1}/#{total_part(pref, count)}"
      else
        "*/#{total_part(pref, count)}"
      end

    put_resp_header(conn, "content-range", range)
  end

  defp put_content_range(conn, _kind, count, pref) do
    put_resp_header(conn, "content-range", "*/#{total_part(pref, count)}")
  end

  defp total_part(%{count: :exact}, count), do: Integer.to_string(count)
  defp total_part(_pref, _count), do: "*"

  # Location for representation/minimal responses: emitted only when the request
  # can determine the full PK — i.e. the relation has a PK and every PK column is
  # present in the selected output (PostgREST omits it otherwise). A
  # response.headers GUC Location set by an INSTEAD OF trigger overrides the
  # computed one, so we skip the computed Location when the GUC already set it.
  defp maybe_location(conn, kind, relation, plan, meta, guc) when kind in [:insert, :put] do
    cond do
      guc_location?(guc) -> conn
      pk_in_select?(relation, plan) -> force_location(conn, kind, relation, meta, guc)
      true -> conn
    end
  end

  defp maybe_location(conn, _kind, _relation, _plan, _meta, _guc), do: conn

  # Location regardless of select (headers-only): from the mutated row's PK. A
  # trigger-supplied response.headers Location (already on `conn`) wins.
  defp force_location(conn, kind, relation, meta, guc) when kind in [:insert, :put] do
    cond do
      guc_location?(guc) ->
        conn

      true ->
        case pk_values(meta) do
          nil ->
            conn

          values ->
            query =
              relation.primary_key
              |> Enum.map(fn col -> "#{col}=eq.#{Map.get(values, col)}" end)
              |> Enum.join("&")

            put_resp_header(conn, "location", "/#{relation.name}?#{query}")
        end
    end
  end

  defp force_location(conn, _kind, _relation, _meta, _guc), do: conn

  # True when the response.headers GUC supplied a Location header.
  defp guc_location?(%{headers: headers}) when is_list(headers) do
    Enum.any?(headers, fn {name, _v} -> String.downcase(name) == "location" end)
  end

  defp guc_location?(_), do: false

  # Every PK column is present in the selected output (or select is `*`).
  defp pk_in_select?(%{primary_key: []}, _plan), do: false
  defp pk_in_select?(_relation, %{select: [:star]}), do: true

  defp pk_in_select?(relation, %{select: fields}) do
    selected =
      fields
      |> Enum.flat_map(fn
        %{kind: :star} -> Enum.map(relation.columns, & &1.name)
        %{kind: :field, column: col, alias: al} -> [al || col]
        %{column: col, alias: al} -> [al || col]
        _ -> []
      end)
      |> MapSet.new()

    Enum.all?(relation.primary_key, &MapSet.member?(selected, &1))
  end

  defp pk_values(nil), do: nil

  defp pk_values(meta) when is_binary(meta) do
    case Bier.json_library().decode(meta) do
      {:ok, map} when is_map(map) -> map
      _ -> nil
    end
  end

  defp pk_values(_), do: nil

  # 201 empty bodies carry Content-Length: 0; 204 carries no Content-Length.
  defp put_content_length_for_empty(conn, 204), do: conn

  defp put_content_length_for_empty(conn, _status),
    do: put_resp_header(conn, "content-length", "0")

  # Echo the recognized Prefer tokens that were honored, in PostgREST's canonical
  # order (not request order).
  defp put_pref_applied(conn, %{applied: []}), do: conn

  defp put_pref_applied(conn, %{applied: tokens}) do
    put_resp_header(conn, "preference-applied", Enum.join(tokens, ", "))
  end

  # ---- preferences ---------------------------------------------------------

  # Parse `Prefer` into the response-affecting bits plus the ordered list of
  # honored tokens to echo via Preference-Applied. `relation` is needed to decide
  # whether an upsert resolution is honored (only when the table has a PK).
  defp preferences(conn, relation, plan) do
    raw = conn |> get_req_header("prefer") |> Enum.flat_map(&split_prefer/1)

    return =
      cond do
        "return=representation" in raw -> :representation
        "return=headers-only" in raw -> :headers_only
        "return=minimal" in raw -> :minimal
        true -> :none
      end

    resolution =
      cond do
        "resolution=merge-duplicates" in raw -> :merge
        "resolution=ignore-duplicates" in raw -> :ignore
        true -> nil
      end

    # A table with no PK (and no explicit `?on_conflict=`) silently ignores the
    # resolution preference — there is no conflict target to upsert on.
    has_conflict_target? =
      relation.primary_key != [] or is_list(plan[:on_conflict])

    resolution = if has_conflict_target?, do: resolution, else: nil

    count =
      cond do
        "count=exact" in raw -> :exact
        "count=planned" in raw -> :planned
        "count=estimated" in raw -> :estimated
        true -> nil
      end

    handling =
      cond do
        "handling=strict" in raw -> :strict
        "handling=lenient" in raw -> :lenient
        true -> nil
      end

    missing =
      cond do
        "missing=default" in raw -> :default
        "missing=null" in raw -> :null
        true -> nil
      end

    max_affected = parse_max_affected(raw)

    %{
      return: return,
      resolution: resolution,
      count: count,
      handling: handling,
      missing: missing,
      max_affected: max_affected,
      applied: applied_tokens(raw, return, resolution, count, handling, missing, max_affected)
    }
  end

  defp parse_max_affected(raw) do
    Enum.find_value(raw, fn token ->
      case token do
        "max-affected=" <> n ->
          case Integer.parse(n) do
            {v, ""} -> v
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  # Build the Preference-Applied token list in PostgREST's canonical order:
  # handling, resolution, missing, return, count, max-affected. max-affected is
  # echoed only with handling=strict (lenient drops it).
  defp applied_tokens(_raw, return, resolution, count, handling, missing, max_affected) do
    [
      handling_token(handling),
      resolution_token(resolution),
      missing_token(missing),
      return_token(return),
      count_token(count),
      max_affected_token(handling, max_affected)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp handling_token(:strict), do: "handling=strict"
  defp handling_token(:lenient), do: "handling=lenient"
  defp handling_token(_), do: nil

  defp resolution_token(:merge), do: "resolution=merge-duplicates"
  defp resolution_token(:ignore), do: "resolution=ignore-duplicates"
  defp resolution_token(_), do: nil

  defp missing_token(:default), do: "missing=default"
  defp missing_token(:null), do: "missing=null"
  defp missing_token(_), do: nil

  defp return_token(:representation), do: "return=representation"
  defp return_token(:headers_only), do: "return=headers-only"
  defp return_token(:minimal), do: "return=minimal"
  defp return_token(_), do: nil

  defp count_token(:exact), do: "count=exact"
  defp count_token(:planned), do: "count=planned"
  defp count_token(:estimated), do: "count=estimated"
  defp count_token(_), do: nil

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
    has_columns? = is_list(plan[:columns])

    cond do
      csv_content?(conn) -> parse_csv(raw)
      true -> parse_json_body(raw, has_columns?)
    end
  end

  defp csv_content?(conn) do
    case get_req_header(conn, "content-type") do
      [value | _] -> String.contains?(String.downcase(value), "text/csv")
      [] -> false
    end
  end

  defp parse_csv(""), do: {:error, :invalid_json}

  defp parse_csv(raw) do
    lines =
      raw
      |> String.replace("\r\n", "\n")
      |> String.trim_trailing("\n")
      |> String.split("\n")

    case lines do
      [header | data] ->
        columns = split_csv_line(header)
        width = length(columns)

        rows =
          Enum.map(data, fn line ->
            fields = split_csv_line(line)
            {length(fields), fields}
          end)

        if Enum.all?(rows, fn {n, _} -> n == width end) do
          parsed =
            Enum.map(rows, fn {_n, fields} ->
              columns
              |> Enum.zip(fields)
              |> Map.new(fn {c, v} -> {c, csv_value(v)} end)
            end)

          {:ok, parsed}
        else
          {:error, :ragged_csv}
        end

      [] ->
        {:error, :ragged_csv}
    end
  end

  defp csv_value("NULL"), do: nil
  defp csv_value(v), do: v

  defp split_csv_line(line), do: line |> String.split(",") |> Enum.map(&String.trim/1)

  # An empty JSON body inserts a single all-defaults row (`{}`).
  defp parse_json_body("", _has_columns?), do: {:ok, [%{}]}

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
  # json/jsonb columns keep their JSON structure (`->`); everything else is
  # pulled as text (`->>`) and cast to the column type so Postgres parses
  # arrays/numbers/etc. `missing=default` substitutes the column DEFAULT for a
  # key the element omits.
  defp row_select_exprs(columns, relation, missing) do
    Enum.map_join(columns, ", ", fn col ->
      coltype = column_type(relation, col)
      value_expr = extract_expr(col, coltype, relation)

      case missing do
        :default ->
          default = column_default(relation, col) || "NULL"
          "CASE WHEN _e ? #{pg_literal(col)} THEN #{value_expr} ELSE #{default} END"

        _ ->
          value_expr
      end
    end)
  end

  defp extract_expr(col, type, relation) do
    case QueryExecutor.write_rep_fn(relation, col) do
      # A DOMAIN with a `json AS <domain>` cast parses the raw JSON body value
      # through its cast function (cases 1811-1813); a plain `::<domain>` cast
      # would strip the domain to its base type and bypass the parser.
      {schema, name} ->
        "#{q(schema)}.#{q(name)}((_e -> #{pg_literal(col)})::json)"

      nil ->
        if json_type?(type) do
          "(_e -> #{pg_literal(col)})"
        else
          "(_e ->> #{pg_literal(col)})::#{type_cast(type)}"
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

  # SET col = EXCLUDED.col for every inserted column not in the conflict target.
  defp update_set_excluded(columns, target_cols) do
    case Enum.reject(columns, &(&1 in target_cols)) do
      [] -> Enum.map_join(target_cols, ", ", fn c -> "#{q(c)} = EXCLUDED.#{q(c)}" end)
      cols -> Enum.map_join(cols, ", ", fn c -> "#{q(c)} = EXCLUDED.#{q(c)}" end)
    end
  end

  # SET col = <typed value> list for UPDATE; single-object body extracted from
  # one bound jsonb parameter.
  defp set_clause(columns, row, relation) do
    payload = Bier.json_library().encode!(row)

    parts =
      Enum.map_join(columns, ", ", fn col ->
        coltype = column_type(relation, col)
        "#{q(col)} = #{extract_expr_from(col, coltype, "$1::text::jsonb", relation)}"
      end)

    {parts, [payload]}
  end

  defp extract_expr_from(col, type, src, relation) do
    case QueryExecutor.write_rep_fn(relation, col) do
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
  # (`format_type`), so they are trusted, but we still constrain the charset.
  defp type_cast(type), do: QueryExecutor.quote_type(type)

  defp qrel(relation), do: QueryExecutor.qrel(relation)
  defp q(ident), do: QueryExecutor.quote_ident(ident)
  defp pg_literal(str), do: QueryExecutor.pg_literal(str)
end
