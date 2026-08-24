defmodule Bier.Wal.AuthorizeTest do
  # Creates a scratch schema/publication: run serially, same as Task 5.
  use ExUnit.Case, async: false

  alias Bier.Wal.Authorize

  @schema "wal_authz_test"
  @pub "wal_authz_pub"

  setup do
    # A dedicated connection just for setup/teardown DDL: one connection is
    # plenty (see Bier.Wal.ConsumerTest's own note on the shared connection
    # budget across the suite).
    {:ok, db} =
      Postgrex.start_link(Keyword.put(Bier.ConformanceServer.base_opts(), :pool_size, 1))

    Postgrex.query!(db, "DROP SCHEMA IF EXISTS #{@schema} CASCADE", [])
    Postgrex.query!(db, "CREATE SCHEMA #{@schema}", [])
    Postgrex.query!(db, "CREATE TABLE #{@schema}.orders (id int, secret text)", [])
    Postgrex.query!(db, "CREATE TABLE #{@schema}.hidden (id int)", [])
    Postgrex.query!(db, "CREATE TABLE #{@schema}.locked (id int)", [])
    Postgrex.query!(db, "ALTER TABLE #{@schema}.locked ENABLE ROW LEVEL SECURITY", [])
    # A partitioned parent exercises the `relkind = 'r'` filter specifically:
    # unlike a view (which Postgres refuses to add to a publication at all,
    # so it can only ever fail the "not published" gate), a partitioned
    # parent CAN be published — and subscribing to it would then deliver
    # nothing, because WAL routes its changes through the child partitions.
    # The view is kept unpublished, covering the other path to the same
    # uniform refusal.
    Postgrex.query!(
      db,
      "CREATE VIEW #{@schema}.orders_view AS SELECT * FROM #{@schema}.orders",
      []
    )

    Postgrex.query!(
      db,
      "CREATE TABLE #{@schema}.parted (id int, at date) PARTITION BY RANGE (at)",
      []
    )

    Postgrex.query!(
      db,
      "CREATE TABLE #{@schema}.parted_2026 PARTITION OF #{@schema}.parted " <>
        "FOR VALUES FROM ('2026-01-01') TO ('2027-01-01')",
      []
    )

    Postgrex.query!(db, "DROP PUBLICATION IF EXISTS #{@pub}", [])

    Postgrex.query!(
      db,
      "CREATE PUBLICATION #{@pub} FOR TABLE #{@schema}.orders, #{@schema}.locked, " <>
        "#{@schema}.parted",
      []
    )

    # postgrest_test_anonymous exists from the fixture chain; grant narrowly.
    Postgrex.query!(db, "GRANT USAGE ON SCHEMA #{@schema} TO postgrest_test_anonymous", [])

    Postgrex.query!(
      db,
      "GRANT SELECT (id) ON #{@schema}.orders TO postgrest_test_anonymous",
      []
    )

    # Granted too, so the ONLY gate that can refuse this role is
    # assumability — see the role-assumability test below. Both grants die
    # with the scratch schema.
    Postgrex.query!(
      db,
      "GRANT SELECT (id) ON #{@schema}.orders TO postgrest_test_author",
      []
    )

    on_exit(fn ->
      {:ok, cleanup} =
        Postgrex.start_link(Keyword.put(Bier.ConformanceServer.base_opts(), :pool_size, 1))

      Postgrex.query!(cleanup, "DROP PUBLICATION IF EXISTS #{@pub}", [])
      Postgrex.query!(cleanup, "DROP SCHEMA IF EXISTS #{@schema} CASCADE", [])
    end)

    %{db: db}
  end

  test "superuser (nil role) sees all columns of a published table", %{db: db} do
    assert {:ok, cols} = Authorize.check(db, nil, @pub, [{@schema, "orders"}])
    assert cols[{@schema, "orders"}] == MapSet.new(["id", "secret"])
  end

  test "restricted role gets only its SELECT-able columns", %{db: db} do
    assert {:ok, cols} =
             Authorize.check(db, "postgrest_test_anonymous", @pub, [{@schema, "orders"}])

    assert cols[{@schema, "orders"}] == MapSet.new(["id"])
  end

  test "not-in-publication, RLS, no-privilege, and nonexistent all fail identically", %{db: db} do
    # postgrest_test_default_role exists in the fixture chain (see
    # spec/fixtures/01_roles.sql) and is never granted anything on the
    # scratch schema above, so it has zero SELECT-able columns here.
    for {table, role} <- [
          {"hidden", nil},
          {"locked", nil},
          {"orders", "postgrest_test_default_role"},
          {"nope", nil},
          # A view (unpublishable, so it fails as unpublished) and a
          # PUBLISHED partitioned parent, which passes every other gate and
          # is refused purely by `relkind = 'r'` — without that filter it
          # would subscribe successfully and then deliver nothing forever.
          {"orders_view", nil},
          {"parted", nil}
        ] do
      key = {@schema, table}
      expected = {:error, {:events_unknown_table, "#{@schema}.#{table}"}}

      assert expected == Authorize.check(db, role, @pub, [key]),
             "expected uniform refusal for #{table} as #{inspect(role)}"
    end
  end

  test "a role the authenticator cannot assume is refused", %{db: db} do
    # `has_column_privilege/3` alone answers for ANY role in pg_roles, so a
    # JWT naming a role the authenticator may not assume would be accepted
    # here while `GET /orders` refuses it with 42501 — the REST path applies
    # the role with `set_config('role', ...)`, which enforces membership.
    # `pg_has_role(..., 'MEMBER')` is what reproduces that check.
    #
    # `postgrest_test_author` HAS the SELECT grant (see setup), so nothing
    # but assumability can decide these two cases apart.
    {:ok, restricted} =
      Postgrex.start_link(Keyword.put(Bier.ConformanceServer.base_opts(), :pool_size, 1))

    # A dedicated connection switched to a role that is not a member of
    # `postgrest_test_author`. The suite's own connection is a superuser,
    # which may assume anything — so without this switch the gate could
    # never fire and the assertion would be vacuous.
    Postgrex.query!(restricted, "SET ROLE postgrest_test_anonymous", [])

    assert {:error, {:events_unknown_table, "#{@schema}.orders"}} ==
             Authorize.check(restricted, "postgrest_test_author", @pub, [{@schema, "orders"}])

    # And the gate must not over-refuse: a connection that CAN assume the
    # role still gets its columns.
    assert {:ok, cols} = Authorize.check(db, "postgrest_test_author", @pub, [{@schema, "orders"}])
    assert cols[{@schema, "orders"}] == MapSet.new(["id"])
  end

  test "columns/4 answers per table so one query can serve many subscribers", %{db: db} do
    # The shape `Bier.Wal.notify_recheck/1` relies on: a table that fails any
    # gate is simply absent, rather than collapsing the whole result into one
    # error, so each subscriber's verdict can be derived from a shared query.
    authorized =
      Authorize.columns(db, nil, @pub, [
        {@schema, "orders"},
        {@schema, "locked"},
        {@schema, "nope"}
      ])

    assert Map.keys(authorized) == [{@schema, "orders"}]
    assert authorized[{@schema, "orders"}] == MapSet.new(["id", "secret"])
  end
end
