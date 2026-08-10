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
  response additionally advertises the allowed methods, headers, and a 24h
  max-age — the fixed set PostgREST configures, widened by the WAI middleware's
  union with the CORS "simple" methods and headers.
  `Access-Control-Allow-Headers` is emitted only when the preflight actually
  carried `Access-Control-Request-Headers`: wai-cors' `hdrRequestHeader`
  returns no header at all for the `Nothing` case (see `put_allow_headers/1`).

  No `Vary: Origin` is emitted even when the origin is echoed: PostgREST builds
  its policy with `corsVaryOrigin = False` (`Cors.hs`), leaving `Vary` entirely
  to `Bier.Plugs.Vary`'s single funnel, which would otherwise be suppressed on
  exactly the requests that carry an `Origin`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Bier.Registry

  # PostgREST's corsMethods, unioned by the WAI middleware with the CORS simple
  # methods (GET, HEAD, POST) — which only contributes HEAD.
  @allow_methods "GET, POST, PATCH, PUT, DELETE, OPTIONS, HEAD"
  @expose_headers "Content-Encoding, Content-Location, Content-Range, Content-Type, Date, Location, Server, Transfer-Encoding, Range-Unit"
  @default_allow_headers ["Authorization"]
  # The CORS simple request headers minus Content-Type, which the WAI
  # middleware unions into every Access-Control-Allow-Headers answer.
  @simple_allow_headers ["Accept", "Accept-Language", "Content-Language"]
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
      |> put_allow_headers()
      |> put_resp_header("access-control-max-age", @max_age)
    else
      put_resp_header(conn, "access-control-expose-headers", @expose_headers)
    end
  end

  # wai-cors' `hdrRequestHeader` looks up Access-Control-Request-Headers and
  # returns `[]` — no Access-Control-Allow-Headers at all — when the preflight
  # did not send one; only the `Just` branch emits the header, and it emits the
  # *supported* set rather than the requested one:
  #
  #     hdrRequestHeader policy = case lookup "Access-Control-Request-Headers" ... of
  #         Nothing -> return []
  #         Just hdrsBytes -> ... return [("Access-Control-Allow-Headers", hdrLI supportedHeaders)]
  #       where
  #         supportedHeaders = corsRequestHeaders policy `union` simpleHeadersWithoutContentType
  #
  # (https://hackage.haskell.org/package/wai-cors/docs/src/Network.Wai.Middleware.Cors.html,
  # `hdrRequestHeader`/`simpleHeadersWithoutContentType`.) For PostgREST
  # `corsRequestHeaders` is `"Authorization" : accHeaders` — the requested
  # names, comma-split and stripped (Cors.hs#L34/#L47) — so the answer is
  # Authorization, then the requested names, then the CORS simple request
  # headers other than Content-Type. Haskell's `union` keeps the left operand's
  # order and appends only the right-hand elements it does not already hold;
  # it compares `HeaderName`s case-insensitively, and `hdrLI` renders each name
  # in its original spelling.
  defp put_allow_headers(conn) do
    case get_req_header(conn, "access-control-request-headers") do
      [requested | _] ->
        supported = @default_allow_headers ++ split_header_names(requested)
        put_resp_header(conn, "access-control-allow-headers", join_supported(supported))

      [] ->
        conn
    end
  end

  defp split_header_names(requested) do
    requested |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp join_supported(supported) do
    known = MapSet.new(supported, &String.downcase/1)
    extra = Enum.reject(@simple_allow_headers, &MapSet.member?(known, String.downcase(&1)))
    Enum.join(supported ++ extra, ", ")
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
