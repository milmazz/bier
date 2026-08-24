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

  describe "WAL change-feed options" do
    test "default to disabled" do
      conf = new!([])
      assert conf.events_publication == nil
      assert conf.events_buffer_size == 1024
      assert conf.events_max_tx_events == 10_000
    end

    test "accept a publication name and sizes" do
      conf =
        new!(
          events_publication: "bier_events",
          events_buffer_size: 16,
          events_max_tx_events: 100
        )

      assert conf.events_publication == "bier_events"
      assert conf.events_buffer_size == 16
      assert conf.events_max_tx_events == 100
    end

    test "reject a publication name that cannot be safely interpolated" do
      # START_REPLICATION takes no bind parameters, so the name is
      # interpolated into a single-quoted literal; a quote or backslash in
      # it would break out of that literal rather than produce a clear
      # error.
      for bad <- [~s(with'quote), ~s(with"quote), "back\\slash", <<?a, 0, ?b>>] do
        assert_raise ArgumentError,
                     ~r/events-publication cannot contain quotes, backslashes, or null bytes/,
                     fn -> new!(events_publication: bad) end
      end

      assert_raise ArgumentError, ~r/events-publication cannot be empty/, fn ->
        new!(events_publication: "")
      end

      assert_raise ArgumentError, ~r/events-publication cannot exceed 63 bytes/, fn ->
        new!(events_publication: String.duplicate("p", 64))
      end
    end

    test "reject a non-positive buffer size" do
      assert_raise ArgumentError, ~r/events_buffer_size option: expected positive integer/, fn ->
        new!(events_buffer_size: 0)
      end
    end
  end
end
