defmodule Mix.Tasks.Bier.Fixtures.LoadTest do
  # Not async: it points the task at a scratch database through PGDATABASE,
  # which is process-global environment. The scratch names are fixed, so two
  # concurrent suite runs would wipe each other's copy — the same constraint
  # the shared `bier_test` database already imposes.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Bier.Fixtures.Load

  # Each test loads the whole fixture chain (PostGIS included) once more.
  @moduletag timeout: 120_000

  @default_scratch "bier_fixtures_load_test"

  setup context do
    scratch = Map.get(context, :scratch, @default_scratch)

    # Restore before anything below can raise: a leaked PGDATABASE would point
    # later sync modules that read it (the CLI db-settings tests) at the
    # scratch database.
    previous = System.get_env("PGDATABASE")
    System.put_env("PGDATABASE", scratch)

    on_exit(fn ->
      if previous,
        do: System.put_env("PGDATABASE", previous),
        else: System.delete_env("PGDATABASE")
    end)

    with_conn("postgres", fn admin ->
      Postgrex.query!(admin, "DROP DATABASE IF EXISTS #{ident(scratch)} WITH (FORCE)", [])
      Postgrex.query!(admin, "CREATE DATABASE #{ident(scratch)}", [])
    end)

    on_exit(fn ->
      with_conn("postgres", fn admin ->
        Postgrex.query!(admin, "DROP DATABASE IF EXISTS #{ident(scratch)} WITH (FORCE)", [])
      end)
    end)

    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    # The load evicts linked holder connections, and with `backoff_type:
    # :stop` their exit would otherwise take the test process down with them.
    Process.flag(:trap_exit, true)

    %{scratch: scratch}
  end

  # A session still attached to the target database — a previous run's
  # backends, a killed run, an open psql — must not make the next load fail on
  # DROP DATABASE (#148).
  test "a session still attached to the target database does not block the reload", %{
    scratch: scratch
  } do
    {:ok, holder} = Postgrex.start_link(conn_opts(scratch))
    %Postgrex.Result{} = Postgrex.query!(holder, "SELECT 1", [])

    # Raises Mix.Error ("database ... is being accessed by other users") when
    # the attached session blocks the DROP; returning at all means it did not.
    Load.run([])

    assert_received {:mix_shell, :info, ["Evicting 1 session(s) still attached to " <> _]}
    assert_chain_loaded(scratch)
  end

  # WITH (FORCE) refuses a database with an ACTIVE logical replication slot,
  # which a Bier.Wal.Consumer walsender from a killed run can hold. A temporary
  # slot created through SQL is active while its creating session lives, the
  # same state. Needs `wal_level = logical`, like the other WAL tests (CI sets
  # it).
  test "an active logical replication slot on the target database does not block the reload",
       %{scratch: scratch} do
    {:ok, holder} = Postgrex.start_link(conn_opts(scratch))

    %Postgrex.Result{} =
      Postgrex.query!(
        holder,
        "SELECT pg_create_logical_replication_slot('bier_fixtures_load_slot', 'pgoutput', true)",
        []
      )

    Load.run([])

    assert_chain_loaded(scratch)

    with_conn("postgres", fn admin ->
      assert %{rows: [[0]]} =
               Postgrex.query!(
                 admin,
                 "SELECT count(*) FROM pg_replication_slots WHERE slot_name = 'bier_fixtures_load_slot'",
                 []
               )
    end)
  end

  # The database name comes from PGDATABASE and is spliced into psql SQL both
  # as a literal and as an identifier; both quote characters must survive.
  @tag scratch: ~s(bier_fixtures_load "q'uote)
  test "a database name containing quotes is evicted, dropped and recreated", %{
    scratch: scratch
  } do
    {:ok, holder} = Postgrex.start_link(conn_opts(scratch))
    %Postgrex.Result{} = Postgrex.query!(holder, "SELECT 1", [])

    Load.run([])

    assert_received {:mix_shell, :info, ["Evicting 1 session(s) still attached to " <> _]}
    assert_chain_loaded(scratch)
  end

  defp assert_chain_loaded(scratch) do
    with_conn(scratch, fn conn ->
      assert %{rows: [[1]]} =
               Postgrex.query!(
                 conn,
                 "SELECT count(*) FROM pg_namespace WHERE nspname = 'test'",
                 []
               ),
             "the fixture chain was not loaded into #{scratch}"
    end)
  end

  defp ident(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")

  defp with_conn(database, fun) do
    {:ok, conn} = Postgrex.start_link(conn_opts(database))

    try do
      fun.(conn)
    after
      GenServer.stop(conn)
    end
  end

  defp conn_opts(database) do
    base = [
      hostname: System.get_env("PGHOST") || "localhost",
      port: String.to_integer(System.get_env("PGPORT") || "5432"),
      database: database,
      username: System.get_env("PGUSER") || System.get_env("USER") || "postgres",
      backoff_type: :stop,
      max_restarts: 0
    ]

    case System.get_env("PGPASSWORD") do
      nil -> base
      password -> Keyword.put(base, :password, password)
    end
  end
end
