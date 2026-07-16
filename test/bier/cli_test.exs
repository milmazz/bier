defmodule Bier.CLITest do
  use ExUnit.Case, async: true

  alias Bier.CLI

  test "--dump-config prints config and exits 0" do
    result = CLI.run(["--dump-config"], env: %{"PGRST_LOG_LEVEL" => "info"})
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
    # Defaults: `.role` dumps in PostgREST's quoted form; is-base64 defaults off.
    result = CLI.run(["--dump-config"], env: %{})
    assert result.exit == 0
    stdout = IO.iodata_to_binary(result.stdout)
    assert stdout =~ ~s|jwt-role-claim-key = ".\\"role\\""|
    assert stdout =~ ~s(jwt-secret-is-base64 = false)

    # The deprecated `role-claim-key` alias resolves to the canonical key
    # (case 1707's shape) and the value is re-serialized quoted.
    result = CLI.run(["--dump-config"], env: %{"PGRST_ROLE_CLAIM_KEY" => ".aliased"})
    assert result.exit == 0
    assert IO.iodata_to_binary(result.stdout) =~ ~s|jwt-role-claim-key = ".\\"aliased\\""|
  end

  test "--dump-config rejects an invalid jwt-role-claim-key (case 1711 shape)" do
    result = CLI.run(["--dump-config"], env: %{"PGRST_JWT_ROLE_CLAIM_KEY" => "role.other"})
    assert result.exit != 0

    assert IO.iodata_to_binary(result.stderr) =~
             "failed to parse role-claim-key value (role.other)"
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
    assert {:boot, resolved} = CLI.run([], env: %{"PGRST_LOG_LEVEL" => "info"})
    assert resolved["log-level"] == :info
  end

  test "--dump-config defaults include the server/pool keys (case 1705 shape)" do
    result = CLI.run(["--dump-config"], env: %{})
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

    env = %{"PGRST_OPENAPI_SERVER_PROXY_URI" => "https://example.com:8443/basePath"}
    result = CLI.run(["--dump-config"], env: env)
    assert result.exit == 0

    assert IO.iodata_to_binary(result.stdout) =~
             ~s(openapi-server-proxy-uri = "https://example.com:8443/basePath")
  end

  test "PGRST_APP_SETTINGS_* env vars dump as app.settings.* and env beats file (case 1729)" do
    path = write_tmp_config(~s(app.settings.from_file = "file"\napp.settings.both = "file"\n))

    env = %{"PGRST_APP_SETTINGS_FOO" => "bar", "PGRST_APP_SETTINGS_BOTH" => "env"}
    result = CLI.run([path, "--dump-config"], env: env)
    assert result.exit == 0
    stdout = IO.iodata_to_binary(result.stdout)
    assert stdout =~ ~s(app.settings.foo = "bar")
    assert stdout =~ ~s(app.settings.from_file = "file")
    assert stdout =~ ~s(app.settings.both = "env")
  end

  test "db-pool-timeout aliases db-pool-max-idletime (case 1707 shape)" do
    path = write_tmp_config("db-pool-timeout = 5\n")

    result = CLI.run([path, "--dump-config"], env: %{})
    assert result.exit == 0
    assert IO.iodata_to_binary(result.stdout) =~ "db-pool-max-idletime = 5"
  end

  test "--dump-config includes jwt-cache-max-entries with its PostgREST default" do
    result = CLI.run(["--dump-config"], env: %{})
    assert result.exit == 0
    assert IO.iodata_to_binary(result.stdout) =~ ~s(jwt-cache-max-entries = 1000)
  end

  test "PGRST_JWT_CACHE_MAX_ENTRIES overrides; a wrong type falls back to the default" do
    result = CLI.run(["--dump-config"], env: %{"PGRST_JWT_CACHE_MAX_ENTRIES" => "0"})
    assert result.exit == 0
    assert IO.iodata_to_binary(result.stdout) =~ ~s(jwt-cache-max-entries = 0)

    # :int coercion failure -> :unset -> dumps as "" and the library default
    # applies at boot (case 1721's shape for int keys).
    result = CLI.run(["--dump-config"], env: %{"PGRST_JWT_CACHE_MAX_ENTRIES" => "notanint"})
    assert result.exit == 0
    assert IO.iodata_to_binary(result.stdout) =~ ~s(jwt-cache-max-entries = "")
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

    # The template is itself a loadable config file.
    path = write_tmp_config(stdout)
    reload = CLI.run([path, "--dump-config"], env: %{})
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
