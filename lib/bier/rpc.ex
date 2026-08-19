defmodule Bier.Rpc do
  @moduledoc """
  Dispatches `/rpc/<fn>` calls across the function return kinds PostgREST
  supports: set-of-relation, set-of-scalar, scalar, scalar array, composite,
  record / TABLE / OUT-params, void, and the special single-unnamed-parameter
  functions whose argument is the raw request body (scalar / json).

  Resolution mirrors PostgREST:

    * the function is looked up in the `Accept-Profile`/`Content-Profile`
      schema (overloads are dispatched by the supplied argument names);
    * GET/HEAD invoke STABLE/IMMUTABLE procs as reads (a VOLATILE proc raises
      `25006` inside the read-only transaction and maps to 405);
    * POST binds args from the JSON body (an array body binds only its first
      object); a single unnamed json/jsonb parameter receives the whole body;
    * unsupported methods (PATCH/PUT/DELETE) are rejected with PGRST101 (405);
    * an unresolvable proc/signature returns PGRST202 (404) with PostgREST's
      hint/details (reported against the base `test` schema for area mirrors).

  Content negotiation runs first (`Bier.Negotiation`), so an Accept that no
  producer can satisfy yields 406 / PGRST107 before any SQL runs.
  """

  import Plug.Conn

  alias Bier.MediaType
  alias Bier.Negotiation
  alias Bier.Pagination
  alias Bier.Plugs.ActionController
  alias Bier.Plugs.Warning
  alias Bier.QueryExecutor
  alias Bier.QueryParser
  alias Bier.Render
  alias Bier.Response

  # Reserved query params that shape the result rather than bind arguments.
  @reserved ~w(select order limit offset on_conflict columns and or not)

  # Area-mirror schemas: PostgREST's RPC cases were authored against `test`, so
  # the not-found PGRST202 envelope reports `test.<fn>` even when resolution went
  # through a mirror label (e.g. `rpc`).
  @mirror_schemas ~w(rpc operators ordering pagination representations mutations config domain_representations)

  @doc """
  Resolve and run an RPC in the (already resolved) profile `schema`.

  The `Prefer` header is parsed with the same reader the relation path uses: a
  call plans as a `CallReadPlan`, and `responsePreferences` masks only the
  mutation-only preferences, passing count/handling/timezone through for every
  plan (`Response.hs#L296`). So an RPC echoes `Preference-Applied: count=exact`
  exactly like `GET /items` does — even for `count=planned`, which has no effect
  on a call — while `return=` is never echoed. The header goes on the request
  conn before the routine runs, so every success shape (setof, scalar, octet,
  void) carries it and an error path, which answers from the untouched conn in
  `Bier.Plugs.ActionController`, does not.
  """
  def dispatch(conn, config, schema, fn_name) do
    with :ok <- check_method(conn),
         {:ok, supplied} <- supplied_args(conn),
         {:ok, prefs} <- Bier.Preferences.parse_read(conn) do
      functions = Bier.SchemaCache.functions(config.name)
      overloads = Map.get(functions, {schema, fn_name}, [])

      case resolve_overload(overloads, supplied) do
        {:ok, fn_def, args} ->
          with :ok <- check_max_affected(prefs, fn_def) do
            conn
            |> Bier.Preferences.put_applied(prefs.applied)
            # Stash the requested zone for `exec/4` to apply inside the call's
            # transaction. Echoing `timezone=` in Preference-Applied without
            # applying it would claim a preference we did not honor.
            |> Plug.Conn.assign(:bier_timezone, prefs.timezone)
            |> run_resolved(config, fn_def, args)
          end

        :error ->
          {:error,
           {:rpc_not_found, not_found(conn, schema, fn_name, supplied, overloads, functions)}}
      end
    end
  end

  # PGRST128: `max-affected` caps how many rows a statement may affect, which is
  # only meaningful for a routine that can return more than one. PostgREST
  # decides this in `callReadPlan`, before the routine runs —
  # `failMaxAffectedRpcReturnsSingle (Just (PreferMaxAffected _), Just Strict)
  # rout = if funcReturnsSingle rout then Left …` (`Plan.hs#L238`) — and
  # `funcReturnsSingle` is true for EVERY non-set return type, `void` included
  # (`Routine.hs#L102-105`, #L122-124). `handling=lenient` (or no handling)
  # leaves the preference inert, exactly as it does on a mutation.
  defp check_max_affected(%{max_affected: cap, handling: :strict}, fn_def)
       when is_integer(cap) do
    if returns_set?(fn_def), do: :ok, else: {:error, :max_affected_rpc_single}
  end

  defp check_max_affected(_prefs, _fn_def), do: :ok

  defp returns_set?(%{retset: retset}), do: retset == true

  @doc """
  Resolve the routine an `OPTIONS /rpc/<fn>` request targets.

  PostgREST's `ActRoutineInfo` runs the same `callReadPlan` resolution a read
  invocation does (`ApiRequest.getAction` hands OPTIONS an `InvRead` method), so
  the overload is picked from the query-string argument names and an
  unresolvable signature is the usual PGRST202. Only the resolved routine is
  returned: the info response needs nothing but its volatility.
  """
  @spec resolve_routine(Plug.Conn.t(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resolve_routine(conn, config, schema, fn_name) do
    functions = Bier.SchemaCache.functions(config.name)
    overloads = Map.get(functions, {schema, fn_name}, [])

    with {:ok, supplied} <- supplied_args(conn),
         {:ok, prefs} <- Bier.Preferences.parse_read(conn) do
      case resolve_overload(overloads, supplied) do
        {:ok, fn_def, _args} ->
          # `failMaxAffectedRpcReturnsSingle` lives inside `callReadPlan`, which
          # `ActRoutineInfo`'s `InvRead True` invocation traverses too — so the
          # OPTIONS path rejects the same combination a GET would, rather than
          # answering `Allow` for a request the invocation would refuse.
          with :ok <- check_max_affected(prefs, fn_def), do: {:ok, fn_def}

        :error ->
          {:error,
           {:rpc_not_found, not_found(conn, schema, fn_name, supplied, overloads, functions)}}
      end
    end
  end

  # ---- method validation ---------------------------------------------------

  defp check_method(%Plug.Conn{method: m}) when m in ["GET", "HEAD", "POST"], do: :ok

  defp check_method(%Plug.Conn{method: m}) do
    {:error, {:rpc_invalid_method, m}}
  end

  # ---- argument collection -------------------------------------------------

  # Collect the caller-supplied argument values, keyed by name. Values are kept
  # as `{:scalar, string}` or `{:list, [string]}` (repeated GET params / POST
  # arrays). The special `:single_unnamed` value carries the raw POST body. The
  # second element of the {:ok, ...} tuple is the *reserved* query params (the
  # query string with arg params removed) for shaping setof results.
  # OPTIONS resolves the routine through the same read-invocation path PostgREST
  # uses for it (`ActRoutineInfo … (InvRead True)`), so its arguments come from
  # the query string like a GET's.
  defp supplied_args(%Plug.Conn{method: m} = conn) when m in ["GET", "HEAD", "OPTIONS"] do
    args =
      conn.query_string
      |> URI.query_decoder()
      |> Enum.reject(fn {k, _v} -> k in @reserved end)
      |> repeated_args()

    {:ok, args}
  end

  defp supplied_args(%Plug.Conn{method: "POST"} = conn) do
    raw = conn.assigns[:bier_raw_body] || ""

    cond do
      # An application/octet-stream body is NOT JSON: it is bound verbatim as the
      # whole single-unnamed parameter (e.g. a bytea function), with the raw bytes
      # passed through a real bound parameter (case 1622).
      octet_stream?(conn) ->
        {:ok, %{__body__: {:single_unnamed_raw, raw}}}

      # An application/x-www-form-urlencoded invocation binds its arguments from
      # the form body through the same DirectArgs path a GET uses —
      # `(Inv, MTUrlEncoded) -> DirectArgs $ maybe mempty (toRpcParams proc .
      # payArray) iPayload` (`Plan.hs#L222`) — so a field repeated in the body
      # feeds a VARIADIC parameter exactly as a repeated query parameter does
      # (case 1442). There is no whole-body fallback: the form fields ARE the
      # named arguments.
      form_urlencoded?(conn) ->
        {:ok, raw |> URI.query_decoder() |> repeated_args()}

      raw == "" ->
        {:ok, %{}}

      true ->
        json_body_args(raw)
    end
  end

  # A JSON invocation binds the body object's top-level keys as named arguments,
  # and keeps the raw body around as the single-unnamed-json/jsonb fallback.
  defp json_body_args(raw) do
    case Bier.json_library().decode(raw) do
      {:ok, map} when is_map(map) ->
        {:ok, body_object_args(map, raw)}

      # An array body binds only its first object (PostgREST RpcSpec L860).
      {:ok, [first | _]} when is_map(first) ->
        {:ok, body_object_args(first, raw)}

      {:ok, _other} ->
        # Non-object body: only consumable by a single unnamed json param.
        {:ok, %{__body__: {:single_unnamed, raw}}}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  # Fold `{key, value}` pairs into the supplied-argument map, collapsing a key
  # that repeats into a `{:list, …}` in occurrence order. `URI.query_decoder/1`
  # applies the same `+`-to-space and percent-decoding `parseSimpleQuery` does,
  # so a query string and a form body fold identically.
  defp repeated_args(pairs) do
    Enum.reduce(pairs, %{}, fn {k, v}, acc ->
      Map.update(acc, k, {:scalar, v}, fn
        {:scalar, prev} -> {:list, [prev, v]}
        {:list, list} -> {:list, list ++ [v]}
      end)
    end)
  end

  defp octet_stream?(conn), do: content_type?(conn, "application/octet-stream")

  defp form_urlencoded?(conn), do: content_type?(conn, "application/x-www-form-urlencoded")

  defp content_type?(conn, mime) do
    case get_req_header(conn, "content-type") do
      [value | _] -> String.contains?(String.downcase(value), mime)
      [] -> false
    end
  end

  defp body_object_args(map, raw) do
    map
    |> Map.new(fn {k, v} -> {k, {:json, v}} end)
    |> Map.put(:__body__, {:single_unnamed, raw})
  end

  # ---- overload resolution -------------------------------------------------

  # Pick the overload whose IN parameters can be satisfied by the supplied named
  # args, or (failing that) the single-unnamed-json overload that swallows the
  # whole body. Returns the bound arg list for the SQL call.
  defp resolve_overload(overloads, supplied) do
    all_named = Map.drop(supplied, [:__body__])

    # Keys that name an argument of some overload bind args; the rest are result
    # filters/shaping (handled by the read plan for setof functions). Restrict the
    # candidate arg set to known param names so a filter like `id=gt.1` on a
    # no-arg setof function does not block resolution.
    all_params =
      overloads
      |> Enum.flat_map(fn fn_def -> Enum.map(fn_def.args, & &1.name) end)
      |> MapSet.new()

    named = Map.take(all_named, MapSet.to_list(all_params))
    named_keys = MapSet.new(Map.keys(named))
    extra_keys = MapSet.difference(MapSet.new(Map.keys(all_named)), all_params)

    cond do
      match = Enum.find(overloads, &named_match?(&1, named_keys)) ->
        # Leftover non-param keys are result filters only for a setof/table
        # relation result; for scalar/composite returns an unknown param is an
        # unresolvable signature (PGRST202), matching PostgREST.
        if MapSet.size(extra_keys) == 0 or match.ret_kind == :setof_rel do
          {:ok, match, bind_named_args(match, named)}
        else
          :error
        end

      # Fall back to a single unnamed json/jsonb parameter binding the whole body.
      body = supplied[:__body__] ->
        case Enum.find(overloads, & &1.single_unnamed?) do
          nil -> :error
          fn_def -> {:ok, fn_def, [bind_unnamed(fn_def, body)]}
        end

      true ->
        :error
    end
  end

  # An overload matches when every supplied key is one of its IN params and every
  # required (no-default, non-variadic) IN param is supplied.
  defp named_match?(fn_def, named_keys) do
    param_names = MapSet.new(fn_def.args, & &1.name)

    required =
      fn_def.args
      |> Enum.reject(fn a -> a.has_default? or a.variadic? end)
      |> MapSet.new(& &1.name)

    not fn_def.single_unnamed? and
      MapSet.subset?(named_keys, param_names) and
      MapSet.subset?(required, named_keys)
  end

  defp bind_named_args(fn_def, named) do
    fn_def.args
    |> Enum.filter(fn a -> Map.has_key?(named, a.name) end)
    |> Enum.map(fn a ->
      {a.name, a.type, a.variadic?, coerce_value(a, Map.fetch!(named, a.name))}
    end)
  end

  defp bind_unnamed(fn_def, {:single_unnamed, raw}) do
    [arg] = fn_def.args
    {arg.name, arg.type, false, {:raw, raw}}
  end

  # An octet-stream body bound to a single unnamed parameter (e.g. bytea): pass
  # the raw bytes through a real bound parameter so binary content is preserved.
  defp bind_unnamed(fn_def, {:single_unnamed_raw, raw}) do
    [arg] = fn_def.args
    {arg.name, arg.type, false, {:param, raw}}
  end

  # Normalize a supplied value to a binding instruction.
  #   * variadic arg: always a list of strings.
  #   * scalar arg: a single string (repeated GET params -> last wins).
  #   * json body value: bound as a typed literal (encode non-strings to JSON).
  defp coerce_value(%{variadic?: true}, {:list, list}), do: {:list, list}
  defp coerce_value(%{variadic?: true}, {:scalar, v}), do: {:list, [v]}

  defp coerce_value(%{variadic?: true}, {:json, list}) when is_list(list),
    do: {:list, Enum.map(list, &to_text/1)}

  defp coerce_value(%{variadic?: true}, {:json, v}), do: {:list, [to_text(v)]}

  defp coerce_value(_arg, {:list, list}), do: {:scalar, List.last(list)}
  defp coerce_value(_arg, {:scalar, v}), do: {:scalar, v}
  defp coerce_value(_arg, {:json, v}) when is_binary(v), do: {:scalar, v}
  defp coerce_value(_arg, {:json, v}), do: {:scalar, to_text(v)}

  defp to_text(v) when is_binary(v), do: v
  defp to_text(v) when is_number(v) or is_boolean(v), do: to_string(v)
  defp to_text(v), do: Bier.json_library().encode!(v)

  # ---- running the resolved function ---------------------------------------

  defp run_resolved(conn, config, fn_def, args) do
    case Bier.CustomMedia.maybe_rpc(conn, config, fn_def) do
      :no_handler -> run(conn, config, fn_def, args)
      result -> result
    end
  end

  # void -> 204, no body, no Content-Type. response.headers / response.status
  # GUCs the function set still apply (e.g. set_cookie_twice emits Set-Cookie).
  defp run(conn, config, %{ret_kind: :void} = fn_def, args) do
    pool = Bier.Registry.via(config.name, Postgrex)
    {arg_sql, params} = build_call_args(args)
    sql = "SELECT #{qfn(fn_def)}(#{arg_sql})"

    case exec(pool, conn, sql, params) do
      {:ok, _result, guc} ->
        conn
        |> delete_resp_header("content-type")
        |> Bier.Guc.put_headers(guc)
        |> send_resp(Bier.Guc.status(guc, 204), "")

      {:error, _} = err ->
        err
    end
  end

  # SETOF <exposed relation> -> table-valued source: select/filter/limit shaping
  # and Content-Range, via the existing read pipeline.
  defp run(conn, config, %{ret_kind: :setof_rel} = fn_def, args) do
    relations = Bier.SchemaCache.relations(config.name)

    case Map.fetch(relations, {fn_def.ret_schema, fn_def.ret_relation}) do
      {:ok, ret_rel} ->
        with {:ok, media} <-
               Negotiation.resolve(conn, ActionController.read_producers(config)),
             {:ok, plan} <- parse_plan(conn, config, fn_def) do
          conn
          |> Warning.record(plan)
          |> run_setof_rel(config, fn_def, ret_rel, args, plan, media, relations)
        end

      :error ->
        {:error, :rpc_unsupported}
    end
  end

  # Everything else: scalar / scalar-array / setof-scalar / composite /
  # record / OUT params. We render the function result as JSON ourselves,
  # plus whatever media type the routine itself registers a handler for.
  defp run(conn, config, fn_def, args) do
    producers = ActionController.read_producers(config) ++ routine_producers(fn_def)

    with {:ok, media} <- Negotiation.resolve(conn, producers) do
      pool = Bier.Registry.via(config.name, Postgrex)
      {arg_sql, params} = build_call_args(args)
      from = "#{qfn(fn_def)}(#{arg_sql})"

      run_call(conn, pool, fn_def, from, params, media)
    end
  end

  defp run_call(conn, pool, fn_def, from, params, %MediaType{symbol: :plan} = media) do
    explain(conn, pool, media, fn ->
      {:ok, result_sql(fn_def, from, MediaType.for_symbol(:json)), params}
    end)
  end

  defp run_call(conn, pool, fn_def, from, params, media) do
    case exec(pool, conn, result_sql(fn_def, from, media), params) do
      {:ok, %Postgrex.Result{rows: [[body]]}, guc} ->
        render_result(conn, fn_def, body, media, guc)

      {:ok, %Postgrex.Result{rows: []}, guc} ->
        render_result(conn, fn_def, empty_body(fn_def), media, guc)

      {:error, _} = err ->
        err
    end
  end

  # `application/vnd.pgrst.plan` over a call. Upstream has no RPC-specific plan
  # code: `mtSnippet` wraps the WHOLE statement — the routine invocation
  # included — in `explainF`, and it does so for `mainCall` exactly as it does
  # for `mainRead` (`Query/Statements.hs`), so both call paths funnel through
  # here. The explained statement is the JSON-bodied one, matching what
  # `Bier.Plan` already explains for a relation read whatever the plan's `for=`
  # target says.
  #
  # `EXPLAIN` without `ANALYZE` plans but does not execute, so the routine
  # itself never runs — which is also why this can share the ordinary `exec/4`
  # transaction (role switch, request GUCs, pre-request hook, cancellation)
  # without a VOLATILE routine tripping the GET path's read-only transaction.
  defp explain(conn, pool, media, build) do
    with {:ok, sql, params} <- Bier.ServerTiming.measure(:plan, build) do
      case exec(pool, conn, Bier.Plan.explain_sql(media, sql), params) do
        {:ok, %Postgrex.Result{rows: rows}, _guc} -> Bier.Plan.render(conn, media, rows)
        {:error, _} = err -> err
      end
    end
  catch
    {:bad_request, _} = err -> {:error, err}
    {:embed_error, _} = err -> {:error, err}
    {:embed_error_raw, reason} -> {:error, reason}
  end

  # A plan asks for the shaped read query itself, built but not run.
  defp run_setof_rel(
         conn,
         config,
         fn_def,
         ret_rel,
         args,
         plan,
         %MediaType{symbol: :plan} = media,
         relations
       ) do
    pool = Bier.Registry.via(config.name, Postgrex)
    count_mode = Pagination.call_count_mode(conn)
    exec_args = Enum.map(args, fn {n, t, _v?, val} -> {n, t, value_for_named(val)} end)

    explain(conn, pool, media, fn ->
      QueryExecutor.build_function(
        fn_def,
        ret_rel,
        exec_args,
        plan,
        relations,
        :json,
        count_mode
      )
    end)
  end

  # The :setof_rel read itself, once media/plan have resolved: the function
  # call becomes the FROM source of the shaped read, run under the
  # client-disconnect watcher AND the per-request auth context (role switch,
  # request GUCs, db-pre-request) like any relation read — issue #108.
  defp run_setof_rel(conn, config, fn_def, ret_rel, args, plan, media, relations) do
    pool = Bier.Registry.via(config.name, Postgrex)
    count_mode = Pagination.call_count_mode(conn)
    exec_args = Enum.map(args, fn {n, t, _v?, val} -> {n, t, value_for_named(val)} end)

    result =
      Bier.Cancellation.run(conn, config, fn ->
        QueryExecutor.run_function(pool, fn_def, ret_rel, exec_args, plan,
          count_mode: count_mode,
          relations: relations,
          auth: ActionController.auth_setup(conn, config),
          format: MediaType.executor_format(media),
          statement_cache: config.db_prepared_statements
        )
      end)

    case result do
      {:ok, %{body: body, count: count}} ->
        columns = ActionController.csv_columns(plan, ret_rel)
        Response.render(conn, body, count, plan, count_mode, media, columns: columns)

      other ->
        other
    end
  end

  # The producers a routine adds on top of the generally-available read set.
  #
  # `initialMediaHandlers` — PostgREST's entire built-in handler map — holds
  # exactly `*/*`, application/json, text/csv and application/geo+json
  # (`SchemaCache.hs#L1016-L1021`); application/octet-stream is NOT among them.
  # A routine registers a handler for it by RETURNING the DOMAIN named after the
  # mime (`SchemaCache.hs#L1080-L1086`), which is the only way it becomes
  # negotiable on a call: a routine returning plain `bytea` — or, as in case
  # 1623, plain `integer` — is not negotiable as octet-stream, and neither is a
  # routine merely because its result is scalar. Aggregate-registered media
  # types are served earlier, by `Bier.CustomMedia`.
  defp routine_producers(fn_def) do
    if return_media_type(fn_def) == "application/octet-stream", do: [:octet], else: []
  end

  # The mime a routine's return-type DOMAIN names, or nil when the return type
  # is not a mime-named domain. `format_type` renders the domain as
  # `schema."name"` (or bare `"name"` when the schema is in the search path), so
  # strip the qualification and the identifier quotes before testing the shape.
  defp return_media_type(%{ret_type: type}) when is_binary(type) do
    name = type |> String.split(".") |> List.last() |> String.trim("\"")
    if String.contains?(name, "/"), do: name
  end

  defp return_media_type(_fn_def), do: nil

  # ---- result SQL shapes ---------------------------------------------------
  #
  # The media-specific shapes come first, then the return-kind ones: upstream
  # picks the body expression by media type (`handlerF`) and only then lets the
  # routine's return kind pick the branch inside it (`asJsonF`, `asCsvF` over
  # whatever `_postgrest_t` the call produced — `Query/Statements.hs` `mainCall`),
  # so every return kind gets a real CSV rather than a JSON body wearing a CSV
  # `Content-Type` (#119).

  # An octet-stream scalar result returns the raw bytes (cast to bytea), not a
  # JSON encoding (cases 1622/1623).
  defp result_sql(_fn_def, from, %MediaType{symbol: :octet}),
    do: "SELECT (#{from})::bytea"

  # geo+json: aggregate the result rows into a FeatureCollection via
  # ST_AsGeoJSON over the row record; a result without a geometry column
  # raises 22023 at execution, mirroring PostgREST.
  defp result_sql(fn_def, from, %MediaType{symbol: :geojson}) do
    inner =
      case fn_def.ret_kind do
        kind when kind in [:setof_record, :composite] -> "SELECT * FROM #{from}"
        _scalar -> "SELECT #{from} AS _v"
      end

    "SELECT json_build_object('type', 'FeatureCollection', 'features', " <>
      "coalesce(json_agg(ST_AsGeoJSON(t)::json), '[]'))::text FROM (#{inner}) t"
  end

  # CSV over a row-shaped result — setof-record and single composite alike. No
  # exposed relation backs an anonymous `TABLE(...)`/OUT-params return, so
  # nothing supplies an ordered column list and `Bier.Render` used to fall back
  # to the sorted keys of a decoded row. Rendering the rows as ordered
  # `[key, value]` pairs carries the routine's declared column order (and the
  # exact cell text) out of PostgreSQL instead (#110) — the same expression the
  # relation reads use.
  defp result_sql(%{ret_kind: kind}, from, %MediaType{symbol: :csv})
       when kind in [:setof_record, :composite],
       do: csv_pairs_sql("SELECT * FROM #{from}")

  # CSV over a scalar / set-of-scalar result. The returned value has no column
  # name of its own, so upstream's CSV header picks up the alias the call query
  # gave it: `callPlanToQuery` wraps the call as `(SELECT fn(…) pgrst_scalar)
  # pgrst_call` (`QueryBuilder.hs`), and `asCsvHeaderF` reads the source CTE's
  # `json_object_keys`. So a scalar comes back as a one-column CSV headed
  # `pgrst_scalar` — verified by running upstream's own `asCsvF` against
  # PostgreSQL.
  defp result_sql(_fn_def, from, %MediaType{symbol: :csv}),
    do: csv_pairs_sql("SELECT #{from} AS pgrst_scalar")

  # Array-of-objects for setof-record / multi-OUT setof. Wrapping the call in a
  # `(SELECT * FROM fn())` subquery keeps `t` a proper composite row even for a
  # single OUT/TABLE column (a bare `FROM fn() t` collapses to the scalar).
  defp result_sql(%{ret_kind: :setof_record}, from, media),
    do: "SELECT #{agg_body("t", media)} FROM (SELECT * FROM #{from}) t"

  # Array-of-scalars for setof-scalar.
  defp result_sql(%{ret_kind: :setof_scalar}, from, media),
    do: "SELECT #{agg_body("t._v", media)} FROM (SELECT #{from} AS _v) t"

  # Single object for a composite / OUT-params single-row return.
  defp result_sql(%{ret_kind: :composite}, from, media),
    do: "SELECT #{single_body("t", media)} FROM (SELECT * FROM #{from}) t"

  # Bare scalar (incl. scalar arrays) -> JSON value of the single returned value.
  defp result_sql(_fn_def, from, media),
    do: "SELECT #{single_body("_v", media)} FROM (SELECT #{from} AS _v) t"

  defp csv_pairs_sql(source) do
    "SELECT coalesce(json_agg(#{QueryExecutor.csv_row_pairs("t")}), '[]')::text " <>
      "FROM (#{source}) t"
  end

  # The array aggregate for the two set-returning shapes, with `nulls=stripped`
  # applied in SQL (`json_strip_nulls`, upstream's `addNullsToSnip`) rather than
  # by re-encoding in `Bier.Render` — a decode/encode round trip loses JSON key
  # order and the exact numeric text PostgreSQL emitted (#109).
  defp agg_body(row, media),
    do: "coalesce(#{strip("json_agg(#{row})", media)}, '[]')::text"

  # The single-row aggregate, which is upstream's expression rather than a
  # `to_jsonb`: `asJsonF`/`asJsonSingleF` build the `returnsScalar` and
  # `returnsSingleComposite` branches as `json_agg(_postgrest_t…)->0`, and
  # `addNullsToSnip` wraps *those* in `json_strip_nulls` too — so
  # `nulls=stripped` applies to a scalar/composite return, which it silently did
  # not before (#119).
  #
  # Going through `json` rather than `jsonb` matters for the same reason #109
  # kept the array bodies out of Elixir: `jsonb` sorts object keys and pads them
  # with spaces, so a `json`-returning routine came back as `{"a": null, "b": 1}`
  # where PostgreSQL (and upstream) say `{"b":1,"a":null}`. It also settles the
  # NULL case — `to_jsonb` is strict, so a routine returning SQL NULL produced a
  # NULL body, while an aggregate over that row yields the JSON text `null`.
  defp single_body(row, media),
    do: "coalesce(#{strip("json_agg(#{row})->0", media)}, 'null')::text"

  defp strip(snippet, %MediaType{params: %{strip: true}}),
    do: "json_strip_nulls(#{snippet})"

  defp strip(snippet, _media), do: snippet

  defp empty_body(%{ret_kind: kind}) when kind in [:setof_record, :setof_scalar], do: "[]"
  defp empty_body(_), do: "null"

  # ---- rendering -----------------------------------------------------------

  # setof results render as a (possibly paginated) array with Content-Range.
  defp render_result(conn, %{ret_kind: kind} = _fn_def, body, media, guc)
       when kind in [:setof_record, :setof_scalar] do
    count_mode = Pagination.call_count_mode(conn)
    count = if count_mode == :none, do: 0, else: Response.row_count(body)

    conn = Bier.Guc.put_headers(conn, guc)
    Response.render(conn, body, count, %{offset: 0}, count_mode, media, [])
  end

  # scalar / composite render as a single value/object. A singular Accept on a
  # scalar still returns the bare value (the scalar is the single object).
  defp render_result(conn, _fn_def, body, %MediaType{symbol: :octet}, guc) do
    conn
    |> Bier.Guc.put_headers(guc)
    |> put_resp_header("content-type", "application/octet-stream")
    |> send_resp(Bier.Guc.status(guc, 200), octet_body(body))
  end

  # CSV: `result_sql/3` built the body as the ordered `[key, value]` pairs of
  # the result row, so `Bier.Render` writes it exactly as it does for a relation
  # read. Before #119 this clause did not exist and the JSON body went out under
  # the CSV `Content-Type`. The row count is fixed at one here, so the body goes
  # through `Bier.Render` directly rather than through `Bier.Response`, which
  # would re-derive `Content-Range` from a body that is no longer a row array.
  defp render_result(conn, _fn_def, body, %MediaType{symbol: :csv} = media, guc) do
    case Render.render(media, body, columns: []) do
      {:ok, out} -> send_single(conn, out, media, guc)
      {:error, _} = err -> err
    end
  end

  defp render_result(conn, _fn_def, body, media, guc),
    do: send_single(conn, body, media, guc)

  defp send_single(conn, body, media, guc) do
    count_mode = Pagination.call_count_mode(conn)
    out = body_for(conn, body)

    conn
    |> Bier.Guc.put_headers(guc)
    |> put_resp_header("content-type", MediaType.content_type(media))
    |> maybe_scalar_content_range(count_mode)
    |> put_resp_header("content-length", Integer.to_string(byte_size(out)))
    |> send_resp(Bier.Guc.status(guc, 200), out)
  end

  # A scalar/composite result is one row: PostgREST always emits a read-style
  # Content-Range for it — `0-0/*` by default, `0-0/1` when a count preference
  # supplies the total (live-verified against 14.12; frozen case 1403).
  defp maybe_scalar_content_range(conn, :none),
    do: put_resp_header(conn, "content-range", Pagination.content_range(0, 1, nil))

  defp maybe_scalar_content_range(conn, _count_mode),
    do: put_resp_header(conn, "content-range", Pagination.content_range(0, 1, 1))

  defp body_for(%Plug.Conn{method: "HEAD"}, _body), do: ""
  defp body_for(_conn, body), do: body

  defp octet_body(value) when is_binary(value), do: value
  defp octet_body(nil), do: ""
  defp octet_body(value), do: to_string(value)

  # ---- SQL building --------------------------------------------------------

  # Build the positional `$n` argument list for the function call, applying
  # VARIADIC / keyword-call syntax. Variadic args are bound as a typed array.
  defp build_call_args(args) do
    {parts, {params, _idx}} = Enum.map_reduce(args, {[], 1}, &call_arg/2)
    {Enum.join(parts, ", "), Enum.reverse(params)}
  end

  # Bind the array as a text[] param and cast to the target element type;
  # Postgres coerces the text[] to the variadic element array.
  defp call_arg({name, type, true = _variadic?, value}, {params, idx}) do
    {:list, list} = ensure_list(value)
    {"VARIADIC \"#{name}\" => $#{idx}::#{type}", {[list | params], idx + 1}}
  end

  # Raw binary (octet-stream) bound through a real parameter and cast to the
  # arg type (e.g. bytea), preserving the exact bytes.
  defp call_arg({name, type, _variadic?, {:param, raw}}, {params, idx}) do
    {keyword_call(name, "$#{idx}::#{type}"), {[raw | params], idx + 1}}
  end

  # Bind the scalar value as a text parameter and cast it to the arg type
  # server-side: `($n::text)::<type>` pins the parameter itself to text (so the
  # raw string encodes as-is) and the outer cast is PostgreSQL's I/O-conversion
  # cast — the same coercion, and the same errors, as an unknown
  # `'<escaped>'::<type>` literal. Binding keeps the SQL text identical across
  # calls that differ only in argument values, so the `db_prepared_statements`
  # cache is effective (mirrors `QueryExecutor.bind/3`).
  defp call_arg({name, type, _variadic?, value}, {params, idx}) do
    {keyword_call(name, "($#{idx}::text)::#{type}"),
     {[to_string(scalar_value(value)) | params], idx + 1}}
  end

  # An unnamed parameter (single-unnamed json/jsonb body) binds positionally;
  # named params use keyword-call syntax.
  defp keyword_call(name, value) when name in ["", nil], do: value
  defp keyword_call(name, value), do: "\"#{name}\" => #{value}"

  defp ensure_list({:list, list}), do: {:list, list}
  defp ensure_list({:scalar, v}), do: {:list, [v]}
  defp ensure_list({:raw, v}), do: {:list, [v]}

  defp scalar_value({:scalar, v}), do: v
  defp scalar_value({:raw, v}), do: v
  defp scalar_value({:list, list}), do: List.last(list)

  defp value_for_named({:scalar, v}), do: v
  defp value_for_named({:raw, v}), do: v
  defp value_for_named({:list, list}), do: list

  # ---- helpers -------------------------------------------------------------

  # Run the call inside a transaction and read the PostgREST response GUCs
  # (response.headers / response.status) the function may have set, before the
  # transaction ends. GET/HEAD run READ ONLY so a VOLATILE proc raises 25006
  # (mapped to 405). Returns `{:ok, result, guc}` or `{:error, reason}` (the GUC
  # read may itself fail with PGRST111/PGRST112).
  defp exec(pool, %Plug.Conn{method: m} = conn, sql, params) do
    read_only? = m in ["GET", "HEAD"]
    config = instance_config(conn)
    auth = ActionController.auth_setup(conn, config)

    timezone = conn.assigns[:bier_timezone]

    Bier.Cancellation.run(conn, config, fn ->
      exec_transaction(
        pool,
        read_only?,
        auth,
        sql,
        params,
        timezone,
        config.db_prepared_statements
      )
    end)
    |> case do
      {:ok, {result, guc}} -> {:ok, result, guc}
      {:error, %Postgrex.Error{} = err} -> map_auth_error(auth, err)
      {:error, other} -> {:error, other}
    end
  end

  defp exec_transaction(pool, read_only?, auth, sql, params, timezone, cache?) do
    Bier.ServerTiming.measure(:transaction, fn ->
      Postgrex.transaction(pool, fn tx ->
        if read_only?, do: Postgrex.query!(tx, "SET TRANSACTION READ ONLY", [])
        apply_auth(tx, auth)

        case Bier.QueryExecutor.set_local_timezone(tx, timezone, cache?) do
          :ok -> query_then_read_gucs(tx, sql, params, cache?)
          {:error, err} -> Postgrex.rollback(tx, err)
        end
      end)
    end)
  end

  defp query_then_read_gucs(tx, sql, params, cache?) do
    Bier.RequestLog.record(sql)

    with {:ok, result} <- Postgrex.query(tx, sql, params, Bier.StatementCache.opts(cache?, sql)),
         {:ok, guc} <- Bier.Guc.read(tx, cache?) do
      {result, guc}
    else
      {:error, reason} -> Postgrex.rollback(tx, reason)
    end
  end

  # Apply the auth context (role + request GUCs + pre-request hook) on the
  # transaction connection. No-op when the request schema does not require it.
  defp apply_auth(_tx, nil), do: :ok

  defp apply_auth(tx, {context, config}) do
    Bier.Auth.with_context(tx, context, config, fn _tx -> :ok end)
  end

  defp map_auth_error(nil, err), do: {:error, err}
  defp map_auth_error({context, _config}, err), do: Bier.Auth.map_error(context, err)

  defp instance_config(conn) do
    Bier.Registry.config(conn.assigns.supervisor_name)
  end

  defp parse_plan(conn, config, fn_def) do
    # Strip only the function's actual argument params from the query string
    # before parsing the read plan; remaining params (e.g. `id=gt.1`) are result
    # filters/select/order/limit/offset operating on the returned rows.
    arg_keys = MapSet.new(fn_def.args, & &1.name)

    reserved_qs =
      conn.query_string
      |> URI.query_decoder()
      |> Enum.reject(fn {k, _v} -> MapSet.member?(arg_keys, k) end)
      |> URI.encode_query()

    Bier.ServerTiming.measure(:parse, fn ->
      with {:ok, plan} <- QueryParser.parse_request(reserved_qs),
           {:ok, plan} <- Pagination.apply_window(plan, conn, config.db_max_rows) do
        Bier.Embed.resolve_target_names(plan, config.url_use_legacy_target_names)
      end
    end)
  end

  # Build the PGRST202 not-found envelope (`Error.hs#L246-L272`), reporting
  # against the base `test` schema for mirror labels.
  #
  # `argumentKeys` is a Set upstream, so the supplied names are reported sorted.
  # `fmtPrms` renders them as a parenthesized list in the message and as
  # " with parameter(s) …" in the details, and collapses BOTH to
  # " without parameters" when nothing was supplied (case 1443). A JSON
  # invocation also searched the whole-body (single unnamed json/jsonb) overload
  # and says so (case 1439); a text/xml/octet-stream invocation binds no named
  # arguments at all — `onlySingleParams` — so it names the parameter's type
  # instead and carries no hint.
  defp not_found(conn, schema, fn_name, supplied, overloads, functions) do
    reported = reported_schema(schema)
    named = supplied |> Map.drop([:__body__]) |> Map.keys() |> Enum.sort()
    func = "#{reported}.#{fn_name}"
    single_body = single_body_param(conn)

    %{
      code: "PGRST202",
      message:
        "Could not find the function #{func}#{message_params(named, single_body)}" <>
          " in the schema cache",
      details:
        "Searched for the function #{func}#{details_params(named, single_body, conn)}," <>
          " but no matches were found in the schema cache.",
      hint: not_found_hint(schema, reported, fn_name, overloads, named, functions, single_body)
    }
  end

  # `onlySingleParams`: a POST whose Content-Type is one of the three
  # single-unnamed-parameter body types (Error.hs#L253-L258).
  @single_body_types [
    {"text/plain", "text"},
    {"text/xml", "xml"},
    {"application/octet-stream", "bytea"}
  ]

  defp single_body_param(%Plug.Conn{method: "POST"} = conn) do
    Enum.find_value(@single_body_types, fn {mime, kind} ->
      if content_type?(conn, mime), do: kind
    end)
  end

  defp single_body_param(_conn), do: nil

  defp message_params(_named, kind) when is_binary(kind), do: ""
  defp message_params([], nil), do: " without parameters"
  defp message_params(named, nil), do: "(" <> Enum.join(named, ", ") <> ")"

  defp details_params(_named, kind, _conn) when is_binary(kind),
    do: " with a single unnamed #{kind} parameter"

  defp details_params(named, nil, conn), do: fmt_params(named) <> json_body_tail(conn)

  defp fmt_params([]), do: " without parameters"
  defp fmt_params([one]), do: " with parameter #{one}"
  defp fmt_params(named), do: " with parameters " <> Enum.join(named, ", ")

  # A JSON invocation searched the single-unnamed-json/jsonb overload too. The
  # request media type defaults to application/json when the POST carries no
  # Content-Type, exactly as `iContentMediaType` does.
  defp json_body_tail(%Plug.Conn{method: "POST"} = conn) do
    if get_req_header(conn, "content-type") == [] or content_type?(conn, "application/json"),
      do: " or with a single unnamed json/jsonb parameter",
      else: ""
  end

  defp json_body_tail(_conn), do: ""

  # `noRpcHint` (`Error.hs#L372`) has two arms, chosen by whether the name
  # matched any routine at all. With no same-named overload it fuzzy-matches the
  # PROC NAME against the requested schema's routines, keeping the single best
  # above `getFuzzyHint`'s 0.75 minimum score (`Error.hs#L397-L403`) — case
  # 1443. With same-named overloads it keeps the name and hints the closest
  # parameter list among them (case 1433). `onlySingleParams` suppresses the
  # hint entirely.
  @rpc_hint_min_score 0.75

  defp not_found_hint(_schema, _reported, _fn_name, _overloads, _named, _functions, kind)
       when is_binary(kind),
       do: nil

  defp not_found_hint(schema, reported, fn_name, [], _named, functions, nil) do
    candidates = for {{^schema, name}, _overloads} <- functions, do: name

    case Bier.Fuzzy.best_match(fn_name, candidates, @rpc_hint_min_score) do
      nil -> nil
      match -> "Perhaps you meant to call the function #{reported}.#{match}"
    end
  end

  defp not_found_hint(_schema, reported, fn_name, overloads, named, _functions, nil) do
    hint_signature(reported, fn_name, overloads, named)
  end

  # The closest real signature for an existing function name, rendered as
  # `<schema>.<fn>(arg, arg)`. PostgREST only hints when an overload shares at
  # least one parameter name with what was supplied (e.g. add_them(a,b) for a
  # call carrying a, b, smthelse); a wholly-disjoint signature gets no hint.
  # `listToText` sorts the parameter list it renders.
  defp hint_signature(reported, fn_name, overloads, named_keys) do
    supplied = MapSet.new(named_keys)

    candidate =
      Enum.find(overloads, fn fn_def ->
        params = MapSet.new(fn_def.args, & &1.name)
        not MapSet.disjoint?(params, supplied)
      end)

    case candidate do
      nil ->
        nil

      fn_def ->
        arg_names = fn_def.args |> Enum.map(& &1.name) |> Enum.sort() |> Enum.join(", ")
        "Perhaps you meant to call the function #{reported}.#{fn_name}(#{arg_names})"
    end
  end

  defp reported_schema(schema) when schema in @mirror_schemas, do: "test"
  defp reported_schema(schema), do: schema

  defp qfn(%{schema: schema, name: name}), do: "#{q(schema)}.#{q(name)}"

  defp q(ident), do: "\"" <> String.replace(ident, "\"", "\"\"") <> "\""
end
