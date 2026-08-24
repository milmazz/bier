defmodule Bier.Wal.ConsumerTest do
  @moduledoc """
  Integration tests against a real logical-replication stream: boots a
  dedicated Bier instance with `events_publication` set, mutates a plain
  table over a raw `Postgrex` connection, and asserts the consumer lands
  commits in `Bier.Wal.Buffer` and broadcasts them to live subscribers.
  """

  # Replication slots are DB-global state: run serially.
  use ExUnit.Case, async: false

  alias Bier.SSETestClient
  alias Bier.Wal.Buffer

  @moduletag :integration

  @schema "wal_consumer_test"

  setup do
    {:ok, db} = Postgrex.start_link(Bier.ConformanceServer.base_opts())

    Postgrex.query!(db, "DROP SCHEMA IF EXISTS #{@schema} CASCADE", [])
    Postgrex.query!(db, "CREATE SCHEMA #{@schema}", [])
    Postgrex.query!(db, "CREATE TABLE #{@schema}.orders (id serial PRIMARY KEY, note text)", [])
    Postgrex.query!(db, "DROP PUBLICATION IF EXISTS wal_consumer_pub", [])
    Postgrex.query!(db, "CREATE PUBLICATION wal_consumer_pub FOR TABLE #{@schema}.orders", [])

    on_exit(fn ->
      {:ok, cleanup} = Postgrex.start_link(Bier.ConformanceServer.base_opts())
      Postgrex.query!(cleanup, "DROP PUBLICATION IF EXISTS wal_consumer_pub", [])
      Postgrex.query!(cleanup, "DROP SCHEMA IF EXISTS #{@schema} CASCADE", [])
    end)

    name = :"wal_consumer_#{System.unique_integer([:positive])}"

    opts =
      Bier.ConformanceServer.base_opts()
      |> Keyword.merge(
        name: name,
        # A small pool: the shared ConformanceServer instances (bulk, auth,
        # and ~30 per-case variants — see Bier.ConformanceServer's own
        # comment on this) already run near Postgres' default
        # max_connections=100, and this test's own extra replication
        # connection adds to that budget.
        pool_size: 2,
        db_schemas: [@schema],
        events_publication: "wal_consumer_pub",
        router: [port: Bier.TestPorts.free_port(), scheme: :http]
      )

    start_supervised!({Bier, opts})
    SSETestClient.wait_until(fn -> wal_streaming?(db) end)
    %{db: db, name: name}
  end

  defp wal_streaming?(db) do
    %{rows: rows} =
      Postgrex.query!(db, "SELECT 1 FROM pg_stat_replication WHERE state = 'streaming'", [])

    rows != []
  end

  test "commits land in the buffer with sequential cursors", %{db: db, name: name} do
    gen = Buffer.generation(name)
    Postgrex.query!(db, "INSERT INTO #{@schema}.orders (note) VALUES ('a'), ('b')", [])

    SSETestClient.wait_until(fn ->
      match?({:ok, [_, _]}, Buffer.replay_after(name, [{@schema, "orders"}], {{0, 0}, 0}, gen))
    end)

    {:ok, [{c1, _, e1}, {c2, _, e2}]} =
      Buffer.replay_after(name, [{@schema, "orders"}], {{0, 0}, 0}, gen)

    assert e1.kind == :insert and e1.row["note"] == "a"
    assert e2.row["note"] == "b"
    # Same commit, sequential seq.
    assert {elem(c1, 0), 0} == c1 and {elem(c1, 0), 1} == c2
    assert %DateTime{} = e1.commit_at
  end

  test "subscribed processes receive per-event broadcasts", %{db: db, name: name} do
    :ok = Bier.Events.Registry.register_table(name, {@schema, "orders"})
    Postgrex.query!(db, "INSERT INTO #{@schema}.orders (note) VALUES ('live')", [])

    assert_receive {:bier_wal_event, {@schema, "orders"}, _cursor, %{kind: :insert} = event},
                   5_000

    assert event.row["note"] == "live"
  end

  test "consumer restart bumps the generation and broadcasts reset", %{name: name} do
    :ok = Bier.Events.Registry.register_table(name, {@schema, "orders"})
    gen = Buffer.generation(name)

    [{pid, _}] = Registry.lookup(Bier.Registry, {name, Bier.Wal.Consumer})
    Process.exit(pid, :kill)

    assert_receive {:bier_wal_reset, "stream_restarted"}, 5_000
    SSETestClient.wait_until(fn -> Buffer.generation(name) > gen end)
  end

  # Retrying past sustained pool exhaustion (see below) needs more than
  # ExUnit's default 60s test timeout.
  @tag timeout: 120_000
  test "boot fails fast when the publication does not exist" do
    opts =
      Bier.ConformanceServer.base_opts()
      |> Keyword.merge(
        name: :"wal_badpub_#{System.unique_integer([:positive])}",
        pool_size: 2,
        # This test only needs the pool connection introspection runs on;
        # skip the extra schema-cache-reload LISTEN connection.
        db_channel_enabled: false,
        events_publication: "does_not_exist",
        router: [port: Bier.TestPorts.free_port(), scheme: :http]
      )

    Process.flag(:trap_exit, true)
    assert {:error, reason} = start_link_past_pool_exhaustion(opts)
    message = inspect(reason)
    assert message =~ "does_not_exist"
    assert message =~ "CREATE PUBLICATION"
  end

  # Under this suite's peak connection pressure (the shared ConformanceServer
  # instances plus every other async test file's own instance, all competing
  # for Postgres' default max_connections=100), boot can occasionally fail on
  # an unrelated pool/queue-timeout error instead of the validation failure
  # this test exercises, and the underlying DBConnection queue timeout itself
  # already runs several seconds per attempt — so this retries with a
  # generous budget. Retry past that specific noise only — a real validation
  # failure (or any other error) is returned immediately.
  defp start_link_past_pool_exhaustion(opts, retries \\ 12) do
    case Bier.start_link(opts) do
      {:error, reason} = error ->
        if retries > 0 and inspect(reason) =~ ~r/too_many_connections|queue_timeout/ do
          Process.sleep(1_000)
          start_link_past_pool_exhaustion(opts, retries - 1)
        else
          error
        end

      other ->
        other
    end
  end
end
