defmodule Bier.Wal.EventsHttpTest do
  @moduledoc """
  HTTP-level tests for `table=` subscriptions on the `/events` SSE endpoint:
  WAL events multiplexed with NOTIFY `channel=` subscriptions on the same
  connection, the uniform 404 for unknown/unpublished/RLS-enabled/
  unprivileged tables, per-role column filtering, and content negotiation.

  Reuses Task 5/6's scratch-schema + publication setup shape. Not async:
  real ports, a real replication slot, and DB-global publication state.
  """
  use ExUnit.Case, async: false

  alias Bier.SSETestClient
  alias Bier.TestPorts

  @moduletag :integration

  @schema "wal_http_test"
  @pub "wal_http_pub"
  @jwt_secret "reallyreallyreallyreallyverysafe"

  setup do
    # A dedicated connection just for setup/teardown DDL and mutations (see
    # Bier.Wal.ConsumerTest's own note on the shared connection budget).
    {:ok, db} =
      Postgrex.start_link(Keyword.put(Bier.ConformanceServer.base_opts(), :pool_size, 1))

    Postgrex.query!(db, "DROP SCHEMA IF EXISTS #{@schema} CASCADE", [])
    Postgrex.query!(db, "CREATE SCHEMA #{@schema}", [])
    Postgrex.query!(db, "CREATE TABLE #{@schema}.orders (id serial PRIMARY KEY, note text)", [])
    Postgrex.query!(db, "CREATE TABLE #{@schema}.hidden (id int)", [])
    Postgrex.query!(db, "CREATE TABLE #{@schema}.locked (id int)", [])
    Postgrex.query!(db, "ALTER TABLE #{@schema}.locked ENABLE ROW LEVEL SECURITY", [])
    Postgrex.query!(db, "DROP PUBLICATION IF EXISTS #{@pub}", [])

    Postgrex.query!(
      db,
      "CREATE PUBLICATION #{@pub} FOR TABLE #{@schema}.orders, #{@schema}.locked",
      []
    )

    # postgrest_test_anonymous exists from the fixture chain; grant narrowly
    # (Task 6's shape) so the column-filtering test has something to prove.
    Postgrex.query!(db, "GRANT USAGE ON SCHEMA #{@schema} TO postgrest_test_anonymous", [])

    Postgrex.query!(
      db,
      "GRANT SELECT (id) ON #{@schema}.orders TO postgrest_test_anonymous",
      []
    )

    on_exit(fn ->
      {:ok, cleanup} =
        Postgrex.start_link(Keyword.put(Bier.ConformanceServer.base_opts(), :pool_size, 1))

      Postgrex.query!(cleanup, "DROP PUBLICATION IF EXISTS #{@pub}", [])
      Postgrex.query!(cleanup, "DROP SCHEMA IF EXISTS #{@schema} CASCADE", [])
    end)

    port = TestPorts.free_port()
    name = :"wal_http_#{System.unique_integer([:positive])}"

    opts =
      Bier.ConformanceServer.base_opts()
      |> Keyword.merge(
        name: name,
        pool_size: 2,
        db_schemas: [@schema],
        db_channel_enabled: false,
        events_publication: @pub,
        events_channels: ["chat"],
        events_heartbeat_interval: 50,
        router: [port: port, scheme: :http]
      )

    start_supervised!({Bier, opts})
    TestPorts.wait_until_listening(port)
    wait_wal_streaming(db, name)

    %{db: db, port: port, name: name}
  end

  # Boots a second, auth-configured instance against the same scratch
  # schema/publication (jwt_secret + db_anon_role, as
  # `test/bier/access_log_http_test.exs` boots its auth variant).
  defp start_auth_instance! do
    port = TestPorts.free_port()
    name = :"wal_http_auth_#{System.unique_integer([:positive])}"

    opts =
      Bier.ConformanceServer.base_opts()
      |> Keyword.merge(
        name: name,
        pool_size: 2,
        db_schemas: [@schema],
        db_channel_enabled: false,
        events_publication: @pub,
        events_heartbeat_interval: 50,
        db_anon_role: "postgrest_test_anonymous",
        jwt_secret: @jwt_secret,
        router: [port: port, scheme: :http]
      )

    start_supervised!({Bier, opts})
    TestPorts.wait_until_listening(port)
    %{port: port, name: name}
  end

  # Waits for THIS instance's own replication slot specifically (not just
  # "some" consumer streaming): a test may run a second Bier instance
  # concurrently (see `start_auth_instance!/0`), and `Bier.Wal.Consumer`
  # mints its temporary slot name from `phash2(instance_name)`, so scoping by
  # that prefix disambiguates which consumer is actually ready. Firing a
  # mutation before the target instance's slot is streaming would silently
  # drop the event (fire-and-forget by design) and hang the test on
  # heartbeats until ExUnit's timeout.
  defp wait_wal_streaming(db, name) do
    prefix = "bier_#{:erlang.phash2(name)}_%"

    SSETestClient.wait_until(fn ->
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
    end)
  end

  test "insert arrives as a typed frame with an id", %{db: db, port: port} do
    sock = SSETestClient.connect_sse(port, "/events?table=orders")
    SSETestClient.recv_until(sock, ": connected")

    Postgrex.query!(db, "INSERT INTO #{@schema}.orders (note) VALUES ('hello')", [])

    frame = SSETestClient.recv_until(sock, "\n\n")
    assert frame =~ "event: orders\n"
    assert frame =~ ~r/id: [0-9A-F]+\/[0-9A-F]+\.0\n/
    data = frame |> String.split("data: ") |> List.last() |> String.trim() |> JSON.decode!()
    assert data["type"] == "INSERT"
    assert data["schema"] == @schema and data["table"] == "orders"
    assert data["row"]["note"] == "hello"
  end

  test "qualified names and channel+table multiplex on one connection", %{
    db: db,
    port: port,
    name: name
  } do
    sock = SSETestClient.connect_sse(port, "/events?channel=chat&table=#{@schema}.orders")

    SSETestClient.recv_until(sock, ": connected")

    SSETestClient.wait_until(fn -> Bier.Events.Registry.subscriber_count(name, "chat") == 1 end)
    SSETestClient.wait_until_listener_connected(name)
    SSETestClient.notify(name, "chat", ~s({"msg":"hi"}))
    chat = SSETestClient.recv_until(sock, "\n\n")
    assert chat =~ "event: chat\n"

    Postgrex.query!(db, "INSERT INTO #{@schema}.orders (note) VALUES ('mux')", [])
    wal = SSETestClient.recv_until(sock, "data: {")
    # Qualified subscription => qualified event name: db_schemas is
    # [@schema] here, so @schema IS the default and the canonical name is
    # unqualified (table_names/2 only qualifies when schema != default).
    assert wal =~ "event: orders\n" and wal =~ ~s("note":"mux")
  end

  test "unknown / unpublished / RLS tables get the uniform 404 payload", %{port: port} do
    bodies =
      for table <- ["missing", "hidden", "locked"] do
        resp = Req.get!("http://127.0.0.1:#{port}/events?table=#{table}", retry: false)
        assert resp.status == 404
        # Normalize the table name out so the envelopes must otherwise be
        # equal (String.replace/3 replaces every occurrence by default).
        resp.body |> Bier.json_library().encode!() |> String.replace(table, "T")
      end

    assert [b, b, b] = bodies, "the three refusals must be indistinguishable"
  end

  test "a role with partial column grants sees only its columns", %{db: db} do
    %{port: port, name: auth_name} = start_auth_instance!()
    wait_wal_streaming(db, auth_name)
    token = SSETestClient.sign_hs256(%{"role" => "postgrest_test_anonymous"}, @jwt_secret)

    sock = SSETestClient.connect_sse(port, "/events?table=orders&access_token=#{token}")

    SSETestClient.recv_until(sock, ": connected")
    Postgrex.query!(db, "INSERT INTO #{@schema}.orders (id, note) VALUES (7, 'secret')", [])

    frame = SSETestClient.recv_until(sock, "\n\n")
    data = frame |> String.split("data: ") |> List.last() |> String.trim() |> JSON.decode!()
    assert data["row"] == %{"id" => 7}
    refute frame =~ "secret"
  end

  test "a JWT carrying a role absent from pg_roles fails without a raw 500", %{} do
    %{port: auth_port} = start_auth_instance!()
    token = SSETestClient.sign_hs256(%{"role" => "wal_http_bogus_role_zzz"}, @jwt_secret)

    resp =
      Req.get!("http://127.0.0.1:#{auth_port}/events?table=orders&access_token=#{token}",
        retry: false
      )

    # `has_column_privilege` raises 42704 (undefined_object) for a role
    # absent from pg_roles; Bier.PgError has no specific 42704 clause so it
    # falls through to the generic SQLSTATE mapping's `true -> 400` branch.
    # Pinned here by direct observation against a live Postgres (verified in
    # the task report), not guessed.
    assert resp.status == 400
    assert resp.body["code"] == "42704"
    assert resp.body["message"] =~ "does not exist"
  end

  test "GET with an Accept that refuses text/event-stream is 406", %{port: port} do
    resp =
      Req.get!("http://127.0.0.1:#{port}/events?table=orders",
        headers: [{"accept", "application/json"}],
        retry: false
      )

    assert resp.status == 406
  end
end
