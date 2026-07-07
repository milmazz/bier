defmodule Bier.SchemaCacheReloadTest do
  @moduledoc """
  Boots a dedicated Bier instance against the test DB and exercises the
  programmatic schema-cache reload (`Bier.reload_schema_cache/1`) end to end.
  Not async: it binds a real port and runs DB introspection at boot.
  """
  use ExUnit.Case, async: false

  alias Bier.TestPorts

  @moduletag :integration

  defp start_instance do
    port = TestPorts.free_port()
    name = :"reload_it_#{System.unique_integer([:positive])}"

    opts =
      [name: name, router: [port: port, scheme: :http]] ++
        Bier.ConformanceServer.base_opts()

    start_supervised!({Bier, opts})
    TestPorts.wait_until_listening(port)
    %{name: name, port: port}
  end

  test "reload_schema_cache/1 picks up a table created after boot" do
    %{name: name} = start_instance()
    pool = Bier.Registry.via(name, Postgrex)
    table = "reload_probe_#{System.unique_integer([:positive])}"

    {:ok, _} = Postgrex.query(pool, "CREATE TABLE test.#{table} (id integer)", [])
    # The bier_test DB is dropped and recreated by every `mix test` run, so a
    # table leaked by a mid-test crash cannot outlive this run.

    refute Map.has_key?(Bier.SchemaCache.relations(name), {"test", table})

    assert :ok = Bier.reload_schema_cache(name)

    assert Map.has_key?(Bier.SchemaCache.relations(name), {"test", table})

    {:ok, _} = Postgrex.query(pool, "DROP TABLE test.#{table}", [])
  end

  test "returns an error for a name that is not a running instance (old cache untouched)" do
    name = :"never_started_#{System.unique_integer([:positive])}"

    assert {:error, :unknown_instance} = Bier.reload_schema_cache(name)
    refute Bier.SchemaCache.loaded?(name)
  end
end
