defmodule Bier.Plugs.Vary do
  @moduledoc """
  Appends PostgREST v16.0's default `Vary` header to every non-error response.

  v16.0 added `Vary: Accept, Prefer, Range` so caching proxies key on the three
  request headers that change the representation. It is emitted from a single
  funnel — `App.hs`' `toWaiResponse`, which appends `varyHeader` to the header
  list it was handed:

      Wai.responseLBS st (hdrs ++ serverTimingHeaders timing
                               ++ warningHeaders warnMsgs
                               ++ [varyHeader | not $ varyHeaderPresent hdrs]) bod

  Two consequences are pinned by the conformance suite and reproduced here:

    * **It is not route-specific.** Reads, writes, RPC and `OPTIONS` all carry
      it, because they all pass through that one funnel — hence a
      `register_before_send/2` callback on the shared router pipeline rather
      than a header set at each rendering site.

    * **A response that already carries a `Vary` keeps its own.** The
      `response.headers` GUC is merged into `hdrs` before the
      `varyHeaderPresent` guard runs (`Response.hs` `addHeadersIfNotIncluded`),
      so `set_config('response.headers', '[{"Vary": "..."}]', true)` replaces
      the default verbatim instead of adding a second `Vary`.

  Error responses are the exception: they never reach `toWaiResponse` at all.
  The outer handler maps a `Left` straight through `Error.errorResponseFor`,
  whose header list is closed (Content-Type, Content-Length, Proxy-Status, plus
  the error's own headers) and contains no `Vary`. `Bier.Plugs.FallbackController`
  is that funnel here, and marks its responses with `mark_error/1`.

  Note this covers only responses built by the *error* funnel. A 416
  out-of-bounds range response is assembled by the ordinary read path with an
  error envelope swapped into its body (`Response.hs`), so it goes through
  `toWaiResponse` like any other read and does carry the default `Vary`.

  ## `Origin` — a deliberate divergence

  When the response echoes the request's `Origin` into
  `Access-Control-Allow-Origin`, `Origin` is appended to the default:
  `Vary: Accept, Prefer, Range, Origin`. A response whose headers depend on a
  request header must name that header in `Vary` (RFC 9111 §4.1); upstream does
  not, because it builds its CORS policy with `corsVaryOrigin = False`
  (`Cors.hs`). See #98 and the README's "Deliberate divergences from PostgREST".

  It is appended *here*, in the funnel, rather than set by `Bier.Plugs.Cors`:
  a `Vary` written upstream of the funnel trips the "already carries a Vary"
  guard and suppresses the default on exactly the requests that carry an
  `Origin`.

  Three cases stay bare, each for its own reason:

    * a **wildcard** `Access-Control-Allow-Origin: *` is not an echo — every
      origin gets the same header, so nothing varies by it;
    * an origin **outside** the allowlist gets no CORS header at all;
    * a **preflight** is answered by the wai-cors middleware upstream, before
      `toWaiResponse` ever runs, so its `Vary` is not this funnel's to change.
  """

  @behaviour Plug

  import Plug.Conn

  alias Bier.Plugs.Cors

  @default_vary "Accept, Prefer, Range"

  @error_assign :bier_error_response

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts), do: register_before_send(conn, &put_default_vary/1)

  @doc """
  Mark `conn` as an error response, so the default `Vary` is not appended.

  Called by `Bier.Plugs.FallbackController` for every response it builds — the
  equivalent of PostgREST's errors bypassing `App.hs`' `toWaiResponse`.
  """
  @spec mark_error(Plug.Conn.t()) :: Plug.Conn.t()
  def mark_error(conn), do: assign(conn, @error_assign, true)

  @doc """
  True when `conn` was built by the error funnel (see `mark_error/1`).

  Shared with the other headers `App.hs` appends in `toWaiResponse` — an error
  response bypasses that funnel, so it carries none of them.
  """
  @spec error_response?(Plug.Conn.t()) :: boolean()
  def error_response?(conn), do: conn.assigns[@error_assign] == true

  defp put_default_vary(conn) do
    if conn.assigns[@error_assign] || get_resp_header(conn, "vary") != [] do
      conn
    else
      put_resp_header(conn, "vary", vary_value(conn))
    end
  end

  defp vary_value(conn) do
    if origin_echoed?(conn), do: @default_vary <> ", Origin", else: @default_vary
  end

  # The response depends on the request's `Origin` exactly when `Bier.Plugs.Cors`
  # echoed it back. The wildcard is the same for every origin, and a preflight is
  # deliberately left alone (see the moduledoc).
  defp origin_echoed?(conn) do
    case get_resp_header(conn, "access-control-allow-origin") do
      [origin] -> origin != "*" and not Cors.preflight?(conn)
      _other -> false
    end
  end
end
