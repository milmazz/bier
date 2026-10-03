defmodule Bier.Wal.PartitionTest do
  @moduledoc """
  Partitioned tables on the WAL change feed (#140), against a real
  logical-replication stream.

  A partitioned table is subscribable only through a publication created
  `WITH (publish_via_partition_root = true)`: PostgreSQL then names the
  topmost published ancestor itself on every change, resolved against the
  catalog AS OF that change. Bier routes by exactly the relation pgoutput
  names and never consults the current catalog, so DDL racing the
  replication lag (ATTACH, DETACH) cannot misroute a row.

  The fixture is a two-level tree:

      orders            PARTITION BY LIST (region)
      ├── orders_eu     PARTITION BY RANGE (id)
      │   ├── orders_eu_low   [0, 1000)
      │   └── orders_eu_high  [1000, ∞)
      └── orders_us     (created standalone with its columns in a different
                          order, then ATTACHed; REPLICA IDENTITY FULL)

  plus `staging`, a standalone table with the same columns, published but
  not (yet) a partition. Three publications, one per test via
  `@tag pub: ...` (default `:on`):

    * `:on`  — `orders` and `staging`, `publish_via_partition_root = true`;
    * `:off` — `orders`, the default `publish_via_partition_root = false`;
    * `:mid` — the intermediate `orders_eu` alone, via the root.

  Not async: real ports, real replication slots, DB-global publications.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Bier.SSETestClient
  alias Bier.TestPorts
  alias Bier.Wal.Authorize

  @moduletag :integration
  # The fixture's orders_us is FULL under a DEFAULT root on purpose (the
  # `old` tests need it), so every boot logs the REPLICA IDENTITY mismatch
  # warning; keep it out of the suite's output. Tests that assert on boot
  # logs capture them explicitly.
  @moduletag capture_log: true

  @schema "wal_partition_test"
  @other_schema "wal_partition_other"
  @pubs %{on: "wal_part_on", off: "wal_part_off", mid: "wal_part_mid"}

  setup context do
    # A dedicated connection just for setup/teardown DDL and mutations (see
    # Bier.Wal.ConsumerTest's own note on the shared connection budget).
    {:ok, db} =
      Postgrex.start_link(Keyword.put(Bier.ConformanceServer.base_opts(), :pool_size, 1))

    drop_all(db)
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
          "ALTER TABLE #{@schema}.orders_us REPLICA IDENTITY FULL",
          "CREATE TABLE #{@schema}.staging (id int NOT NULL, region text NOT NULL, " <>
            "note text, PRIMARY KEY (id, region))",
          "CREATE PUBLICATION #{@pubs.on} FOR TABLE #{@schema}.orders, #{@schema}.staging " <>
            "WITH (publish_via_partition_root = true)",
          "CREATE PUBLICATION #{@pubs.off} FOR TABLE #{@schema}.orders",
          "CREATE PUBLICATION #{@pubs.mid} FOR TABLE #{@schema}.orders_eu " <>
            "WITH (publish_via_partition_root = true)"
        ],
        do: Postgrex.query!(db, sql, [])

    on_exit(fn ->
      {:ok, cleanup} =
        Postgrex.start_link(Keyword.put(Bier.ConformanceServer.base_opts(), :pool_size, 1))

      drop_all(cleanup)
    end)

    port = TestPorts.free_port()
    name = :"wal_partition_#{System.unique_integer([:positive])}"

    # `@tag auth: true` boots with `db_anon_role`, so an unauthenticated
    # subscription runs as `postgrest_test_anonymous` and its column grants
    # filter the frames.
    auth =
      if context[:auth],
        do: [db_anon_role: "postgrest_test_anonymous", jwt_secret: String.duplicate("s", 32)],
        else: []

    opts =
      Bier.ConformanceServer.base_opts()
      |> Keyword.merge(
        name: name,
        pool_size: 2,
        db_schemas: [@schema],
        db_channel_enabled: false,
        events_publication: Map.fetch!(@pubs, context[:pub] || :on),
        events_heartbeat_interval: 50,
        router: [port: port, scheme: :http]
      )
      |> Keyword.merge(auth)

    start_supervised!({Bier, opts})
    TestPorts.wait_until_listening(port)
    wait_wal_streaming(db, name)

    %{db: db, port: port, name: name}
  end

  defp drop_all(db) do
    for pub <- Map.values(@pubs),
        do: Postgrex.query!(db, "DROP PUBLICATION IF EXISTS #{pub}", [])

    Postgrex.query!(db, "DROP SCHEMA IF EXISTS #{@schema} CASCADE", [])
    Postgrex.query!(db, "DROP SCHEMA IF EXISTS #{@other_schema} CASCADE", [])
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

  defp insert!(db, id, region, note),
    do: sql!(db, "INSERT INTO #{@schema}.orders VALUES (#{id}, '#{region}', '#{note}')")

  # Every `{:bier_wal_event, ...}` for `table` up to and including the first
  # one matching `stop?`, in arrival order.
  defp events_until(table, stop?, acc \\ []) do
    k = key(table)

    receive do
      {:bier_wal_event, ^k, _cursor, event} ->
        acc = [event | acc]
        if stop?.(event), do: Enum.reverse(acc), else: events_until(table, stop?, acc)
    after
      5_000 -> flunk("no matching event for #{table}; got #{inspect(Enum.reverse(acc))}")
    end
  end

  # `{old_kind, old}` per row id of the UPDATEs on `orders` up to the one
  # for row `last_id`.
  defp updates_until(last_id) do
    id = Integer.to_string(last_id)

    events_until("orders", fn e -> e.kind == :update and e.row["id"] == id end)
    |> Enum.filter(&(&1.kind == :update))
    |> Map.new(&{&1.row["id"], {&1.old_kind, &1.old}})
  end

  defp consumer_pid(name) do
    [{pid, _}] = Registry.lookup(Bier.Registry, {name, Bier.Wal.Consumer})
    pid
  end

  describe "publish_via_partition_root = true" do
    test "every level's changes reach root subscribers named after the root",
         %{db: db, name: name} do
      register!(name, "orders")

      # The deepest leaf (orders_eu_low, two levels down) and a shallow one.
      insert!(db, 1, "eu", "deep")
      insert!(db, 2, "us", "shallow")
      sql!(db, "UPDATE #{@schema}.orders SET note = 'b' WHERE id = 1")
      sql!(db, "DELETE FROM #{@schema}.orders WHERE id = 2")
      sql!(db, "TRUNCATE #{@schema}.orders")

      for kind <- [:insert, :insert, :update, :delete, :truncate] do
        assert_receive {:bier_wal_event, {@schema, "orders"}, _, %{kind: ^kind} = event}, 5_000
        assert event.relation.table == "orders"
      end

      refute_received {:bier_wal_event, _, _, _}
    end

    # PostgreSQL decomposes an UPDATE that moves a row to another partition
    # into a DELETE from the old leaf and an INSERT into the new one; via the
    # root, both are reported as the root. There is no UPDATE frame to diff.
    test "a cross-partition UPDATE arrives as DELETE then INSERT of the root",
         %{db: db, name: name} do
      register!(name, "orders")
      insert!(db, 5, "eu", "moving")
      assert_receive {:bier_wal_event, {@schema, "orders"}, _, %{kind: :insert}}, 5_000

      sql!(db, "UPDATE #{@schema}.orders SET id = 1500 WHERE id = 5")

      assert [delete, insert] =
               events_until("orders", &(&1.kind == :insert))
               |> Enum.map(&Map.take(&1, [:kind, :old, :row]))

      assert delete == %{kind: :delete, old: %{"id" => "5", "region" => "eu"}}

      assert insert == %{
               kind: :insert,
               row: %{"id" => "1500", "region" => "eu", "note" => "moving"}
             }
    end

    # Two settings meet in `old`: the PARTITION's REPLICA IDENTITY decides
    # what PostgreSQL logs, and the ROOT's decides how pgoutput labels it
    # (`O` full / `K` key, from the relation it reports the change as). Bier
    # keeps a `K` image to the root's identity columns, so the two must
    # agree to see a full pre-image.
    test "old follows the partition's logging and the root's REPLICA IDENTITY label",
         %{db: db, name: name} do
      register!(name, "orders")
      insert!(db, 7, "eu", "eu-before")
      insert!(db, 8, "us", "us-before")
      sql!(db, "UPDATE #{@schema}.orders SET note = 'after' WHERE id IN (7, 8)")

      updates = updates_until(8)

      # orders_eu_low: DEFAULT identity, and the key did not change, so
      # nothing was logged at all — no `old`, no `old_kind`.
      assert updates["7"] == {nil, nil}
      # orders_us is FULL, but the root is DEFAULT: labelled a key image and
      # kept to the root's key columns.
      assert updates["8"] == {:key, %{"id" => "8", "region" => "us"}}

      sql!(db, "ALTER TABLE #{@schema}.orders REPLICA IDENTITY FULL")
      sql!(db, "UPDATE #{@schema}.orders SET note = 'again' WHERE id IN (7, 8)")

      updates = updates_until(8)
      assert updates["8"] == {:full, %{"id" => "8", "region" => "us", "note" => "after"}}
      assert updates["7"] == {nil, nil}

      # The documented hazard of a mismatch: orders_eu_low (DEFAULT) logs
      # only its key when the key changes, but the FULL root labels that a
      # full image — so the never-logged `note` reads as NULL. The guide
      # tells operators to give the root and every partition the same
      # REPLICA IDENTITY.
      sql!(db, "UPDATE #{@schema}.orders SET id = 9 WHERE id = 7")

      assert updates_until(9)["9"] ==
               {:full, %{"id" => "7", "region" => "eu", "note" => nil}}
    end

    # PostgreSQL never publishes a TRUNCATE that names only a partition when
    # publishing via the root (pgoutput skips it). This pins that upstream
    # behavior, because the guide documents it as a gap: if it ever changes,
    # the guide must too.
    test "a root TRUNCATE is published; a single partition's is not",
         %{db: db, name: name} do
      register!(name, "orders")

      sql!(db, "TRUNCATE #{@schema}.orders_us")
      insert!(db, 9, "eu", "sentinel")
      sql!(db, "TRUNCATE #{@schema}.orders")

      assert [%{kind: :insert}, %{kind: :truncate} = truncate] =
               events_until("orders", &(&1.kind == :truncate))

      assert truncate.relation.table == "orders"
    end

    # The leak #140's first design had: a row written to a standalone table
    # BEFORE it was attached must never reach the root's subscribers, even
    # when bier decodes it after the ATTACH. PostgreSQL names the relation as
    # of each change, and bier must not second-guess it from the current
    # catalog. Suspending the consumer forces bier to process the pre-ATTACH
    # rows only after the ATTACH has committed.
    test "a row written before ATTACH never reaches root subscribers", %{db: db, name: name} do
      register!(name, "orders")
      pid = consumer_pid(name)
      :ok = :sys.suspend(pid)

      try do
        sql!(db, "INSERT INTO #{@schema}.staging VALUES (100, 'staging', 'staging-secret')")
        sql!(db, "DELETE FROM #{@schema}.staging WHERE id = 100")

        sql!(
          db,
          "ALTER TABLE #{@schema}.orders ATTACH PARTITION #{@schema}.staging " <>
            "FOR VALUES IN ('staging')"
        )

        insert!(db, 101, "staging", "post-attach")
      after
        :sys.resume(pid)
      end

      events = events_until("orders", &(&1.kind == :insert and &1.row["note"] == "post-attach"))
      assert [%{kind: :insert, relation: %{table: "orders"}}] = events
      refute inspect(events) =~ "staging-secret"
    end

    test "a change made before DETACH still reaches root subscribers", %{db: db, name: name} do
      register!(name, "orders")
      pid = consumer_pid(name)
      :ok = :sys.suspend(pid)

      try do
        insert!(db, 200, "us", "pre-detach")
        sql!(db, "ALTER TABLE #{@schema}.orders DETACH PARTITION #{@schema}.orders_us")
        # No longer a partition, and not published on its own: never streamed.
        sql!(db, "INSERT INTO #{@schema}.orders_us (id, region, note) VALUES (201, 'us', 'x')")
        insert!(db, 202, "eu", "sentinel")
      after
        :sys.resume(pid)
      end

      events = events_until("orders", &(&1.row["note"] == "sentinel"))
      assert Enum.map(events, & &1.row["note"]) == ["pre-detach", "sentinel"]
    end
  end

  describe "subscribing over HTTP" do
    test "a root subscription streams leaf changes as the root", %{db: db, port: port} do
      sock = SSETestClient.connect_sse(port, "/events?table=orders")
      SSETestClient.recv_until(sock, ": connected")

      insert!(db, 1, "eu", "hi")

      frame = SSETestClient.recv_until(sock, "data: {")
      assert frame =~ "event: orders\n"
      data = decode_frame(frame)
      assert data["type"] == "INSERT"
      assert {data["schema"], data["table"]} == key("orders")
      assert data["row"] == %{"id" => 1, "region" => "eu", "note" => "hi"}
    end

    @tag auth: true
    test "the root's column grants filter leaf-originated rows", %{db: db, port: port} do
      sql!(db, "GRANT USAGE ON SCHEMA #{@schema} TO postgrest_test_anonymous")
      sql!(db, "GRANT SELECT (id, region) ON #{@schema}.orders TO postgrest_test_anonymous")

      sock = SSETestClient.connect_sse(port, "/events?table=orders")
      SSETestClient.recv_until(sock, ": connected")

      insert!(db, 3, "us", "secret")

      frame = SSETestClient.recv_until(sock, "data: {")
      assert decode_frame(frame)["row"] == %{"id" => 3, "region" => "us"}
      refute frame =~ "secret"
    end

    test "Last-Event-ID resumes a root subscription from the root's history",
         %{db: db, port: port} do
      sock = SSETestClient.connect_sse(port, "/events?table=orders")
      SSETestClient.recv_until(sock, ": connected")
      insert!(db, 10, "eu", "seen")
      frame = SSETestClient.recv_until(sock, "data: {")
      [_, id] = Regex.run(~r/id: ([^\n]+)\n/, frame)
      :gen_tcp.close(sock)

      # Missed while disconnected, from two different leaves.
      insert!(db, 11, "us", "missed-us")
      insert!(db, 12, "eu", "missed-eu")

      sock2 = SSETestClient.connect_sse(port, "/events?table=orders&last_event_id=#{id}")
      replay = SSETestClient.recv_until(sock2, ~s("note":"missed-eu"))

      frames =
        ~r/event: ([^\n]+)\nid: ([^\n]+)\ndata: (\{.*?\})\n/
        |> Regex.scan(replay)
        |> Enum.map(fn [_, name, _id, data] -> {name, JSON.decode!(data)["row"]["note"]} end)

      assert frames == [{"orders", "missed-us"}, {"orders", "missed-eu"}]
    end

    test "leaves and non-topmost partitioned tables get the uniform 404", %{port: port} do
      missing = refusal_body(port, "missing")

      for table <- ["orders_eu", "orders_eu_low", "orders_us"],
          do: assert(refusal_body(port, table) == missing, table)
    end

    @tag pub: :off
    test "without publish_via_partition_root the root is refused and leaves stream as " <>
           "themselves",
         %{db: db, port: port} do
      assert refusal_body(port, "orders") == refusal_body(port, "missing")
      assert refusal_body(port, "orders_eu") == refusal_body(port, "missing")

      sock = SSETestClient.connect_sse(port, "/events?table=orders_eu_low")
      SSETestClient.recv_until(sock, ": connected")
      insert!(db, 3, "eu", "leaf")

      frame = SSETestClient.recv_until(sock, "data: {")
      assert frame =~ "event: orders_eu_low\n"
      assert decode_frame(frame)["table"] == "orders_eu_low"
    end

    # Only the intermediate level is published: PostgreSQL names IT, so it
    # is the subscribable table, and neither its root nor its leaves are.
    @tag pub: :mid
    test "an intermediate published on its own is subscribable as itself",
         %{db: db, port: port} do
      missing = refusal_body(port, "missing")

      for table <- ["orders", "orders_eu_low"],
          do: assert(refusal_body(port, table) == missing, table)

      sock = SSETestClient.connect_sse(port, "/events?table=orders_eu")
      SSETestClient.recv_until(sock, ": connected")
      insert!(db, 1500, "eu", "high")

      frame = SSETestClient.recv_until(sock, "data: {")
      assert frame =~ "event: orders_eu\n"
      assert decode_frame(frame)["row"]["note"] == "high"
    end
  end

  describe "authorization of a partitioned root" do
    test "privileges are the root's, not a partition's", %{db: db} do
      sql!(db, "GRANT USAGE ON SCHEMA #{@schema} TO postgrest_test_anonymous")
      sql!(db, "GRANT USAGE ON SCHEMA #{@schema} TO postgrest_test_default_role")
      sql!(db, "GRANT SELECT (id, note) ON #{@schema}.orders TO postgrest_test_anonymous")
      sql!(db, "GRANT SELECT ON ALL TABLES IN SCHEMA #{@schema} TO postgrest_test_default_role")
      sql!(db, "REVOKE SELECT ON #{@schema}.orders FROM postgrest_test_default_role")

      assert {:ok, %{{@schema, "orders"} => cols}} =
               Authorize.check(db, "postgrest_test_anonymous", @pubs.on, [key("orders")])

      assert cols == MapSet.new(["id", "note"])

      # SELECT on every partition but not the root: refused — a query
      # through the root would be refused too.
      assert {:error, {:events_unknown_table, "#{@schema}.orders"}} ==
               Authorize.check(db, "postgrest_test_default_role", @pubs.on, [key("orders")])
    end

    test "RLS is the root's: on the root it refuses, on a leaf alone it does not",
         %{db: db} do
      sql!(db, "ALTER TABLE #{@schema}.orders_us ENABLE ROW LEVEL SECURITY")
      assert {:ok, _} = Authorize.check(db, nil, @pubs.on, [key("orders")])

      sql!(db, "ALTER TABLE #{@schema}.orders ENABLE ROW LEVEL SECURITY")

      assert {:error, {:events_unknown_table, "#{@schema}.orders"}} ==
               Authorize.check(db, nil, @pubs.on, [key("orders")])
    end

    # `TABLES IN SCHEMA` publishes the tables IN that schema: a root living in
    # another schema is not published, so PostgreSQL names the leaves in the
    # published schema even via the root (verified against PG 15-18).
    # Authorization must match what pgoutput names.
    test "a schema publication admits the leaves in it, not a root outside it", %{db: db} do
      pub = "wal_part_schema"

      on_exit(fn ->
        {:ok, cleanup} =
          Postgrex.start_link(Keyword.put(Bier.ConformanceServer.base_opts(), :pool_size, 1))

        Postgrex.query!(cleanup, "DROP PUBLICATION IF EXISTS #{pub}", [])
      end)

      sql!(db, "CREATE SCHEMA #{@other_schema}")

      sql!(
        db,
        "CREATE TABLE #{@other_schema}.events (id int, at date) PARTITION BY RANGE (at)"
      )

      sql!(
        db,
        "CREATE TABLE #{@schema}.events_2026 PARTITION OF #{@other_schema}.events " <>
          "FOR VALUES FROM ('2026-01-01') TO ('2027-01-01')"
      )

      sql!(
        db,
        "CREATE PUBLICATION #{pub} FOR TABLES IN SCHEMA #{@schema} " <>
          "WITH (publish_via_partition_root = true)"
      )

      assert {:ok, _} = Authorize.check(db, nil, pub, [key("events_2026")])

      assert {:error, _} = Authorize.check(db, nil, pub, [{@other_schema, "events"}])
      # The partitioned `orders` lives IN the published schema: it is the
      # topmost published ancestor of its leaves, so it is admitted and they
      # are not.
      assert {:ok, _} = Authorize.check(db, nil, pub, [key("orders")])
      assert {:error, _} = Authorize.check(db, nil, pub, [key("orders_us")])
    end
  end

  describe "boot warning" do
    # The single-partition TRUNCATE gap cannot be detected per event, so it
    # is named once, when the feed starts, for exactly the configuration it
    # applies to.
    test "names the single-partition TRUNCATE gap for a via-root publication of a " <>
           "partitioned table" do
      assert boot_log(@pubs.on) =~ "TRUNCATE of a single partition"
      refute boot_log(@pubs.off) =~ "TRUNCATE of a single partition"
    end
  end

  describe "REPLICA IDENTITY mismatch warning" do
    # `old`/`old_kind` are labelled and shaped from the ROOT's identity while
    # each partition logs by its own, so a mismatch produces wrong `old`
    # data no event can flag. Named once at boot instead.
    test "names partitions whose REPLICA IDENTITY differs from their root's", %{db: db} do
      sql!(db, "ALTER TABLE #{@schema}.orders REPLICA IDENTITY FULL")

      log = boot_log(@pubs.on)
      assert log =~ "REPLICA IDENTITY differs"
      assert log =~ "#{@schema}.orders (FULL)"
      assert log =~ "#{@schema}.orders_eu_low (DEFAULT)"
      assert log =~ "#{@schema}.orders_eu_high (DEFAULT)"
      # orders_us is FULL like its root: not named.
      refute log =~ "orders_us ("
    end

    test "is silent when the whole tree agrees, or nothing is published via the root",
         %{db: db} do
      sql!(db, "ALTER TABLE #{@schema}.orders_us REPLICA IDENTITY DEFAULT")
      refute boot_log(@pubs.on) =~ "REPLICA IDENTITY differs"

      sql!(db, "ALTER TABLE #{@schema}.orders REPLICA IDENTITY FULL")
      refute boot_log(@pubs.off) =~ "REPLICA IDENTITY differs"
    end

    # USING INDEX matches only when the partition's identity index is a
    # partition of the root's own identity index.
    test "treats a USING INDEX on an unrelated index as a mismatch", %{db: db} do
      sql!(db, "ALTER TABLE #{@schema}.orders_us REPLICA IDENTITY DEFAULT")
      sql!(db, "CREATE UNIQUE INDEX orders_ident ON #{@schema}.orders (id, region)")
      sql!(db, "ALTER TABLE #{@schema}.orders REPLICA IDENTITY USING INDEX orders_ident")

      # Each partition's piece of the root's identity index: a match.
      for {leaf, idx} <- [
            {"orders_eu_low", "orders_eu_low_id_region_idx"},
            {"orders_eu_high", "orders_eu_high_id_region_idx"},
            {"orders_us", "orders_us_id_region_idx"}
          ],
          do: sql!(db, "ALTER TABLE #{@schema}.#{leaf} REPLICA IDENTITY USING INDEX #{idx}")

      refute boot_log(@pubs.on) =~ "REPLICA IDENTITY differs"

      # A standalone index on one partition: not the root's identity.
      sql!(db, "CREATE UNIQUE INDEX orders_us_other ON #{@schema}.orders_us (region, id)")
      sql!(db, "ALTER TABLE #{@schema}.orders_us REPLICA IDENTITY USING INDEX orders_us_other")

      log = boot_log(@pubs.on)
      assert log =~ "REPLICA IDENTITY differs"
      assert log =~ "#{@schema}.orders_us (USING INDEX #{@schema}.orders_us_other)"
      refute log =~ "orders_eu_low ("
    end
  end

  defp boot_log(publication) do
    name = :"wal_partition_boot_#{System.unique_integer([:positive])}"

    capture_log(fn ->
      opts =
        Bier.ConformanceServer.base_opts()
        |> Keyword.merge(
          name: name,
          pool_size: 1,
          db_schemas: [@schema],
          db_channel_enabled: false,
          events_publication: publication,
          router: [port: TestPorts.free_port(), scheme: :http]
        )

      start_supervised!({Bier, opts}, id: name)
      stop_supervised!(name)
    end)
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

    assert resp.status == 404, "#{table}: #{resp.status}"
    assert resp.headers["proxy-status"] == ["Bier; error=BIER003"]
    String.replace(resp.body, "#{@schema}.#{table}", "T")
  end

  # The `data:` payload of the LAST frame in `raw`, decoded (same shape as
  # `Bier.Wal.EventsHttpTest.decode_frame/1`).
  defp decode_frame(raw),
    do: raw |> String.split("data: ") |> List.last() |> String.trim() |> JSON.decode!()
end
