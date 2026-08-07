defmodule Bier.CliCase do
  @moduledoc """
  Drives a `kind: cli` conformance case through `Bier.CLI.run/2` in-process and
  returns a normalized `%{stdout, stderr, exit}` map (iodata flattened to
  strings). Any `config.file` map is written to a temp file; `config.env` is
  merged over `base_pg_env/0` — the suite's `PG*` connection variables — the
  same way PostgREST's io tests spawn the binary with the test environment
  plus per-test overrides (the CLI needs them since db-config=true connects).

  `config.preconditions_sql` statements run first over a superuser connection
  (the same `PG*` defaults as `mix bier.fixtures.load`). `CREATE ROLE` of an
  already-existing role is tolerated — cluster-level roles survive the
  per-run database drop, so preconditions must be re-runnable. When the case
  switches `PGUSER` and the suite connects with a password (CI's scram auth;
  upstream's io harness runs Postgres with trust instead), the role's
  password is aligned to `PGPASSWORD` so the CLI can authenticate as it.
  """

  @doc "Run a CLI conformance case and return its normalized result."
  def perform(%Bier.ConformanceCase{request: req, config: config}) do
    env = Map.merge(base_pg_env(), Map.get(config, "env", %{}))
    run_preconditions(Map.get(config, "preconditions_sql", []), env)

    file_path = write_config_file(Map.get(config, "file"))
    argv = build_argv(Map.get(req, "flag"), file_path)

    try do
      result = Bier.CLI.run(argv, env: env)

      %{
        stdout: IO.iodata_to_binary(result.stdout),
        stderr: IO.iodata_to_binary(result.stderr),
        exit: result.exit
      }
    after
      if file_path, do: File.rm(file_path)
    end
  end

  @doc """
  The suite's `PG*` connection environment: system values with the same
  defaults as `mix bier.fixtures.load` (localhost / 5432 / `bier_test`).
  """
  def base_pg_env do
    %{
      "PGHOST" => System.get_env("PGHOST") || "localhost",
      "PGPORT" => System.get_env("PGPORT") || "5432",
      "PGDATABASE" => System.get_env("PGDATABASE") || "bier_test",
      "PGUSER" => System.get_env("PGUSER") || System.get_env("USER") || "postgres"
    }
    |> put_password(System.get_env("PGPASSWORD"))
  end

  defp put_password(env, nil), do: env
  defp put_password(env, password), do: Map.put(env, "PGPASSWORD", password)

  defp run_preconditions([], _env), do: :ok

  defp run_preconditions(statements, env) do
    base = base_pg_env()

    {:ok, conn} =
      Postgrex.start_link(
        hostname: base["PGHOST"],
        port: String.to_integer(base["PGPORT"]),
        database: base["PGDATABASE"],
        username: base["PGUSER"],
        password: base["PGPASSWORD"],
        pool_size: 1
      )

    try do
      Enum.each(statements, &run_precondition(conn, &1))
      align_role_password(conn, env, base)
    after
      GenServer.stop(conn)
    end
  end

  # Roles are cluster-global and survive `mix bier.fixtures.load`'s database
  # recreate, so a case's CREATE ROLE must tolerate the role already existing
  # (ALTER ROLE ... SET is naturally idempotent).
  defp run_precondition(conn, sql) do
    case Postgrex.query(conn, sql, []) do
      {:ok, _result} -> :ok
      {:error, %Postgrex.Error{postgres: %{code: :duplicate_object}}} -> :ok
      {:error, err} -> raise err
    end
  end

  defp align_role_password(conn, env, base) do
    role = env["PGUSER"]
    password = base["PGPASSWORD"]

    if is_binary(role) and role != base["PGUSER"] and is_binary(password) do
      Postgrex.query!(
        conn,
        ~s(ALTER ROLE "#{String.replace(role, "\"", "\"\"")}" PASSWORD '#{password}'),
        []
      )
    end

    :ok
  end

  # The case `flag` is either a CLI flag ("--dump-config") or a config-file path
  # that does not exist ("does_not_exist.conf", case 1719).
  defp build_argv(nil, file_path), do: List.wrap(file_path)
  defp build_argv("--" <> _ = flag, file_path), do: List.wrap(file_path) ++ [flag]
  defp build_argv(path, _file_path), do: [path]

  defp write_config_file(nil), do: nil

  defp write_config_file(file_map) do
    path = Path.join(System.tmp_dir!(), "bier_conf_#{System.unique_integer([:positive])}.conf")
    File.write!(path, render_file(file_map))
    path
  end

  defp render_file(file_map) do
    Enum.map_join(file_map, "\n", fn {k, v} -> "#{k} = #{render_value(v)}" end) <> "\n"
  end

  defp render_value(v) when is_binary(v), do: ~s("#{String.replace(v, ~S("), ~S(\"))}")
  defp render_value(v) when is_boolean(v), do: to_string(v)
  defp render_value(v) when is_integer(v), do: Integer.to_string(v)
end
