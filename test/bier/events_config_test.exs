defmodule Bier.EventsConfigTest do
  use ExUnit.Case, async: true

  defp new!(overrides) do
    Bier.Config.new!(overrides, Bier.schema())
  end

  test "defaults: feature disabled, path 'events', heartbeat 15s" do
    conf = new!([])
    assert conf.events_channels == []
    assert conf.events_path == "events"
    assert conf.events_heartbeat_interval == 15_000
  end

  test "accepts a channel allowlist and custom path/heartbeat" do
    conf =
      new!(
        events_channels: ["chat", "jobs"],
        events_path: "realtime",
        events_heartbeat_interval: 50
      )

    assert conf.events_channels == ["chat", "jobs"]
    assert conf.events_path == "realtime"
    assert conf.events_heartbeat_interval == 50
  end

  test "rejects empty channel names" do
    assert_raise ArgumentError, ~r/events-channels entries cannot be empty/, fn ->
      new!(events_channels: [""])
    end
  end

  test "rejects channel names over 63 bytes" do
    assert_raise ArgumentError, ~r/cannot exceed 63 bytes/, fn ->
      new!(events_channels: [String.duplicate("a", 64)])
    end
  end

  test "rejects channel names containing double quotes or null bytes" do
    assert_raise ArgumentError, ~r/cannot contain double quotes/, fn ->
      new!(events_channels: [~s(bad"name)])
    end

    assert_raise ArgumentError, ~r/cannot contain null bytes/, fn ->
      new!(events_channels: [<<?a, 0, ?b>>])
    end
  end

  test "rejects an empty or multi-segment events_path" do
    assert_raise ArgumentError, ~r/events-path cannot be empty/, fn ->
      new!(events_channels: ["chat"], events_path: "")
    end

    assert_raise ArgumentError, ~r/single path segment/, fn ->
      new!(events_channels: ["chat"], events_path: "a/b")
    end
  end
end
