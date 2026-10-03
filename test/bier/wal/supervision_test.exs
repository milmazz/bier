defmodule Bier.Wal.SupervisionTest do
  @moduledoc """
  How the WAL pair (`Bier.Wal.Buffer` + `Bier.Wal.Consumer`) fails, against a
  real logical-replication stream (#150).

  The feed is strictly additive, so its failures must stay its own: consumer
  crashes spend the WAL sub-supervisor's restart budget, never the instance
  supervisor's — three of them within five seconds used to take the whole
  instance down, HTTP server included. And the pair restarts as a pair: a
  Buffer crash restarts the Consumer too, so the fresh Buffer's generation
  is bumped and every subscriber is told the stream restarted, instead of the
  Consumer discovering the loss on its next `append`.
  """

  # Replication slots are DB-global state: run serially.
  use ExUnit.Case, async: false

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

    # The Consumer is restarted with it, not left to find out on its next
    # `append` that the history it was writing into is gone ...
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
