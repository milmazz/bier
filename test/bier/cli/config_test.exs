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
end
