defmodule Mix.Tasks.Bier.Fixtures.Load do
  @shortdoc "Drops/creates the test DB and loads the postgrest-conformance fixture chain"
  @moduledoc """
  Loads the conformance fixture database from the `spec/` submodule's numbered
  chain (see spec/fixtures/README.md). Idempotent. Connection parameters come
  from the standard `PG*` environment variables; `PGUSER` must be a superuser
  (the chain creates roles and the PostGIS extension).

  Destructive: it terminates every session still attached to the target
  database — including any walsender holding a logical replication slot on
  it — and then drops and recreates it. The evicted sessions are reported.
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    cfg = db_config()
    psql = psql_bin()
    files = Path.wildcard("spec/fixtures/0*_*.sql") |> Enum.sort()

    if files == [] do
      Mix.raise("spec/fixtures/ is empty — run: git submodule update --init")
    end

    [roles | rest] = files

    # The first chain file runs against the maintenance DB, before the target
    # database exists — guard the positional assumption so an upstream rename
    # fails loudly at the pin bump instead of running roles SQL against the
    # wrong database.
    if Path.basename(roles) != "01_roles.sql" do
      Mix.raise(
        "unexpected first chain file #{Path.basename(roles)} (expected 01_roles.sql) — " <>
          "the spec/ submodule's fixture chain layout changed; update this task to match"
      )
    end

    Mix.shell().info("Loading conformance chain into #{cfg[:database]}")

    # Evict whatever is still attached before the drop (#148): a plain DROP
    # fails with "database ... is being accessed by other users" while any
    # session remains — a previous run's backends that have not drained, a
    # killed run, an open psql. Nothing evicted had durable work: the database
    # is destroyed by the same statement. It also ends a CONCURRENT run's
    # sessions, so the count is reported rather than evicted silently.
    #
    # WITH (FORCE) terminates the attached sessions and drops in one statement,
    # but refuses a database with an ACTIVE logical replication slot, which a
    # Bier.Wal.Consumer walsender from a killed run can still hold.
    # Terminating those walsenders first, waiting up to 5s for each to exit,
    # releases their temporary slots. The 2-argument pg_terminate_backend
    # needs PostgreSQL 14+ (WITH (FORCE) alone is 13+); the suite requires 15+.
    db_literal = quote_literal(cfg[:database])
    db_ident = quote_ident(cfg[:database])

    attached =
      run_psql!(psql, cfg, "postgres", [
        "-X",
        "-At",
        "-c",
        "SELECT count(*) FROM pg_stat_activity " <>
          "WHERE datname = #{db_literal} AND pid <> pg_backend_pid();"
      ])
      |> String.trim()

    if attached not in ["", "0"] do
      Mix.shell().info("Evicting #{attached} session(s) still attached to #{cfg[:database]}")
    end

    run_psql!(psql, cfg, "postgres", [
      "-c",
      "SELECT pg_terminate_backend(active_pid, 5000) FROM pg_replication_slots " <>
        "WHERE database = #{db_literal} AND active_pid IS NOT NULL;"
    ])

    run_psql!(psql, cfg, "postgres", ["-c", "DROP DATABASE IF EXISTS #{db_ident} WITH (FORCE);"])

    run_psql!(psql, cfg, "postgres", ["-f", roles])

    run_psql!(psql, cfg, "postgres", [
      "-c",
      "CREATE DATABASE #{db_ident} TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C';"
    ])

    Enum.each(rest, &run_psql!(psql, cfg, cfg[:database], ["-f", &1]))
    Mix.shell().info("Done.")
  end

  # --- helpers -------------------------------------------------------------

  # The database name is operator input (PGDATABASE) spliced into SQL that
  # psql runs: quote it as a literal or an identifier, doubling the quote
  # character, so a name like `o'brien` or `a"b` stays one name.
  defp quote_literal(name), do: "'" <> String.replace(name, "'", "''") <> "'"
  defp quote_ident(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")

  # Connection params from the standard PG* environment variables (CI sets
  # PGUSER/PGPASSWORD/PGHOST/PGPORT), defaulting to a local `bier_test`. Read
  # here rather than from application env so the task does not depend on a
  # shipped `config/` (the conformance settings live in the test harness, see
  # Bier.ConformanceServer.base_opts/0).
  defp db_config do
    [
      hostname: System.get_env("PGHOST") || "localhost",
      port: String.to_integer(System.get_env("PGPORT") || "5432"),
      database: System.get_env("PGDATABASE") || "bier_test",
      username: System.get_env("PGUSER") || System.get_env("USER") || "postgres",
      password: System.get_env("PGPASSWORD")
    ]
  end

  defp base_args(cfg, database) do
    args = ["-h", to_string(cfg[:hostname]), "-p", to_string(cfg[:port]), "-d", database]
    if cfg[:username], do: args ++ ["-U", to_string(cfg[:username])], else: args
  end

  defp psql_env(cfg) do
    # Load under UTC so timestamps inserted WITHOUT an explicit offset (e.g. the
    # domain-representation seed `'2017-12-14 01:02:30'::timestamptz`) become the
    # same absolute instants as PostgREST's reference DB, which runs in UTC. The
    # request pipeline also pins the session timezone to UTC (see Bier.postgrex_opts/1).
    base = [{"PGTZ", "UTC"}]
    if cfg[:password], do: [{"PGPASSWORD", to_string(cfg[:password])} | base], else: base
  end

  defp run_psql!(psql, cfg, database, extra) do
    args = base_args(cfg, database) ++ ["-v", "ON_ERROR_STOP=1", "-q"] ++ extra
    {out, status} = System.cmd(psql, args, env: psql_env(cfg), stderr_to_stdout: true)
    if status != 0, do: Mix.raise("psql failed (exit #{status}): #{inspect(extra)}\n#{out}")
    out
  end

  defp psql_bin do
    cond do
      bin = System.find_executable("psql") -> bin
      File.exists?("/opt/homebrew/opt/libpq/bin/psql") -> "/opt/homebrew/opt/libpq/bin/psql"
      true -> Mix.raise("psql not found on PATH or at /opt/homebrew/opt/libpq/bin/psql")
    end
  end
end
