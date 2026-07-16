defmodule Bier.Events.TelemetryTest do
  use ExUnit.Case, async: false

  setup do
    handler_id = "events-telemetry-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:bier, :events, :subscribe, :start],
        [:bier, :events, :subscribe, :stop],
        [:bier, :events, :notification],
        [:bier, :events, :listener]
      ],
      fn event, measurements, metadata, _config ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "subscribe start/stop span with delivered count" do
    meta = %{instance: :t, channels: ["chat"]}
    start = Bier.Telemetry.events_subscribe_start(meta)
    assert is_integer(start)

    assert_receive {:telemetry, [:bier, :events, :subscribe, :start], %{system_time: _}, ^meta}

    :ok = Bier.Telemetry.events_subscribe_stop(start, 3, meta)

    assert_receive {:telemetry, [:bier, :events, :subscribe, :stop],
                    %{duration: duration, delivered: 3}, ^meta}

    assert duration >= 0
  end

  test "notification carries the subscriber count" do
    :ok = Bier.Telemetry.events_notification(2, %{instance: :t, channel: "chat"})

    assert_receive {:telemetry, [:bier, :events, :notification], %{subscribers: 2},
                    %{instance: :t, channel: "chat"}}
  end

  test "listener status events" do
    :ok = Bier.Telemetry.events_listener(:connected, %{instance: :t})

    assert_receive {:telemetry, [:bier, :events, :listener], %{count: 1},
                    %{instance: :t, status: :connected}}
  end
end
