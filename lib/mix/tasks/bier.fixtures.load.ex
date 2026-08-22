defmodule Mix.Tasks.Bier.Fixtures.Load do
  @shortdoc "Drops/creates the test DB and loads the postgrest-conformance fixture chain"
  @moduledoc """
  Loads the conformance fixture database from the `spec/` submodule's numbered
  chain (see spec/fixtures/README.md). Idempotent. Connection parameters come
  from the standard `PG*` environment variables.
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
    run_psql!(psql, cfg, "postgres", ["-f", roles])
    run_psql!(psql, cfg, "postgres", ["-c", ~s(DROP DATABASE IF EXISTS "#{cfg[:database]}";)])

    run_psql!(psql, cfg, "postgres", [
      "-c",
      ~s(CREATE DATABASE "#{cfg[:database]}" TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C';)
    ])

    Enum.each(rest, &run_psql!(psql, cfg, cfg[:database], ["-f", &1]))
    Mix.shell().info("Done.")
  end

  # --- helpers -------------------------------------------------------------

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
