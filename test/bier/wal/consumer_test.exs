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

  setup context do
    # A dedicated connection just for setup/teardown DDL: one connection is
    # plenty (default pool_size: 10 would needlessly add to the suite's
    # shared connection budget — see start_link_past_pool_exhaustion/2).
    {:ok, db} =
      Postgrex.start_link(Keyword.put(Bier.ConformanceServer.base_opts(), :pool_size, 1))

    Postgrex.query!(db, "DROP SCHEMA IF EXISTS #{@schema} CASCADE", [])
    Postgrex.query!(db, "CREATE SCHEMA #{@schema}", [])
    Postgrex.query!(db, "CREATE TABLE #{@schema}.orders (id serial PRIMARY KEY, note text)", [])
    Postgrex.query!(db, "DROP PUBLICATION IF EXISTS wal_consumer_pub", [])
    Postgrex.query!(db, "CREATE PUBLICATION wal_consumer_pub FOR TABLE #{@schema}.orders", [])

    on_exit(fn ->
      {:ok, cleanup} =
        Postgrex.start_link(Keyword.put(Bier.ConformanceServer.base_opts(), :pool_size, 1))

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
        # Overridable per test via `@tag events_max_tx_events: N` (the
        # overflow test needs a tiny cap); defaults to the same value
        # Bier.Config itself defaults to.
        events_max_tx_events: Map.get(context, :events_max_tx_events, 10_000),
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
    table = {@schema, "orders"}
    gen = Buffer.generation(name)

    # An anchoring commit first, whose broadcast cursor is what the replay
    # below starts from. "Everything in the buffer" cannot be spelled
    # `{{0, 0}, 0}` any more: a cursor older than this generation's first
    # appended id names pre-restart history and resets by design.
    :ok = Bier.Events.Registry.register_table(name, table)
    Postgrex.query!(db, "INSERT INTO #{@schema}.orders (note) VALUES ('anchor')", [])
    assert_receive {:bier_wal_event, ^table, anchor, %{kind: :insert}}, 5_000

    Postgrex.query!(db, "INSERT INTO #{@schema}.orders (note) VALUES ('a'), ('b')", [])

    SSETestClient.wait_until(fn ->
      match?({:ok, [_, _]}, Buffer.replay_after(name, [table], anchor, gen))
    end)

    {:ok, [{c1, _, e1}, {c2, _, e2}]} = Buffer.replay_after(name, [table], anchor, gen)

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

  @tag events_max_tx_events: 1
  test "a transaction over the cap is dropped and announced, resetting replay", %{
    db: db,
    name: name
  } do
    table = {@schema, "orders"}
    :ok = Bier.Events.Registry.register_table(name, table)
    gen = Buffer.generation(name)

    # A one-row transaction fits under the cap of 1: it anchors the Buffer's
    # epoch floor and hands us a cursor that is genuinely replayable right
    # up until the overflow below, so the reset asserted at the end can only
    # come from the dropped history — not from a cursor that predated this
    # generation's first id to begin with.
    Postgrex.query!(db, "INSERT INTO #{@schema}.orders (note) VALUES ('anchor')", [])
    assert_receive {:bier_wal_event, ^table, anchor, %{kind: :insert}}, 5_000
    assert {:ok, []} = Buffer.replay_after(name, [table], anchor, gen)

    # One transaction, two insert events — one over the cap of 1.
    Postgrex.query!(db, "INSERT INTO #{@schema}.orders (note) VALUES ('x'), ('y')", [])

    assert_receive {:bier_wal_reset, "transaction_too_large"}, 5_000

    # The whole transaction (including the event that fit under the cap) was
    # discarded, and Buffer.drop marked the table as having lost history: a
    # cursor from before the overflow — same generation — now resets rather
    # than replaying anything.
    assert Buffer.replay_after(name, [table], anchor, gen) == :reset
  end

  test "boot fails fast when the publication does not exist" do
    opts =
      Bier.ConformanceServer.base_opts()
      |> Keyword.merge(
        name: :"wal_badpub_#{System.unique_integer([:positive])}",
        pool_size: 2,
        # Scope introspection to one schema, and skip the extra
        # schema-cache-reload LISTEN connection: this instance only needs
        # to reach Bier.Wal.validate! as cheaply as possible.
        db_schemas: [@schema],
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

  test "boot fails fast when the connecting role lacks REPLICATION", %{db: db} do
    role = "wal_norepl_#{System.unique_integer([:positive])}"

    Postgrex.query!(db, ~s(CREATE ROLE "#{role}" LOGIN PASSWORD '#{role}'), [])
    Postgrex.query!(db, ~s(GRANT USAGE ON SCHEMA #{@schema} TO "#{role}"), [])
    Postgrex.query!(db, ~s(GRANT SELECT ON ALL TABLES IN SCHEMA #{@schema} TO "#{role}"), [])

    on_exit(fn ->
      {:ok, cleanup} =
        Postgrex.start_link(Keyword.put(Bier.ConformanceServer.base_opts(), :pool_size, 1))

      # DROP OWNED revokes the grants above (and anything else the role
      # might hold) so the role itself can then be dropped, regardless of
      # whether this runs before or after the schema/publication cleanup
      # registered in `setup` (on_exit callbacks run LIFO).
      Postgrex.query!(cleanup, ~s(DROP OWNED BY "#{role}"), [])
      Postgrex.query!(cleanup, ~s(DROP ROLE IF EXISTS "#{role}"), [])
    end)

    opts =
      Bier.ConformanceServer.base_opts()
      |> Keyword.merge(
        name: :"wal_norepl_#{System.unique_integer([:positive])}",
        username: role,
        password: role,
        pool_size: 1,
        db_schemas: [@schema],
        db_channel_enabled: false,
        # A real, existing publication: this boot must fail on the
        # REPLICATION-attribute check specifically, not an earlier one.
        events_publication: "wal_consumer_pub",
        router: [port: Bier.TestPorts.free_port(), scheme: :http]
      )

    Process.flag(:trap_exit, true)
    assert {:error, reason} = start_link_past_pool_exhaustion(opts)
    message = inspect(reason)
    assert message =~ "REPLICATION attribute"
    assert message =~ "ALTER ROLE"
  end

  # Under this suite's peak connection pressure (the shared ConformanceServer
  # instances plus every other async test file's own instance, all competing
  # for Postgres' default max_connections=100), boot has been observed to
  # fail on an unrelated pool/queue-timeout error instead of the validation
  # failure these tests exercise. This file's own contribution to that
  # pressure is now minimal (pool_size 1 utility connections, schema-scoped
  # introspection on every instance it boots), so this retry is kept small —
  # a modest safety net against pressure from OTHER concurrently-running test
  # files, not a crutch for this file's own footprint. Retries past that
  # specific noise only — a real validation failure (or any other error) is
  # returned immediately.
  defp start_link_past_pool_exhaustion(opts, retries \\ 3) do
    case Bier.start_link(opts) do
      {:error, reason} = error ->
        if retries > 0 and inspect(reason) =~ ~r/too_many_connections|queue_timeout/ do
          Process.sleep(500)
          start_link_past_pool_exhaustion(opts, retries - 1)
        else
          error
        end

      other ->
        other
    end
  end
end
