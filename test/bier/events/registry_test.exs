defmodule Bier.Events.RegistryTest do
  use ExUnit.Case, async: true

  alias Bier.Events.Registry, as: EventsRegistry

  test "register + broadcast delivers {:bier_event, channel, payload} to subscribers" do
    instance = :"events_reg_#{System.unique_integer([:positive])}"
    assert :ok = EventsRegistry.register(instance, "chat")

    assert EventsRegistry.broadcast(instance, "chat", "hello") == 1
    assert_receive {:bier_event, "chat", "hello"}
  end

  test "broadcast only reaches the matching instance and channel" do
    instance = :"events_reg_#{System.unique_integer([:positive])}"
    other = :"events_reg_#{System.unique_integer([:positive])}"
    assert :ok = EventsRegistry.register(instance, "chat")

    assert EventsRegistry.broadcast(instance, "jobs", "x") == 0
    assert EventsRegistry.broadcast(other, "chat", "x") == 0
    refute_receive {:bier_event, _, _}, 50
  end

  test "entries are cleaned up when the subscriber dies" do
    instance = :"events_reg_#{System.unique_integer([:positive])}"

    {pid, ref} =
      spawn_monitor(fn ->
        EventsRegistry.register(instance, "chat")

        receive do
          :stop -> :ok
        end
      end)

    # Wait until the spawned process has registered.
    wait_until(fn -> EventsRegistry.subscriber_count(instance, "chat") == 1 end)

    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    wait_until(fn -> EventsRegistry.subscriber_count(instance, "chat") == 0 end)
  end

  defp wait_until(fun, retries \\ 100) do
    cond do
      fun.() ->
        :ok

      retries == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(10)
        wait_until(fun, retries - 1)
    end
  end
end
