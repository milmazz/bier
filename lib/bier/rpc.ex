defmodule Bier.Rpc do
  @moduledoc """
  Dispatches `/rpc/<fn>` calls across the function return kinds PostgREST
  supports: set-of-relation, set-of-scalar, scalar, composite, and the special
  single-unnamed-parameter functions whose argument is the raw request body
  (octet-stream / scalar json).

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

  @doc "Resolve and run an RPC. `schema_result` is `resolve_schema/2`'s output."
  def dispatch(_conn, _config, {:error, _} = err, _fn_name), do: err

  def dispatch(conn, config, {:ok, schema}, fn_name) do
    functions = :persistent_term.get({Bier, :functions, config.name}, %{})

    case Map.fetch(functions, {schema, fn_name}) do
      {:ok, fn_def} ->
        case Bier.CustomMedia.maybe_rpc(conn, config, fn_def) do
          :no_handler -> run(conn, config, fn_def)
          result -> result
        end

      :error ->
        {:error, :rpc_unsupported}
    end
  end

  # ---- single unnamed body parameter (octet-stream / scalar) --------------

  defp run(conn, config, %{single_unnamed?: true} = fn_def) do
    [arg] = fn_def.args
    producers = octet_producers(fn_def)

    with {:ok, media} <- Negotiation.resolve(conn, producers) do
      pool = Bier.Registry.via(config.name, Postgrex)
      raw = conn.assigns[:bier_raw_body] || ""

      call = "SELECT #{call_expr(fn_def, "$1")}" |> with_typed_arg(arg.type)

      case Postgrex.query(pool, call, [coerce_arg(arg.type, raw)]) do
        {:ok, %Postgrex.Result{rows: [[value]]}} ->
          send_scalar(conn, media, value)

        {:ok, %Postgrex.Result{rows: []}} ->
          send_scalar(conn, media, nil)

        {:error, _} = err ->
          err
      end
    end
  end

  # ---- set-of-relation (table-valued) -------------------------------------

  defp run(conn, config, %{ret_kind: :setof_rel} = fn_def) do
    relations = :persistent_term.get({Bier, :relations, config.name}, %{})

    case Map.fetch(relations, {fn_def.ret_schema, fn_def.ret_relation}) do
      {:ok, ret_rel} ->
        with {:ok, media} <-
               Negotiation.resolve(conn, ActionController.relation_producers(config)),
             {:ok, plan, args} <- parse_args(conn, config, fn_def) do
          pool = Bier.Registry.via(config.name, Postgrex)
          count_mode = Pagination.count_mode(conn)

          case QueryExecutor.run_function(pool, fn_def, ret_rel, args, plan,
                 count_mode: count_mode
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

  # ---- scalar / setof-scalar / composite ----------------------------------

  defp run(conn, config, fn_def) do
    with {:ok, media} <- Negotiation.resolve(conn, ActionController.relation_producers(config)),
         {:ok, _plan, args} <- parse_args(conn, config, fn_def) do
      pool = Bier.Registry.via(config.name, Postgrex)

      {arg_sql, params} = build_named_args(args)
      from = "#{q(fn_def.schema)}.#{q(fn_def.name)}(#{arg_sql})"

      sql =
        "SELECT coalesce(json_agg(t._v), '[]')::text " <>
          "FROM (SELECT to_jsonb(__f) AS _v FROM #{from} __f) t"

      case Postgrex.query(pool, sql, params) do
        {:ok, %Postgrex.Result{rows: [[body]]}} ->
          count = Response.row_count(body)
          plan = %{offset: 0}
          Response.render(conn, body, count, plan, :none, media, [])

        {:ok, %Postgrex.Result{rows: []}} ->
          Response.render(conn, "[]", 0, %{offset: 0}, :none, media, [])

        {:error, _} = err ->
          err
      end
    end
  end

  # ---- helpers -------------------------------------------------------------

  # octet-stream is available for a single-unnamed function whose return type is
  # bytea or whose result can stream raw; json/octet always offered here.
  defp octet_producers(%{ret_type: "bytea"}), do: [:octet, :json]
  defp octet_producers(_), do: [:json, :octet, :singular]

  defp send_scalar(conn, %MediaType{symbol: :octet}, value) do
    body = octet_body(value)

    conn
    |> put_resp_header("content-type", "application/octet-stream")
    |> send_resp(200, body)
  end

  defp send_scalar(conn, %MediaType{symbol: :singular} = media, value) do
    conn
    |> put_resp_header("content-type", MediaType.content_type(media))
    |> send_resp(200, scalar_json(value))
  end

  defp send_scalar(conn, media, value) do
    conn
    |> put_resp_header("content-type", MediaType.content_type(media))
    |> send_resp(200, scalar_json(value))
  end

  defp octet_body(value) when is_binary(value), do: value
  defp octet_body(nil), do: ""
  defp octet_body(value), do: to_string(value)

  defp scalar_json(value), do: Bier.json_library().encode!(value)

  # Coerce the raw body into the function argument type for binding.
  defp coerce_arg("bytea", raw), do: raw
  defp coerce_arg(_type, raw), do: raw

  defp with_typed_arg(sql, "bytea"), do: String.replace(sql, "$1", "$1::bytea")
  defp with_typed_arg(sql, _type), do: sql

  defp call_expr(fn_def, placeholder) do
    "#{q(fn_def.schema)}.#{q(fn_def.name)}(#{placeholder})"
  end

  # Parse query string into a plan, peeling off the function's named args (GET
  # passes them as query params; POST passes them in the JSON body).
  defp parse_args(conn, config, fn_def) do
    params = URI.decode_query(conn.query_string)
    arg_names = MapSet.new(fn_def.args, & &1.name)

    {arg_params, query_params} =
      Enum.split_with(params, fn {k, _v} -> MapSet.member?(arg_names, k) end)

    query_string = URI.encode_query(query_params)
    body_args = if conn.method == "POST", do: body_args(conn), else: %{}

    with {:ok, plan} <- QueryParser.parse_request(query_string),
         {:ok, plan} <- apply_range(conn, plan) do
      merged = Map.merge(Map.new(arg_params), body_args)
      args = build_args(fn_def, merged)
      {:ok, apply_max_rows(plan, config), args}
    end
  end

  defp body_args(conn) do
    case conn.assigns[:bier_raw_body] do
      body when is_binary(body) and body != "" ->
        case Bier.json_library().decode(body) do
          {:ok, map} when is_map(map) -> stringify(map)
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp stringify(map) do
    Map.new(map, fn
      {k, v} when is_binary(v) -> {k, v}
      {k, v} -> {k, to_arg(v)}
    end)
  end

  defp to_arg(v) when is_number(v) or is_boolean(v), do: to_string(v)
  defp to_arg(v), do: Bier.json_library().encode!(v)

  defp apply_range(conn, plan) do
    case Pagination.range_window(conn) do
      {:ok, nil} -> {:ok, plan}
      {:ok, {offset, limit}} -> {:ok, %{plan | offset: offset, limit: limit}}
      {:error, :range_offside} -> {:error, :range_offside}
    end
  end

  defp apply_max_rows(plan, %{db_max_rows: nil}), do: plan
  defp apply_max_rows(%{limit: nil} = plan, %{db_max_rows: max}), do: %{plan | limit: max}

  defp apply_max_rows(%{limit: limit} = plan, %{db_max_rows: max}),
    do: %{plan | limit: min(limit, max)}

  defp build_args(fn_def, arg_params) do
    fn_def.args
    |> Enum.filter(fn %{name: n} -> Map.has_key?(arg_params, n) end)
    |> Enum.map(fn %{name: n, type: t} -> {n, t, Map.fetch!(arg_params, n)} end)
  end

  defp build_named_args([]), do: {"", []}

  defp build_named_args(args) do
    {parts, params} =
      args
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {{name, _type, value}, idx}, acc ->
        {"#{q(name)} => $#{idx}", acc ++ [value]}
      end)

    {Enum.join(parts, ", "), params}
  end

  defp q(ident), do: "\"" <> String.replace(ident, "\"", "\"\"") <> "\""
end
