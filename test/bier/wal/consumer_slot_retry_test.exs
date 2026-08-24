defmodule Bier.Wal.ConsumerSlotRetryTest do
  @moduledoc """
  Unit guard for the slot-creation failure path in `Bier.Wal.Consumer`.

  Needs no database, publication or running instance: it drives the
  `Postgrex.ReplicationConnection` callbacks directly, which is the only way
  to observe what a FAILED `CREATE_REPLICATION_SLOT` does — a real failure
  needs `max_replication_slots` exhausted, which cannot be manufactured in a
  shared test cluster without disrupting every other suite.
  """
  use ExUnit.Case, async: true

  alias Bier.Wal.Consumer

  setup do
    name = :"wal_retry_#{System.unique_integer([:positive])}"
    conf = struct!(Bier.Config, name: name, events_publication: "irrelevant")
    {:ok, state} = Consumer.init(conf)
    %{name: name, state: state}
  end

  test "a failed slot creation neither resets subscribers nor spins", %{name: name, state: state} do
    # Registered as a table subscriber, so a stray reset broadcast would
    # land in this process's mailbox.
    :ok = Bier.Events.Registry.register_table(name, {"api", "orders"}, nil)

    assert {:noreply, failed} =
             Consumer.handle_result(%Postgrex.Error{message: "out of slots"}, state)

    # The generation bump and its `stream_restarted` broadcast belong to the
    # SUCCESS arm only. Bumping per ATTEMPT would push a reset at every
    # subscriber on every retry, and the documented client contract answers
    # each one with a fresh bootstrapping GET — turning a slot outage into a
    # request storm. (No Buffer is running here, so a call to it would also
    # exit :noproc — this passing at all is part of the assertion.)
    refute_receive {:bier_wal_reset, _reason}, 100

    # Retried on a timer, NOT by disconnecting: postgrex arms its
    # reconnect_backoff only when `Protocol.connect/1` itself fails, so a
    # `{:disconnect, _}` after a successful connect reconnects immediately
    # and spins at full connection-setup rate.
    assert failed.slot_backoff == 500
    assert_receive :bier_wal_retry_slot, 2_000

    # And the backoff escalates rather than retrying at a fixed rate.
    assert {:noreply, again} = Consumer.handle_result(%Postgrex.Error{message: "still"}, failed)
    assert again.slot_backoff > failed.slot_backoff
    assert again.slot_backoff <= 1_000
  end

  test "each retry mints a fresh slot name", %{state: state} do
    assert {:query, first_sql, first} = Consumer.handle_info(:bier_wal_retry_slot, state)
    assert {:query, second_sql, second} = Consumer.handle_info(:bier_wal_retry_slot, first)

    # Slot names are CLUSTER-global and a TEMPORARY slot outlives its
    # connection briefly, so reusing one across a retry collides with the
    # server still reaping the previous attempt's slot (`42710`).
    assert first.slot != second.slot
    assert first_sql =~ "CREATE_REPLICATION_SLOT #{first.slot} TEMPORARY LOGICAL pgoutput"
    assert second_sql =~ second.slot
  end

  test "a successful connect restarts the backoff", %{state: state} do
    assert {:noreply, failed} = Consumer.handle_result(%Postgrex.Error{message: "x"}, state)
    assert failed.slot_backoff == 500

    # `handle_connect/1` runs on a REAL (re)connect, which is a different
    # situation from another failed attempt on a connection that is already
    # up: the escalation earned by the previous connection should not carry
    # over to a fresh one.
    assert {:query, _sql, reconnected} = Consumer.handle_connect(failed)
    assert reconnected.slot_backoff == nil
  end
end
