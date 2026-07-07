defmodule Bier.CLI.BootValidationTest do
  use ExUnit.Case, async: true

  alias Bier.CLI
  alias Bier.CLI.Config

  # The parse layer (PostgREST parity, pinned by --dump-config conformance
  # cases) accepts values Bier's boot schema rejects — e.g. db-max-rows=0 or a
  # non-positive server-port. These tests pin the boot-time gate that turns
  # those into a clean {:error, message} instead of a raised
  # MatchError/ArgumentError.

  describe "Config.validated_start_opts/1" do
    test "a valid resolve returns the same options as to_start_opts/1" do
      {:ok, resolved} =
        Config.load(%{"PGRST_DB_SCHEMAS" => "api", "PGRST_SERVER_PORT" => "4000"}, nil, %{})

      assert Config.validated_start_opts(resolved) == {:ok, Config.to_start_opts(resolved)}
    end

    test "db-max-rows = 0 is fatal at boot (schema :pos_integer means >= 1)" do
      {:ok, resolved} = Config.load(%{"PGRST_DB_MAX_ROWS" => "0"}, nil, %{})

      assert {:error, message} = Config.validated_start_opts(resolved)
      assert message =~ "db_max_rows"
      # CLI fatals are one stderr line even for multi-line NimbleOptions errors.
      refute message =~ "\n"
    end

    test "server-port = 0 is fatal at boot" do
      {:ok, resolved} = Config.load(%{"PGRST_SERVER_PORT" => "0"}, nil, %{})

      assert {:error, message} = Config.validated_start_opts(resolved)
      assert message =~ ":port"
    end

    test "a negative server-port is fatal at boot" do
      {:ok, resolved} = Config.load(%{"PGRST_SERVER_PORT" => "-1"}, nil, %{})

      assert {:error, message} = Config.validated_start_opts(resolved)
      assert message =~ ":port"
    end
  end

  describe "Bier.Config.new/2 (non-raising variant)" do
    test "returns {:ok, %Bier.Config{}} for valid options" do
      assert {:ok, %Bier.Config{}} = Bier.Config.new([], Bier.schema())
    end

    test "returns the schema error message instead of raising" do
      assert {:error, message} = Bier.Config.new([db_max_rows: 0], Bier.schema())
      assert message =~ "db_max_rows"
    end

    test "returns the semantic validator message instead of raising" do
      assert Bier.Config.new([jwt_secret: "short_secret"], Bier.schema()) ==
               {:error, "The JWT secret must be at least 32 characters long."}
    end

    test "new!/2 raises ArgumentError with the same message" do
      assert_raise ArgumentError, ~r/db_max_rows/, fn ->
        Bier.Config.new!([db_max_rows: 0], Bier.schema())
      end
    end
  end

  describe "the standalone (BIER_STANDALONE) boot path" do
    test "a value the parse layer tolerates but the boot schema rejects is a fatal message" do
      env = %{"BIER_STANDALONE" => "1", "PGRST_DB_MAX_ROWS" => "0"}

      assert {:error, message} = Bier.Application.standalone_spec(env)
      assert message =~ "db_max_rows"
    end

    test "a non-positive server-port is a fatal message" do
      env = %{"BIER_STANDALONE" => "1", "PGRST_SERVER_PORT" => "0"}

      assert {:error, message} = Bier.Application.standalone_spec(env)
      assert message =~ ":port"
    end
  end

  describe "--dump-config parity (validation happens at boot, not at parse/dump)" do
    test "--dump-config still dumps db-max-rows = 0 and exits 0" do
      result = CLI.run(["--dump-config"], env: %{"PGRST_DB_MAX_ROWS" => "0"})

      assert result.exit == 0
      assert IO.iodata_to_binary(result.stdout) =~ "db-max-rows = 0"
      assert IO.iodata_to_binary(result.stderr) == ""
    end

    test "--dump-config still dumps a non-positive server-port and exits 0" do
      result = CLI.run(["--dump-config"], env: %{"PGRST_SERVER_PORT" => "-1"})

      assert result.exit == 0
      assert IO.iodata_to_binary(result.stdout) =~ "server-port = -1"
    end

    test "the CLI core still returns a boot directive for such values" do
      assert {:boot, resolved} = CLI.run([], env: %{"PGRST_DB_MAX_ROWS" => "0"})
      assert resolved["db-max-rows"] == 0
      assert {:error, _message} = Config.validated_start_opts(resolved)
    end
  end
end
