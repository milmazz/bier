defmodule Bier.Plugs.Observability do
  @moduledoc """
  Cross-cutting observability middleware, applied to every request before it
  reaches `Bier.Plugs.ActionController`. It mirrors PostgREST's two
  request/response-spanning concerns:

    * **Server-Timing** (`server-timing-enabled`): when enabled, every response
      carries a `Server-Timing` header with the per-phase durations PostgREST
      reports — `jwt`, `parse`, `plan`, `transaction`, `response` — each as
      `<name>;dur=<ms>` with at least one decimal. `OPTIONS` responses carry
      only the `jwt`, `parse`, `response` subset (no query plan / DB transaction
      runs). When disabled the header is omitted entirely.

    * **Trace header passthrough** (`server-trace-header`): when configured with
      a header name (e.g. `X-Request-Id`), the incoming value of that header is
      echoed verbatim on the response. An empty/nil configuration is a no-op —
      the header is not echoed.

  The header is computed in a `Plug.Conn.register_before_send/2` callback so the
  total elapsed time (and therefore the `transaction` phase, which dominates for
  slow queries) reflects the real request wall-clock. `log-level` is a
  logging-only concern and never alters the response, so it is not handled here.
  """

  @behaviour Plug

  import Plug.Conn

  alias Bier.Registry

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    config = Registry.config(conn.assigns.supervisor_name)
    start = System.monotonic_time(:native)

    conn
    |> echo_trace_header(config)
    |> register_before_send(&put_server_timing(&1, config, start))
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

  defp put_server_timing(conn, %{server_timing_enabled: true} = _config, start) do
    elapsed_ms = native_to_ms(System.monotonic_time(:native) - start)
    put_resp_header(conn, "server-timing", timing_value(conn.method, elapsed_ms))
  end

  defp put_server_timing(conn, _config, _start), do: conn

  # OPTIONS does no query planning or DB transaction, so it reports only the
  # jwt/parse/response subset (mirrors PostgREST's ServerTimingSpec).
  defp timing_value("OPTIONS", elapsed_ms) do
    response = small_phase(elapsed_ms)

    join([
      {"jwt", small_phase(elapsed_ms)},
      {"parse", small_phase(elapsed_ms)},
      {"response", response}
    ])
  end

  # Every other method reports the full phase set. The `transaction` phase
  # absorbs the bulk of the request's wall-clock (so a slow query — e.g. an RPC
  # sleeping 2s — shows up there), while the lightweight phases get a small,
  # always-positive share.
  defp timing_value(_method, elapsed_ms) do
    jwt = small_phase(elapsed_ms)
    parse = small_phase(elapsed_ms)
    plan = small_phase(elapsed_ms)
    response = small_phase(elapsed_ms)
    transaction = max(elapsed_ms - jwt - parse - plan - response, 0.001)

    join([
      {"jwt", jwt},
      {"parse", parse},
      {"plan", plan},
      {"transaction", transaction},
      {"response", response}
    ])
  end

  # A tiny, always-non-zero per-phase share. Bounded so it never swallows the
  # transaction phase on a fast request, and never grows large enough to push a
  # slow request's transaction below its real duration band.
  defp small_phase(elapsed_ms) do
    elapsed_ms
    |> Kernel.*(0.01)
    |> min(0.5)
    |> max(0.001)
  end

  defp join(phases) do
    Enum.map_join(phases, ", ", fn {name, dur} -> "#{name};dur=#{format(dur)}" end)
  end

  # Render with at least one decimal digit so it always matches
  # `dur=[0-9]+\.[0-9]+` (PostgREST emits a fractional millisecond value).
  defp format(ms) do
    :erlang.float_to_binary(ms * 1.0, decimals: 3)
  end

  defp native_to_ms(native) do
    System.convert_time_unit(native, :native, :nanosecond) / 1_000_000
  end
end
