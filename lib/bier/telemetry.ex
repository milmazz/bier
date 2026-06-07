defmodule Bier.Telemetry do
  @moduledoc """
  `:telemetry` events emitted by Bier.

  Bier follows the idiomatic Elixir observability path: it emits `:telemetry`
  events and leaves it to the host application to attach `Telemetry.Metrics` /
  a reporter (Prometheus, StatsD, …). Nothing is exported in-process.

  Because a single BEAM node can host several Bier instances at once — each its
  own database, config, and HTTP server (see `Bier`) — **every event carries the
  originating instance name under `:instance` in its metadata**. Attach with
  `:telemetry.attach/4` (or `attach_many/4`) and filter on `metadata.instance`
  to scope metrics to one instance.

  ## Events

  ### `[:bier, :request, :start]`

  Emitted when a request enters the pipeline (`Bier.Plugs.Observability`).

    * Measurements: `:system_time`, `:monotonic_time`.
    * Metadata: `:instance`, `:method`, `:route` (the request path).

  ### `[:bier, :request, :stop]`

  Emitted when the response is sent (a `Plug.Conn.register_before_send/2`
  callback), so the duration is the real request wall-clock.

    * Measurements: `:duration` (native time units), `:monotonic_time`.
    * Metadata: `:instance`, `:method`, `:route`, `:status`, plus `:schema` and
      `:relation` once the target has been resolved (both `nil` for the root
      document, `OPTIONS`, and error responses that never resolve a relation).

  > #### Per-phase timings {: .info}
  > These events carry only the **total** request duration. The per-phase
  > splits (jwt / parse / plan / transaction / response) that `Server-Timing`
  > reports are still fabricated today; threading real per-phase timings through
  > the pipeline is tracked as the Server-Timing fidelity follow-up (#26).

  ### `[:bier, :schema_cache, :load, :start | :stop | :exception]`

  A `:telemetry.span/3` around boot-time DB introspection
  (`Bier.HttpServerStarter`). The `:stop` event marks a successful load; a
  failing introspection emits `:exception` instead (the "fail" status, mirroring
  PostgREST's `pgrst_schema_cache_loads_total{status="fail"}`).

    * `:start` metadata: `:instance`, `:schemas`.
    * `:stop` measurements: `:duration`; metadata: `:instance`, `:schemas`,
      `:status` (`:ok`), `:relation_count`.
    * `:exception` carries the standard `:kind`, `:reason`, `:stacktrace`
      alongside `:instance` and `:schemas`.

  ## Not yet emitted

  Two further families from #26 depend on infrastructure Bier does not have yet
  and are tracked as a follow-up:

    * `[:bier, :pool, …]` — Postgrex/DBConnection pool gauges (no clean public
      API to poll pool size/queue today).
    * `[:bier, :jwt_cache, …]` — Bier verifies every JWT directly; there is no
      verification cache to instrument.
  """

  @request_start [:bier, :request, :start]
  @request_stop [:bier, :request, :stop]
  @schema_cache_load [:bier, :schema_cache, :load]

  @doc """
  Emit `[:bier, :request, :start]` and return the monotonic start time to hand
  back to `request_stop/2` when the response is sent.
  """
  @spec request_start(map()) :: integer()
  def request_start(metadata) do
    start = System.monotonic_time()

    :telemetry.execute(
      @request_start,
      %{system_time: System.system_time(), monotonic_time: start},
      metadata
    )

    start
  end

  @doc """
  Emit `[:bier, :request, :stop]`, computing `:duration` from the `start` value
  returned by `request_start/1`.
  """
  @spec request_stop(integer(), map()) :: :ok
  def request_stop(start, metadata) do
    stop = System.monotonic_time()

    :telemetry.execute(
      @request_stop,
      %{duration: stop - start, monotonic_time: stop},
      metadata
    )
  end

  @doc """
  Wrap a schema-cache load in a `[:bier, :schema_cache, :load, *]` span.

  `fun` must return `{result, stop_metadata}`; `result` is returned to the
  caller and `stop_metadata` (e.g. `%{relation_count: n}`) is merged with the
  start `metadata` and `status: :ok` for the `:stop` event. A raise inside `fun`
  surfaces as the `:exception` event.
  """
  @spec schema_cache_load(map(), (-> {result, map()})) :: result when result: var
  def schema_cache_load(metadata, fun) when is_function(fun, 0) do
    :telemetry.span(@schema_cache_load, metadata, fn ->
      {result, stop_metadata} = fun.()
      {result, metadata |> Map.put(:status, :ok) |> Map.merge(stop_metadata)}
    end)
  end
end
