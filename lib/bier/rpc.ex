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
  alias Bier.QueryExecutor
  alias Bier.QueryParser
  alias Bier.Response

  # Reserved query params that shape the result rather than bind arguments.
  @reserved ~w(select order limit offset on_conflict columns and or not)

  # Area-mirror schemas: PostgREST's RPC cases were authored against `test`, so
  # the not-found PGRST202 envelope reports `test.<fn>` even when resolution went
  # through a mirror label (e.g. `rpc`).
  @mirror_schemas ~w(rpc operators ordering pagination representations mutations config domain_representations)

  @doc "Resolve and run an RPC in the (already resolved) profile `schema`."
  def dispatch(conn, config, schema, fn_name) do
    with :ok <- check_method(conn) do
      functions = Bier.SchemaCache.functions(config.name)
      overloads = Map.get(functions, {schema, fn_name}, [])

      with {:ok, supplied} <- supplied_args(conn) do
        case resolve_overload(overloads, supplied) do
          {:ok, fn_def, args} ->
            run_resolved(conn, config, fn_def, args)

          :error ->
            {:error, {:rpc_not_found, not_found(schema, fn_name, supplied, overloads)}}
        end
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
  defp supplied_args(%Plug.Conn{method: m} = conn) when m in ["GET", "HEAD"] do
    pairs =
      conn.query_string
      |> URI.query_decoder()
      |> Enum.to_list()

    {arg_pairs, _reserved} =
      Enum.split_with(pairs, fn {k, _v} -> k not in @reserved end)

    args =
      Enum.reduce(arg_pairs, %{}, fn {k, v}, acc ->
        Map.update(acc, k, {:scalar, v}, fn
          {:scalar, prev} -> {:list, [prev, v]}
          {:list, list} -> {:list, list ++ [v]}
        end)
      end)

    {:ok, args}
  end

  defp supplied_args(%Plug.Conn{method: "POST"} = conn) do
    raw = conn.assigns[:bier_raw_body] || ""

    cond do
      # An application/octet-stream body is NOT JSON: it is bound verbatim as the
      # whole single-unnamed parameter (e.g. a bytea function), with the raw bytes
      # passed through a real bound parameter (cases 1622/1623).
      octet_stream?(conn) ->
        {:ok, %{__body__: {:single_unnamed_raw, raw}}}

      raw == "" ->
        {:ok, %{}}

      true ->
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
  end

  defp octet_stream?(conn) do
    case get_req_header(conn, "content-type") do
      [value | _] -> String.contains?(String.downcase(value), "application/octet-stream")
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
          pool = Bier.Registry.via(config.name, Postgrex)
          count_mode = Pagination.count_mode(conn)
          exec_args = Enum.map(args, fn {n, t, _v?, val} -> {n, t, value_for_named(val)} end)

          case QueryExecutor.run_function(pool, fn_def, ret_rel, exec_args, plan,
                 count_mode: count_mode,
                 relations: relations,
                 format: MediaType.executor_format(media)
               ) do
            {:ok, %{body: body, count: count}} ->
              columns = ActionController.csv_columns(plan, ret_rel)
              Response.render(conn, body, count, plan, count_mode, media, columns: columns)

            other ->
              other
          end
        end

      :error ->
        {:error, :rpc_unsupported}
    end
  end

  # Everything else: scalar / scalar-array / setof-scalar / composite /
  # record / OUT params. We render the function result as JSON ourselves.
  # A scalar RPC result can additionally be emitted as application/octet-stream
  # (cases 1622/1623), which is not a generally-available table producer.
  defp run(conn, config, fn_def, args) do
    producers = ActionController.read_producers(config) ++ [:octet]

    with {:ok, media} <- Negotiation.resolve(conn, producers) do
      pool = Bier.Registry.via(config.name, Postgrex)
      {arg_sql, params} = build_call_args(args)
      from = "#{qfn(fn_def)}(#{arg_sql})"

      sql = result_sql(fn_def, from, media)

      case exec(pool, conn, sql, params) do
        {:ok, %Postgrex.Result{rows: [[body]]}, guc} ->
          render_result(conn, fn_def, body, media, guc)

        {:ok, %Postgrex.Result{rows: []}, guc} ->
          render_result(conn, fn_def, empty_body(fn_def), media, guc)

        {:error, _} = err ->
          err
      end
    end
  end

  # ---- result SQL shapes ---------------------------------------------------

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

  defp result_sql(fn_def, from, _media), do: result_sql(fn_def, from)

  # Array-of-objects for setof-record / multi-OUT setof. Wrapping the call in a
  # `(SELECT * FROM fn())` subquery keeps `t` a proper composite row even for a
  # single OUT/TABLE column (a bare `FROM fn() t` collapses to the scalar).
  defp result_sql(%{ret_kind: :setof_record}, from),
    do: "SELECT coalesce(json_agg(t), '[]')::text FROM (SELECT * FROM #{from}) t"

  # Array-of-scalars for setof-scalar.
  defp result_sql(%{ret_kind: :setof_scalar}, from),
    do: "SELECT coalesce(json_agg(t._v), '[]')::text FROM (SELECT #{from} AS _v) t"

  # Single object for a composite / OUT-params single-row return.
  defp result_sql(%{ret_kind: :composite}, from),
    do: "SELECT to_jsonb(t)::text FROM (SELECT * FROM #{from}) t"

  # Bare scalar (incl. scalar arrays) -> JSON value of the single returned value.
  defp result_sql(_fn_def, from),
    do: "SELECT to_jsonb(_v)::text FROM (SELECT #{from} AS _v) t"

  defp empty_body(%{ret_kind: kind}) when kind in [:setof_record, :setof_scalar], do: "[]"
  defp empty_body(_), do: "null"

  # ---- rendering -----------------------------------------------------------

  # setof results render as a (possibly paginated) array with Content-Range.
  defp render_result(conn, %{ret_kind: kind} = _fn_def, body, media, guc)
       when kind in [:setof_record, :setof_scalar] do
    count_mode = Pagination.count_mode(conn)

    # A count= preference combined with geo+json on a non-setof_rel RPC is out
    # of conformance scope; the guard just prevents Response.row_count/1 from
    # mis-decoding the FeatureCollection object as a (zero-length) row array.
    count =
      if count_mode == :none or media.symbol == :geojson,
        do: 0,
        else: Response.row_count(body)

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

  defp render_result(conn, _fn_def, body, media, guc) do
    count_mode = Pagination.count_mode(conn)
    out = body_for(conn, body)

    conn
    |> Bier.Guc.put_headers(guc)
    |> put_resp_header("content-type", MediaType.content_type(media))
    |> maybe_scalar_content_range(count_mode)
    |> put_resp_header("content-length", Integer.to_string(byte_size(out)))
    |> send_resp(Bier.Guc.status(guc, 200), out)
  end

  # A requested count on a scalar/composite result -> Content-Range 0-0/1.
  defp maybe_scalar_content_range(conn, :none), do: conn

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

  # Inline a single-quote-escaped literal cast to the arg type (Postgres
  # coerces from an *unknown* literal, which a typed param cannot supply).
  # The literal is escaped, so it is injection-safe.
  defp call_arg({name, type, _variadic?, value}, acc) do
    {keyword_call(name, "#{pg_literal(scalar_value(value))}::#{type}"), acc}
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

  defp pg_literal(value) do
    "'" <> String.replace(to_string(value), "'", "''") <> "'"
  end

  # ---- helpers -------------------------------------------------------------

  # Run the call inside a transaction and read the PostgREST response GUCs
  # (response.headers / response.status) the function may have set, before the
  # transaction ends. GET/HEAD run READ ONLY so a VOLATILE proc raises 25006
  # (mapped to 405). Returns `{:ok, result, guc}` or `{:error, reason}` (the GUC
  # read may itself fail with PGRST111/PGRST112).
  defp exec(pool, %Plug.Conn{method: m} = conn, sql, params) do
    read_only? = m in ["GET", "HEAD"]
    auth = ActionController.auth_setup(conn, instance_config(conn))

    Bier.ServerTiming.measure(:transaction, fn ->
      Postgrex.transaction(pool, fn tx ->
        if read_only?, do: Postgrex.query!(tx, "SET TRANSACTION READ ONLY", [])
        apply_auth(tx, auth)
        query_then_read_gucs(tx, sql, params)
      end)
    end)
    |> case do
      {:ok, {result, guc}} -> {:ok, result, guc}
      {:error, %Postgrex.Error{} = err} -> map_auth_error(auth, err)
      {:error, other} -> {:error, other}
    end
  end

  defp query_then_read_gucs(tx, sql, params) do
    with {:ok, result} <- Postgrex.query(tx, sql, params),
         {:ok, guc} <- Bier.Guc.read(tx) do
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
      with {:ok, plan} <- QueryParser.parse_request(reserved_qs) do
        Pagination.apply_window(plan, conn, config.db_max_rows)
      end
    end)
  end

  # Build the PGRST202 not-found envelope, reporting against the base `test`
  # schema for mirror labels. The hint points at a real signature when the name
  # exists but the supplied parameters did not match an overload.
  defp not_found(schema, fn_name, supplied, overloads) do
    reported = reported_schema(schema)
    named = supplied |> Map.drop([:__body__]) |> Map.keys() |> Enum.sort()
    has_body? = Map.has_key?(supplied, :__body__)

    params_str = Enum.join(named, ", ")
    sig = "#{reported}.#{fn_name}(#{params_str})"

    details_tail =
      if has_body? and named != [], do: " or with a single unnamed json/jsonb parameter", else: ""

    details =
      "Searched for the function #{reported}.#{fn_name} with parameters #{params_str}" <>
        "#{details_tail}, but no matches were found in the schema cache."

    %{
      code: "PGRST202",
      message: "Could not find the function #{sig} in the schema cache",
      details: details,
      hint: hint_signature(reported, fn_name, overloads, named)
    }
  end

  # The closest real signature for an existing function name, rendered as
  # `<schema>.<fn>(arg, arg)`. PostgREST only hints when an overload shares at
  # least one parameter name with what was supplied (e.g. add_them(a,b) for a
  # call carrying a, b, smthelse); a wholly-disjoint signature gets no hint.
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
        arg_names = Enum.map_join(fn_def.args, ", ", & &1.name)
        "Perhaps you meant to call the function #{reported}.#{fn_name}(#{arg_names})"
    end
  end

  defp reported_schema(schema) when schema in @mirror_schemas, do: "test"
  defp reported_schema(schema), do: schema

  defp qfn(%{schema: schema, name: name}), do: "#{q(schema)}.#{q(name)}"

  defp q(ident), do: "\"" <> String.replace(ident, "\"", "\"\"") <> "\""
end
