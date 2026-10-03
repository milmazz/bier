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

    # Documented, not ideal: the TRUNCATE frame names one relation, so a
    # single partition's truncate can only reach root subscribers as a
    # truncate OF the root. The guide tells clients to read it as
    # "re-bootstrap", which is right either way; withholding it would leave
    # root subscribers holding rows that no longer exist.
    test "a truncate of a single partition reaches root subscribers as the root",
         %{db: db, name: name} do
      register!(name, "orders")

      sql!(db, "TRUNCATE #{@schema}.orders_us")

      assert_receive {:bier_wal_event, {@schema, "orders"}, _, truncate}, 5_000
      assert truncate.kind == :truncate and truncate.relation.table == "orders"
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

  describe "subscribing over HTTP" do
    test "a root subscription streams leaf changes as the root", %{db: db, port: port} do
      sock = SSETestClient.connect_sse(port, "/events?table=orders")
      SSETestClient.recv_until(sock, ": connected")

      sql!(db, "INSERT INTO #{@schema}.orders (id, region, note) VALUES (1, 'eu', 'hi')")

      frame = SSETestClient.recv_until(sock, "data: {")
      assert frame =~ "event: orders\n"
      data = decode_frame(frame)
      assert data["type"] == "INSERT"
      assert {data["schema"], data["table"]} == key("orders")
      assert data["row"] == %{"id" => 1, "region" => "eu", "note" => "hi"}
    end

    @tag pub: :on
    test "a root subscription streams as the root with publish_via_partition_root on",
         %{db: db, port: port} do
      sock = SSETestClient.connect_sse(port, "/events?table=orders")
      SSETestClient.recv_until(sock, ": connected")

      sql!(db, "INSERT INTO #{@schema}.orders (id, region, note) VALUES (2, 'us', 'on')")

      frame = SSETestClient.recv_until(sock, "data: {")
      assert frame =~ "event: orders\n"
      assert decode_frame(frame)["row"] == %{"id" => 2, "region" => "us", "note" => "on"}
    end

    test "a leaf subscription keeps streaming as the leaf", %{db: db, port: port} do
      sock = SSETestClient.connect_sse(port, "/events?table=orders_eu_low")
      SSETestClient.recv_until(sock, ": connected")

      sql!(db, "INSERT INTO #{@schema}.orders (id, region, note) VALUES (3, 'eu', 'leaf')")

      frame = SSETestClient.recv_until(sock, "data: {")
      assert frame =~ "event: orders_eu_low\n"
      assert decode_frame(frame)["table"] == "orders_eu_low"
    end

    test "Last-Event-ID resumes a root subscription from the root's own history",
         %{db: db, port: port} do
      sock = SSETestClient.connect_sse(port, "/events?table=orders")
      SSETestClient.recv_until(sock, ": connected")
      sql!(db, "INSERT INTO #{@schema}.orders (id, region, note) VALUES (10, 'eu', 'seen')")
      frame = SSETestClient.recv_until(sock, "data: {")
      [_, id] = Regex.run(~r/id: ([^\n]+)\n/, frame)
      :gen_tcp.close(sock)

      # Missed while disconnected, from two different leaves.
      sql!(db, "INSERT INTO #{@schema}.orders (id, region, note) VALUES (11, 'us', 'missed-us')")
      sql!(db, "INSERT INTO #{@schema}.orders (id, region, note) VALUES (12, 'eu', 'missed-eu')")

      sock2 = SSETestClient.connect_sse(port, "/events?table=orders&last_event_id=#{id}")
      replay = SSETestClient.recv_until(sock2, ~s("note":"missed-eu"))

      frames =
        ~r/event: ([^\n]+)\nid: ([^\n]+)\ndata: (\{.*?\})\n/
        |> Regex.scan(replay)
        |> Enum.map(fn [_, name, _id, data] -> {name, JSON.decode!(data)["row"]["note"]} end)

      # Only the root's copies: the leaf copies of the same changes live
      # under the leaves' own keys and are not part of this subscription.
      assert frames == [{"orders", "missed-us"}, {"orders", "missed-eu"}]
    end

    test "an intermediate partitioned table gets the uniform 404", %{port: port} do
      assert refusal_body(port, "orders_eu") == refusal_body(port, "missing")
    end
  end

  describe "subscribing to a leaf partition directly" do
    test "is admitted with publish_via_partition_root off, where pgoutput names leaves",
         %{db: db} do
      assert {:ok, _} = Bier.Wal.Authorize.check(db, nil, @pub_off, [key("orders_eu_low")])
    end

    # pgoutput reports every change of the tree as the root, so a leaf
    # subscription could only ever be silent: refused, through the same
    # uniform shape as an unknown table, rather than admitted and starved.
    @tag pub: :on
    test "gets the uniform 404 with publish_via_partition_root on", %{port: port} do
      assert refusal_body(port, "orders_eu_low") == refusal_body(port, "missing")
      assert refusal_body(port, "orders_us") == refusal_body(port, "missing")
    end

    # The refusal follows what pgoutput names, not the setting alone: a leaf
    # published on its own, with no published ancestor, is reported as
    # itself even with publish_via_partition_root on.
    test "is admitted under publish_via_partition_root on when no ancestor is published",
         %{db: db} do
      pub = "wal_part_leaf_via_root"

      on_exit(fn ->
        {:ok, cleanup} =
          Postgrex.start_link(Keyword.put(Bier.ConformanceServer.base_opts(), :pool_size, 1))

        Postgrex.query!(cleanup, "DROP PUBLICATION IF EXISTS #{pub}", [])
      end)

      sql!(
        db,
        "CREATE PUBLICATION #{pub} FOR TABLE #{@schema}.orders_us " <>
          "WITH (publish_via_partition_root = true)"
      )

      assert {:ok, _} = Bier.Wal.Authorize.check(db, nil, pub, [key("orders_us")])
    end
  end

  describe "authorization of a partitioned root" do
    alias Bier.Wal.Authorize

    @all_columns MapSet.new(["id", "region", "note"])

    test "a published root is admitted under either publish_via_partition_root setting",
         %{db: db} do
      for pub <- [@pub_off, @pub_on] do
        assert {:ok, %{{@schema, "orders"} => @all_columns}} ==
                 Authorize.check(db, nil, pub, [key("orders")])
      end
    end

    test "an intermediate partitioned table is refused: changes route to the topmost root",
         %{db: db} do
      for pub <- [@pub_off, @pub_on] do
        assert {:error, {:events_unknown_table, "#{@schema}.orders_eu"}} ==
                 Authorize.check(db, nil, pub, [key("orders_eu")])
      end
    end

    test "privileges are the root's, not a partition's", %{db: db} do
      sql!(db, "GRANT USAGE ON SCHEMA #{@schema} TO postgrest_test_anonymous")
      sql!(db, "GRANT USAGE ON SCHEMA #{@schema} TO postgrest_test_default_role")
      sql!(db, "GRANT SELECT (id, note) ON #{@schema}.orders TO postgrest_test_anonymous")
      sql!(db, "GRANT SELECT ON #{@schema}.orders_eu_low TO postgrest_test_default_role")

      # SELECT on the root only: the root is admitted with exactly the
      # root's column grants, and a leaf it holds no grant on is refused —
      # querying the leaf directly would be refused too.
      assert {:ok, %{{@schema, "orders"} => cols}} =
               Authorize.check(db, "postgrest_test_anonymous", @pub_off, [key("orders")])

      assert cols == MapSet.new(["id", "note"])

      assert {:error, {:events_unknown_table, _}} =
               Authorize.check(db, "postgrest_test_anonymous", @pub_off, [key("orders_eu_low")])

      # SELECT on a leaf only: the leaf is admitted, the root is not — a
      # grant on one partition must not open the whole tree.
      assert {:ok, _} =
               Authorize.check(db, "postgrest_test_default_role", @pub_off, [
                 key("orders_eu_low")
               ])

      assert {:error, {:events_unknown_table, "#{@schema}.orders"}} ==
               Authorize.check(db, "postgrest_test_default_role", @pub_off, [key("orders")])
    end

    test "RLS is the root's: on the root it refuses, on a leaf alone it does not",
         %{db: db} do
      sql!(db, "ALTER TABLE #{@schema}.orders_us ENABLE ROW LEVEL SECURITY")
      assert {:ok, _} = Authorize.check(db, nil, @pub_off, [key("orders")])

      sql!(db, "ALTER TABLE #{@schema}.orders ENABLE ROW LEVEL SECURITY")

      assert {:error, {:events_unknown_table, "#{@schema}.orders"}} ==
               Authorize.check(db, nil, @pub_off, [key("orders")])
    end

    test "membership is the root's own, not inferred from its published leaves", %{db: db} do
      leaf_pub = "wal_part_leaf_only"
      schema_pub = "wal_part_schema"
      all_pub = "wal_part_all"

      on_exit(fn ->
        {:ok, cleanup} =
          Postgrex.start_link(Keyword.put(Bier.ConformanceServer.base_opts(), :pool_size, 1))

        for pub <- [leaf_pub, schema_pub, all_pub],
            do: Postgrex.query!(cleanup, "DROP PUBLICATION IF EXISTS #{pub}", [])
      end)

      # Only one leaf published: its changes are on the wire, but the root's
      # subscribers would see a fraction of the table, so the root is
      # refused while the leaf itself stays subscribable.
      sql!(db, "CREATE PUBLICATION #{leaf_pub} FOR TABLE #{@schema}.orders_us")

      assert {:error, {:events_unknown_table, "#{@schema}.orders"}} ==
               Authorize.check(db, nil, leaf_pub, [key("orders")])

      assert {:ok, _} = Authorize.check(db, nil, leaf_pub, [key("orders_us")])

      # The root reaches a publication through its schema, or through
      # FOR ALL TABLES, as well as by name.
      sql!(db, "CREATE PUBLICATION #{schema_pub} FOR TABLES IN SCHEMA #{@schema}")
      sql!(db, "CREATE PUBLICATION #{all_pub} FOR ALL TABLES")

      for pub <- [schema_pub, all_pub] do
        assert {:ok, _} = Authorize.check(db, nil, pub, [key("orders")]), pub
      end
    end
  end

  # The RAW 404 body with the echoed identifier normalized out, after
  # asserting the BIER003 envelope — byte-compared against an unknown
  # table's so a partition refusal can't be told apart from any other (see
  # `Bier.Wal.EventsHttpTest.refusal_body/3`).
  defp refusal_body(port, table) do
    resp =
      Req.get!("http://127.0.0.1:#{port}/events?table=#{table}",
        retry: false,
        decode_body: false
      )

    assert resp.status == 404
    assert resp.headers["proxy-status"] == ["Bier; error=BIER003"]
    String.replace(resp.body, "#{@schema}.#{table}", "T")
  end

  # The `data:` payload of the LAST frame in `raw`, decoded (same shape as
  # `Bier.Wal.EventsHttpTest.decode_frame/1`).
  defp decode_frame(raw),
    do: raw |> String.split("data: ") |> List.last() |> String.trim() |> JSON.decode!()
end
