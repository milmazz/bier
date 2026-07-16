defmodule Bier.Events.ListenerTest do
  @moduledoc """
  Boots the events listener against the bier_test DB (loaded by the mix test
  alias) and drives it with pg_notify. Not async: real DB connections.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  defp config(channels) do
    opts =
      [
        name: :"events_listener_#{System.unique_integer([:positive])}",
        events_channels: channels
      ] ++ Bier.ConformanceServer.base_opts()

    Bier.Config.new!(opts, Bier.schema())
  end

  defp notify(channel, payload) do
    conf = config([])
    {:ok, conn} = Postgrex.start_link(Keyword.drop(Bier.postgrex_opts(conf), [:name, :pool_size]))
    Postgrex.query!(conn, "SELECT pg_notify($1, $2)", [channel, payload])
    GenServer.stop(conn)
  end

  test "broadcasts NOTIFY payloads to registered subscribers" do
    conf = config(["events_it_chat"])
    pid = start_supervised!({Bier.Events.Listener, conf})
    wait_until_connected(pid)

    :ok = Bier.Events.Registry.register(conf.name, "events_it_chat")
    notify("events_it_chat", "hello")

    assert_receive {:bier_event, "events_it_chat", "hello"}, 2_000
  end

  test "reconnects and re-LISTENs after losing the notifications connection" do
    conf = config(["events_it_chat"])
    pid = start_supervised!({Bier.Events.Listener, conf})
    wait_until_connected(pid)

    :ok = Bier.Events.Registry.register(conf.name, "events_it_chat")

    %{notifications: notif} = :sys.get_state(pid)
    Process.exit(notif, :kill)

    # Backoff starts at 500ms; after reconnect the LISTEN must be re-issued.
    wait_until_connected(pid, 200)
    notify("events_it_chat", "after-reconnect")

    assert_receive {:bier_event, "events_it_chat", "after-reconnect"}, 2_000
  end

  # `:sys.get_state/1` and a linked process's `:EXIT` signal race independently
  # for the listener's mailbox, so right after `Process.exit(notif, :kill)` a
  # `get_state` call can still observe the old (already dying) pid before the
  # GenServer has processed its own `:EXIT` and reconnected. `is_pid/1` alone
  # can't tell the stale pid from a fresh one, so liveness must be checked too.
  defp wait_until_connected(pid, retries \\ 100) do
    state = :sys.get_state(pid)

    cond do
      is_pid(state.notifications) and Process.alive?(state.notifications) ->
        :ok

      retries > 0 ->
        Process.sleep(20)
        wait_until_connected(pid, retries - 1)

      true ->
        flunk("listener never connected: #{inspect(state)}")
    end
  end
end
