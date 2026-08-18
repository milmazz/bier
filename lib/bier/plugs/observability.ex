defmodule Bier.Plugs.Observability do
  @moduledoc """
  Cross-cutting observability middleware, applied to every request before it
  reaches `Bier.Plugs.ActionController`. It mirrors PostgREST's two
  request/response-spanning concerns:

    * **Server-Timing** (`server-timing-enabled`): when enabled, every response
      carries a `Server-Timing` header with the per-phase durations PostgREST
      reports — `jwt`, `parse`, `plan`, `transaction`, `response` — joined by
      `", "` in that fixed order, each rendered `<name>;dur=<ms>` with EXACTLY
      one fractional digit (`showFFloat (Just 1)`, `Performance.hs`). The
      durations are *measured*: each phase is timed at its real call site via
      `Bier.ServerTiming.measure/2` and accumulated for the request; a phase
      that did no work for a given request reports `0.0` (never a fabricated
      share of the total). The metric set does not depend on the action —
      `withTiming` branches only on the config key (`App.hs`), so an `OPTIONS`
      response reports `plan` and `transaction` too, both `0.0` (it builds no
      plan and opens no transaction). When disabled the header is omitted
      entirely.

    * **Server version header**: every response carries
      `Server: bier/<version>` (`Bier.version/0`). This is a deliberate
      divergence (#122): upstream sends `Server: postgrest/<version>` (set once
      as a Warp server setting — `setServerName`, `App.hs`), but a `Server`
      header names the software that built the response. Like upstream's, the
      header is unconditional — no config key gates it and it rides on every
      response whatever the method, status or content type, error responses
      included.

    * **Trace header passthrough** (`server-trace-header`): when configured with
      a header name (e.g. `X-Request-Id`), the incoming value of that header is
      echoed verbatim on the response. An empty/nil configuration is a no-op —
      the header is not echoed.

    * **Access log + log-level + log-query** (#28): every response whose status
      passes the `log-level` filter (`Bier.RequestLog.should_log?/2`, PostgREST
      `Logger.hs` `shouldLogResponse`) emits one Apache-combined access line
      through Elixir's `Logger` — at `:error` for 5xx, `:warning` for 4xx,
      `:info` otherwise — with the resolved request role as the user field.
      With `log-query` on, the SQL the request executed (recorded into
      `Bier.RequestLog`'s process-scoped accumulator at the execution sites) is
      logged under the same filter, each statement single-lined. `log-level`
      never alters the response itself.

  The headers are written in `Plug.Conn.register_before_send/2` callbacks, which
  fire synchronously while the response is sent — at which point every phase the
  request ran (recorded into `Bier.ServerTiming`'s process-scoped accumulator as
  it went) is available, including `response`, since `Bier.Render` records its
  rendering time before the caller calls `send_resp`.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Bier.Registry
  alias Bier.RequestLog

  # The metric set and its wire order (`Performance.hs` `serverTimingHeader`).
  @phases [:jwt, :parse, :plan, :transaction, :response]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    name = conn.assigns.supervisor_name
    config = Registry.config(name)

    # Initialise the per-phase accumulator for this request (and clear any phases
    # left by a previous request on a keep-alive connection). Phases are only
    # collected when server-timing is enabled.
    Bier.ServerTiming.reset(config.server_timing_enabled)

    # `[:bier, :request, :start]` fires here; `:stop` fires in a before_send
    # callback so its duration is the real request wall-clock. The span is keyed
    # by the instance name (a node can host several Bier instances).
    request_start = Bier.Telemetry.request_start(request_metadata(conn, name))

    # Arm the per-request SQL accumulator only when log-query is on, so the
    # execution sites' record calls stay no-ops otherwise (mirrors the
    # ServerTiming reset above).
    RequestLog.arm(config.log_query)

    conn
    |> echo_trace_header(config)
    |> register_before_send(&put_server_header/1)
    |> register_before_send(&put_server_timing(&1, config))
    |> register_before_send(&emit_request_stop(&1, name, request_start))
    |> register_before_send(&log_request(&1, config))
  end

  # ---- access log / log-query ----------------------------------------------

  defp log_request(conn, config) do
    if RequestLog.should_log?(config.log_level, conn.status) do
      level = logger_level(conn.status)
      role = role_of(conn)

      Logger.log(level, fn -> RequestLog.access_line(conn, role, DateTime.utc_now()) end)

      for sql <- RequestLog.drain() do
        Logger.log(level, fn -> single_line(sql) end)
      end
    end

    conn
  end

  # The resolved request role from the auth context (`Bier.Auth`); nil (logged
  # as "-") when the request failed before role resolution or auth is not
  # applicable — matching PostgREST's user field.
  defp role_of(conn) do
    case conn.assigns[:bier_auth] do
      %{role: role} -> role
      _no_auth_context -> nil
    end
  end

  defp logger_level(status) when status >= 500, do: :error
  defp logger_level(status) when status >= 400, do: :warning
  defp logger_level(_status), do: :info

  # PostgREST single-lines each logged query (Logger.hs showOnSingleLine).
  defp single_line(sql) do
    sql |> String.split("\n") |> Enum.map_join(" ", &String.trim/1)
  end

  # ---- request span --------------------------------------------------------

  defp request_metadata(conn, name) do
    %{instance: name, method: conn.method, route: conn.request_path}
  end

  # The `{schema, relation}` target is stashed in `:bier_target` by
  # `Bier.Plugs.ActionController` once resolved; it is `nil` for the root
  # document, OPTIONS, and responses that error before resolving a relation.
  defp emit_request_stop(conn, name, request_start) do
    {schema, relation} = conn.assigns[:bier_target] || {nil, nil}

    metadata =
      conn
      |> request_metadata(name)
      |> Map.merge(%{status: conn.status, schema: schema, relation: relation})

    Bier.Telemetry.request_stop(request_start, metadata)
    conn
  end

  # ---- trace header --------------------------------------------------------

  defp echo_trace_header(conn, %{server_trace_header: header})
       when is_binary(header) and header != "" do
    case get_req_header(conn, String.downcase(header)) do
      [value | _] -> put_resp_header(conn, String.downcase(header), value)
      [] -> conn
    end
  end

  defp echo_trace_header(conn, _config), do: conn

  # ---- Server ---------------------------------------------------------------

  # A server-level setting upstream, not a per-response header: it is written
  # here from a before_send callback so it also reaches the responses the error
  # funnel builds (`Bier.Plugs.FallbackController`), which bypass the ordinary
  # rendering path.
  #
  # DELIBERATE DIVERGENCE (#122): upstream sends `postgrest/<prettyVersion>`,
  # and conformance case 1771 pins that prefix. Bier answers under its own
  # name instead — a `Server:` header identifies the software that built the
  # response, and reporting another project's product token would misattribute
  # Bier's bugs to PostgREST. The dialect a client is speaking is stated in the
  # OpenAPI document's description and `externalDocs` instead, which is where a
  # client can actually act on it. Case 1771 is exempted in the harness.
  defp put_server_header(conn) do
    put_resp_header(conn, "server", "bier/" <> Bier.version())
  end

  # ---- Server-Timing -------------------------------------------------------

  defp put_server_timing(conn, %{server_timing_enabled: true} = _config) do
    put_resp_header(conn, "server-timing", timing_value(Bier.ServerTiming.snapshot()))
  end

  defp put_server_timing(conn, _config), do: conn

  # `serverTimingHeader` joins the five metrics with the two-byte separator
  # ", " in this fixed order, whatever the action (`Performance.hs`). Each value
  # is the measured duration of that phase for this request; a phase that ran no
  # work reports 0.0 — an OPTIONS response builds no plan and opens no
  # transaction, and still renders both metrics.
  defp timing_value(phases) do
    Enum.map_join(@phases, ", ", fn name ->
      "#{name};dur=#{format(Map.get(phases, name, 0.0))}"
    end)
  end

  # `showFFloat (Just 1)`: exactly one fractional digit, never more
  # (`Performance.hs`). The value is milliseconds.
  defp format(ms) do
    :erlang.float_to_binary(ms * 1.0, decimals: 1)
  end
end
