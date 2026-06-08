defmodule Bier.ServerTiming do
  @moduledoc """
  Per-request accumulator for the real per-phase durations reported in the
  `Server-Timing` response header (`Bier.Plugs.Observability`).

  PostgREST measures each request phase — JWT verification, query-string parse,
  SQL planning, the database transaction, and response rendering — and reports
  them as named `Server-Timing` metrics. Bier mirrors that by timing each phase
  *where the work actually happens* (`measure/2` wraps the real call site) and
  accumulating the durations here, keyed to the current request.

  ## Why the process dictionary

  A request is handled start to finish — router pipeline, controller, query
  executor, and the `Plug.Conn.register_before_send/2` callback that writes the
  header — in a single Bandit process, and the phases are spread across modules
  at different call depths. Threading a `Plug.Conn` accumulator through every one
  would be invasive and, worse, *lossy*: error paths discard the inner conn (e.g.
  `Bier.Plugs.ActionController` hands the original conn to the fallback
  controller), so a JWT or parse timing measured on a request that then fails
  would never reach the header. Process-scoped state survives those hand-offs and
  is naturally request-scoped, since each request runs in its own process.

  `reset/1` is called once at the top of the pipeline so a connection reused
  across keep-alive requests never carries stale phases. Timing is collected only
  when `server-timing-enabled` is set for the instance; otherwise `measure/2`
  runs its function with no instrumentation and no process-dictionary writes.
  """

  @key {__MODULE__, :phases}

  # `Server-Timing` durations are milliseconds (HTTP spec / PostgREST). Phases
  # are accumulated as integer nanoseconds (`:timer.tc(_, :nanosecond)`) and
  # converted here. Float division is deliberate: a phase can take well under a
  # millisecond, and `:erlang.convert_time_unit/3` would truncate that to 0.
  @ns_per_ms 1_000_000

  @doc """
  Initialise (or clear) the accumulator for the current request.

  `enabled?` mirrors the instance's `server-timing-enabled`: when `false` the
  accumulator is put into a disabled state so `measure/2` skips instrumentation
  entirely. Called once per request by `Bier.Plugs.Observability`.
  """
  @spec reset(boolean()) :: :ok
  def reset(true) do
    Process.put(@key, %{})
    :ok
  end

  def reset(false) do
    Process.put(@key, :disabled)
    :ok
  end

  @doc """
  Time `fun`, accumulate its elapsed wall-clock under `phase`, and return its
  result unchanged.

  A no-op wrapper (just `fun.()`, no timing) when server-timing is disabled for
  this request, or when called outside an initialised request. Repeated measures
  of the same `phase` accumulate, so a phase that issues several round-trips
  (e.g. a read plus an exact-count query) reports their sum.
  """
  @spec measure(atom(), (-> result)) :: result when result: var
  def measure(phase, fun) when is_function(fun, 0) do
    case Process.get(@key) do
      phases when is_map(phases) ->
        {elapsed, result} = :timer.tc(fun, :nanosecond)
        Process.put(@key, Map.update(phases, phase, elapsed, &(&1 + elapsed)))
        result

      _ ->
        fun.()
    end
  end

  @doc """
  The phases accumulated so far for the current request, as a map of
  `phase => milliseconds` (float). Empty when timing is disabled or nothing was
  recorded — `Bier.Plugs.Observability` reports a phase absent from this map as
  `0.0` (truthful: no time was spent there) rather than a fabricated value.
  """
  @spec snapshot() :: %{optional(atom()) => float()}
  def snapshot do
    case Process.get(@key) do
      phases when is_map(phases) ->
        Map.new(phases, fn {phase, ns} -> {phase, ns / @ns_per_ms} end)

      _ ->
        %{}
    end
  end
end
