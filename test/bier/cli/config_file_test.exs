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

  test "an empty quoted string parses to an empty string" do
    assert ConfigFile.parse(~s(jwt-secret = "")) == {:ok, %{"jwt-secret" => ""}}
  end

  test "a value containing '=' keeps everything after the first '='" do
    assert ConfigFile.parse("db-uri = postgresql://u:p@h/db?x=1") ==
             {:ok, %{"db-uri" => "postgresql://u:p@h/db?x=1"}}
  end

  test "a line with no '=' is a malformed-line error" do
    assert {:error, message} = ConfigFile.parse("not-a-valid-line")
    assert message =~ "malformed config line"
  end

  test "an end-of-line comment after a quoted value is ignored" do
    assert ConfigFile.parse(~s(db-anon-role = "web_anon" # the public role)) ==
             {:ok, %{"db-anon-role" => "web_anon"}}
  end

  test "an end-of-line comment after a bare value is ignored" do
    assert ConfigFile.parse("server-port = 3000 # main port") ==
             {:ok, %{"server-port" => 3000}}
  end

  test "a '#' inside a quoted value is literal" do
    assert ConfigFile.parse(~s(jwt-secret = "sec#ret-sec#ret-sec#ret-sec#ret!")) ==
             {:ok, %{"jwt-secret" => "sec#ret-sec#ret-sec#ret-sec#ret!"}}
  end

  test "trailing garbage after a quoted value is a malformed-line error" do
    assert {:error, message} = ConfigFile.parse(~s(db-anon-role = "web_anon" oops))
    assert message =~ "unexpected characters after quoted value"
  end

  test "an unterminated quoted value is a malformed-line error" do
    assert {:error, message} = ConfigFile.parse(~s(db-anon-role = "web_anon))
    assert message =~ "unterminated quoted value"
  end
end
