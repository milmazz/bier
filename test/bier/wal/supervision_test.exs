defmodule Bier.Wal.SupervisionTest do
  @moduledoc """
  How the WAL pair (`Bier.Wal.Buffer` + `Bier.Wal.Consumer`) fails, against a
  real logical-replication stream (#150).

  The feed is strictly additive, so its failures must stay its own: consumer
  crashes spend the WAL sub-supervisor's restart budget, never the instance
  supervisor's — a fourth within five seconds used to take the whole
  instance down, HTTP server included. The pair restarts as a pair: a Buffer
  crash restarts the Consumer too, so the fresh Buffer's generation is
  bumped and every subscriber is told the stream restarted — under the old
  layout the Consumer just kept appending to the fresh, empty Buffer and
  nobody learned history had vanished. And a feed that keeps crashing is
  given up on explicitly: announced, refused, and logged, with the API
  still serving.
  """

  # Replication slots are DB-global state: run serially.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Bier.SSETestClient
  alias Bier.Wal.Buffer

  @moduletag :integration

  @schema "wal_supervision_test"
  @table {@schema, "orders"}

  setup do
    # One connection for setup/teardown DDL — see Bier.Wal.ConsumerTest's
    # note on the suite's shared connection budget.
    {:ok, db} =
      Postgrex.start_link(Keyword.put(Bier.ConformanceServer.base_opts(), :pool_size, 1))

    Postgrex.query!(db, "DROP SCHEMA IF EXISTS #{@schema} CASCADE", [])
    Postgrex.query!(db, "CREATE SCHEMA #{@schema}", [])
    Postgrex.query!(db, "CREATE TABLE #{@schema}.orders (id serial PRIMARY KEY, note text)", [])
    Postgrex.query!(db, "DROP PUBLICATION IF EXISTS wal_supervision_pub", [])
    Postgrex.query!(db, "CREATE PUBLICATION wal_supervision_pub FOR TABLE #{@schema}.orders", [])

    on_exit(fn ->
      {:ok, cleanup} =
        Postgrex.start_link(Keyword.put(Bier.ConformanceServer.base_opts(), :pool_size, 1))

      Postgrex.query!(cleanup, "DROP PUBLICATION IF EXISTS wal_supervision_pub", [])
      Postgrex.query!(cleanup, "DROP SCHEMA IF EXISTS #{@schema} CASCADE", [])
    end)

    name = :"wal_supervision_#{System.unique_integer([:positive])}"
    port = Bier.TestPorts.free_port()

    opts =
      Bier.ConformanceServer.base_opts()
      |> Keyword.merge(
        name: name,
        pool_size: 2,
        db_schemas: [@schema],
        # No schema-cache LISTEN connection: nothing here reloads, and every
        # connection counts against the suite's shared budget.
        db_channel_enabled: false,
        events_publication: "wal_supervision_pub",
        events_channels: ["chat"],
        events_heartbeat_interval: 50,
        router: [port: port, scheme: :http]
      )

    instance = start_supervised!({Bier, opts})
    :ok = Bier.Events.Registry.register_table(name, @table, nil)
    wait_feed_live(db, name)

    %{db: db, name: name, port: port, instance: instance}
  end

  test "consumer crashes never take down the instance or its HTTP server", %{
    db: db,
    name: name,
    port: port,
    instance: instance
  } do
    http_server = whereis!(name, Bier.HttpServerStarter)

    # More crashes inside five seconds than the instance supervisor's
    # default budget (3 in 5s) tolerates. Each kill waits only for the
    # replacement to REGISTER — not for its slot — so all five land well
    # inside the window.
    for _ <- 1..5 do
      consumer = whereis!(name, Bier.Wal.Consumer)
      Process.exit(consumer, :kill)
      SSETestClient.wait_until(fn -> restarted?(name, Bier.Wal.Consumer, consumer) end)
    end

    # The same instance, the same HTTP server process, still serving.
    assert Process.alive?(instance)
    assert whereis!(name, Bier.HttpServerStarter) == http_server
    assert Req.get!("http://localhost:#{port}/", retry: false).status == 200

    # And the feed itself came back.
    wait_feed_live(db, name)
  end

  test "a Buffer crash restarts the Consumer and announces the restart", %{
    db: db,
    name: name,
    instance: instance
  } do
    buffer = whereis!(name, Buffer)
    consumer = whereis!(name, Bier.Wal.Consumer)
    flush_resets()

    Process.exit(buffer, :kill)

    # The Consumer is restarted with it, rather than carrying on appending
    # to the fresh, empty Buffer as if nothing had been lost ...
    SSETestClient.wait_until(fn -> restarted?(name, Bier.Wal.Consumer, consumer) end)
    refute Process.alive?(consumer)

    # ... so the fresh Buffer's generation is bumped once the new slot
    # exists, and live subscribers are told the stream restarted rather than
    # resuming against history that no longer exists.
    assert_receive {:bier_wal_reset, "stream_restarted"}, 5_000
    assert Buffer.generation(name) >= 1

    assert Process.alive?(instance)
    wait_feed_live(db, name)
  end

  test "a feed that keeps crashing is given up on, announced, and refused — the API stays up",
       %{name: name, port: port, instance: instance} do
    parent = self()
    handler = "wal-feed-stopped-#{inspect(name)}"

    :ok =
      :telemetry.attach(
        handler,
        [:bier, :wal, :feed, :stopped],
        fn event, measurements, metadata, _ -> send(parent, {event, measurements, metadata}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    # Live before the give-up: a table subscriber, a channel+table one, and
    # a channel-only one.
    table_sock = SSETestClient.connect_sse(port, "/events?table=orders")
    SSETestClient.recv_until(table_sock, ": connected")
    mixed_sock = SSETestClient.connect_sse(port, "/events?channel=chat&table=orders")
    SSETestClient.recv_until(mixed_sock, ": connected")
    channel_sock = SSETestClient.connect_sse(port, "/events?channel=chat")
    SSETestClient.recv_until(channel_sock, ": connected")
    SSETestClient.wait_until_listener_connected(name)

    http_server = whereis!(name, Bier.HttpServerStarter)

    # One crash past the WAL supervisor's budget (5 restarts in 30s).
    log =
      capture_log(fn ->
        for n <- 1..6 do
          consumer = whereis!(name, Bier.Wal.Consumer)
          Process.exit(consumer, :kill)

          if n < 6,
            do: SSETestClient.wait_until(fn -> restarted?(name, Bier.Wal.Consumer, consumer) end)
        end

        SSETestClient.wait_until(fn ->
          Registry.lookup(Bier.Registry, {name, Bier.Wal.Supervisor}) == []
        end)

        assert_receive {[:bier, :wal, :feed, :stopped], %{count: 1}, %{instance: ^name}}, 5_000
      end)

    # Logged at error level, naming the instance, the budget and the remedy.
    assert log =~ "[error]"
    assert log =~ inspect(name)
    assert log =~ "5 restarts in 30s"
    assert log =~ "restart"

    # Every live subscription with a table in it is told, then closed: its
    # table half can never deliver again.
    assert_closed_then_closes(table_sock, "feed_stopped")
    assert_closed_then_closes(mixed_sock, "feed_stopped")

    # New table subscriptions and resumes are refused up front, uniformly,
    # instead of streaming a 200 that can never deliver.
    for path <- ["/events?table=orders", "/events?table=orders&last_event_id=0/1.0"] do
      resp = Req.get!("http://localhost:#{port}#{path}", retry: false)
      assert resp.status == 503, "#{path}: #{inspect(resp)}"
      assert resp.body["code"] == "BIER004"
    end

    # NOTIFY channels are not the WAL feed: unaffected, old and new alike.
    fresh_channel = SSETestClient.connect_sse(port, "/events?channel=chat")
    SSETestClient.recv_until(fresh_channel, ": connected")
    SSETestClient.notify(name, "chat", ~s({"msg":"still here"}))
    assert SSETestClient.recv_until(channel_sock, "still here") =~ "event: chat\n"
    assert SSETestClient.recv_until(fresh_channel, "still here") =~ "event: chat\n"

    # And the instance never went anywhere.
    assert Process.alive?(instance)
    assert whereis!(name, Bier.HttpServerStarter) == http_server
    assert Req.get!("http://localhost:#{port}/", retry: false).status == 200
  end

  # A terminal `bier:closed` frame carrying `reason`, then the close itself
  # (Bandit's chunked terminator may share the frame's recv).
  defp assert_closed_then_closes(sock, reason) do
    raw = SSETestClient.recv_until(sock, ~r/event: bier:closed\ndata: \{[^\n]*\}\n/)
    [_, data] = Regex.run(~r/event: bier:closed\ndata: ([^\n]*)\n/, raw)
    assert JSON.decode!(data) == %{"reason" => reason}
    refute raw =~ ~r/^id:/m
    assert_socket_closes(sock)
  end

  defp assert_socket_closes(sock) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:error, :closed} ->
        :ok

      {:ok, data} ->
        refute data =~ "data: {", "stream kept delivering: #{inspect(data)}"
        assert_socket_closes(sock)

      {:error, reason} ->
        flunk("expected the socket to close, got #{inspect(reason)}")
    end
  end

  defp whereis!(name, role) do
    [{pid, _}] = Registry.lookup(Bier.Registry, {name, role})
    pid
  end

  defp restarted?(name, role, old) do
    case Registry.lookup(Bier.Registry, {name, role}) do
      [{pid, _}] -> pid != old and Process.alive?(pid)
      [] -> false
    end
  end

  defp flush_resets do
    receive do
      {:bier_wal_reset, _} -> flush_resets()
    after
      0 -> :ok
    end
  end

  # Live end to end: a row committed now reaches this (registered) test
  # process. A freshly (re)started consumer's temporary slot begins at the
  # current LSN, so a row committed before the slot exists is gone for good
  # — hence one fresh row per attempt rather than one row waited on.
  defp wait_feed_live(db, name) do
    SSETestClient.wait_until(
      fn ->
        Postgrex.query!(db, "INSERT INTO #{@schema}.orders (note) VALUES ('probe')", [])

        receive do
          {:bier_wal_event, @table, _cursor, %{kind: :insert}} -> true
        after
          200 -> false
        end
      end,
      50
    )

    # The instance is still the one under test, not a replacement booted by
    # ExUnit's test supervisor after it died.
    assert [{_, _}] = Registry.lookup(Bier.Registry, {name, Bier.HttpServerStarter})
  end
end
