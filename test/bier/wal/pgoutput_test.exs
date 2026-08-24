defmodule Bier.Wal.PgoutputTest do
  use ExUnit.Case, async: true

  alias Bier.Wal.Pgoutput

  # Relation message for public.items(id int4 PK, name text) with default
  # replica identity ('d'), id flagged as key column.
  defp relation_msg(oid) do
    <<?R, oid::32, "public", 0, "items", 0, ?d, 2::16, 1::8, "id", 0, 23::32, -1::signed-32, 0::8,
      "name", 0, 25::32, -1::signed-32>>
  end

  defp reg(oid) do
    {_event, reg} = Pgoutput.decode(relation_msg(oid), %{})
    reg
  end

  test "Relation registers columns, identity, and key flags" do
    {event, reg} = Pgoutput.decode(relation_msg(42), %{})
    assert event.kind == :relation
    assert reg[42].schema == "public"
    assert reg[42].table == "items"
    assert reg[42].replica_identity == :default

    assert [%{name: "id", type_oid: 23, key?: true}, %{name: "name", type_oid: 25, key?: false}] =
             reg[42].columns
  end

  test "Begin and Commit carry LSN pairs and timestamps" do
    # 2000-01-01 epoch; 0 microseconds = 2000-01-01T00:00:00Z.
    {b, _} = Pgoutput.decode(<<?B, 7::32, 100::32, 0::64, 99::32>>, %{})

    assert b == %{
             kind: :begin,
             final_lsn: {7, 100},
             commit_at: ~U[2000-01-01 00:00:00.000000Z],
             xid: 99
           }

    {c, _} = Pgoutput.decode(<<?C, 0::8, 7::32, 100::32, 7::32, 200::32, 0::64>>, %{})
    assert c.kind == :commit and c.lsn == {7, 100} and c.end_lsn == {7, 200}
  end

  test "Insert zips tuple values with column names" do
    tuple = <<2::16, ?t, 1::32, "3", ?n>>
    {event, _} = Pgoutput.decode(<<?I, 42::32, ?N, tuple::binary>>, reg(42))
    assert event.kind == :insert
    assert event.row == %{"id" => "3", "name" => nil}
    assert event.relation.table == "items"
  end

  test "Update with key old-tuple ('K') and unchanged TOAST ('u')" do
    old = <<2::16, ?t, 1::32, "3", ?n>>
    new = <<2::16, ?t, 1::32, "3", ?u>>
    msg = <<?U, 42::32, ?K, old::binary, ?N, new::binary>>
    {event, _} = Pgoutput.decode(msg, reg(42))
    assert event.kind == :update and event.old_kind == :key
    # A 'K' tuple is ExtractReplicaIdentity's output: every attribute outside
    # the replica identity is NULLed and lands on the wire as 'n'. Reporting
    # `"name" => nil` would be indistinguishable from a column that really
    # held NULL, so a client diffing old against row would read an unlogged
    # column as having changed FROM null. Only the key columns were logged,
    # so only the key columns are reported.
    assert event.old == %{"id" => "3"}
    assert event.row == %{"id" => "3", "name" => :unchanged_toast}
  end

  test "Delete with a key old-tuple ('K') reports only the identity columns" do
    old = <<2::16, ?t, 1::32, "3", ?n>>
    {event, _} = Pgoutput.decode(<<?D, 42::32, ?K, old::binary>>, reg(42))
    assert event.kind == :delete and event.old_kind == :key
    assert event.old == %{"id" => "3"}
  end

  test "Update without old tuple has old: nil" do
    new = <<2::16, ?t, 1::32, "4", ?t, 3::32, "ada">>
    {event, _} = Pgoutput.decode(<<?U, 42::32, ?N, new::binary>>, reg(42))
    assert event.old == nil and event.old_kind == nil
    assert event.row == %{"id" => "4", "name" => "ada"}
  end

  test "Delete carries the old tuple" do
    old = <<2::16, ?t, 1::32, "3", ?n>>
    {event, _} = Pgoutput.decode(<<?D, 42::32, ?O, old::binary>>, reg(42))
    assert event.kind == :delete and event.old_kind == :full
    # An 'O' tuple is the whole row, so nothing is filtered out — `name` is
    # reported as a genuine NULL even though this relation flags only `id`
    # as a key column. (Postgres only sends 'O' under REPLICA IDENTITY FULL,
    # where it flags every column, but pinning the tag rather than the flags
    # is what keeps the 'K' filtering above from over-reaching.)
    assert event.old == %{"id" => "3", "name" => nil}
  end

  test "Truncate decodes flags and relations" do
    {event, _} = Pgoutput.decode(<<?T, 1::32, 1::8, 42::32>>, reg(42))
    assert event.kind == :truncate and event.cascade and not event.restart_identity
    assert [%{table: "items"}] = event.relations
  end

  test "data message for an unknown relation oid raises" do
    assert_raise RuntimeError, ~r/unknown relation oid/, fn ->
      Pgoutput.decode(<<?I, 7::32, ?N, 0::16>>, %{})
    end
  end

  test "Origin, Type and Message decode without disturbing the registry" do
    # These arrive interleaved with data messages — Type in particular is
    # emitted ahead of Relation for user-defined types, so a table with an
    # enum column hits it on the very first event. A mistake here raises
    # inside handle_data/2 and kills the consumer.
    reg = reg(42)

    {origin, ^reg} = Pgoutput.decode(<<?O, 7::32, 99::32, "pg_1", 0>>, reg)
    assert origin.kind == :origin and origin.lsn == {7, 99} and origin.name == "pg_1"

    {type, ^reg} = Pgoutput.decode(<<?Y, 16_385::32, "public", 0, "mood", 0>>, reg)
    assert type.kind == :type and type.oid == 16_385
    assert type.schema == "public" and type.name == "mood"

    content = "hello"
    msg = <<?M, 1::8, 7::32, 100::32, "bier", 0, byte_size(content)::32, content::binary>>
    {message, ^reg} = Pgoutput.decode(msg, reg)
    assert message.kind == :message and message.transactional
    assert message.prefix == "bier" and message.content == content

    # Bit 0 is the transactional flag; higher bits are reserved, so a future
    # flag set alongside it must not read as non-transactional.
    {both, ^reg} =
      Pgoutput.decode(
        <<?M, 3::8, 7::32, 100::32, "bier", 0, byte_size(content)::32, content::binary>>,
        reg
      )

    assert both.transactional
    {none, ^reg} = Pgoutput.decode(<<?M, 2::8, 7::32, 100::32, "bier", 0, 0::32>>, reg)
    refute none.transactional
  end

  test "binary tuple values are tagged rather than mistaken for text" do
    # Only reachable when the binary option is negotiated, which bier does
    # not do — but a value silently read as text would be corrupt data, so
    # the kind is preserved rather than guessed at.
    tuple = <<2::16, ?t, 1::32, "3", ?b, 2::32, 0xFF, 0x00>>
    {event, _} = Pgoutput.decode(<<?I, 42::32, ?N, tuple::binary>>, reg(42))
    assert event.row == %{"id" => "3", "name" => {:binary, <<0xFF, 0x00>>}}
  end

  test "every replica identity setting decodes" do
    for {byte, expected} <- [{?d, :default}, {?n, :nothing}, {?f, :full}, {?i, :index}] do
      msg = <<?R, 7::32, "public", 0, "t", 0, byte, 1::16, 1::8, "id", 0, 23::32, -1::signed-32>>
      {event, _} = Pgoutput.decode(msg, %{})
      assert event.relation.replica_identity == expected
    end
  end

  test "an unrecognised message kind is inert rather than fatal" do
    # Protocol additions (the streaming and two-phase families, none of them
    # reachable at proto_version 1) must not raise: this runs inside the
    # replication process, where a FunctionClauseError kills the consumer and
    # resets every subscriber.
    {event, reg} = Pgoutput.decode(<<?Z, 1, 2, 3>>, %{})
    assert event == %{kind: :unknown, tag: ?Z}
    assert reg == %{}
  end

  test "a tuple whose arity disagrees with the cached relation raises" do
    # Enum.zip/2 truncates to the shorter side, so without an explicit check
    # this would silently DROP a column instead of failing — the one outcome
    # the feed must not have. Raising restarts the consumer, which re-reads
    # the relation and announces the gap as a reset.
    assert_raise RuntimeError, ~r/columns but the tuple carried/, fn ->
      Pgoutput.decode(<<?I, 42::32, ?N, 1::16, ?t, 1::32, "3">>, reg(42))
    end

    assert_raise RuntimeError, ~r/columns but the old tuple carried/, fn ->
      Pgoutput.decode(<<?D, 42::32, ?K, 1::16, ?t, 1::32, "3">>, reg(42))
    end
  end
end
