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

    test "resolves alias-derived env vars (PGRST_DB_SCHEMA, PostgREST optWithAlias)" do
      assert {:ok, resolved} = Config.load(%{"PGRST_DB_SCHEMA" => "api"}, nil, %{})
      assert resolved["db-schemas"] == ["api"]

      assert {:ok, resolved} = Config.load(%{"PGRST_MAX_ROWS" => "50"}, nil, %{})
      assert resolved["db-max-rows"] == 50
    end

    test "a canonical file key still beats an alias env var" do
      env = %{"PGRST_DB_SCHEMA" => "from_alias_env"}
      file = %{"db-schemas" => "from_canonical_file"}
      assert {:ok, resolved} = Config.load(env, file, %{})
      assert resolved["db-schemas"] == ["from_canonical_file"]
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

  describe "to_start_opts/1" do
    test "maps resolved keys to Bier.start_link/1 options" do
      {:ok, resolved} =
        Config.load(
          %{
            "PGRST_DB_URI" => "postgresql://alice:secret@db.example.com:5433/shop",
            "PGRST_DB_SCHEMAS" => "api,public",
            "PGRST_SERVER_PORT" => "4000",
            "PGRST_LOG_LEVEL" => "info"
          },
          nil,
          %{}
        )

      opts = Config.to_start_opts(resolved)

      assert opts[:hostname] == "db.example.com"
      assert opts[:port] == 5433
      assert opts[:database] == "shop"
      assert opts[:username] == "alice"
      assert opts[:password] == "secret"
      assert opts[:db_schemas] == ["api", "public"]
      assert opts[:log_level] == :info
      assert get_in(opts, [:router, :port]) == 4000
    end

    test "percent-decodes db-uri credentials and database" do
      {:ok, resolved} =
        Config.load(%{"PGRST_DB_URI" => "postgresql://al%20ice:p%40ss@host/my%20db"}, nil, %{})

      opts = Config.to_start_opts(resolved)

      assert opts[:username] == "al ice"
      assert opts[:password] == "p@ss"
      assert opts[:database] == "my db"
    end

    test "omits unset optional keys so Bier defaults apply" do
      {:ok, resolved} = Config.load(%{}, nil, %{})
      opts = Config.to_start_opts(resolved)
      refute Keyword.has_key?(opts, :db_max_rows)
      refute Keyword.has_key?(opts, :jwt_secret)
    end

    test "collapses db-tx-end allow-override variants to Bier's base mode" do
      {:ok, resolved} = Config.load(%{"PGRST_DB_TX_END" => "commit-allow-override"}, nil, %{})
      opts = Config.to_start_opts(resolved)
      assert opts[:db_tx_end] == :commit
    end

    test "parses a libpq keyword/value conninfo db-uri" do
      uri = "host=db.example.com port=5433 dbname=shop user=alice password=secret"
      {:ok, resolved} = Config.load(%{"PGRST_DB_URI" => uri}, nil, %{})
      opts = Config.to_start_opts(resolved)

      assert opts[:hostname] == "db.example.com"
      assert opts[:port] == 5433
      assert opts[:database] == "shop"
      assert opts[:username] == "alice"
      assert opts[:password] == "secret"
    end

    test "maps sslmode=require/verify-* to ssl: true, in both db-uri forms" do
      {:ok, resolved} =
        Config.load(%{"PGRST_DB_URI" => "postgresql://h/db?sslmode=require"}, nil, %{})

      assert Config.to_start_opts(resolved)[:ssl] == true

      {:ok, resolved} =
        Config.load(%{"PGRST_DB_URI" => "host=h dbname=db sslmode=verify-full"}, nil, %{})

      assert Config.to_start_opts(resolved)[:ssl] == true

      {:ok, resolved} =
        Config.load(%{"PGRST_DB_URI" => "postgresql://h/db?sslmode=disable"}, nil, %{})

      refute Keyword.has_key?(Config.to_start_opts(resolved), :ssl)
    end

    test "maps openapi-security-active to Bier.start_link/1 options" do
      {:ok, resolved} = Config.load(%{"PGRST_OPENAPI_SECURITY_ACTIVE" => "true"}, nil, %{})
      assert Config.to_start_opts(resolved)[:openapi_security_active] == true
    end

    test "produced options validate via Bier.Config.new!/2" do
      {:ok, resolved} =
        Config.load(%{"PGRST_DB_SCHEMAS" => "api", "PGRST_SERVER_PORT" => "4000"}, nil, %{})

      opts = Config.to_start_opts(resolved)
      assert %Bier.Config{} = Bier.Config.new!(opts, Bier.schema())
    end

    test "maps the bool observability keys and trace header" do
      {:ok, resolved} =
        Config.load(
          %{"PGRST_DB_PLAN_ENABLED" => "true", "PGRST_SERVER_TRACE_HEADER" => "X-Request-Id"},
          nil,
          %{}
        )

      opts = Config.to_start_opts(resolved)

      assert opts[:db_plan_enabled] == true
      assert opts[:server_timing_enabled] == false
      assert opts[:server_trace_header] == "X-Request-Id"
    end

    test "a fully-populated resolve produces options that all validate via Bier.Config.new!/2" do
      env = %{
        "PGRST_DB_URI" => "postgresql://u:p@h:5432/db",
        "PGRST_DB_SCHEMAS" => "api,public",
        "PGRST_DB_ANON_ROLE" => "anon",
        "PGRST_DB_EXTRA_SEARCH_PATH" => "public,extra",
        "PGRST_DB_MAX_ROWS" => "100",
        "PGRST_DB_TX_END" => "rollback",
        "PGRST_DB_PRE_REQUEST" => "auth.hook",
        "PGRST_DB_ROOT_SPEC" => "root_fn",
        "PGRST_SERVER_PORT" => "4000",
        "PGRST_ADMIN_SERVER_PORT" => "4001",
        "PGRST_JWT_SECRET" => "reallyreallyreallyreallyverysafe",
        "PGRST_JWT_AUD" => "https://example.com",
        "PGRST_OPENAPI_MODE" => "ignore-privileges",
        "PGRST_LOG_LEVEL" => "info",
        "PGRST_SERVER_CORS_ALLOWED_ORIGINS" => "http://example.com",
        "PGRST_DB_PLAN_ENABLED" => "true",
        "PGRST_SERVER_TRACE_HEADER" => "X-Request-Id",
        "PGRST_SERVER_TIMING_ENABLED" => "true"
      }

      {:ok, resolved} = Config.load(env, nil, %{})
      opts = Config.to_start_opts(resolved)
      assert %Bier.Config{} = Bier.Config.new!(opts, Bier.schema())
    end
  end

  describe "dump/1" do
    test "renders strings, ints, lists and unset values PostgREST-style" do
      {:ok, resolved} =
        Config.load(
          %{
            "PGRST_DB_SCHEMAS" => "multi,tenant,setup",
            "PGRST_DB_MAX_ROWS" => "1000",
            "PGRST_LOG_LEVEL" => "info"
          },
          nil,
          %{}
        )

      dump = Config.dump(resolved) |> IO.iodata_to_binary()

      assert dump =~ ~s(db-schemas = "multi,tenant,setup")
      assert dump =~ ~s(db-max-rows = 1000)
      assert dump =~ ~s(log-level = "info")
      assert dump =~ ~s(db-anon-role = "")
    end

    test "an unset db-max-rows renders as empty string (case 1721)" do
      {:ok, resolved} = Config.load(%{}, %{"db-max-rows" => true}, %{})
      dump = Config.dump(resolved) |> IO.iodata_to_binary()
      assert dump =~ ~s(db-max-rows = "")
    end

    test "db-tx-end round-trips its value (case 1722)" do
      {:ok, resolved} = Config.load(%{"PGRST_DB_TX_END" => "commit-allow-override"}, nil, %{})
      dump = Config.dump(resolved) |> IO.iodata_to_binary()
      assert dump =~ ~s(db-tx-end = "commit-allow-override")
    end

    test "db-extra-search-path renders empty list as empty string (case 1728)" do
      {:ok, resolved} = Config.load(%{"PGRST_DB_EXTRA_SEARCH_PATH" => ""}, nil, %{})
      dump = Config.dump(resolved) |> IO.iodata_to_binary()
      assert dump =~ ~s(db-extra-search-path = "")
    end

    test "bool keys render bare; default db-plan-enabled is false" do
      {:ok, resolved} = Config.load(%{"PGRST_SERVER_TIMING_ENABLED" => "true"}, nil, %{})
      dump = Config.dump(resolved) |> IO.iodata_to_binary()
      assert dump =~ "server-timing-enabled = true"
      assert dump =~ "db-plan-enabled = false"
    end

    test "dump output is reparse-stable (case 1726)" do
      {:ok, resolved} =
        Config.load(
          %{
            "PGRST_DB_MAX_ROWS" => "1000",
            "PGRST_SERVER_PORT" => "80",
            "PGRST_LOG_LEVEL" => "info"
          },
          nil,
          %{}
        )

      dump1 = Config.dump(resolved) |> IO.iodata_to_binary()

      {:ok, file} = Bier.CLI.ConfigFile.parse(dump1)
      {:ok, resolved2} = Config.load(%{}, file, %{})
      dump2 = Config.dump(resolved2) |> IO.iodata_to_binary()

      assert dump1 == dump2
    end
  end
end
