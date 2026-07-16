defmodule Bier.Events.Listener do
  @moduledoc """
  Per-instance LISTEN connection for the realtime events endpoint.

  Subscribes to every channel in `events_channels` on one dedicated
  `Postgrex.Notifications` connection and fans each notification out to SSE
  subscribers via `Bier.Events.Registry.broadcast/3`.

  Connection ownership mirrors `Bier.SchemaCacheListener`: the connection is
  started with `auto_reconnect: false` under `trap_exit`, and on loss the
  listener stays alive and retries with exponential backoff, so a database
  outage never crash-loops the instance's supervisor. Delivery is
  fire-and-forget by contract — notifications sent while disconnected are
  lost and no catch-up is attempted (unlike the schema-cache listener, there
  is nothing to reload).
  """

  use GenServer

  require Logger

  @initial_backoff 500
  @max_backoff 30_000

  def start_link(%Bier.Config{name: name} = conf) do
    GenServer.start_link(__MODULE__, conf, name: Bier.Registry.via(name, __MODULE__))
  end

  @impl GenServer
  def init(%Bier.Config{} = conf) do
    Process.flag(:trap_exit, true)
    {:ok, %{conf: conf, notifications: nil, backoff: @initial_backoff}, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state), do: connect(state)

  @impl GenServer
  def handle_info(:connect, state), do: connect(state)

  def handle_info({:notification, _pid, _ref, channel, payload}, %{conf: conf} = state) do
    subscribers = Bier.Events.Registry.broadcast(conf.name, channel, payload)
    Bier.Telemetry.events_notification(subscribers, %{instance: conf.name, channel: channel})
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %{notifications: pid, conf: conf} = state) do
    Logger.warning(
      "Bier events listener for #{inspect(conf.name)} lost its LISTEN " <>
        "connection: #{inspect(reason)}"
    )

    Bier.Telemetry.events_listener(:disconnected, %{instance: conf.name})
    {:noreply, schedule_reconnect(%{state | notifications: nil})}
  end

  # An EXIT from a connection already replaced after an earlier failure.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # The LISTEN connection cannot go through the request pool; run a dedicated
  # Postgrex.Notifications connection built from the instance options.
  defp connect(%{conf: conf} = state) do
    opts =
      conf
      |> Bier.postgrex_opts()
      |> Keyword.drop([:name, :pool_size])
      |> Keyword.merge(sync_connect: true, auto_reconnect: false)

    case Postgrex.Notifications.start_link(opts) do
      {:ok, pid} ->
        case listen_all(pid, conf.events_channels) do
          :ok ->
            Bier.Telemetry.events_listener(:connected, %{instance: conf.name})
            {:noreply, %{state | notifications: pid, backoff: @initial_backoff}}

          {:error, other} ->
            Logger.warning(
              "Bier events listener for #{inspect(conf.name)} could not LISTEN " <>
                "(retrying in #{state.backoff}ms): #{inspect(other)}"
            )

            # Not a real subscription — drop the connection and retry. We stay
            # linked and do NOT touch state.notifications: a late :EXIT from
            # this pid lands on the catch-all clause above and is ignored.
            Process.exit(pid, :kill)
            {:noreply, schedule_reconnect(state)}
        end

      {:error, reason} ->
        Logger.warning(
          "Bier events listener for #{inspect(conf.name)} cannot reach the " <>
            "database (retrying in #{state.backoff}ms): #{inspect(reason)}"
        )

        {:noreply, schedule_reconnect(state)}
    end
  end

  # Every allowlisted channel must subscribe; the first failure aborts the
  # attempt (all-or-retry keeps the LISTEN set consistent with the config).
  defp listen_all(pid, channels) do
    Enum.reduce_while(channels, :ok, fn channel, :ok ->
      case safe_listen(pid, channel) do
        {:ok, _ref} -> {:cont, :ok}
        other -> {:halt, {:error, other}}
      end
    end)
  end

  # `listen/3` returns `{:ok, ref}` once subscribed, or `{:eventually, ref}`
  # when the connection isn't actually up — not a real subscription either.
  # It can also raise if the fresh connection died between `start_link/1`
  # returning and this call; caught so a lost race becomes a retry.
  defp safe_listen(pid, channel) do
    Postgrex.Notifications.listen(pid, channel)
  catch
    :exit, reason -> {:exit, reason}
  end

  defp schedule_reconnect(state) do
    Process.send_after(self(), :connect, state.backoff)
    %{state | backoff: min(state.backoff * 2, @max_backoff)}
  end
end
