defmodule Bier.Plugs.Cors do
  @moduledoc """
  CORS middleware mirroring PostgREST's `server-cors-allowed-origins`
  (PostgREST `src/PostgREST/Cors.hs`).

  CORS headers are emitted only when the request carries an `Origin` header; a
  request without `Origin` is a same-origin request and gets no CORS headers
  (PostgREST's `corsPolicy` returns `Nothing` when no `Origin` is present).

  Origin matching follows the WAI `cors` middleware semantics PostgREST relies
  on:

    * **Allowlist configured** (`server-cors-allowed-origins` is a non-empty,
      comma-separated list): a request whose `Origin` is in the list gets that
      origin echoed in `Access-Control-Allow-Origin` together with
      `Access-Control-Allow-Credentials: true`. An `Origin` not in the list gets
      **no** `Access-Control-Allow-Origin` header.
    * **Empty/unset** (`""` or nil): every origin is allowed, so
      `Access-Control-Allow-Origin: *` is returned (no credentials, per the WAI
      wildcard rule).

  For a CORS preflight (`OPTIONS` carrying `Access-Control-Request-Method`) the
  response additionally advertises the allowed methods, headers, exposed
  headers, and a 24h max-age — the fixed set PostgREST configures.
  """

  @behaviour Plug

  import Plug.Conn

  alias Bier.Registry

  @allow_methods "GET, POST, PATCH, PUT, DELETE, OPTIONS"
  @expose_headers "Content-Encoding, Content-Location, Content-Range, Content-Type, Date, Location, Server, Transfer-Encoding, Range-Unit"
  @default_allow_headers "Authorization"
  @max_age "86400"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case get_req_header(conn, "origin") do
      [origin | _] ->
        config = Registry.config(conn.assigns.supervisor_name)
        apply_cors(conn, origin, allowed_origins(config))

      [] ->
        conn
    end
  end

  # Empty/unset allowlist allows every origin with the wildcard (no credentials).
  defp apply_cors(conn, _origin, :all) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_preflight_headers()
  end

  defp apply_cors(conn, origin, origins) when is_list(origins) do
    if origin in origins do
      conn
      |> put_resp_header("access-control-allow-origin", origin)
      |> put_resp_header("access-control-allow-credentials", "true")
      |> put_resp_header("vary", "Origin")
      |> put_preflight_headers()
    else
      # Origin not in the allowlist: emit no Access-Control-Allow-Origin header.
      conn
    end
  end

  # Preflight extras are only meaningful when the request is an actual preflight
  # (OPTIONS with Access-Control-Request-Method). Other requests just carry the
  # allow-origin / expose-headers.
  defp put_preflight_headers(conn) do
    if conn.method == "OPTIONS" and get_req_header(conn, "access-control-request-method") != [] do
      conn
      |> put_resp_header("access-control-allow-methods", @allow_methods)
      |> put_resp_header("access-control-allow-headers", allow_headers(conn))
      |> put_resp_header("access-control-max-age", @max_age)
    else
      put_resp_header(conn, "access-control-expose-headers", @expose_headers)
    end
  end

  # PostgREST always allows Authorization plus whatever the client requests in
  # Access-Control-Request-Headers.
  defp allow_headers(conn) do
    case get_req_header(conn, "access-control-request-headers") do
      [requested | _] when requested != "" -> @default_allow_headers <> ", " <> requested
      _ -> @default_allow_headers
    end
  end

  # `nil` or "" means "allow all"; a non-empty comma list is the allowlist.
  defp allowed_origins(%{server_cors_allowed_origins: nil}), do: :all
  defp allowed_origins(%{server_cors_allowed_origins: ""}), do: :all

  defp allowed_origins(%{server_cors_allowed_origins: raw}) when is_binary(raw) do
    case raw |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> :all
      origins -> origins
    end
  end
end
