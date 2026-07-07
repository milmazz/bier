defmodule Bier.DbChannelConfigTest do
  use ExUnit.Case, async: true

  describe "schema defaults" do
    test "db_channel defaults to \"pgrst\" and db_channel_enabled to true (PostgREST parity)" do
      conf = Bier.Config.new!([], Bier.schema())

      assert conf.db_channel == "pgrst"
      assert conf.db_channel_enabled == true
    end

    test "both options are configurable" do
      conf =
        Bier.Config.new!(
          [db_channel: "my_channel", db_channel_enabled: false],
          Bier.schema()
        )

      assert conf.db_channel == "my_channel"
      assert conf.db_channel_enabled == false
    end
  end

  describe "validate_db_channel/1" do
    test "a regular channel name is ok" do
      assert Bier.Config.validate_db_channel("pgrst") == :ok
    end

    test "empty is rejected" do
      assert Bier.Config.validate_db_channel("") ==
               {:error, "db-channel cannot be empty"}
    end

    test "longer than 63 bytes is rejected (Postgres identifier limit)" do
      assert Bier.Config.validate_db_channel(String.duplicate("a", 64)) ==
               {:error, "db-channel cannot exceed 63 bytes"}
    end

    test "a null byte is rejected (Postgrex.Notifications.listen/3 would raise)" do
      assert Bier.Config.validate_db_channel(<<0>>) ==
               {:error, "db-channel cannot contain null bytes"}
    end

    test "new!/2 enforces it" do
      assert_raise ArgumentError, ~r/db-channel cannot be empty/, fn ->
        Bier.Config.new!([db_channel: ""], Bier.schema())
      end
    end

    test "new!/2 enforces the null-byte rejection" do
      assert_raise ArgumentError, ~r/db-channel cannot contain null bytes/, fn ->
        Bier.Config.new!([db_channel: <<0>>], Bier.schema())
      end
    end
  end
end
