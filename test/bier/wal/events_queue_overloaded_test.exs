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

  # Pinned at the boundary rather than at a comfortable 1_100: flooding well
  # past the mark and asserting the guard trips would hold on ANY threshold
  # at or below the flood size, so it could not tell `>` from `>=` and would
  # survive the mark being moved. `@max_queue` is 1_000, so 1_000 queued
  # messages must NOT trip it and 1_001 must.
  @max_queue 1_000

  test "queue_overloaded? is false at the high-water mark and true one past it" do
    refute Bier.Events.queue_overloaded?()

    for n <- 1..@max_queue, do: send(self(), {:flood, n})
    refute Bier.Events.queue_overloaded?()

    send(self(), {:flood, @max_queue + 1})
    assert Bier.Events.queue_overloaded?()

    for _ <- 1..(@max_queue + 1), do: receive(do: ({:flood, _} -> :ok))
    refute Bier.Events.queue_overloaded?()
  end
end
