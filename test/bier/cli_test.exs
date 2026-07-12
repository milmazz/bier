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
end
