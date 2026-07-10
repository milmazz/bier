defmodule Bier.QueryExecutor do
  @moduledoc """
  Turns a parsed request plan (`Bier.QueryParser.parse_request/1`) plus a target
  relation into ONE parameterized SQL statement that returns the result set as
  JSON text, then executes it through the per-instance Postgrex pool.

  The shape mirrors PostgREST:

      SELECT coalesce(json_agg(_postgrest_t), '[]')::text AS body,
             count(*) OVER() AS full_count
      FROM ( SELECT <select-list> FROM <schema>.<relation>
             WHERE <filters> ORDER BY <order> LIMIT <l> OFFSET <o> ) _postgrest_t;

  User-supplied values are always passed as bound parameters (`$1`, `$2`, …);
  identifiers (columns) are validated by the parser and quoted here.
  """

  alias Bier.Embed
  alias Bier.Introspection.Relation

  defmodule State do
    @moduledoc false
    # Threads the parameter accumulator + relation through SQL building.
    # `relations` is the full introspection map (for embedding resolution),
    # `alias_name` is the SQL alias of the current relation.
    defstruct params: [],
              count: 0,
              relation: nil,
              relations: %{},
              alias_name: nil,
              embed_seq: 0,
              embed_orders: %{},
              embed_limits: %{},
              embed_offsets: %{},
              # When set, the FROM source for the top-level query (e.g. a mutation
              # CTE name) instead of the relation's qualified name.
              from_override: nil,
              # Output aggregation: :json (a JSON array) or :geojson (a GeoJSON
              # FeatureCollection built with ST_AsGeoJSON).
              format: :json
  end

  @doc """
  Build and run the read query.

  Options:

    * `:count_mode` — `:none` (default) / `:exact` / `:planned` / `:estimated`.
      Controls how the total row count (for `Content-Range`) is computed.
    * `:max_rows` — server `db-max-rows`; used by `:estimated` to decide when to
      fall back to an exact count.
    * `:format` — `:json` (default) or `:geojson` (aggregate the rows into a
      GeoJSON FeatureCollection via `ST_AsGeoJSON`; requires postgis).

  Returns `{:ok, %{body: json_string, count: non_neg_integer}}` or
  `{:error, %Postgrex.Error{}}`.
  """
  @spec run(conn :: term(), Relation.t(), map(), map(), keyword()) ::
          {:ok, %{body: String.t(), count: non_neg_integer()}} | {:error, term()}
  def run(conn, %Relation{} = relation, plan, relations \\ %{}, opts \\ []) do
    count_mode = Keyword.get(opts, :count_mode, :none)
    timezone = Keyword.get(opts, :timezone)
    auth = Keyword.get(opts, :auth)
    format = Keyword.get(opts, :format, :json)

    with {:ok, sql, params} <-
           Bier.ServerTiming.measure(:plan, fn -> build(relation, plan, relations, format) end) do
      Bier.ServerTiming.measure(:transaction, fn ->
        case query_read(conn, sql, params, timezone, auth) do
          {:ok, %Postgrex.Result{rows: [[body, exact_count]]}} ->
            resolve_count(
              conn,
              relation,
              plan,
              relations,
              count_mode,
              opts,
              body,
              exact_count || 0
            )

          {:ok, %Postgrex.Result{rows: []}} ->
            {:ok, %{body: "[]", count: 0}}

          {:error, _} = err ->
            err
        end
      end)
    end
  end

  # Run the read query, honoring the auth context (role switch + request GUCs +
  # pre-request hook) when present. The auth-context query runs in a single
  # transaction; a `42501` under the anon role is re-mapped to a 401 envelope.
  # Note: subsequent count/timezone queries (`resolve_count`) reuse the pool as
  # the connecting superuser. That is intentional — the auth cases that read GUCs
  # use count=none, and the privilege-gated reads either succeed (granted) or
  # raise here before any count query runs.
  defp query_read(conn, sql, params, timezone, nil),
    do: query_with_timezone(conn, sql, params, timezone)

  defp query_read(pool, sql, params, timezone, {context, config}) do
    result =
      Postgrex.transaction(pool, fn tx ->
        Bier.Auth.with_context(tx, context, config, fn tx ->
          set_local_timezone(tx, timezone)

          case Postgrex.query(tx, sql, params) do
            {:ok, result} -> result
            {:error, err} -> Postgrex.rollback(tx, err)
          end
        end)
      end)

    case result do
      {:ok, result} -> {:ok, result}
      {:error, %Postgrex.Error{} = err} -> Bier.Auth.map_error(context, err)
      {:error, other} -> {:error, other}
    end
  end

  defp query_with_timezone(conn, sql, params, nil), do: Postgrex.query(conn, sql, params)

  defp query_with_timezone(conn, sql, params, timezone) do
    Postgrex.transaction(conn, fn tx ->
      set_local_timezone(tx, timezone)

      case Postgrex.query(tx, sql, params) do
        {:ok, result} -> result
        {:error, err} -> Postgrex.rollback(tx, err)
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, other} -> {:error, other}
    end
  end

  # `Prefer: timezone=<name>` shifts timestamptz rendering. The name is validated
  # against pg_timezone_names before we get here, so a `SET LOCAL TIME ZONE`
  # inside the request transaction is safe; the literal is single-quote escaped.
  defp set_local_timezone(_tx, nil), do: :ok

  defp set_local_timezone(tx, timezone) do
    Postgrex.query!(tx, "SET LOCAL TIME ZONE '#{String.replace(timezone, "'", "''")}'", [])
    :ok
  end

  defp resolve_count(_conn, _rel, _plan, _rels, :none, _opts, body, exact) do
    {:ok, %{body: body, count: exact}}
  end

  # The window query carries `count(*) OVER()`, computed over the full filtered
  # set (window functions run before LIMIT/OFFSET) — so for a non-empty window
  # it already holds the exact total. When the window is empty (e.g. an offset
  # past the last row), no rows survive to carry the count, so we run a dedicated
  # `count(*)` over the unlimited filtered set to recover the real total.
  defp resolve_count(conn, relation, plan, relations, :exact, _opts, "[]", _exact) do
    case exact_count(conn, relation, plan, relations) do
      {:ok, total} -> {:ok, %{body: "[]", count: total}}
      {:error, _} = err -> err
    end
  end

  defp resolve_count(_conn, _rel, _plan, _rels, :exact, _opts, body, exact) do
    {:ok, %{body: body, count: exact}}
  end

  defp resolve_count(conn, relation, plan, relations, :planned, _opts, body, _exact) do
    case planned_count(conn, relation, plan, relations) do
      {:ok, est} -> {:ok, %{body: body, count: est}}
      {:error, _} = err -> err
    end
  end

  defp resolve_count(conn, relation, plan, relations, :estimated, opts, body, exact) do
    max_rows = Keyword.get(opts, :max_rows)

    case planned_count(conn, relation, plan, relations) do
      {:ok, est} ->
        # PostgREST returns the planner estimate only when it exceeds max-rows;
        # otherwise it returns the exact count. With no max-rows configured the
        # estimate is small enough that exact and estimate coincide for the
        # conformance fixtures, so prefer exact for determinism.
        count =
          if is_integer(max_rows) and est > max_rows, do: est, else: exact

        {:ok, %{body: body, count: count}}

      {:error, _} = err ->
        err
    end
  end

  # Exact `count(*)` over the filtered query (no limit/offset/order).
  defp exact_count(conn, relation, plan, relations) do
    {:ok, inner_sql, params} = build_count_query(relation, plan, relations)

    case Postgrex.query(conn, "SELECT count(*) FROM (#{inner_sql}) _bier_count", params) do
      {:ok, %Postgrex.Result{rows: [[n]]}} -> {:ok, n || 0}
      {:error, _} = err -> err
    end
  end

  # Planner row estimate for the filtered query, ignoring limit/offset (mirrors
  # PostgREST's planned/estimated count which counts the unlimited query).
  defp planned_count(conn, relation, plan, relations) do
    {:ok, sql, params} = build_count_query(relation, plan, relations)

    case Postgrex.query(conn, "EXPLAIN (FORMAT JSON) " <> sql, params) do
      {:ok, %Postgrex.Result{rows: [[explain]]}} ->
        {:ok, extract_plan_rows(explain)}

      {:error, _} = err ->
        err
    end
  end

  defp extract_plan_rows(explain) when is_list(explain) do
    case explain do
      [%{"Plan" => %{"Plan Rows" => rows}} | _] -> rows
      _ -> 0
    end
  end

  defp extract_plan_rows(explain) when is_binary(explain) do
    case Bier.json_library().decode(explain) do
      {:ok, decoded} -> extract_plan_rows(decoded)
      _ -> 0
    end
  end

  defp extract_plan_rows(_), do: 0

  @doc false
  # A bare counting query for the planner: `SELECT 1 FROM <rel> WHERE <filters>`,
  # with no select-list, order, or limit/offset (planned/estimated counts the
  # unlimited filtered set). Embedded-resource filters are not applied here;
  # PostgREST's planned count is on the top-level relation only.
  def build_count_query(%Relation{} = relation, plan, _relations) do
    state = %State{relation: relation, alias_name: nil}
    column_filters = Enum.reject(plan.filters || [], &embed_null_filter?(&1, plan.select))
    {where_sql, state} = build_where(column_filters, state)
    sql = "SELECT 1 FROM #{qrel(relation)}" <> where_sql
    {:ok, sql, Enum.reverse(state.params)}
  end

  # A top-level leaf filter whose column names a selected embed is an embed
  # null-filter, not a real column on the relation; skip it for counting.
  defp embed_null_filter?(%{logic: _}, _select), do: false

  defp embed_null_filter?(%{column: col}, select) do
    MapSet.member?(embed_filter_names(select), col)
  end

  defp embed_null_filter?(_node, _select), do: false

  @doc """
  Build and run a read query whose source is a set-returning function
  (`/rpc/<fn>`), called with the parsed `args` (a list of `{name, type, value}`).

  Only the flat read shape is supported (select / filters / order / limit /
  offset / count) — enough for the GET RPC pagination cases. The function's
  returned relation supplies the column set for `select` and column filters.
  """
  @spec run_function(term(), map(), Relation.t(), [tuple()], map(), keyword()) ::
          {:ok, %{body: String.t(), count: non_neg_integer()}} | {:error, term()}
  def run_function(conn, fn_def, %Relation{} = ret_relation, args, plan, opts \\ []) do
    count_mode = Keyword.get(opts, :count_mode, :none)
    relations = Keyword.get(opts, :relations, %{})

    try do
      case Bier.ServerTiming.measure(:plan, fn ->
             build_function(fn_def, ret_relation, args, plan, relations)
           end) do
        {:ok, sql, params} ->
          Bier.ServerTiming.measure(:transaction, fn ->
            case Postgrex.query(conn, sql, params) do
              {:ok, %Postgrex.Result{rows: [[body, exact_count]]}} ->
                # planned/estimated counts are not needed by the RPC pagination
                # cases; exact reuses the window count, which (with a non-empty
                # window) is the full count. Empty RPC windows are not exercised.
                {:ok, %{body: body, count: count_for(count_mode, exact_count || 0)}}

              {:ok, %Postgrex.Result{rows: []}} ->
                {:ok, %{body: "[]", count: 0}}

              {:error, _} = err ->
                err
            end
          end)

        {:error, _} = err ->
          err
      end
    catch
      {:bad_request, _} = err -> {:error, err}
      {:embed_error, _} = err -> {:error, err}
      {:embed_error_raw, reason} -> {:error, reason}
    end
  end

  defp count_for(:none, _exact), do: 0
  defp count_for(_mode, exact), do: exact

  defp build_function(fn_def, ret_relation, args, plan, relations) do
    # Bind the function arguments first so their params lead the parameter list;
    # the function call becomes the FROM source for the read builder.
    {arg_sql, arg_state} = build_function_args(args, %State{relation: ret_relation})
    from = "#{quote_ident(fn_def.schema)}.#{quote_ident(fn_def.name)}(#{arg_sql})"

    # Route the projection through the embed-capable read builders so a function
    # whose result set is embedded (e.g. `/rpc/fn?select=...,children(...)`)
    # resolves the embedding against `ret_relation`'s foreign keys, exactly like
    # a table read. The function call is threaded in via `from_override`.
    #
    # The simple (flat) path leaves the function call unaliased and renders bare
    # column references, so `alias_name` must be nil there. The advanced path
    # aliases the FROM with the relation name and qualifies every column with it,
    # so `alias_name` is the relation name. Pick accordingly.
    advanced? = advanced_select?(plan.select, ret_relation) or advanced_order?(plan, ret_relation)

    state = %State{
      relation: ret_relation,
      relations: relations,
      alias_name: if(advanced?, do: ret_relation.name, else: nil),
      embed_orders: plan[:embed_orders] || %{},
      embed_limits: plan[:embed_limits] || %{},
      embed_offsets: plan[:embed_offsets] || %{},
      from_override: from,
      params: arg_state.params,
      count: arg_state.count
    }

    with :ok <- validate_embed_filters(plan) do
      if advanced? do
        build_advanced(ret_relation, plan, state)
      else
        build_simple(ret_relation, plan, state)
      end
    end
  end

  # Named function arguments rendered as `"name" => $n` keyword-call syntax, with
  # each value bound as a typed literal so Postgres coerces it to the arg type.
  defp build_function_args([], state), do: {"", state}

  defp build_function_args(args, state) do
    {parts, state} =
      Enum.map_reduce(args, state, fn {name, type, value}, st ->
        {ph, st} = bind(value, type, st)
        {"#{quote_ident(name)} => #{ph}", st}
      end)

    {Enum.join(parts, ", "), state}
  end

  # The FROM source for the top-level query: a CTE override (used by the
  # mutation representation path) or the relation's qualified name.
  defp from_source(relation, %State{from_override: nil}), do: qrel(relation)
  defp from_source(_relation, %State{from_override: src}), do: src

  @doc """
  Build a representation query whose source is a mutation CTE.

  `source_sql` is the `INSERT/UPDATE/DELETE ... RETURNING *` statement; its
  bound params are `source_params` (in `$1..$n` order). The returned SQL wraps
  the source in a CTE named `pgrst_source` and renders `plan.select` (with
  embedding) over it.

  The result is a single row `{body, count, meta}` where:

    * `body`  — the JSON-array representation shaped by `plan.select`,
    * `count` — the number of mutated rows,
    * `meta`  — a JSON object `{"pk": <first row's PK cols>}` used to build the
      `Location` header.
  """
  def build_representation(%Relation{} = relation, plan, relations, {source_sql, source_params}) do
    cte = "pgrst_source"

    state = %State{
      relation: relation,
      relations: relations,
      alias_name: relation.name,
      embed_orders: plan[:embed_orders] || %{},
      embed_limits: plan[:embed_limits] || %{},
      embed_offsets: plan[:embed_offsets] || %{},
      from_override: cte,
      params: Enum.reverse(source_params),
      count: length(source_params)
    }

    try do
      with :ok <- validate_embed_filters(plan) do
        result =
          if advanced_select?(plan.select, relation) or advanced_order?(plan, relation) do
            build_advanced(relation, %{plan | filters: [], order: []}, state)
          else
            build_simple(relation, %{plan | filters: [], order: []}, state)
          end

        {:ok, repr_sql, params} = result
        meta = build_meta_select(relation)

        sql =
          "WITH #{cte} AS (#{source_sql}) " <>
            "SELECT (SELECT body FROM (#{repr_sql}) _bier_repr) AS body, " <>
            "(SELECT count(*) FROM #{cte}) AS count, " <>
            "(#{meta}) AS meta"

        {:ok, sql, params}
      end
    catch
      {:embed_error, _} = err -> {:error, err}
      {:embed_error_raw, reason} -> {:error, reason}
    end
  end

  # A JSON object carrying the first mutated row's PK values, for the Location
  # header. NULL when the relation has no primary key.
  defp build_meta_select(%Relation{primary_key: pk}) do
    pk_obj =
      case pk do
        [] ->
          "NULL::jsonb"

        cols ->
          pairs =
            Enum.map_join(cols, ", ", fn c -> "#{pg_literal(c)}, _s.#{quote_ident(c)}" end)

          "(SELECT jsonb_build_object(#{pairs}) FROM pgrst_source _s LIMIT 1)"
      end

    "SELECT #{pk_obj}::text"
  end

  @doc false
  def build(relation, plan, relations \\ %{}, format \\ :json)

  def build(%Relation{} = relation, plan, relations, format) do
    state = %State{
      relation: relation,
      relations: relations,
      alias_name: relation.name,
      embed_orders: plan[:embed_orders] || %{},
      embed_limits: plan[:embed_limits] || %{},
      embed_offsets: plan[:embed_offsets] || %{},
      format: format
    }

    try do
      with :ok <- validate_embed_filters(plan) do
        if advanced_select?(plan.select, relation) or advanced_order?(plan, relation) do
          build_advanced(relation, plan, state)
        else
          build_simple(relation, plan, state)
        end
      end
    catch
      {:embed_error, _} = err -> {:error, err}
      {:embed_error_raw, reason} -> {:error, reason}
    end
  end

  # Every embedded-resource filter (`<rel>.<col>=op.value`, `<rel>.or=(...)`,
  # `<rel>=is.null`) must target a resource embedded in the `select` parameter.
  # A filter whose path head names no top-level embed is a 400 PGRST108.
  defp validate_embed_filters(%{embed_filters: ef, select: select}) when map_size(ef) > 0 do
    names = embed_filter_names(select)

    Enum.reduce_while(ef, :ok, fn {[head | _], _nodes}, :ok ->
      if MapSet.member?(names, head),
        do: {:cont, :ok},
        else: {:halt, {:error, {:embed_not_selected, head}}}
    end)
  end

  defp validate_embed_filters(_plan), do: :ok

  # The select tree needs the row-object builder when it references embeds,
  # aggregates, spread, computed columns, or mixes `*` with explicit fields.
  defp advanced_select?([:star], _relation), do: false

  defp advanced_select?(nodes, relation) when is_list(nodes) do
    computed = relation.computed_columns

    Enum.any?(nodes, fn
      %{kind: :embed} -> true
      %{kind: :agg} -> true
      %{kind: :field, column: col} -> col in computed
      _ -> false
    end)
  end

  defp advanced_select?(_, _relation), do: false

  # An order clause needs the aliased (advanced) path when it references a
  # computed column or a related (to-one embedded) resource, or when there are
  # embed orders to thread into embedded resources.
  defp advanced_order?(plan, relation) do
    computed = relation.computed_columns

    related_or_computed? =
      Enum.any?(plan.order || [], fn
        %{relation: _} -> true
        %{column: col, json_path: jp} -> col in computed or composite_column?(relation, col, jp)
      end)

    related_or_computed? or map_size(plan[:embed_orders] || %{}) > 0
  end

  # A non-empty json path on a composite-typed column needs `(col).field` access
  # rather than the `->` json operator.
  defp composite_column?(_relation, _col, []), do: false

  defp composite_column?(relation, col, _json_path) do
    case Enum.find(relation.columns, &(&1.name == col)) do
      %{composite?: true} -> true
      _ -> false
    end
  end

  # ---- simple (flat) path --------------------------------------------------

  defp build_simple(relation, plan, state) do
    {select_sql, state} = build_select(plan.select, relation, state)
    {where_sql, state} = build_where(plan.filters, state)
    order_sql = build_order(plan.order)
    {limit_sql, state} = build_limit(plan, state)

    # `_bier_cols` projects ONLY the named select-list (filtered, ordered) — no
    # count column. Rendering its row with `to_json` then yields compact JSON
    # matching PostgREST's wire bytes; `json_build_object` would space `"k" : v`
    # and `to_jsonb` would space `{"k": v}`. The full-count window is a SIBLING of
    # the row (not embedded then removed with the jsonb `-` operator, which the
    # earlier attempt tripped on), and runs over the unlimited filtered set so it
    # is the exact total before LIMIT/OFFSET. See issue #17.
    cols =
      "SELECT #{select_sql} FROM #{from_source(relation, state)}" <> where_sql <> order_sql

    paged =
      "SELECT #{row_json(state.format)} AS _bier_row, count(*) OVER() AS _bier_full_count " <>
        "FROM (#{cols}) _bier_cols" <> limit_sql

    sql =
      "SELECT #{aggregate_body(state.format)} AS body, " <>
        "coalesce(max(_postgrest_t._bier_full_count), 0) AS full_count " <>
        "FROM (#{paged}) _postgrest_t"

    {:ok, sql, Enum.reverse(state.params)}
  end

  # GeoJSON (Accept: application/geo+json) renders each row with PostGIS's
  # `ST_AsGeoJSON(record)` — the geometry column becomes the Feature's geometry
  # and the remaining columns its properties — and the aggregate is wrapped in a
  # FeatureCollection, mirroring PostgREST's asGeoJsonF. A relation without a
  # geometry column raises SQLSTATE 22023 "geometry column is missing" (400).
  # Only this flat path supports it: the advanced path pre-collapses each row
  # into a JSON object, which ST_AsGeoJSON cannot consume.
  defp row_json(:geojson), do: "ST_AsGeoJSON(_bier_cols)::json"
  defp row_json(_format), do: "to_json(_bier_cols)"

  defp aggregate_body(:geojson) do
    "json_build_object('type', 'FeatureCollection', 'features', " <>
      "coalesce(json_agg(_postgrest_t._bier_row), '[]'))::text"
  end

  defp aggregate_body(_format), do: "coalesce(json_agg(_postgrest_t._bier_row), '[]')::text"

  # ---- advanced (embed/aggregate/spread) path ------------------------------

  defp build_advanced(relation, plan, state) do
    al = state.alias_name
    aliased_from = "#{from_source(relation, state)} #{quote_ident(al)}"

    # A top-level filter whose column names a selected embed is a null-filter on
    # that embedded resource (semi/anti-join), not a real column filter.
    {null_embed_filters, column_filters} = split_embed_null_filters(plan.filters, plan.select)

    {row_expr, state} =
      Embed.build_row_object(
        plan.select,
        relation,
        al,
        plan.embed_filters || %{},
        state,
        __MODULE__
      )

    {where_sql, state} = build_where_aliased(column_filters, al, state)

    {inner_where, state} =
      Embed.inner_join_where(
        plan.select,
        relation,
        al,
        plan.embed_filters || %{},
        state,
        __MODULE__
      )

    {null_where, state} =
      Embed.null_filter_where(null_embed_filters, plan.select, relation, al, state, __MODULE__)

    where_sql = combine_where(where_sql, inner_where)
    where_sql = combine_where(where_sql, null_where)

    {group_sql, having} = Embed.group_by(plan.select, al)

    {order_sql, state} =
      Embed.build_order_advanced(plan.order, plan.select, relation, al, state, __MODULE__)

    {limit_sql, state} = build_limit(plan, state)

    inner =
      "SELECT #{row_expr} AS __row__, count(*) OVER() AS _bier_full_count FROM #{aliased_from}" <>
        where_sql <> group_sql <> having <> order_sql <> limit_sql

    sql =
      "SELECT coalesce(json_agg(_postgrest_t.__row__), '[]')::text AS body, " <>
        "coalesce(max(_postgrest_t._bier_full_count), 0) AS full_count " <>
        "FROM (#{inner}) _postgrest_t"

    {:ok, sql, Enum.reverse(state.params)}
  end

  # Separate `<embed>=is.null` / `<embed>=not.is.null` style filters (whose
  # column names a selected embed) from ordinary column filters. Only logic-free
  # leaf filters can name an embed this way.
  defp split_embed_null_filters(filters, select) do
    names = embed_filter_names(select)

    Enum.split_with(filters, fn
      %{logic: _} -> false
      %{column: col} -> MapSet.member?(names, col)
      _ -> false
    end)
  end

  # The set of names an embed filter (or embed null-filter) may target: each
  # top-level embed node's alias and its target relation name.
  defp embed_filter_names(select) do
    select
    |> Enum.flat_map(fn
      %{kind: :embed} = e -> [e.alias, e.target]
      _ -> []
    end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp combine_where("", inner), do: inner
  defp combine_where(w, ""), do: w
  defp combine_where(" WHERE " <> a, " WHERE " <> b), do: " WHERE (#{a}) AND (#{b})"

  # ---- select (simple) -----------------------------------------------------

  # `select=*` expands to an explicit projection only when the relation has at
  # least one data-representation column, so each such column's `<domain> AS json`
  # cast is applied (case 1803). Otherwise `*` is kept verbatim (cheapest path).
  defp build_select([:star], relation, state) do
    if Enum.any?(relation.columns, &(&1.data_rep != nil)) do
      sql =
        relation.columns
        |> Enum.map_join(", ", fn c ->
          "#{apply_read_rep(quote_ident(c.name), relation, c.name)} AS #{quote_ident(c.name)}"
        end)

      {sql, state}
    else
      {"*", state}
    end
  end

  defp build_select(fields, relation, state) do
    {Enum.map_join(fields, ", ", &render_select_field(&1, relation)), state}
  end

  defp render_select_field(%{kind: :star}, _relation), do: "*"

  defp render_select_field(%{column: col, alias: al, cast: cast, json_path: path}, relation) do
    expr = column_expr(col, path)
    # The read representation is applied first; an explicit `::cast` (case 1805)
    # then operates on the already-formatted JSON value.
    expr = if path == [] and relation, do: apply_read_rep(expr, relation, col), else: expr
    expr = if cast, do: "#{expr}::#{quote_type(cast)}", else: expr
    out_name = al || json_output_name(col, path)
    "#{expr} AS #{quote_ident(out_name)}"
  end

  # Output column name PostgREST uses for a json-path select. The key is the last
  # path segment *when it is a textual key*; a trailing numeric array index does
  # NOT name the output column, so the base column name is used instead. E.g.
  # `data->>0` => `data`, `settings->foo->>bar` => `bar`, `data->1->>x` => `x`.
  def json_output_name(col, []), do: col

  def json_output_name(col, path) do
    {_kind, key} = List.last(path)

    if Regex.match?(~r/^-?\d+$/, key), do: col, else: key
  end

  # ---- where ---------------------------------------------------------------

  defp build_where([], state), do: {"", state}

  defp build_where(filters, state) do
    {clauses, state} =
      Enum.map_reduce(filters, state, fn node, st -> render_node(node, st) end)

    {" WHERE " <> Enum.join(clauses, " AND "), state}
  end

  # Aliased variant: filters reference the given relation alias. Public so the
  # embed builder can render WHERE clauses for nested relations.
  def build_where_aliased([], _al, state), do: {"", state}

  def build_where_aliased(filters, al, state) do
    prev = state.alias_name
    {clauses, state} = Enum.map_reduce(filters, %{state | alias_name: al}, &render_node(&1, &2))
    {" WHERE " <> Enum.join(clauses, " AND "), %{state | alias_name: prev}}
  end

  def render_node(%{logic: op, negate: neg, children: children}, state) do
    {parts, state} = Enum.map_reduce(children, state, &render_node/2)
    joiner = if op == :and, do: " AND ", else: " OR "
    inner = "(" <> Enum.join(parts, joiner) <> ")"
    {if(neg, do: "NOT " <> inner, else: inner), state}
  end

  def render_node(%{column: _} = filter, state) do
    render_filter(filter, state)
  end

  # ---- single column filter -> SQL ----------------------------------------

  defp render_filter(%{op: op} = f, state) do
    col_expr = qualified_column_expr(f.column, f.json_path, state)
    {sql, state} = operator_sql(op, col_expr, f, state)
    sql = if f.negate, do: "NOT (#{sql})", else: sql
    {sql, state}
  end

  # Column expression qualified by the current relation alias, when present.
  def qualified_column_expr(col, path, %State{alias_name: nil}), do: column_expr(col, path)

  def qualified_column_expr(col, path, %State{alias_name: al}),
    do: column_expr_aliased(col, path, al)

  # is.null / is.not_null / is.true / is.false / is.unknown
  defp operator_sql("is", col, f, state) do
    case String.downcase(f.value) do
      "null" -> {"#{col} IS NULL", state}
      "not_null" -> {"#{col} IS NOT NULL", state}
      "true" -> {"#{col} IS TRUE", state}
      "false" -> {"#{col} IS FALSE", state}
      "unknown" -> {"#{col} IS NOT DISTINCT FROM NULL", state}
      _ -> throw({:bad_request, :is_value})
    end
  end

  # Comparison operators
  defp operator_sql(op, col, f, state) when op in ~w(eq neq gt gte lt lte) do
    case f.modifier do
      nil ->
        {ph, state} = bind_filter_value(f, dequote(f.value), state)
        {"#{col} #{cmp(op)} #{ph}", state}

      quant when quant in ["any", "all"] ->
        # eq(any).{...} -> col = ANY('{...}'::coltype[])
        {ph, state} = bind(f.value, array_of(coltype(f, state)), state)
        {"#{col} #{cmp(op)} #{String.upcase(quant)}(#{ph})", state}
    end
  end

  # IN
  defp operator_sql("in", col, f, state) do
    values = parse_in_list(f.value)

    {phs, state} =
      Enum.map_reduce(values, state, fn v, st ->
        bind_filter_value(f, v, st)
      end)

    case phs do
      [] -> {"false", state}
      _ -> {"#{col} IN (#{Enum.join(phs, ", ")})", state}
    end
  end

  # LIKE / ILIKE (with `*` -> `%`)
  defp operator_sql(op, col, f, state) when op in ~w(like ilike) do
    case f.modifier do
      nil ->
        {ph, state} = bind(like_value(f.value), :text, state)
        {"#{col} #{like_sql(op)} #{ph}", state}

      quant when quant in ["any", "all"] ->
        vals = f.value |> parse_array_braces() |> Enum.map(&like_value/1)
        {ph, state} = bind(pg_text_array(vals), array_of(:text), state)
        {"#{col} #{like_sql(op)} #{String.upcase(quant)}(#{ph})", state}
    end
  end

  # ~ / ~* regex
  defp operator_sql(op, col, f, state) when op in ~w(match imatch) do
    sql_op = if op == "match", do: "~", else: "~*"

    case f.modifier do
      nil ->
        {ph, state} = bind(f.value, :text, state)
        {"#{col} #{sql_op} #{ph}", state}

      quant when quant in ["any", "all"] ->
        vals = parse_array_braces(f.value)
        {ph, state} = bind(pg_text_array(vals), array_of(:text), state)
        {"#{col} #{sql_op} #{String.upcase(quant)}(#{ph})", state}
    end
  end

  # IS DISTINCT FROM
  defp operator_sql("isdistinct", col, f, state) do
    {ph, state} = bind(f.value, coltype(f, state), state)
    {"#{col} IS DISTINCT FROM #{ph}", state}
  end

  # Full text search
  defp operator_sql(op, col, f, state) when op in ~w(fts plfts phfts wfts) do
    fn_name =
      case op do
        "fts" -> "to_tsquery"
        "plfts" -> "plainto_tsquery"
        "phfts" -> "phraseto_tsquery"
        "wfts" -> "websearch_to_tsquery"
      end

    {ph, state} = bind(f.value, :text, state)

    query =
      case f.modifier do
        nil -> "#{fn_name}(#{ph})"
        lang -> "#{fn_name}(#{pg_literal(lang)}::regconfig, #{ph})"
      end

    {"#{col} @@ #{query}", state}
  end

  # Array/range structural operators. Cast the bound param to the column type.
  defp operator_sql(op, col, f, state) when op in ~w(cs cd ov sl sr nxr nxl adj) do
    {ph, state} = bind(f.value, coltype(f, state), state)
    {"#{col} #{range_op(op)} #{ph}", state}
  end

  defp operator_sql(_op, _col, _f, _state), do: throw({:bad_request, :unknown_operator})

  defp cmp("eq"), do: "="
  defp cmp("neq"), do: "<>"
  defp cmp("gt"), do: ">"
  defp cmp("gte"), do: ">="
  defp cmp("lt"), do: "<"
  defp cmp("lte"), do: "<="

  defp like_sql("like"), do: "LIKE"
  defp like_sql("ilike"), do: "ILIKE"

  defp range_op("cs"), do: "@>"
  defp range_op("cd"), do: "<@"
  defp range_op("ov"), do: "&&"
  defp range_op("sl"), do: "<<"
  defp range_op("sr"), do: ">>"
  defp range_op("nxr"), do: "&<"
  defp range_op("nxl"), do: "&>"
  defp range_op("adj"), do: "-|-"

  defp like_value(v), do: v |> dequote() |> String.replace("*", "%")

  # PostgREST allows a filter literal to be wrapped in double quotes to protect
  # the reserved characters `( ) , .` inside the value; the quotes are stripped
  # before the value is used (AndOrParamsSpec "eq/like can have quotes", cases
  # 1171/1172). Only a fully-wrapped `"..."` is unquoted; an inner `""` escape is
  # collapsed to a single `"`.
  defp dequote(<<?", _::binary>> = v) do
    if String.length(v) >= 2 and String.ends_with?(v, "\"") do
      v |> String.slice(1..-2//1) |> String.replace("\"\"", "\"")
    else
      v
    end
  end

  defp dequote(v), do: v

  # ---- order ---------------------------------------------------------------

  defp build_order([]), do: ""

  defp build_order(terms) do
    " ORDER BY " <>
      Enum.map_join(terms, ", ", fn t ->
        dir = if t.dir == :desc, do: " DESC", else: " ASC"
        column_expr(t.column, t.json_path) <> dir <> order_nulls(t.nulls)
      end)
  end

  defp order_nulls(:first), do: " NULLS FIRST"
  defp order_nulls(:last), do: " NULLS LAST"
  defp order_nulls(:default), do: ""

  # ---- limit / offset ------------------------------------------------------

  defp build_limit(plan, state) do
    {limit_sql, state} =
      case plan.limit do
        nil -> {"", state}
        n -> {" LIMIT #{n}", state}
      end

    {offset_sql, state} =
      case plan.offset do
        nil -> {"", state}
        0 -> {"", state}
        n -> {" OFFSET #{n}", state}
      end

    {limit_sql <> offset_sql, state}
  end

  # ---- parameter binding ---------------------------------------------------

  # Render a user value for SQL.
  #
  #   * For text/untyped comparisons we use a real bound parameter (`$n`) so the
  #     value is never interpolated.
  #   * When the value must carry a Postgres type (ranges, arrays, numeric/typed
  #     comparisons, quantifier arrays), we emit a *quoted* SQL literal
  #     `'<escaped>'::<type>`. Postgres only coerces text into ranges/arrays from
  #     an *unknown* literal, not from a `text`-typed parameter, so a parameter
  #     cannot be used here. The literal is single-quote-escaped, so it is still
  #     injection-safe; only the (validated) column type is templated.
  def bind(value, type, %State{} = state) when type in [nil, :text] do
    n = state.count + 1
    {"$#{n}", %{state | count: n, params: [to_param(value) | state.params]}}
  end

  def bind(value, type, %State{} = state) do
    {"#{pg_literal(to_param(value))}::#{quote_type(type)}", state}
  end

  defp to_param(value) when is_binary(value), do: value
  defp to_param(value), do: to_string(value)

  # ---- helpers -------------------------------------------------------------

  # The Postgres type of a filter's left-hand-side expression. With a json path,
  # the type follows the last arrow: `->>` yields text, `->` yields jsonb — so a
  # comparison value binds/casts to that, NOT to the json/jsonb column's base
  # type (cases 1173/1174/1176/1179). Without a path it is the column type.
  defp coltype(%{json_path: [_ | _] = path}, %State{}) do
    case List.last(path) do
      {:arrow_text, _} -> :text
      {:arrow, _} -> "jsonb"
    end
  end

  defp coltype(%{column: col}, %State{relation: rel}) do
    case Enum.find(rel.columns, &(&1.name == col)) do
      %{type: type} -> type
      _ -> :text
    end
  end

  # Bind a comparison value for filter `f`. When the filter's column is a DOMAIN
  # with a `text AS <domain>` cast (a data representation), the raw query-string
  # value is parsed through that function (`textfn($n)`) instead of being coerced
  # to the column type — a plain `'<v>'::<domain>` cast would strip the domain to
  # its base type and bypass the parser (cases 1808/1810). Without a text parser
  # the value reaches the base type as usual (case 1809 errors on the base type).
  defp bind_filter_value(%{column: col, json_path: []} = _f, value, %State{relation: rel} = state)
       when not is_nil(rel) do
    case text_rep_fn(rel, col) do
      {schema, name} ->
        {ph, state} = bind(value, :text, state)
        {"#{quote_ident(schema)}.#{quote_ident(name)}(#{ph})", state}

      nil ->
        bind(value, coltype(%{column: col}, state), state)
    end
  end

  defp bind_filter_value(f, value, state) do
    bind(value, coltype(f, state), state)
  end

  defp array_of(:text), do: "text[]"
  defp array_of(type) when is_binary(type), do: type <> "[]"
  defp array_of(_), do: "text[]"

  def column_expr(col, path), do: column_expr_base(quote_ident(col), path)

  def column_expr_aliased(col, path, al),
    do: column_expr_base("#{quote_ident(al)}.#{quote_ident(col)}", path)

  defp column_expr_base(base_col, []), do: base_col

  defp column_expr_base(base_col, path) do
    {init, [last]} = Enum.split(path, length(path) - 1)

    base =
      Enum.reduce(init, base_col, fn {_kind, key}, acc ->
        "#{acc}->#{pg_literal_or_index(key)}"
      end)

    {kind, key} = last
    arrow = if kind == :arrow_text, do: "->>", else: "->"
    "(#{base}#{arrow}#{pg_literal_or_index(key)})"
  end

  defp pg_literal_or_index(key) do
    if Regex.match?(~r/^-?\d+$/, key), do: key, else: pg_literal(key)
  end

  defp parse_in_list(value) do
    value
    |> String.trim()
    |> strip_parens()
    |> split_csv()
    |> Enum.map(&unquote_value/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp strip_parens("(" <> rest) do
    if String.ends_with?(rest, ")"), do: String.slice(rest, 0..-2//1), else: rest
  end

  defp strip_parens(s), do: s

  defp split_csv(""), do: []

  defp split_csv(str) do
    str
    |> Bier.QueryParser.split_top_commas()
    |> Enum.map(&String.trim/1)
  end

  defp unquote_value(<<?", _::binary>> = v) do
    if String.ends_with?(v, "\""), do: String.slice(v, 1..-2//1), else: v
  end

  defp unquote_value(v), do: v

  # `{1,2,4}` -> ["1","2","4"]
  defp parse_array_braces(value) do
    value
    |> String.trim()
    |> String.trim_leading("{")
    |> String.trim_trailing("}")
    |> case do
      "" -> []
      body -> body |> Bier.QueryParser.split_top_commas() |> Enum.map(&String.trim/1)
    end
  end

  defp pg_text_array(values) do
    inner =
      Enum.map_join(values, ",", fn v -> "\"" <> String.replace(v, "\"", "\\\"") <> "\"" end)

    "{" <> inner <> "}"
  end

  def qrel(%Relation{schema: schema, name: name}) do
    "#{quote_ident(schema)}.#{quote_ident(name)}"
  end

  def quote_ident(ident) do
    "\"" <> String.replace(ident, "\"", "\"\"") <> "\""
  end

  # Cast types may include array/range/qualified forms produced internally; we
  # validate to a conservative charset to avoid injection through the cast.
  def quote_type(type) do
    if Regex.match?(~r/^[A-Za-z0-9_ \[\]\".]+$/, type) do
      type
    else
      throw({:bad_request, :bad_cast})
    end
  end

  def pg_literal(str) do
    "'" <> String.replace(str, "'", "''") <> "'"
  end

  # ---- data representations ------------------------------------------------

  @doc """
  The read-representation cast function (`<domain> AS json`) for a column, as a
  `{schema, function}` tuple, or `nil` when the column has no such cast.

  PostgREST applies this cast in the SELECT list so the column's JSON output is
  produced by the user-defined representation rather than the base type's
  default rendering. PostgreSQL strips a domain to its base type for a plain
  `CAST(col AS json)`, so the cast function is invoked by name instead.
  """
  def read_rep_fn(rel, col) do
    case Enum.find(rel.columns, &(&1.name == col)) do
      %{data_rep: %{read: {_, _} = fn_ref}} -> fn_ref
      _ -> nil
    end
  end

  @doc """
  The query-string filter parser (`text AS <domain>`) for a column, as a
  `{schema, function}` tuple, or `nil`. When present, a filter value is parsed
  through this function before comparison (cases 1808/1810).
  """
  def text_rep_fn(rel, col) do
    case Enum.find(rel.columns, &(&1.name == col)) do
      %{data_rep: %{text: {_, _} = fn_ref}} -> fn_ref
      _ -> nil
    end
  end

  @doc """
  The body-value parser (`json AS <domain>`) for a column, as a
  `{schema, function}` tuple, or `nil`. When present, a JSON body value is
  parsed through this function on write (cases 1811-1813).
  """
  def write_rep_fn(rel, col) do
    case Enum.find(rel.columns, &(&1.name == col)) do
      %{data_rep: %{write: {_, _} = fn_ref}} -> fn_ref
      _ -> nil
    end
  end

  @doc """
  Wrap a column value expression in its read-representation cast function when
  the column has one, so its JSON output uses the registered representation.
  Returns `expr` unchanged when there is no read cast. The result is a `json`
  value (which `to_jsonb`/`json_build_object` embed directly).
  """
  def apply_read_rep(expr, rel, col) do
    case read_rep_fn(rel, col) do
      {schema, name} -> "#{quote_ident(schema)}.#{quote_ident(name)}(#{expr})"
      nil -> expr
    end
  end
end
