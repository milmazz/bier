defmodule Bier.PoolMonitor do
  @moduledoc """
  Per-instance poller that samples the Postgrex connection pool and emits the
  `[:bier, :pool, :status]` gauge event (see `Bier.Telemetry`).

  PostgREST exposes its pool as the Prometheus gauges `pgrst_db_pool_max`,
  `pgrst_db_pool_available` and `pgrst_db_pool_waiting`. DBConnection's pool is
  sampled through `DBConnection.get_connection_metrics/1` — a snapshot of
  ready connections and checkout-queue depth per pool source — so the event's
  measurements map onto those gauges:

    * `:max` — the configured `pool_size`;
    * `:available` — connections ready to be checked out (0 while the pool is
      busy);
    * `:waiting` — callers queued for a checkout.

  One sample is emitted immediately on start (so an attached handler observes
  the pool without waiting a full interval), then every 5 seconds. A sample
  that finds the pool unreachable (e.g. mid-restart) is skipped — no event is
  emitted, and the poller stays alive for the next tick.

  The counter half of PostgREST's pool metrics (`pgrst_db_pool_timeouts_total`)
  is event-driven, not polled: `[:bier, :pool, :checkout_timeout]` fires from
  `Bier.Plugs.FallbackController` when a request fails on a checkout-queue
  timeout.
  """

  use GenServer

  @interval 5_000

  def start_link(%Bier.Config{name: name} = conf) do
    GenServer.start_link(__MODULE__, conf, name: Bier.Registry.via(name, __MODULE__))
  end

  @impl GenServer
  def init(%Bier.Config{} = conf) do
    {:ok, conf, {:continue, :sample}}
  end

  @impl GenServer
  def handle_continue(:sample, conf) do
    sample(conf)
    Process.send_after(self(), :sample, @interval)
    {:noreply, conf}
  end

  @impl GenServer
  def handle_info(:sample, conf) do
    {:noreply, conf, {:continue, :sample}}
  end

  # `get_connection_metrics/1` is a call into the pool process; it returns one
  # entry per source (the pool itself, plus any ownership proxies), summed here.
  # A pool that is down or mid-restart exits the call — caught so the poller
  # just skips that sample instead of crash-looping alongside the pool.
  defp sample(%Bier.Config{name: name, pool_size: pool_size}) do
    metrics = DBConnection.get_connection_metrics(Bier.Registry.via(name, Postgrex))

    {available, waiting} =
      Enum.reduce(metrics, {0, 0}, fn entry, {ready, queued} ->
        {ready + entry.ready_conn_count, queued + entry.checkout_queue_length}
      end)

    Bier.Telemetry.pool_status(
      %{max: pool_size, available: available, waiting: waiting},
      %{instance: name}
    )
  catch
    :exit, _reason -> :ok
  end
end
