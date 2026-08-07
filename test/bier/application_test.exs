defmodule Bier.ApplicationTest do
  use ExUnit.Case, async: true

  describe "standalone_spec/1" do
    test "without the BIER_STANDALONE flag it is inert (:none)" do
      assert Bier.Application.standalone_spec(%{}) == :none
      assert Bier.Application.standalone_spec(%{"BIER_STANDALONE" => "0"}) == :none
    end

    test "with BIER_STANDALONE set and valid config it returns a {Bier, opts} child" do
      # db-config=false keeps this a pure config test; the in-database source
      # (which would connect to Postgres) is covered by the CLI wiring tests.
      env = %{
        "BIER_STANDALONE" => "1",
        "PGRST_DB_CONFIG" => "false",
        "PGRST_DB_SCHEMAS" => "api",
        "PGRST_SERVER_PORT" => "4000"
      }

      assert {:ok, {Bier, opts}} = Bier.Application.standalone_spec(env)
      assert opts[:db_schemas] == ["api"]
      assert get_in(opts, [:router, :port]) == 4000
    end

    test "accepts \"true\" as well as \"1\" for the flag" do
      assert {:ok, {Bier, _opts}} =
               Bier.Application.standalone_spec(%{
                 "BIER_STANDALONE" => "true",
                 "PGRST_DB_CONFIG" => "false"
               })
    end

    test "with BIER_STANDALONE set and invalid config it returns the fatal message" do
      env = %{"BIER_STANDALONE" => "1", "PGRST_JWT_SECRET" => "short"}

      assert Bier.Application.standalone_spec(env) ==
               {:error, "The JWT secret must be at least 32 characters long."}
    end
  end
end
