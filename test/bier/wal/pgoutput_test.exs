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
end
