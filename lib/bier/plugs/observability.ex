defmodule Bier.Plugs.Observability do
  @moduledoc """
  Cross-cutting observability middleware, applied to every request before it
  reaches `Bier.Plugs.ActionController`. It mirrors PostgREST's two
  request/response-spanning concerns:

    * **Server-Timing** (`server-timing-enabled`): when enabled, every response
      carries a `Server-Timing` header with the per-phase durations PostgREST
      reports — `jwt`, `parse`, `plan`, `transaction`, `response` — each as
      `<name>;dur=<ms>` with at least one decimal. The durations are *measured*:
      each phase is timed at its real call site via `Bier.ServerTiming.measure/2`
      and accumulated for the request; a phase that did no work for a given
      request reports `0.0` (never a fabricated share of the total). `OPTIONS`
      responses carry only the `jwt`, `parse`, `response` subset (no query plan /
      DB transaction runs). When disabled the header is omitted entirely.

    * **Trace header passthrough** (`server-trace-header`): when configured with
      a header name (e.g. `X-Request-Id`), the incoming value of that header is
      echoed verbatim on the response. An empty/nil configuration is a no-op —
      the header is not echoed.

  The header is written in a `Plug.Conn.register_before_send/2` callback, which
  fires synchronously while the response is sent — at which point every phase the
  request ran (recorded into `Bier.ServerTiming`'s process-scoped accumulator as
  it went) is available, including `response`, since `Bier.Render` records its
  rendering time before the caller calls `send_resp`. `log-level` is a
  logging-only concern and never alters the response, so it is not handled here.
  """

  @behaviour Plug

  import Plug.Conn

  alias Bier.Registry

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

    conn
    |> echo_trace_header(config)
    |> register_before_send(&put_server_timing(&1, config))
    |> register_before_send(&emit_request_stop(&1, name, request_start))
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

  # ---- Server-Timing -------------------------------------------------------

  defp put_server_timing(conn, %{server_timing_enabled: true} = _config) do
    value = timing_value(conn.method, Bier.ServerTiming.snapshot())
    put_resp_header(conn, "server-timing", value)
  end

  defp put_server_timing(conn, _config), do: conn

  # OPTIONS does no query planning or DB transaction, so it reports only the
  # jwt/parse/response subset (mirrors PostgREST's ServerTimingSpec); `plan` and
  # `transaction` are omitted entirely (not rendered as the substring at all).
  defp timing_value("OPTIONS", phases), do: join(phases, [:jwt, :parse, :response])

  # Every other method reports the full phase set, in PostgREST's fixed order.
  # Each value is the measured duration of that phase for this request; a phase
  # that ran no work reports 0.0.
  defp timing_value(_method, phases),
    do: join(phases, [:jwt, :parse, :plan, :transaction, :response])

  defp join(phases, names) do
    Enum.map_join(names, ", ", fn name ->
      "#{name};dur=#{format(Map.get(phases, name, 0.0))}"
    end)
  end

  # Render with at least one decimal digit so it always matches
  # `dur=[0-9]+\.[0-9]+` (PostgREST emits a fractional millisecond value).
  defp format(ms) do
    :erlang.float_to_binary(ms * 1.0, decimals: 3)
  end
end
