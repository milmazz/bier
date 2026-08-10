defmodule Bier.CLITest do
  use ExUnit.Case, async: true

  alias Bier.CLI

  # Pure-parse tests opt out of the in-database config source; with the
  # PostgREST-default db-config=true a successful dump/boot would connect to
  # the database (covered by the db-config wiring tests + cases 1724/1725).
  @no_db %{"PGRST_DB_CONFIG" => "false"}

  test "--dump-config prints config and exits 0" do
    result = CLI.run(["--dump-config"], env: Map.merge(@no_db, %{"PGRST_LOG_LEVEL" => "info"}))
    assert result.exit == 0
    assert IO.iodata_to_binary(result.stdout) =~ ~s(log-level = "info")
    assert IO.iodata_to_binary(result.stderr) == ""
  end

  test "--dump-config with an invalid value prints the message to stderr, nonzero exit" do
    result = CLI.run(["--dump-config"], env: %{"PGRST_JWT_SECRET" => "short_secret"})
    assert result.exit != 0

    assert IO.iodata_to_binary(result.stderr) =~
             "The JWT secret must be at least 32 characters long."

    assert IO.iodata_to_binary(result.stdout) == ""
  end

  test "--dump-config canonicalizes jwt-role-claim-key and resolves its alias" do
    # Defaults: the v16.0 RFC 9535 default `$.role` dumps with the literal `$`
    # doubled, because Data.Configurator reads `$$` as an escaped `$` when the
    # file is read back (case 1705). is-base64 defaults off.
    result = CLI.run(["--dump-config"], env: @no_db)
    assert result.exit == 0
    stdout = IO.iodata_to_binary(result.stdout)
    assert stdout =~ ~s|jwt-role-claim-key = "$$.role"|
    assert stdout =~ ~s(jwt-secret-is-base64 = false)

    # The deprecated `role-claim-key` alias resolves to the canonical key
    # (case 1707's shape) and the value is re-serialized the same way.
    result =
      CLI.run(["--dump-config"], env: Map.merge(@no_db, %{"PGRST_ROLE_CLAIM_KEY" => "$.aliased"}))

    assert result.exit == 0
    assert IO.iodata_to_binary(result.stdout) =~ ~s|jwt-role-claim-key = "$$.aliased"|
  end

  test "--dump-config rejects an invalid jwt-role-claim-key (case 1711 shape)" do
    result = CLI.run(["--dump-config"], env: %{"PGRST_JWT_ROLE_CLAIM_KEY" => "role.other"})
    assert result.exit != 0

    assert IO.iodata_to_binary(result.stderr) =~
             "failed to parse role-claim-key value (role.other)"
  end

  describe "in-database config wiring (db-config, #64)" do
    @tag capture_log: true
    test "--dump-config with db-config on and an unreachable DB is fatal" do
      env = %{"PGPORT" => "1", "PGUSER" => "nobody", "PGDATABASE" => "nowhere"}
      result = CLI.run(["--dump-config"], env: env)

      assert result.exit == 1
      assert IO.iodata_to_binary(result.stderr) =~ "in-database config"
      assert IO.iodata_to_binary(result.stdout) == ""
    end

    test "db-config=false skips the database entirely" do
      env = %{"PGRST_DB_CONFIG" => "false", "PGPORT" => "1"}
      result = CLI.run(["--dump-config"], env: env)

      assert result.exit == 0
      assert IO.iodata_to_binary(result.stdout) =~ "db-config = false"
    end
  end

  describe "--ready (PostgREST Client.hs parity)" do
    test "without admin-server-port it fails with the no-admin-server error" do
      result = CLI.run(["--ready"], env: %{})

      assert result == %{
               stdout: "",
               stderr: [
                 "ERROR: Admin server is not running. Please check admin-server-port config.",
                 "\n"
               ],
               exit: 1
             }
    end

    test "a special server-host (the !4 default) cannot be resolved to an address" do
      result = CLI.run(["--ready"], env: %{"PGRST_ADMIN_SERVER_PORT" => "3001"})

      assert result == %{
               stdout: "",
               stderr: [
                 "ERROR: The `--ready` flag cannot be used when server-host is configured as \"!4\". " <>
                   "Please update your server-host config to \"localhost\".",
                 "\n"
               ],
               exit: 1
             }
    end

    test "a resolvable host yields the ready-check directive with the /ready URL" do
      env = %{"PGRST_ADMIN_SERVER_PORT" => "3001", "PGRST_SERVER_HOST" => "localhost"}
      assert CLI.run(["--ready"], env: env) == {:ready, "http://localhost:3001/ready"}
    end

    test "an IPv6 host is bracket-wrapped in the URL" do
      env = %{"PGRST_ADMIN_SERVER_PORT" => "3001", "PGRST_SERVER_HOST" => "::1"}
      assert CLI.run(["--ready"], env: env) == {:ready, "http://[::1]:3001/ready"}
    end

    test "config fatals still win over the ready check" do
      env = %{"PGRST_ADMIN_SERVER_PORT" => "3001", "PGRST_JWT_SECRET" => "short_secret"}
      result = CLI.run(["--ready"], env: env)
      assert result.exit == 1
      assert IO.iodata_to_binary(result.stderr) =~ "at least 32 characters"
    end
  end

  test "--dump-config rejects a non-base64 secret when is-base64 is set (case 1718 shape)" do
    # Long enough to pass the 32-byte length check (which runs first, like
    # PostgREST's raw-length rule), so the base64 decode is what rejects it.
    long_invalid = String.duplicate("no base-64!", 3)
    env = %{"PGRST_JWT_SECRET_IS_BASE64" => "true", "PGRST_JWT_SECRET" => long_invalid}
    result = CLI.run(["--dump-config"], env: env)
    assert result.exit != 0
    assert IO.iodata_to_binary(result.stderr) =~ "not valid base64"

    # The `secret-is-base64` alias engages the same validation.
    env = %{"PGRST_SECRET_IS_BASE64" => "true", "PGRST_JWT_SECRET" => long_invalid}
    result = CLI.run(["--dump-config"], env: env)
    assert result.exit != 0
    assert IO.iodata_to_binary(result.stderr) =~ "not valid base64"
  end

  test "a missing config file is fatal" do
    result = CLI.run(["does_not_exist.conf", "--dump-config"], env: %{})
    assert result.exit != 0
    assert IO.iodata_to_binary(result.stderr) =~ "does_not_exist.conf"
  end

  test "--version prints the version and exits 0" do
    result = CLI.run(["--version"], env: %{})
    assert result.exit == 0
    assert IO.iodata_to_binary(result.stdout) =~ ~r/bier \S/
  end

  test "--version and --help print even when the config would be fatal" do
    result = CLI.run(["--version"], env: %{"PGRST_JWT_SECRET" => "short_secret"})
    assert result.exit == 0
    assert IO.iodata_to_binary(result.stdout) =~ ~r/bier \S/

    result = CLI.run(["does_not_exist.conf", "--help"], env: %{})
    assert result.exit == 0
    assert IO.iodata_to_binary(result.stdout) =~ "Usage"
  end

  test "--help prints usage and exits 0" do
    result = CLI.run(["--help"], env: %{})
    assert result.exit == 0
    assert IO.iodata_to_binary(result.stdout) =~ "Usage"
  end

  test "no flag returns a boot directive" do
    assert {:boot, resolved} =
             CLI.run([], env: Map.merge(@no_db, %{"PGRST_LOG_LEVEL" => "info"}))

    assert resolved["log-level"] == :info
  end

  test "--dump-config defaults include the server/pool keys (case 1705 shape)" do
    result = CLI.run(["--dump-config"], env: @no_db)
    assert result.exit == 0
    stdout = IO.iodata_to_binary(result.stdout)
    assert stdout =~ ~s(server-host = "!4")
    assert stdout =~ ~s(server-unix-socket = "")
    assert stdout =~ ~s(server-unix-socket-mode = "660")
    assert stdout =~ ~s(openapi-server-proxy-uri = "")
    assert stdout =~ ~s(db-pool = 10)
    assert stdout =~ ~s(db-pool-max-idletime = 30)
  end

  test "an invalid server-unix-socket-mode is fatal (cases 1714/1715 shapes)" do
    result = CLI.run(["--dump-config"], env: %{"PGRST_SERVER_UNIX_SOCKET_MODE" => "800"})
    assert result.exit != 0
    assert IO.iodata_to_binary(result.stderr) =~ "Invalid server-unix-socket-mode: not an octal"

    result = CLI.run(["--dump-config"], env: %{"PGRST_SERVER_UNIX_SOCKET_MODE" => "599"})
    assert result.exit != 0

    assert IO.iodata_to_binary(result.stderr) =~
             "Invalid server-unix-socket-mode: needs to be between 600 and 777"
  end

  test "a malformed openapi-server-proxy-uri is fatal, a valid one dumps (case 1716 shape)" do
    env = %{"PGRST_OPENAPI_SERVER_PROXY_URI" => "htp:/@@localhorst.invalid"}
    result = CLI.run(["--dump-config"], env: env)
    assert result.exit != 0

    assert IO.iodata_to_binary(result.stderr) =~
             "Malformed proxy uri, a correct example: https://example.com:8443/basePath"

    env =
      Map.merge(@no_db, %{"PGRST_OPENAPI_SERVER_PROXY_URI" => "https://example.com:8443/basePath"})

    result = CLI.run(["--dump-config"], env: env)
    assert result.exit == 0

    assert IO.iodata_to_binary(result.stdout) =~
             ~s(openapi-server-proxy-uri = "https://example.com:8443/basePath")
  end

  test "PGRST_APP_SETTINGS_* env vars dump as app.settings.* and env beats file (case 1729)" do
    # v16.0 keeps the name after the prefix VERBATIM: `normalize` only strips
    # PGRST_APP_SETTINGS_ and prepends "app.settings.", with no case folding
    # (Config.hs#L348). So a file key must be spelled the same way as the env
    # var for the two to collide at all.
    path = write_tmp_config(~s(app.settings.from_file = "file"\napp.settings.BOTH = "file"\n))

    env =
      Map.merge(@no_db, %{"PGRST_APP_SETTINGS_FOO" => "bar", "PGRST_APP_SETTINGS_BOTH" => "env"})

    result = CLI.run([path, "--dump-config"], env: env)
    assert result.exit == 0
    stdout = IO.iodata_to_binary(result.stdout)
    assert stdout =~ ~s(app.settings.FOO = "bar")
    assert stdout =~ ~s(app.settings.from_file = "file")
    assert stdout =~ ~s(app.settings.BOTH = "env")

    # ...and a name differing only in case is a DIFFERENT setting, not an
    # override of one. This is the v14.12 behavior that v16.0 dropped.
    refute stdout =~ ~s(app.settings.foo = "bar")
  end

  test "db-pool-timeout aliases db-pool-max-idletime (case 1707 shape)" do
    path = write_tmp_config("db-pool-timeout = 5\n")

    result = CLI.run([path, "--dump-config"], env: @no_db)
    assert result.exit == 0
    assert IO.iodata_to_binary(result.stdout) =~ "db-pool-max-idletime = 5"
  end

  test "--dump-config includes jwt-cache-max-entries with its PostgREST default" do
    result = CLI.run(["--dump-config"], env: @no_db)
    assert result.exit == 0
    assert IO.iodata_to_binary(result.stdout) =~ ~s(jwt-cache-max-entries = 1000)
  end

  test "PGRST_JWT_CACHE_MAX_ENTRIES overrides; a wrong type falls back to the default" do
    result =
      CLI.run(["--dump-config"], env: Map.merge(@no_db, %{"PGRST_JWT_CACHE_MAX_ENTRIES" => "0"}))

    assert result.exit == 0
    assert IO.iodata_to_binary(result.stdout) =~ ~s(jwt-cache-max-entries = 0)

    # A wrong-typed value coerces to :unset, which resolve/4 collapses back to
    # the key's own default (PostgREST's wrong-type rule; case 1721's :unset
    # dump-as-blank shape is scoped to optInt keys, not required :int keys
    # like this one — matches server-port/db-pool).
    result =
      CLI.run(["--dump-config"],
        env: Map.merge(@no_db, %{"PGRST_JWT_CACHE_MAX_ENTRIES" => "notanint"})
      )

    assert result.exit == 0
    assert IO.iodata_to_binary(result.stdout) =~ ~s(jwt-cache-max-entries = 1000)
  end

  test "--example prints a loadable config template (case 1727 shape)" do
    result = CLI.run(["--example"], env: %{})
    assert result.exit == 0
    stdout = IO.iodata_to_binary(result.stdout)
    assert stdout =~ ~s(db-uri = "postgresql://")
    assert stdout =~ ~s(db-schemas = "public")
    assert stdout =~ ~s(db-channel = "pgrst")
    assert stdout =~ "server-port = 3000"
    assert stdout =~ ~s(log-level = "error")

    # `-e` is the short form, and it answers before config loading like
    # --version/--help.
    assert CLI.run(["-e"], env: %{"PGRST_JWT_SECRET" => "short_secret"}).exit == 0

    # The template is itself a loadable config file (env opts out of the DB
    # read the template's own db-config = true would trigger).
    path = write_tmp_config(stdout)
    reload = CLI.run([path, "--dump-config"], env: @no_db)
    assert reload.exit == 0
  end

  defp write_tmp_config(contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "bier_cli_test_#{System.unique_integer([:positive])}.conf"
      )

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
