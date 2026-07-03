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
