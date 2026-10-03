defmodule Bier.Wal.PartitionTest do
  @moduledoc """
  Partitioned tables on the WAL change feed (#140), against a real
  logical-replication stream.

  The fixture is a two-level tree:

      orders            PARTITION BY LIST (region)
      ├── orders_eu     PARTITION BY RANGE (id)
      │   ├── orders_eu_low   [0, 1000)
      │   └── orders_eu_high  [1000, ∞)
      └── orders_us     (created standalone with its columns in a DIFFERENT
                          order, then ATTACHed)

  and two publications of the root, one per `publish_via_partition_root`
  setting, because the two settings put changes on the wire under different
  names: with it off (the default) pgoutput names the LEAF a row landed in,
  with it on it names the root. Every test boots its own instance against
  one of them (`@tag pub: :on`, default `:off`).

  `orders_us`'s shuffled column order is deliberate. Partitions share their
  parent's column names and types but not their attribute numbers, so the
  Relation messages pgoutput sends for two leaves of one root list the same
  columns in different orders — which is exactly what would make the
  Buffer's per-table relation interning think the root's relation "changed"
  every time consecutive changes came from different leaves.

  Not async: real ports, real replication slots, DB-global publications.
  """
  use ExUnit.Case, async: false

  alias Bier.SSETestClient
  alias Bier.TestPorts
  alias Bier.Wal.Buffer

  @moduletag :integration

  @schema "wal_partition_test"
  @pub_off "wal_part_off"
  @pub_on "wal_part_on"

  setup context do
    # A dedicated connection just for setup/teardown DDL and mutations (see
    # Bier.Wal.ConsumerTest's own note on the shared connection budget).
    {:ok, db} =
      Postgrex.start_link(Keyword.put(Bier.ConformanceServer.base_opts(), :pool_size, 1))

    Postgrex.query!(db, "DROP PUBLICATION IF EXISTS #{@pub_off}", [])
    Postgrex.query!(db, "DROP PUBLICATION IF EXISTS #{@pub_on}", [])
    Postgrex.query!(db, "DROP SCHEMA IF EXISTS #{@schema} CASCADE", [])
    Postgrex.query!(db, "CREATE SCHEMA #{@schema}", [])

    for sql <- [
          "CREATE TABLE #{@schema}.orders (id int NOT NULL, region text NOT NULL, " <>
            "note text, PRIMARY KEY (id, region)) PARTITION BY LIST (region)",
          "CREATE TABLE #{@schema}.orders_eu PARTITION OF #{@schema}.orders " <>
            "FOR VALUES IN ('eu') PARTITION BY RANGE (id)",
          "CREATE TABLE #{@schema}.orders_eu_low PARTITION OF #{@schema}.orders_eu " <>
            "FOR VALUES FROM (0) TO (1000)",
          "CREATE TABLE #{@schema}.orders_eu_high PARTITION OF #{@schema}.orders_eu " <>
            "FOR VALUES FROM (1000) TO (MAXVALUE)",
          "CREATE TABLE #{@schema}.orders_us (note text, region text NOT NULL, id int NOT NULL)",
          "ALTER TABLE #{@schema}.orders ATTACH PARTITION #{@schema}.orders_us " <>
            "FOR VALUES IN ('us')",
          "CREATE PUBLICATION #{@pub_off} FOR TABLE #{@schema}.orders",
          "CREATE PUBLICATION #{@pub_on} FOR TABLE #{@schema}.orders " <>
            "WITH (publish_via_partition_root = true)"
        ],
        do: Postgrex.query!(db, sql, [])

    on_exit(fn ->
      {:ok, cleanup} =
        Postgrex.start_link(Keyword.put(Bier.ConformanceServer.base_opts(), :pool_size, 1))

      Postgrex.query!(cleanup, "DROP PUBLICATION IF EXISTS #{@pub_off}", [])
      Postgrex.query!(cleanup, "DROP PUBLICATION IF EXISTS #{@pub_on}", [])
      Postgrex.query!(cleanup, "DROP SCHEMA IF EXISTS #{@schema} CASCADE", [])
    end)

    port = TestPorts.free_port()
    name = :"wal_partition_#{System.unique_integer([:positive])}"

    opts =
      Bier.ConformanceServer.base_opts()
      |> Keyword.merge(
        name: name,
        pool_size: 2,
        db_schemas: [@schema],
        db_channel_enabled: false,
        events_publication: if(context[:pub] == :on, do: @pub_on, else: @pub_off),
        events_heartbeat_interval: 50,
        events_max_tx_events: Map.get(context, :events_max_tx_events, 10_000),
        router: [port: port, scheme: :http]
      )

    start_supervised!({Bier, opts})
    TestPorts.wait_until_listening(port)
    wait_wal_streaming(db, name)

    %{db: db, port: port, name: name}
  end

  # Scoped to THIS instance's own slot — see
  # `Bier.Wal.EventsHttpTest.wait_wal_streaming/2` for why an unscoped
  # "something is streaming" check races the previous test's teardown, and
  # for the ~5s budget.
  defp wait_wal_streaming(db, name) do
    prefix = "bier_#{:erlang.phash2(name)}_%"

    SSETestClient.wait_until(
      fn ->
        %{rows: rows} =
          Postgrex.query!(
            db,
            """
            SELECT 1 FROM pg_stat_replication sr
            JOIN pg_replication_slots rs ON rs.active_pid = sr.pid
            WHERE rs.slot_name LIKE $1 AND sr.state = 'streaming'
            """,
            [prefix]
          )

        rows != []
      end,
      500
    )
  end

  defp key(table), do: {@schema, table}

  defp register!(name, table),
    do: :ok = Bier.Events.Registry.register_table(name, key(table), nil)

  defp sql!(db, sql), do: Postgrex.query!(db, sql, [])

  describe "publish_via_partition_root = false (the default)" do
    test "a leaf change reaches root subscribers named after the root, and leaf " <>
           "subscribers named after the leaf, each with its own cursor",
         %{db: db, name: name} do
      register!(name, "orders")
      register!(name, "orders_eu_low")

      sql!(db, "INSERT INTO #{@schema}.orders (id, region, note) VALUES (1, 'eu', 'hello')")

      assert_receive {:bier_wal_event, {@schema, "orders"}, root_cursor, root_event}, 5_000
      assert_receive {:bier_wal_event, {@schema, "orders_eu_low"}, leaf_cursor, leaf_event}

      assert root_event.kind == :insert
      assert {root_event.relation.schema, root_event.relation.table} == key("orders")
      assert root_event.row == %{"id" => "1", "region" => "eu", "note" => "hello"}

      assert {leaf_event.relation.schema, leaf_event.relation.table} == key("orders_eu_low")
      assert leaf_event.row == root_event.row

      # Same commit, distinct sequence numbers: each copy is its own event
      # in the cursor space, as a fanned-out TRUNCATE's copies are.
      assert elem(root_cursor, 0) == elem(leaf_cursor, 0)
      assert root_cursor != leaf_cursor

      # The intermediate level is never a routing target: the root is the
      # table a subscriber to the whole tree asked for.
      refute_received {:bier_wal_event, {@schema, "orders_eu"}, _, _}
    end

    test "update and delete route to the root too", %{db: db, name: name} do
      register!(name, "orders")
      sql!(db, "INSERT INTO #{@schema}.orders (id, region, note) VALUES (5, 'us', 'a')")
      assert_receive {:bier_wal_event, {@schema, "orders"}, _, %{kind: :insert}}, 5_000

      sql!(db, "UPDATE #{@schema}.orders SET note = 'b' WHERE id = 5")
      assert_receive {:bier_wal_event, {@schema, "orders"}, _, update}, 5_000
      assert update.kind == :update and update.relation.table == "orders"
      assert update.row["note"] == "b"

      sql!(db, "DELETE FROM #{@schema}.orders WHERE id = 5")
      assert_receive {:bier_wal_event, {@schema, "orders"}, _, delete}, 5_000
      assert delete.kind == :delete and delete.relation.table == "orders"
      # DEFAULT replica identity on a partitioned table: the key, (id, region).
      assert delete.old == %{"id" => "5", "region" => "us"}
    end

    test "a truncate of the root reaches root subscribers exactly once", %{db: db, name: name} do
      register!(name, "orders")
      register!(name, "orders_us")

      sql!(db, "TRUNCATE #{@schema}.orders")

      assert_receive {:bier_wal_event, {@schema, "orders"}, _, truncate}, 5_000
      assert truncate.kind == :truncate and truncate.relation.table == "orders"
      assert_receive {:bier_wal_event, {@schema, "orders_us"}, _, %{kind: :truncate}}

      # Every leaf in the TRUNCATE maps to the same root: one root copy,
      # not one per leaf.
      refute_receive {:bier_wal_event, {@schema, "orders"}, _, _}, 200
    end

    test "root history replays across leaves whose columns are ordered differently",
         %{db: db, name: name} do
      register!(name, "orders")
      gen = Buffer.generation(name)

      sql!(db, "INSERT INTO #{@schema}.orders (id, region, note) VALUES (1, 'eu', 'anchor')")
      assert_receive {:bier_wal_event, {@schema, "orders"}, anchor, _}, 5_000

      # Two more transactions, from leaves whose Relation messages list the
      # same columns in different orders. If the root copies carried their
      # leaf's column list verbatim, the Buffer would see the root's
      # relation "change" between them and invalidate the root's history —
      # a resume would read `history_evicted` instead of these two rows.
      sql!(db, "INSERT INTO #{@schema}.orders (id, region, note) VALUES (2, 'us', 'us-row')")
      assert_receive {:bier_wal_event, {@schema, "orders"}, _, _}, 5_000
      sql!(db, "INSERT INTO #{@schema}.orders (id, region, note) VALUES (3, 'eu', 'eu-row')")
      assert_receive {:bier_wal_event, {@schema, "orders"}, _, _}, 5_000

      assert {:ok, [{_, _, us}, {_, _, eu}]} =
               Buffer.replay_after(name, [key("orders")], anchor, gen)

      assert {us.relation.table, us.row["note"]} == {"orders", "us-row"}
      assert {eu.relation.table, eu.row["note"]} == {"orders", "eu-row"}
    end

    # Each fanned-out copy is a real event — its own cursor sequence, its
    # own Buffer entry — so the cap counts copies, not wire messages, the
    # same rule a TRUNCATE naming N relations already follows. Two rows into
    # one leaf are FOUR events (leaf + root each) against a cap of 3.
    @tag events_max_tx_events: 3
    test "the per-transaction cap counts the fanned-out copies, and the overflow " <>
           "reset reaches root subscribers",
         %{db: db, name: name} do
      register!(name, "orders")

      sql!(
        db,
        "INSERT INTO #{@schema}.orders (id, region, note) VALUES (1, 'eu', 'x'), (2, 'eu', 'y')"
      )

      assert_receive {:bier_wal_reset, "transaction_too_large"}, 5_000
      refute_received {:bier_wal_event, _, _, _}
    end
  end

  describe "publish_via_partition_root = true" do
    @describetag pub: :on

    test "insert, update, delete and truncate reach root subscribers as the root",
         %{db: db, name: name} do
      register!(name, "orders")

      sql!(db, "INSERT INTO #{@schema}.orders (id, region, note) VALUES (1500, 'eu', 'a')")
      sql!(db, "UPDATE #{@schema}.orders SET note = 'b' WHERE id = 1500")
      sql!(db, "DELETE FROM #{@schema}.orders WHERE id = 1500")
      sql!(db, "TRUNCATE #{@schema}.orders")

      for kind <- [:insert, :update, :delete, :truncate] do
        assert_receive {:bier_wal_event, {@schema, "orders"}, _, %{kind: ^kind} = event}, 5_000
        assert event.relation.table == "orders"
      end

      refute_received {:bier_wal_event, _, _, _}
    end
  end
end
