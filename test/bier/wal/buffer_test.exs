defmodule Bier.Wal.BufferTest do
  use ExUnit.Case, async: true

  alias Bier.Wal.Buffer

  @orders {"api", "orders"}
  @items {"api", "items"}

  defp start!(buffer_size) do
    name = :"buffer_test_#{System.unique_integer([:positive])}"
    conf = struct!(Bier.Config, name: name, events_buffer_size: buffer_size)
    start_supervised!({Buffer, conf})
    gen = Buffer.new_generation(name)
    {name, gen}
  end

  defp cursor(lo, seq \\ 0), do: {{0, lo}, seq}

  # Real events always carry their relation; the Buffer interns it (one copy
  # per table rather than one per entry) and re-attaches it on replay, so the
  # fixtures have to carry one for the round trip to be exercised at all.
  defp relation(table_key, columns \\ ["id"])

  defp relation({schema, table}, columns) do
    %{
      oid: :erlang.phash2({schema, table}),
      schema: schema,
      table: table,
      replica_identity: :default,
      columns: Enum.map(columns, &%{name: &1, type_oid: 23, type_mod: -1, key?: &1 == "id"})
    }
  end

  defp event(n, table_key \\ @orders, columns \\ ["id"]),
    do: %{kind: :insert, n: n, relation: relation(table_key, columns)}

  test "replays events strictly after the cursor, across tables, in order" do
    {name, gen} = start!(10)

    :ok =
      Buffer.append(name, [
        {cursor(1), @orders, event(1)},
        {cursor(1, 1), @items, event(2, @items)}
      ])

    :ok = Buffer.append(name, [{cursor(2), @orders, event(3)}])

    assert {:ok, replayed} = Buffer.replay_after(name, [@orders, @items], cursor(1), gen)

    assert Enum.map(replayed, fn {c, _t, e} -> {c, e.n} end) == [
             {cursor(1, 1), 2},
             {cursor(2), 3}
           ]
  end

  test "a cursor older than a wrapped table's history resets" do
    {name, gen} = start!(2)

    for n <- 1..4, do: Buffer.append(name, [{cursor(n), @orders, event(n)}])

    # Buffer holds cursors 3 and 4; cursor 1 predates retained history.
    assert Buffer.replay_after(name, [@orders], cursor(1), gen) == :reset
    assert {:ok, [_]} = Buffer.replay_after(name, [@orders], cursor(3), gen)
  end

  test "an empty table never forces a reset" do
    {name, gen} = start!(2)

    # Anchor the epoch on a DIFFERENT table first: a generation that has
    # issued no ids at all resets every cursor (see the epoch-floor test
    # below), so what this test is about — a table with no history of its
    # own contributing no reset — is only observable once some id exists.
    :ok = Buffer.append(name, [{cursor(1), @orders, event(1)}])

    assert {:ok, []} = Buffer.replay_after(name, [@items], cursor(1), gen)
  end

  test "generation mismatch resets and new_generation clears history" do
    {name, gen} = start!(10)
    :ok = Buffer.append(name, [{cursor(5), @orders, event(5)}])

    assert Buffer.replay_after(name, [@orders], cursor(5), gen - 1) == :reset

    new_gen = Buffer.new_generation(name)
    assert new_gen == gen + 1

    # Anchor the new epoch BELOW the cleared entry's cursor: replaying from
    # that anchor comes back empty, which it could only do if the bump
    # really did drop cursor(5)'s entry — it sorts after the anchor.
    :ok = Buffer.append(name, [{cursor(1), @orders, event(1)}])
    assert {:ok, []} = Buffer.replay_after(name, [@orders], cursor(1), new_gen)
  end

  test "a cursor minted before the current epoch resets, even at the current generation" do
    {name, _gen} = start!(10)

    :ok = Buffer.append(name, [{cursor(5), @orders, event(5)}])
    old = cursor(5)

    # The generation the endpoint hands back is the one it just READ from
    # this Buffer, so the generation guard can never fire for a real client
    # (`Bier.Events.replay/4`); the epoch floor is what has to catch a
    # cursor minted before the last (re)start. Nothing has been appended
    # since the bump, so no id this Buffer could honor exists at all.
    new_gen = Buffer.new_generation(name)
    assert Buffer.replay_after(name, [@orders], old, new_gen) == :reset

    # The first append after the bump anchors the epoch floor: a cursor
    # older than it belongs to the previous epoch and still resets, while
    # replay from the floor itself works normally.
    :ok =
      Buffer.append(name, [{cursor(9), @orders, event(9)}, {cursor(9, 1), @orders, event(10)}])

    assert Buffer.replay_after(name, [@orders], old, new_gen) == :reset
    assert Buffer.replay_after(name, [@orders], cursor(8), new_gen) == :reset

    assert {:ok, [{cursor(9, 1), @orders, event(10)}]} ==
             Buffer.replay_after(name, [@orders], cursor(9), new_gen)
  end

  test "drop marks a table as having lost history until a new entry re-anchors it" do
    {name, gen} = start!(10)

    :ok =
      Buffer.append(name, [
        {cursor(1), @orders, event(1)},
        {cursor(1, 1), @items, event(2, @items)}
      ])

    :ok = Buffer.drop(name, [@orders])

    # The undropped table is unaffected by the drop. cursor(1) — the epoch
    # floor here, this generation's first appended cursor — rather than
    # cursor(0): anything below the floor resets on its own, which would
    # mask the per-table behavior under test.
    assert {:ok, [{cursor(1, 1), @items, event(2, @items)}]} ==
             Buffer.replay_after(name, [@items], cursor(1), gen)

    # A dropped table with no entries yet resets for every cursor.
    assert Buffer.replay_after(name, [@orders], cursor(1), gen) == :reset

    # Once a new entry lands it re-anchors the table: a cursor at-or-past it
    # is fine, anything older still resets.
    :ok = Buffer.append(name, [{cursor(9), @orders, event(9)}])
    assert {:ok, []} = Buffer.replay_after(name, [@orders], cursor(9), gen)

    # cursor(8), NOT cursor(0). cursor(0) is below this generation's epoch
    # floor (cursor(1)), so `before_floor?/2` would reset it whatever
    # `restore_oldest/3` did — the assertion would hold even if the
    # re-anchor were broken. cursor(8) sits above the floor and below the
    # re-anchored `oldest`, so only the per-table staleness check can
    # produce this reset.
    assert Buffer.replay_after(name, [@orders], cursor(8), gen) == :reset
  end

  test "replay re-attaches each table's interned relation" do
    {name, gen} = start!(10)

    # An anchoring append first: the epoch floor is this generation's FIRST
    # cursor, and anything below it resets by design, so the cursor a client
    # can legitimately resume from has to be at-or-after it.
    :ok = Buffer.append(name, [{cursor(1), @orders, event(0, @orders, ["id", "note"])}])

    :ok =
      Buffer.append(name, [
        {cursor(2), @orders, event(1, @orders, ["id", "note"])},
        {cursor(2, 1), @items, event(2, @items, ["id", "sku"])}
      ])

    assert {:ok, replayed} = Buffer.replay_after(name, [@orders, @items], cursor(1), gen)

    # The relation is stripped before storage (one copy per table, not one
    # per entry) and put back on the way out, so a replayed event must be
    # indistinguishable from the live one Render sees — including the right
    # relation for the right table.
    assert [{_, @orders, orders_event}, {_, @items, items_event}] = replayed
    assert orders_event.relation.table == "orders"
    assert Enum.map(orders_event.relation.columns, & &1.name) == ["id", "note"]
    assert items_event.relation.table == "items"
    assert Enum.map(items_event.relation.columns, & &1.name) == ["id", "sku"]
  end

  test "a changed relation invalidates that table's history, not its neighbours" do
    {name, gen} = start!(10)

    :ok =
      Buffer.append(name, [
        {cursor(1), @orders, event(1, @orders, ["id", "note"])},
        {cursor(1, 1), @items, event(2, @items, ["id", "sku"])}
      ])

    # A DDL changed `orders`: the entry retained above was decoded against
    # the old column list, so replaying it with the new relation would name
    # its values wrongly. Resuming across the change must reset rather than
    # hand back mislabeled rows.
    :ok = Buffer.append(name, [{cursor(2), @orders, event(3, @orders, ["id", "note", "extra"])}])
    :ok = Buffer.append(name, [{cursor(3), @orders, event(4, @orders, ["id", "note", "extra"])}])

    assert Buffer.replay_after(name, [@orders], cursor(1), gen) == :reset

    # `items` never changed, so its history survives — the invalidation is
    # per table, not a wholesale generation bump.
    assert {:ok, [{_, @items, items_event}]} =
             Buffer.replay_after(name, [@items], cursor(1), gen)

    assert items_event.n == 2

    # And `orders` resumes normally from its re-anchored history onward,
    # now carrying the NEW column list.
    assert {:ok, [{_, @orders, orders_event}]} =
             Buffer.replay_after(name, [@orders], cursor(2), gen)

    assert orders_event.n == 4
    assert Enum.map(orders_event.relation.columns, & &1.name) == ["id", "note", "extra"]
  end
end
