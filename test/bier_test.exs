defmodule BierTest do
  use ExUnit.Case, async: true

  describe "Bier.Config.new!/2 admin-server-port validation" do
    defp opts(extra), do: [name: :"admin_cfg_#{System.unique_integer([:positive])}"] ++ extra

    test "rejects admin_server_port equal to the router port" do
      assert_raise ArgumentError, ~r/admin-server-port cannot be the same as server-port/, fn ->
        Bier.Config.new!(
          opts(router: [port: 3000, scheme: :http], admin_server_port: 3000),
          Bier.schema()
        )
      end
    end

    test "accepts admin_server_port that differs from the router port" do
      conf =
        Bier.Config.new!(
          opts(router: [port: 3000, scheme: :http], admin_server_port: 3001),
          Bier.schema()
        )

      assert conf.admin_server_port == 3001
    end

    test "accepts a nil admin_server_port (default, admin server disabled)" do
      conf = Bier.Config.new!(opts(router: [port: 3000, scheme: :http]), Bier.schema())
      assert conf.admin_server_port == nil
    end
  end
end
