defmodule Bier.RouterModuleCollisionTest do
  @moduledoc """
  Boots real Bier instances against the test DB to exercise the router-module
  uniqueness guard in `Bier.start_link/1`. Not async: it binds real ports and
  runs DB introspection at boot.
  """
  use ExUnit.Case, async: false

  alias Bier.TestPorts

  @moduletag :integration

  # The module-alias and plain-atom shapes of the same dotted name are distinct
  # atoms (distinct registry keys) that concat to the SAME router module.
  @alias_name Bier.RouterCollisionIT
  @plain_name :"Bier.RouterCollisionIT"

  defp opts(name) do
    [name: name, router: [port: TestPorts.free_port(), scheme: :http]] ++
      Bier.ConformanceServer.base_opts()
  end

  test "colliding name shapes produce the same router module" do
    assert Module.concat(@alias_name, Router) == Module.concat(@plain_name, Router)
  end

  test "starting an instance whose router module is owned by a live instance raises" do
    start_supervised!({Bier, opts(@alias_name)})

    err = assert_raise(ArgumentError, fn -> Bier.start_link(opts(@plain_name)) end)

    assert err.message =~ ~s(:"Bier.RouterCollisionIT")
    assert err.message =~ "Bier.RouterCollisionIT.Router"
    assert err.message =~ "running instance Bier.RouterCollisionIT"
  end

  test "restarting the same named instance boots although its router module already exists" do
    name = Bier.RouterRestartIT
    port = TestPorts.free_port()

    opts =
      [name: name, router: [port: port, scheme: :http]] ++ Bier.ConformanceServer.base_opts()

    start_supervised!({Bier, opts})
    # The router module is created by HttpServerStarter's handle_continue, so
    # wait for the listener before asserting the module exists.
    TestPorts.wait_until_listening(port)
    assert Code.ensure_loaded?(Module.concat(name, Router))

    :ok = stop_supervised!(name)

    # The module is still defined in the VM, but no live instance owns it — the
    # guard keys on the registry, so the same name must boot again.
    start_supervised!({Bier, opts})
    TestPorts.wait_until_listening(port)
  end
end
