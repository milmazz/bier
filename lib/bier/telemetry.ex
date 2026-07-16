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
  > These events carry only the **total** request duration. The per-phase splits
  > (jwt / parse / plan / transaction / response) are measured separately and
  > surfaced through the `Server-Timing` response header — see
  > `Bier.ServerTiming` and `Bier.Plugs.Observability`. They are not (yet)
  > attached to these `:telemetry` events.

  ### `[:bier, :schema_cache, :load, :start | :stop | :exception]`

  A `:telemetry.span/3` around every schema-cache load — both boot-time DB
  introspection (`Bier.HttpServerStarter`) and a later `Bier.SchemaCache.reload/1`
  — since both funnel through `Bier.SchemaCache.load!/3`. The snapshot swap
  (`Bier.SchemaCache.put/2`) happens *inside* the span, before the `:stop`
  event fires, so a caller synchronizing on `:stop` (e.g.
  `Bier.SchemaCacheListener`, or a test using `:telemetry_test`) is guaranteed
  the new snapshot is already visible by the time it observes `:stop`. The
  `:stop` event marks a successful load; a failing introspection emits
  `:exception` instead (the "fail" status, mirroring PostgREST's
  `pgrst_schema_cache_loads_total{status="fail"}`) and leaves the previous
  snapshot in place.

    * `:start` metadata: `:instance`, `:schemas`.
    * `:stop` measurements: `:duration`; metadata: `:instance`, `:schemas`,
      `:status` (`:ok`), `:relation_count`.
    * `:exception` carries the standard `:kind`, `:reason`, `:stacktrace`
      alongside `:instance` and `:schemas`.

  ### `[:bier, :pool, :status]`

  A periodic gauge sample of the instance's Postgrex connection pool, emitted
  by `Bier.PoolMonitor` (once at startup, then every 5 seconds). Mirrors
  PostgREST's `pgrst_db_pool_max` / `pgrst_db_pool_available` /
  `pgrst_db_pool_waiting` Prometheus gauges.

    * Measurements: `:max` (the configured `pool_size`), `:available`
      (connections ready for checkout), `:waiting` (callers queued for a
      checkout).
    * Metadata: `:instance`.

  ### `[:bier, :pool, :checkout_timeout]`

  Emitted by `Bier.Plugs.FallbackController` when a request fails because its
  pool checkout was dropped from the queue after timing out (a
  `DBConnection.ConnectionError` with reason `:queue_timeout`). The counter
  counterpart of the `:status` gauges — mirrors PostgREST's
  `pgrst_db_pool_timeouts_total`.

    * Measurements: `:count` (always `1`).
    * Metadata: `:instance`.

  ## JWT cache events (#36)

    * `[:bier, :jwt_cache, :lookup]` — one per cache consultation, with
      measurement `%{count: 1}` and metadata `%{hit: boolean, instance: name}`.
      All lookups mirror `pgrst_jwt_cache_requests_total`; those with
      `hit: true` mirror `pgrst_jwt_cache_hits_total`.
    * `[:bier, :jwt_cache, :eviction]` — one per entry evicted by the SIEVE
      hand, measurement `%{count: 1}`, metadata `%{instance: name}`; mirrors
      `pgrst_jwt_cache_evictions_total`.

  Emitted only when the cache is enabled (`jwt_secret` set and
  `jwt_cache_max_entries > 0`), matching PostgREST, which records no cache
  observations in `JwtNoCache` mode.

  ## SSE Events (#81)

    * `[:bier, :events, :subscribe, :start]` — start of an SSE subscription,
      measurement `%{system_time: ...}`, metadata `:instance`, `:channels`.
    * `[:bier, :events, :subscribe, :stop]` — end of an SSE subscription,
      measurements `:duration` (native units), `:delivered` (frames sent),
      metadata `:instance`, `:channels`.
    * `[:bier, :events, :notification]` — one NOTIFY fanned out to subscribers,
      measurement `%{subscribers: count}`, metadata `:instance`, `:channel`.
    * `[:bier, :events, :listener]` — connection status event from the database
      listener, measurement `%{count: 1}`, metadata `:instance`, `:status`
      (`:connected` or `:disconnected`).
  """

  @request_start [:bier, :request, :start]
  @request_stop [:bier, :request, :stop]
  @schema_cache_load [:bier, :schema_cache, :load]
  @pool_status [:bier, :pool, :status]
  @pool_checkout_timeout [:bier, :pool, :checkout_timeout]
  @jwt_cache_lookup [:bier, :jwt_cache, :lookup]
  @jwt_cache_eviction [:bier, :jwt_cache, :eviction]
  @events_subscribe_start [:bier, :events, :subscribe, :start]
  @events_subscribe_stop [:bier, :events, :subscribe, :stop]
  @events_notification [:bier, :events, :notification]
  @events_listener [:bier, :events, :listener]

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

  @doc """
  Emit `[:bier, :pool, :status]` with the sampled pool gauges (`:max`,
  `:available`, `:waiting`). Called by `Bier.PoolMonitor`.
  """
  @spec pool_status(map(), map()) :: :ok
  def pool_status(measurements, metadata) do
    :telemetry.execute(@pool_status, measurements, metadata)
  end

  @doc """
  Emit `[:bier, :pool, :checkout_timeout]` for one request dropped from the
  pool's checkout queue. Called by `Bier.Plugs.FallbackController`.
  """
  @spec pool_checkout_timeout(map()) :: :ok
  def pool_checkout_timeout(metadata) do
    :telemetry.execute(@pool_checkout_timeout, %{count: 1}, metadata)
  end

  @doc """
  Emit `[:bier, :jwt_cache, :lookup]` for one cache consultation; `hit?` is
  merged into the metadata as `:hit`. Called by `Bier.JwtCache`.
  """
  @spec jwt_cache_lookup(boolean(), map()) :: :ok
  def jwt_cache_lookup(hit?, metadata) do
    :telemetry.execute(@jwt_cache_lookup, %{count: 1}, Map.put(metadata, :hit, hit?))
  end

  @doc """
  Emit `[:bier, :jwt_cache, :eviction]` for one entry evicted by the cache's
  SIEVE hand. Called by `Bier.JwtCache`.
  """
  @spec jwt_cache_eviction(map()) :: :ok
  def jwt_cache_eviction(metadata) do
    :telemetry.execute(@jwt_cache_eviction, %{count: 1}, metadata)
  end

  @doc """
  Start of an SSE events subscription (`[:bier, :events, :subscribe, :start]`).
  Returns the monotonic start time to pass to `events_subscribe_stop/3`.
  Metadata: `:instance`, `:channels`.
  """
  @spec events_subscribe_start(map()) :: integer()
  def events_subscribe_start(metadata) do
    start = System.monotonic_time()
    :telemetry.execute(@events_subscribe_start, %{system_time: System.system_time()}, metadata)
    start
  end

  @doc """
  End of an SSE events subscription (`[:bier, :events, :subscribe, :stop]`).
  Measurements: `:duration` (native units), `:delivered` (frames sent).
  """
  @spec events_subscribe_stop(integer(), non_neg_integer(), map()) :: :ok
  def events_subscribe_stop(start, delivered, metadata) do
    duration = System.monotonic_time() - start

    :telemetry.execute(
      @events_subscribe_stop,
      %{duration: duration, delivered: delivered},
      metadata
    )
  end

  @doc """
  One NOTIFY fanned out to subscribers (`[:bier, :events, :notification]`).
  Measurement `:subscribers` is how many processes received it — a steady 0
  reveals an orphaned channel. Metadata: `:instance`, `:channel`.
  """
  @spec events_notification(non_neg_integer(), map()) :: :ok
  def events_notification(subscribers, metadata) do
    :telemetry.execute(@events_notification, %{subscribers: subscribers}, metadata)
  end

  @doc """
  Events listener connectivity (`[:bier, :events, :listener]`): `:status` in
  metadata is `:connected` or `:disconnected`. Useful for alerting on gap
  windows (fire-and-forget delivery loses events while disconnected).
  """
  @spec events_listener(:connected | :disconnected, map()) :: :ok
  def events_listener(status, metadata) do
    :telemetry.execute(@events_listener, %{count: 1}, Map.put(metadata, :status, status))
  end
end
