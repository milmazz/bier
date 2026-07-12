defmodule Bier.CustomMedia do
  @moduledoc """
  PostgREST custom media-type handlers.

  A custom media type is a `DOMAIN` whose name is the MIME string; a handler is
  an aggregate whose transition-state type is that domain. The aggregate's first
  argument is the relation (or `anyelement`) it applies to. A function returning
  a media-type domain is the "Any"/per-result handler.

  When a request's `Accept` matches a handler for the target relation/RPC, the
  handler runs in SQL and its (already-serialized) output becomes the response
  body, with the domain's MIME as the `Content-Type`.
  """

  import Plug.Conn

  alias Bier.MediaType
  alias Bier.Negotiation
  alias Bier.QueryExecutor, as: QE

  @doc """
  Try to satisfy a relation GET via a custom media handler aggregate keyed on
  the relation. Returns a `Plug.Conn` if handled, or `:no_handler`.
  """
  def maybe_relation(conn, config, relation) do
    handlers = handlers(config.name)
    accepts = Negotiation.accept(conn) |> MediaType.parse_accept()

    match =
      Enum.find_value(accepts, fn mt ->
        Enum.find(handlers, &relation_handler?(&1, mt, relation))
      end)

    case match do
      nil -> :no_handler
      handler -> run_relation_aggregate(conn, config, relation, handler)
    end
  end

  @doc """
  Try to satisfy an RPC via a custom handler: either the function itself returns
  a media-type domain (the "Any"/scalar handler), or an `anyelement` aggregate
  applies to the function's result. Returns a `Plug.Conn` or `:no_handler`.
  """
  def maybe_rpc(conn, config, fn_def) do
    if media_domain?(fn_def.ret_type) do
      run_media_fn(conn, config, fn_def)
    else
      run_rpc_aggregate(conn, config, fn_def)
    end
  end

  # ---- relation aggregate (e.g. ov_json override) -------------------------

  defp run_relation_aggregate(conn, config, relation, handler) do
    run_aggregate(conn, config, handler, QE.qrel(relation), & &1)
  end

  # ---- function returning a media-type domain (Any handler) ---------------

  defp run_media_fn(conn, config, fn_def) do
    # Negotiation: the `*/*` domain matches any Accept; a specific media domain
    # matches that Accept (or */*).
    if any_or_matches?(conn, fn_def.ret_type) do
      pool = Bier.Registry.via(config.name, Postgrex)
      # The `*/*` domain is over bytea; selecting the value as bytea yields the
      # raw bytes (Postgrex returns them as a binary).
      sql = "SELECT #{qfn_call(fn_def)}::bytea"

      case Postgrex.query(pool, sql, []) do
        {:ok, %Postgrex.Result{rows: [[value]]}} ->
          # When the handler does not set response headers, PostgREST defaults
          # the Content-Type to application/octet-stream.
          send_octet(conn, value)

        {:error, _} = err ->
          err
      end
    else
      :no_handler
    end
  end

  # ---- anyelement aggregate over an RPC result (e.g. geo2json) -------------

  defp run_rpc_aggregate(conn, config, fn_def) do
    handlers = handlers(config.name)
    accepts = Negotiation.accept(conn) |> MediaType.parse_accept()

    match =
      Enum.find_value(accepts, fn mt ->
        Enum.find(handlers, &anyelement_handler?(&1, mt))
      end)

    case match do
      nil ->
        :no_handler

      handler ->
        # The anyelement aggregate path prepends a 0x01 SOH control byte to the
        # serialized output, mirroring PostgREST's "-- TODO SOH" behavior
        # (CustomMediaSpec, case 1636).
        run_aggregate(conn, config, handler, qfn_call(fn_def), &soh/1)
    end
  end

  # Run the handler aggregate over `source` (a relation or a function call) and
  # send its serialized output, decorated by `transform`, as the response body.
  defp run_aggregate(conn, config, handler, source, transform) do
    pool = Bier.Registry.via(config.name, Postgrex)
    agg = "#{QE.quote_ident(handler.agg_schema)}.#{QE.quote_ident(handler.agg_name)}"
    sql = "SELECT #{agg}(__r)::text FROM #{source} __r"

    case Postgrex.query(pool, sql, []) do
      {:ok, %Postgrex.Result{rows: [[value]]}} ->
        send_custom(conn, handler.media_type, transform.(value))

      {:ok, %Postgrex.Result{rows: []}} ->
        send_custom(conn, handler.media_type, transform.(""))

      {:error, _} = err ->
        err
    end
  end

  defp qfn_call(fn_def),
    do: "#{QE.quote_ident(fn_def.schema)}.#{QE.quote_ident(fn_def.name)}()"

  defp soh(value) when is_binary(value), do: <<0x01>> <> value
  defp soh(nil), do: <<0x01>>

  # ---- matching ------------------------------------------------------------

  defp relation_handler?(handler, %MediaType{} = mt, relation) do
    handler.arg_relation == relation.name and
      handler.arg_schema == relation.schema and
      mime_matches?(handler.media_type, mt)
  end

  defp anyelement_handler?(handler, %MediaType{} = mt) do
    handler.arg_type == "anyelement" and mime_matches?(handler.media_type, mt)
  end

  defp mime_matches?(_media_type, %MediaType{symbol: :any}), do: false
  defp mime_matches?(media_type, %MediaType{mime: mime}), do: media_type == mime

  defp media_domain?(type) when is_binary(type), do: String.contains?(type, "/")
  defp media_domain?(_), do: false

  # The `*/*` domain matches any Accept; a specific domain matches its own mime.
  defp any_or_matches?(_conn, "*/*"), do: true

  defp any_or_matches?(conn, ret_type) do
    accepts = Negotiation.accept(conn) |> MediaType.parse_accept()
    Enum.any?(accepts, fn mt -> mt.symbol == :any or mt.mime == ret_type end)
  end

  # ---- responses -----------------------------------------------------------

  defp send_custom(conn, "application/json", value) do
    conn
    |> put_resp_header("content-type", "application/json; charset=utf-8")
    |> send_resp(200, value)
  end

  defp send_custom(conn, media_type, value) do
    conn
    |> put_resp_header("content-type", media_type)
    |> send_resp(200, value)
  end

  defp send_octet(conn, value) do
    conn
    |> put_resp_header("content-type", "application/octet-stream")
    |> send_resp(200, octet(value))
  end

  defp octet(value) when is_binary(value), do: value
  defp octet(nil), do: ""
  defp octet(value), do: to_string(value)

  defp handlers(name), do: Bier.SchemaCache.media_handlers(name)
end
