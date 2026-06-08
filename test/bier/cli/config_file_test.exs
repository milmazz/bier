defmodule Bier.CLI.ConfigFileTest do
  use ExUnit.Case, async: true

  alias Bier.CLI.ConfigFile

  test "parses quoted strings, bare ints and bools, ignores comments/blanks" do
    contents = """
    # a comment
    db-schemas = "api,public"

    server-port = 3000
    jwt-secret-is-base64 = true
    """

    assert ConfigFile.parse(contents) ==
             {:ok,
              %{
                "db-schemas" => "api,public",
                "server-port" => 3000,
                "jwt-secret-is-base64" => true
              }}
  end

  test "unquotes escaped quotes inside string values" do
    assert ConfigFile.parse(~S(role-claim-key = ".\"role\"")) ==
             {:ok, %{"role-claim-key" => ~S(."role")}}
  end

  test "read/1 errors on a missing file" do
    assert {:error, message} = ConfigFile.read("does_not_exist.conf")
    assert message =~ "does_not_exist.conf"
  end

  test "read/1 parses an existing file" do
    path = Path.join(System.tmp_dir!(), "bier_cfg_#{System.unique_integer([:positive])}.conf")
    File.write!(path, "log-level = \"info\"\n")
    on_exit(fn -> File.rm(path) end)

    assert ConfigFile.read(path) == {:ok, %{"log-level" => "info"}}
  end
end
