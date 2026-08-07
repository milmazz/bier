defmodule Bier.CLI.DbSettingsTest do
  # Creates/drops a dedicated login role in the shared Postgres cluster.
  use ExUnit.Case, async: false

  alias Bier.CLI.DbSettings

  @role "bier_db_settings_test_role"
  @password "bier_db_settings_pw"

  # Same PG* defaults as mix bier.fixtures.load: the suite's local/CI Postgres.
  defp base_pg_env do
    %{
      "PGHOST" => System.get_env("PGHOST") || "localhost",
      "PGPORT" => System.get_env("PGPORT") || "5432",
      "PGDATABASE" => System.get_env("PGDATABASE") || "bier_test",
      "PGUSER" => System.get_env("PGUSER") || System.get_env("USER") || "postgres"
    }
    |> then(fn env ->
      case System.get_env("PGPASSWORD") do
        nil -> env
        pw -> Map.put(env, "PGPASSWORD", pw)
      end
    end)
  end

  defp superuser_conn! do
    env = base_pg_env()

    start_supervised!(
      {Postgrex,
       hostname: env["PGHOST"],
       port: String.to_integer(env["PGPORT"]),
       database: env["PGDATABASE"],
       username: env["PGUSER"],
       password: env["PGPASSWORD"],
       pool_size: 1}
    )
  end

  setup do
    conn = superuser_conn!()
    Postgrex.query!(conn, "DROP ROLE IF EXISTS #{@role}", [])
    Postgrex.query!(conn, "CREATE ROLE #{@role} LOGIN PASSWORD '#{@password}'", [])
    on_exit_conn_cleanup()
    {:ok, conn: conn}
  end

  defp on_exit_conn_cleanup do
    env = base_pg_env()

    on_exit(fn ->
      {:ok, conn} =
        Postgrex.start_link(
          hostname: env["PGHOST"],
          port: String.to_integer(env["PGPORT"]),
          database: env["PGDATABASE"],
          username: env["PGUSER"],
          password: env["PGPASSWORD"],
          pool_size: 1
        )

      Postgrex.query!(conn, "DROP ROLE IF EXISTS #{@role}", [])
      GenServer.stop(conn)
    end)
  end

  # The role's env: the CLI connects with the default "postgresql://" db-uri,
  # so every connection field comes from the PG* fallbacks.
  defp role_env do
    base_pg_env()
    |> Map.put("PGUSER", @role)
    |> Map.put("PGPASSWORD", @password)
  end

  defp resolved(env) do
    {:ok, resolved} = Bier.CLI.Config.load(env, nil, %{})
    resolved
  end

  test "whitelisted pgrst.* role settings come back under their kebab keys", %{conn: conn} do
    Postgrex.query!(conn, "ALTER ROLE #{@role} SET pgrst.db_max_rows = '7'", [])
    Postgrex.query!(conn, "ALTER ROLE #{@role} SET pgrst.db_schemas = 'test, tenant1'", [])

    env = role_env()
    assert {:ok, db} = DbSettings.fetch(resolved(env), env)
    assert db == %{"db-max-rows" => "7", "db-schemas" => "test, tenant1"}
  end

  test "non-whitelisted settings are filtered by the query itself", %{conn: conn} do
    Postgrex.query!(conn, "ALTER ROLE #{@role} SET pgrst.server_port = 'ignored'", [])

    env = role_env()
    assert {:ok, db} = DbSettings.fetch(resolved(env), env)
    refute Map.has_key?(db, "server-port")
  end

  test "a database-specific setting beats the cluster-wide one", %{conn: conn} do
    db_name = base_pg_env()["PGDATABASE"]
    Postgrex.query!(conn, "ALTER ROLE #{@role} SET pgrst.db_max_rows = '7'", [])

    Postgrex.query!(
      conn,
      "ALTER ROLE #{@role} IN DATABASE #{db_name} SET pgrst.db_max_rows = '9'",
      []
    )

    env = role_env()
    assert {:ok, db} = DbSettings.fetch(resolved(env), env)
    assert db["db-max-rows"] == "9"
  end

  @tag capture_log: true
  test "an unreachable server reports an error instead of raising" do
    env = Map.put(role_env(), "PGPORT", "1")
    assert {:error, message} = DbSettings.fetch(resolved(env), env)
    assert is_binary(message)
  end
end
