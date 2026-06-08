defmodule Bier.CLI.ConfigTest do
  use ExUnit.Case, async: true

  alias Bier.CLI.Config

  describe "coerce/2" do
    test ":string coerces any value to a string" do
      assert Config.coerce(:string, "postgresql://") == {:ok, "postgresql://"}
      assert Config.coerce(:string, 3000) == {:ok, "3000"}
    end

    test ":csv trims whitespace around items and drops empties" do
      assert Config.coerce(:csv, " a , b ,") == {:ok, ["a", "b"]}
    end

    test ":bool is case-insensitive and accepts positive integers (PostgREST coerceBool)" do
      assert Config.coerce(:bool, "TRUE") == {:ok, true}
      assert Config.coerce(:bool, "true") == {:ok, true}
      assert Config.coerce(:bool, "2") == {:ok, true}
      assert Config.coerce(:bool, true) == {:ok, true}
      assert Config.coerce(:bool, "0") == {:ok, false}
      assert Config.coerce(:bool, "no") == {:ok, false}
      assert Config.coerce(:bool, false) == {:ok, false}
    end

    test ":csv splits on commas" do
      assert Config.coerce(:csv, "multi,tenant,setup") == {:ok, ["multi", "tenant", "setup"]}
    end

    test ":csv_emptyable yields [] for empty string" do
      assert Config.coerce(:csv_emptyable, "") == {:ok, []}
    end

    test ":opt_int parses ints, treats wrong type as absent" do
      assert Config.coerce(:opt_int, "1000") == {:ok, 1000}
      assert Config.coerce(:opt_int, true) == {:ok, :unset}
      assert Config.coerce(:opt_int, "") == {:ok, :unset}
    end

    test ":opt_string treats empty string as absent" do
      assert Config.coerce(:opt_string, "") == {:ok, :unset}
      assert Config.coerce(:opt_string, "x") == {:ok, "x"}
    end

    test "log-level enum maps known values, rejects unknown with PostgREST message" do
      assert Config.coerce({:enum_atom, :log_level}, "info") == {:ok, :info}

      assert Config.coerce({:enum_atom, :log_level}, "never") ==
               {:error, "Invalid logging level. Check your configuration."}
    end

    test "db-tx-end enum rejects unknown with PostgREST message" do
      assert Config.coerce({:enum_atom, :db_tx_end}, "commit-allow-override") ==
               {:ok, :"commit-allow-override"}

      assert Config.coerce({:enum_atom, :db_tx_end}, "random") ==
               {:error, "Invalid transaction termination. Check your configuration."}
    end

    test "openapi-mode enum stays a string, rejects unknown with PostgREST message" do
      assert Config.coerce({:enum_str, :openapi_mode}, "ignore-privileges") ==
               {:ok, "ignore-privileges"}

      assert Config.coerce({:enum_str, :openapi_mode}, "follow-") ==
               {:error, "Invalid openapi-mode. Check your configuration."}
    end
  end

  describe "spec/0" do
    test "exposes db-schemas with its alias and env var" do
      entry = Enum.find(Config.spec(), &(&1.key == "db-schemas"))
      assert entry.env == "PGRST_DB_SCHEMAS"
      assert "db-schema" in entry.aliases
      assert entry.kind == :csv
    end
  end

  describe "load/3" do
    test "reads from environment only" do
      env = %{
        "PGRST_DB_SCHEMAS" => "multi,tenant,setup",
        "PGRST_DB_MAX_ROWS" => "1000",
        "PGRST_LOG_LEVEL" => "info"
      }

      assert {:ok, resolved} = Config.load(env, nil, %{})
      assert resolved["db-schemas"] == ["multi", "tenant", "setup"]
      assert resolved["db-max-rows"] == 1000
      assert resolved["log-level"] == :info
    end

    test "env overrides file (case 1720)" do
      file = %{"db-max-rows" => 100, "log-level" => "warn"}
      env = %{"PGRST_DB_MAX_ROWS" => "999", "PGRST_LOG_LEVEL" => "debug"}
      assert {:ok, resolved} = Config.load(env, file, %{})
      assert resolved["db-max-rows"] == 999
      assert resolved["log-level"] == :debug
    end

    test "resolves the db-schema alias (case 1730)" do
      assert {:ok, resolved} = Config.load(%{}, %{"db-schema" => "aliased_schema"}, %{})
      assert resolved["db-schemas"] == ["aliased_schema"]
    end

    test "wrong type for an optional int falls back to its default :unset (case 1721)" do
      assert {:ok, resolved} = Config.load(%{}, %{"db-max-rows" => true}, %{})
      assert resolved["db-max-rows"] == :unset
    end

    test "wrong type for a required int falls back to its numeric default (server-port)" do
      assert {:ok, resolved} = Config.load(%{"PGRST_SERVER_PORT" => "garbage"}, nil, %{})
      assert resolved["server-port"] == 3000
    end

    test "empty log-level falls back to default error, not an enum error (case 1723)" do
      assert {:ok, resolved} = Config.load(%{"PGRST_LOG_LEVEL" => ""}, nil, %{})
      assert resolved["log-level"] == :error
    end

    test "empty db-extra-search-path is the empty list, not the default (case 1728)" do
      assert {:ok, resolved} = Config.load(%{"PGRST_DB_EXTRA_SEARCH_PATH" => ""}, nil, %{})
      assert resolved["db-extra-search-path"] == []
    end

    test "a too-short jwt-secret is fatal (case 1708)" do
      assert Config.load(%{"PGRST_JWT_SECRET" => "short_secret"}, nil, %{}) ==
               {:error, "The JWT secret must be at least 32 characters long."}
    end

    test "an unknown log-level is fatal (case 1712)" do
      assert Config.load(%{"PGRST_LOG_LEVEL" => "never"}, nil, %{}) ==
               {:error, "Invalid logging level. Check your configuration."}
    end

    test "admin-server-port equal to server-port is fatal (case 1717)" do
      assert Config.load(
               %{"PGRST_SERVER_PORT" => "3000", "PGRST_ADMIN_SERVER_PORT" => "3000"},
               nil,
               %{}
             ) ==
               {:error, "admin-server-port cannot be the same as server-port"}
    end

    test "flags override both env and file for the same key" do
      flags = %{"log-level" => "debug"}
      env = %{"PGRST_LOG_LEVEL" => "info"}
      file = %{"log-level" => "warn"}
      assert {:ok, resolved} = Config.load(env, file, flags)
      assert resolved["log-level"] == :debug
    end
  end
end
