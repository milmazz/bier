defmodule Bier.Mutation do
  @moduledoc """
  Write pipeline for `POST` / `PATCH` / `PUT` / `DELETE` on a relation.

  Mirrors PostgREST's mutation semantics:

    * `POST`   — `INSERT ... RETURNING`, optionally `ON CONFLICT` for upsert
      (`Prefer: resolution=merge-duplicates|ignore-duplicates`).
    * `PATCH`  — `UPDATE ... WHERE <filters> RETURNING`, honoring the request's
      column filters.
    * `DELETE` — `DELETE ... WHERE <filters> RETURNING`.
    * `PUT`    — single-row upsert keyed by the request's PK filter
      (`INSERT ... ON CONFLICT (<pk>) DO UPDATE`).

  The `Prefer: return=` token selects the response shape:

    * `return=representation` — the mutated rows as a JSON array body, shaped by
      `&select` (with embedding), status 200/201, `Preference-Applied`.
    * `return=minimal` / `return=headers-only` / no token — empty body, status
      201 (insert) or 204 (update/delete), with `Location` for `headers-only`.

  All values are passed as bound parameters; only validated identifiers are
  templated into SQL.
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
         {:ok, columns, rows} <- parse_body(conn, relation) do
      pref = preferences(conn)
      resolution = pref.resolution

      cond do
        # Empty payload with merge/ignore upsert resolution -> 0 rows, 200 [].
        rows == [] and resolution != nil ->
          respond_empty_set(conn, plan, relation, media, pref, 200)

        true ->
          {sql, params} = insert_sql(relation, columns, rows, resolution)
          run(conn, config, relation, plan, media, pref, sql, params, :insert, 201)
      end
    end
  end

  # ---- UPDATE --------------------------------------------------------------

  defp update(conn, config, relation, media) do
    with {:ok, plan} <- ActionController.parse(conn, config),
         {:ok, columns, rows} <- parse_body(conn, relation) do
      pref = preferences(conn)
      row = single_row(rows)

      {set_sql, params} = set_clause(columns, row)
      {where_sql, params} = where_clause(plan.filters, relation, params)

      sql = "UPDATE #{qrel(relation)} SET #{set_sql}#{where_sql} RETURNING *"
      run(conn, config, relation, plan, media, pref, sql, params, :update, 200)
    end
  end

  # ---- DELETE --------------------------------------------------------------

  defp delete(conn, config, relation, media) do
    with {:ok, plan} <- ActionController.parse(conn, config) do
      pref = preferences(conn)
      {where_sql, params} = where_clause(plan.filters, relation, [])
      sql = "DELETE FROM #{qrel(relation)}#{where_sql} RETURNING *"
      run(conn, config, relation, plan, media, pref, sql, params, :delete, 200)
    end
  end

  # ---- PUT (single-row upsert) ---------------------------------------------

  defp put(conn, config, relation, media) do
    with {:ok, plan} <- ActionController.parse(conn, config),
         {:ok, columns, rows} <- parse_body(conn, relation) do
      pref = preferences(conn)
      pk = relation.primary_key

      with [row] <- rows,
           true <- pk != [] do
        {sql, params} = upsert_sql(relation, columns, row, pk)
        run(conn, config, relation, plan, media, pref, sql, params, {:put, row, pk}, 200)
      else
        _ -> {:error, :method_not_allowed}
      end
    end
  end

  # ---- shared execution ----------------------------------------------------

  # Run the mutation. We always wrap the RETURNING in a representation query so
  # we can (a) shape the body by &select / embedding and (b) count the mutated
  # rows for Content-Range and the Location header, even for minimal responses.
  defp run(conn, config, relation, plan, media, pref, sql, params, mutation, ok_status) do
    pool = Bier.Registry.via(config.name, Postgrex)
    relations = :persistent_term.get({Bier, :relations, config.name}, %{})

    {:ok, wrapped, wparams} =
      QueryExecutor.build_representation(relation, plan, relations, {sql, params})

    result =
      Postgrex.transaction(pool, fn tx ->
        # For PUT, distinguish insert (201) from replace (200) by whether the PK
        # already existed before the upsert.
        existed = put_existed?(tx, relation, mutation)

        case Postgrex.query(tx, wrapped, wparams) do
          {:ok, %Postgrex.Result{rows: [[body, count, meta]]}} ->
            case enforce_singular(media, body) do
              # The response is fully computed inside the transaction (the CTE's
              # RETURNING is already serialized into `body`). Under db-tx-end
              # :rollback we abort the transaction here, discarding the write but
              # returning the same response — see config/test.exs for why.
              :ok -> finish_tx(tx, config, {body, count || 0, meta, existed})
              {:error, _} = err -> Postgrex.rollback(tx, err)
            end

          {:error, _} = err ->
            Postgrex.rollback(tx, err)
        end
      end)

    case result do
      {:ok, {body, count, meta, existed}} ->
        respond(
          conn,
          body,
          count,
          meta,
          existed,
          relation,
          plan,
          media,
          pref,
          mutation,
          ok_status
        )

      {:error, {:bier_rollback_ok, {body, count, meta, existed}}} ->
        respond(
          conn,
          body,
          count,
          meta,
          existed,
          relation,
          plan,
          media,
          pref,
          mutation,
          ok_status
        )

      {:error, reason} ->
        reason
    end
  end

  # End the per-request transaction. Under db-tx-end :rollback we abort it (the
  # response is already computed), so the write never persists; the transaction
  # then returns `{:error, {:bier_rollback_ok, payload}}`, handled above. Under
  # :commit we return the payload normally and the transaction commits.
  defp finish_tx(tx, %{db_tx_end: :rollback}, payload),
    do: Postgrex.rollback(tx, {:bier_rollback_ok, payload})

  defp finish_tx(_tx, _config, payload), do: payload

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

  defp put_existed?(_tx, _relation, _mutation), do: false

  # Normalize the mutation tag to its base kind.
  defp mutation_kind({:put, _row, _pk}), do: :put
  defp mutation_kind(kind), do: kind

  # Zero-row response without running SQL (empty upsert payload).
  defp respond_empty_set(conn, _plan, _relation, media, pref, status) do
    conn
    |> put_pref_applied(pref)
    |> put_resp_header("content-type", MediaType.content_type(media))
    |> send_resp(status, "[]")
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
         ok_status
       ) do
    kind = mutation_kind(mutation)
    columns = ActionController.csv_columns(plan, relation)

    case Render.render(media, body, columns: columns) do
      {:ok, payload} ->
        status = representation_status(kind, count, existed, ok_status, pref)

        conn
        |> put_pref_applied(pref)
        |> put_resp_header("content-type", MediaType.content_type(media))
        |> maybe_location(kind, relation, plan, meta)
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
         ok_status
       ) do
    kind = mutation_kind(mutation)
    status = empty_status(kind, count, existed, ok_status, pref)

    conn
    |> put_pref_applied(pref)
    |> force_location(kind, relation, meta)
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
         ok_status
       ) do
    kind = mutation_kind(mutation)
    status = empty_status(kind, count, existed, ok_status, pref)

    conn
    |> put_pref_applied(pref)
    |> maybe_location(kind, relation, plan, meta)
    |> put_content_range(kind, count, pref)
    |> put_content_length_for_empty(status)
    |> send_resp(status, "")
  end

  # Status for representation responses: inserts are 201 when at least one row
  # was created (200 for a zero-row upsert); put depends on insert vs replace;
  # updates/deletes are 200.
  defp representation_status(:insert, count, _existed, _ok, %{resolution: res})
       when count == 0 and res != nil,
       do: 200

  defp representation_status(:insert, _count, _existed, ok, _pref), do: ok

  defp representation_status(:put, _count, existed, _ok, _pref),
    do: if(existed, do: 200, else: 201)

  defp representation_status(_kind, _count, _existed, _ok, _pref), do: 200

  # Status for empty-body responses: inserts are 201; minimal PUT is always 204;
  # other PUT depends on insert vs replace; updates/deletes are 204.
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
  # present in the selected output (PostgREST omits it otherwise).
  defp maybe_location(conn, kind, relation, plan, meta) when kind in [:insert, :put] do
    if pk_in_select?(relation, plan) do
      force_location(conn, kind, relation, meta)
    else
      conn
    end
  end

  defp maybe_location(conn, _kind, _relation, _plan, _meta), do: conn

  # Location regardless of select (headers-only): from the mutated row's PK.
  defp force_location(conn, kind, relation, meta) when kind in [:insert, :put] do
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

  defp force_location(conn, _kind, _relation, _meta), do: conn

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

  # Echo the recognized Prefer tokens that were honored, preserving input order.
  defp put_pref_applied(conn, %{applied: []}), do: conn

  defp put_pref_applied(conn, %{applied: tokens}) do
    put_resp_header(conn, "preference-applied", Enum.join(tokens, ", "))
  end

  # ---- preferences ---------------------------------------------------------

  # Parse `Prefer` into the response-affecting bits plus the ordered list of
  # recognized tokens to echo via Preference-Applied.
  defp preferences(conn) do
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

    count =
      cond do
        "count=exact" in raw -> :exact
        "count=planned" in raw -> :planned
        "count=estimated" in raw -> :estimated
        true -> nil
      end

    applied = Enum.filter(raw, &applied_token?/1)

    %{return: return, resolution: resolution, count: count, applied: applied}
  end

  defp split_prefer(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Tokens echoed in Preference-Applied. PostgREST only echoes the preferences it
  # actually honors; for the representation slice that is return= and count=.
  defp applied_token?("return=representation"), do: true
  defp applied_token?("return=minimal"), do: true
  defp applied_token?("return=headers-only"), do: true
  defp applied_token?("count=exact"), do: true
  defp applied_token?("count=planned"), do: true
  defp applied_token?("count=estimated"), do: true
  defp applied_token?(_), do: false

  # ---- body parsing --------------------------------------------------------

  defp parse_body(conn, relation) do
    raw = conn.assigns[:bier_raw_body] || ""

    cond do
      csv_content?(conn) -> parse_csv(raw)
      true -> parse_json(raw, relation)
    end
  end

  defp csv_content?(conn) do
    case get_req_header(conn, "content-type") do
      [value | _] -> String.contains?(String.downcase(value), "text/csv")
      [] -> false
    end
  end

  defp parse_csv(""), do: {:error, :unprocessable}

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

          {:ok, columns, parsed}
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

  defp parse_json("", _relation), do: {:ok, [], []}

  defp parse_json(raw, _relation) do
    case Bier.json_library().decode(raw) do
      {:ok, obj} when is_map(obj) ->
        {:ok, Map.keys(obj), [obj]}

      {:ok, list} when is_list(list) ->
        columns =
          Enum.reduce(list, [], fn row, acc ->
            keys = if is_map(row), do: Map.keys(row), else: []
            acc ++ Enum.reject(keys, &(&1 in acc))
          end)

        {:ok, columns, list}

      _ ->
        {:error, :unprocessable}
    end
  end

  defp single_row([row | _]), do: row
  defp single_row(_), do: %{}

  # ---- SQL building --------------------------------------------------------

  defp insert_sql(relation, [], _rows, _resolution) do
    {"INSERT INTO #{qrel(relation)} DEFAULT VALUES RETURNING *", []}
  end

  defp insert_sql(relation, columns, rows, resolution) do
    cols = Enum.map_join(columns, ", ", &q/1)
    width = length(columns)

    groups =
      rows
      |> Enum.with_index()
      |> Enum.map_join(", ", fn {_row, ri} ->
        ph = Enum.map_join(1..width, ", ", fn ci -> "$#{ri * width + ci}" end)
        "(#{ph})"
      end)

    params = Enum.flat_map(rows, fn row -> Enum.map(columns, &Map.get(row, &1)) end)

    conflict = on_conflict(relation, columns, resolution)

    {"INSERT INTO #{qrel(relation)} (#{cols}) VALUES #{groups}#{conflict} RETURNING *", params}
  end

  defp on_conflict(_relation, _columns, nil), do: ""

  defp on_conflict(relation, _columns, :ignore) do
    case relation.primary_key do
      [] -> " ON CONFLICT DO NOTHING"
      pk -> " ON CONFLICT (#{Enum.map_join(pk, ", ", &q/1)}) DO NOTHING"
    end
  end

  defp on_conflict(relation, columns, :merge) do
    case relation.primary_key do
      [] ->
        ""

      pk ->
        updates =
          columns
          |> Enum.reject(&(&1 in pk))
          |> case do
            [] -> Enum.map_join(pk, ", ", fn c -> "#{q(c)} = EXCLUDED.#{q(c)}" end)
            cols -> Enum.map_join(cols, ", ", fn c -> "#{q(c)} = EXCLUDED.#{q(c)}" end)
          end

        " ON CONFLICT (#{Enum.map_join(pk, ", ", &q/1)}) DO UPDATE SET #{updates}"
    end
  end

  # PUT upsert keyed on the PK: insert, on conflict replace every supplied column.
  defp upsert_sql(relation, columns, row, pk) do
    cols = Enum.map_join(columns, ", ", &q/1)
    {phs, params} = placeholders(columns, row)

    updates =
      case Enum.reject(columns, &(&1 in pk)) do
        [] -> Enum.map_join(pk, ", ", fn c -> "#{q(c)} = EXCLUDED.#{q(c)}" end)
        cols2 -> Enum.map_join(cols2, ", ", fn c -> "#{q(c)} = EXCLUDED.#{q(c)}" end)
      end

    sql =
      "INSERT INTO #{qrel(relation)} (#{cols}) VALUES (#{phs}) " <>
        "ON CONFLICT (#{Enum.map_join(pk, ", ", &q/1)}) DO UPDATE SET #{updates} RETURNING *"

    {sql, params}
  end

  defp placeholders(columns, row) do
    {phs, params} =
      columns
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {col, i}, acc ->
        {"$#{i}", [Map.get(row, col) | acc]}
      end)

    {Enum.join(phs, ", "), Enum.reverse(params)}
  end

  # SET col = $n list for UPDATE; appends params (kept in $1.. order).
  defp set_clause(columns, row) do
    {parts, params} =
      columns
      |> Enum.map_reduce([], fn col, acc ->
        i = length(acc) + 1
        {"#{q(col)} = $#{i}", [Map.get(row, col) | acc]}
      end)

    {Enum.join(parts, ", "), Enum.reverse(params)}
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

  defp qrel(relation), do: QueryExecutor.qrel(relation)
  defp q(ident), do: QueryExecutor.quote_ident(ident)
end
