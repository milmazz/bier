defmodule Bier.CLI.DbChannelTest do
  use ExUnit.Case, async: true

  alias Bier.CLI.Config

  test "defaults: db-channel = \"pgrst\", db-channel-enabled = true" do
    {:ok, resolved} = Config.load(%{}, nil, %{})

    assert resolved["db-channel"] == "pgrst"
    assert resolved["db-channel-enabled"] == true
  end

  test "PGRST_DB_CHANNEL / PGRST_DB_CHANNEL_ENABLED are honored and mapped to start opts" do
    {:ok, resolved} =
      Config.load(
        %{"PGRST_DB_CHANNEL" => "my_channel", "PGRST_DB_CHANNEL_ENABLED" => "false"},
        nil,
        %{}
      )

    opts = Config.to_start_opts(resolved)

    assert opts[:db_channel] == "my_channel"
    assert opts[:db_channel_enabled] == false
    assert %Bier.Config{} = Bier.Config.new!(opts, Bier.schema())
  end

  test "--dump-config renders both keys" do
    {:ok, resolved} = Config.load(%{}, nil, %{})
    dump = resolved |> Config.dump() |> IO.iodata_to_binary()

    assert dump =~ ~s(db-channel = "pgrst")
    assert dump =~ "db-channel-enabled = true"
  end
end
