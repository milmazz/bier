defmodule Bier.EventsQueueOverloadedTest do
  @moduledoc """
  Pure, process-local test for `Bier.Events.queue_overloaded?/0` — the
  slow-subscriber guard checked in the `{:bier_wal_event, ...}` clause of
  `Bier.Events`'s streaming loop.

  Unlike the sibling `events_http_test.exs` in this directory, this needs no
  DB connection, publication, or running `Bier` instance: the guard reads
  only `self()`'s own mailbox length, so a real slow socket would be far
  less deterministic than just flooding this test process directly. Kept as
  its own file (rather than folded into `events_http_test.exs`) so it can
  run async and skip that file's per-test instance boot.
  """
  use ExUnit.Case, async: true

  test "queue_overloaded? trips past the high-water mark" do
    refute Bier.Events.queue_overloaded?()
    for n <- 1..1_100, do: send(self(), {:flood, n})
    assert Bier.Events.queue_overloaded?()
    for _ <- 1..1_100, do: receive(do: ({:flood, _} -> :ok))
    refute Bier.Events.queue_overloaded?()
  end
end
