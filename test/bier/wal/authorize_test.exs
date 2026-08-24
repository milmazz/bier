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
    Postgrex.query!(db, "DROP PUBLICATION IF EXISTS #{@pub}", [])

    Postgrex.query!(
      db,
      "CREATE PUBLICATION #{@pub} FOR TABLE #{@schema}.orders, #{@schema}.locked",
      []
    )

    # postgrest_test_anonymous exists from the fixture chain; grant narrowly.
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
          {"nope", nil}
        ] do
      key = {@schema, table}
      expected = {:error, {:events_unknown_table, "#{@schema}.#{table}"}}

      assert expected == Authorize.check(db, role, @pub, [key]),
             "expected uniform refusal for #{table} as #{inspect(role)}"
    end
  end
end
