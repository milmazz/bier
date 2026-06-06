defmodule Bier.Plugs.ActionController do
  @moduledoc """
  Request-time controller for the read + mutation pipeline.

  Every request reaches this plug via the catch-all router. It:

    1. resolves the target `{schema, relation}` from the path + `Accept-Profile`
       / `Content-Profile` (default schema = first of `db_schemas`),
    2. negotiates the response media type against the `Accept` header,
    3. parses the query string with `Bier.QueryParser`,
    4. builds and runs one parameterized JSON query via `Bier.QueryExecutor`,
    5. renders the negotiated format (JSON / CSV / singular object /
       nulls-stripped / EXPLAIN plan) with a `Content-Range`.

  Anything that is not a successful `Plug.Conn` falls through to
  `Bier.Plugs.FallbackController`, which emits the PostgREST error envelope.
  """

  @behaviour Plug

  import Plug.Conn

  alias Bier.MediaType
  alias Bier.Mutation
  alias Bier.Negotiation
  alias Bier.Pagination
  alias Bier.Plan
  alias Bier.Plugs.FallbackController
  alias Bier.QueryExecutor
  alias Bier.QueryParser
  alias Bier.Registry
  alias Bier.Response

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    name = conn.assigns.supervisor_name
    config = Registry.config(name)
    relations = :persistent_term.get({Bier, :relations, name}, %{})

    case dispatch(conn, config, relations) do
      %Plug.Conn{} = conn -> conn
      error -> FallbackController.call(conn, error)
    end
  catch
    {:bad_request, _reason} -> FallbackController.call(conn, {:error, :unprocessable})
  end

  defp dispatch(conn, config, relations) do
    case conn.path_info do
      [] -> dispatch_root(conn, config)
      ["rpc", fn_name] -> Bier.Rpc.dispatch(conn, config, resolve_schema(conn, config), fn_name)
      _ -> dispatch_relation(conn, config, relations)
    end
  end

  # ---- root (`/`) ----------------------------------------------------------

  # The root path only produces openapi+json / json / */*. Bier does not yet
  # serve the OpenAPI document here, so negotiation is enough to satisfy the
  # 406 cases (unsupported Accept at root -> 406).
  defp dispatch_root(conn, _config) do
    case Negotiation.resolve(conn, [:openapi, :json]) do
      {:ok, _mt} -> {:error, :not_implemented}
      {:error, _} = err -> err
    end
  end

  defp dispatch_relation(conn, config, relations) do
    with {:ok, schema} <- resolve_schema(conn, config),
         {:ok, relation} <- resolve_relation(conn, schema, relations) do
      handle(conn.method, conn, config, relation)
    end
  end

  # ---- handlers (relations) ------------------------------------------------

  defp handle(method, conn, config, relation) when method in ["GET", "HEAD"] do
    case Bier.CustomMedia.maybe_relation(conn, config, relation) do
      :no_handler ->
        with {:ok, media} <- Negotiation.resolve(conn, relation_producers(config)) do
          handle_get(conn, config, relation, media)
        end

      result ->
        result
    end
  end

  defp handle(method, conn, config, relation) when method in ["POST", "PATCH", "PUT", "DELETE"] do
    with {:ok, media} <- Negotiation.resolve(conn, relation_producers(config)) do
      Mutation.handle(conn, config, relation, media)
    end
  end

  defp handle(_method, _conn, _config, _relation), do: {:error, :method_not_allowed}

  defp handle_get(conn, config, relation, %MediaType{symbol: :plan} = media) do
    pool = Bier.Registry.via(config.name, Postgrex)

    with {:ok, plan} <- parse(conn, config) do
      Plan.explain(conn, pool, relation, plan, media)
    end
  end

  defp handle_get(conn, config, relation, media) do
    pool = Bier.Registry.via(config.name, Postgrex)
    relations = :persistent_term.get({Bier, :relations, config.name}, %{})
    count_mode = Pagination.count_mode(conn)

    with {:ok, plan} <- parse(conn, config),
         {:ok, %{body: body, count: count}} <-
           QueryExecutor.run(pool, relation, plan, relations,
             count_mode: count_mode,
             max_rows: config.db_max_rows
           ) do
      render(conn, body, count, plan, count_mode, media, csv_columns(plan, relation))
    end
  end

  # ---- target resolution ---------------------------------------------------

  defp resolve_schema(conn, config) do
    [default | _] = config.db_schemas

    profile =
      case conn.method do
        m when m in ["GET", "HEAD"] ->
          header(conn, "accept-profile")

        _ ->
          # Writes target the Content-Profile schema; fall back to Accept-Profile
          # so a write whose response schema is pinned (the conformance harness
          # sends only Accept-Profile) still resolves to that schema.
          header(conn, "content-profile") || header(conn, "accept-profile")
      end

    schema = profile || default

    if schema in config.db_schemas do
      {:ok, schema}
    else
      {:error, {:invalid_schema, schema}}
    end
  end

  defp resolve_relation(conn, schema, relations) do
    case conn.path_info do
      [relation] ->
        case Map.fetch(relations, {schema, relation}) do
          {:ok, rel} -> {:ok, rel}
          :error -> {:error, {:unknown_relation, schema, relation}}
        end

      _ ->
        {:error, :invalid_path}
    end
  end

  # ---- query plan ----------------------------------------------------------

  @doc false
  def parse(conn, config) do
    with {:ok, plan} <- QueryParser.parse_request(conn.query_string),
         {:ok, plan} <- apply_range_header(conn, plan) do
      {:ok, apply_max_rows(plan, config)}
    end
  end

  defp apply_range_header(conn, plan) do
    case Pagination.range_window(conn) do
      {:ok, nil} -> {:ok, plan}
      {:ok, {offset, limit}} -> {:ok, %{plan | offset: offset, limit: limit}}
      {:error, :range_offside} -> {:error, :range_offside}
    end
  end

  defp apply_max_rows(plan, %{db_max_rows: nil}), do: plan

  defp apply_max_rows(%{limit: nil} = plan, %{db_max_rows: max}),
    do: %{plan | limit: max}

  defp apply_max_rows(%{limit: limit} = plan, %{db_max_rows: max}),
    do: %{plan | limit: min(limit, max)}

  # The available producers for a relation/RPC result set. Plan is gated on
  # db-plan-enabled. octet-stream and geo+json are not generally available
  # (they require specific handlers) and are negotiated only where supported.
  @doc false
  def relation_producers(config) do
    base = [:json, :csv, :singular, :array_strip]
    if config.db_plan_enabled, do: base ++ [:plan], else: base
  end

  # CSV column order: explicit select fields, else the relation's columns.
  @doc false
  def csv_columns(plan, relation) do
    case plan.select do
      [:star] -> Enum.map(relation.columns, & &1.name)
      fields -> select_field_names(fields)
    end
  end

  defp select_field_names(fields) do
    fields
    |> Enum.flat_map(fn
      %{kind: :star} -> []
      %{alias: al, column: col, json_path: jp} -> [QueryExecutor.json_output_name(al || col, jp)]
      _ -> []
    end)
  end

  # ---- render --------------------------------------------------------------

  defp render(conn, body, count, plan, count_mode, media, columns) do
    Response.render(conn, body, count, plan, count_mode, media, columns: columns)
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end
end
