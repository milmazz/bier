defmodule Bier.SchemaCacheListenerTest do
  @moduledoc """
  Boots dedicated Bier instances against the test DB and exercises the
  LISTEN/NOTIFY schema-cache reload end to end. Every instance gets its own
  unique notification channel so these tests never signal the shared
  conformance instance (which listens on the default "pgrst").

  Not async: binds real ports and runs DB introspection at boot.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Bier.TestPorts

  @moduletag :integration

  @load_stop [:bier, :schema_cache, :load, :stop]

  defp start_instance(extra_opts) do
    port = TestPorts.free_port()
    name = :"listener_it_#{System.unique_integer([:positive])}"

    opts =
      [name: name, router: [port: port, scheme: :http]] ++
        extra_opts ++ Bier.ConformanceServer.base_opts()

    start_supervised!({Bier, opts})
    TestPorts.wait_until_listening(port)
    %{name: name, port: port}
  end

  defp unique_channel, do: "bier_reload_test_#{System.unique_integer([:positive])}"

  defp notify(name, channel, payload) do
    {:ok, _} =
      Postgrex.query(
        Bier.Registry.via(name, Postgrex),
        "SELECT pg_notify($1, $2)",
        [channel, payload]
      )
  end

  defp attach_load_stop do
    ref = :telemetry_test.attach_event_handlers(self(), [@load_stop])
    on_exit(fn -> :telemetry.detach(ref) end)
    ref
  end

  # The listener subscribes in a handle_continue after its init returns, so a
  # NOTIFY fired immediately after boot can race the LISTEN and be lost
  # forever (notifications are not queued server-side). Poll the listener's
  # state until the subscription is up; only then is a NOTIFY guaranteed to
  # be delivered. (`:sys.get_state/1` blocks while the continue runs, so one
  # probe usually suffices.)
  defp await_listener_connected(name) do
    pid = Bier.Registry.whereis(name, Bier.SchemaCacheListener)
    assert is_pid(pid), "no schema-cache listener registered for #{inspect(name)}"
    await_subscription(pid, 200)
  end

  defp await_subscription(pid, attempts) do
    cond do
      :sys.get_state(pid).notifications != nil ->
        :ok

      attempts > 0 ->
        Process.sleep(25)
        await_subscription(pid, attempts - 1)

      true ->
        flunk("listener never established its LISTEN subscription")
    end
  end

  test "NOTIFY 'reload schema' makes a table created after boot servable" do
    channel = unique_channel()
    %{name: name, port: port} = start_instance(db_channel: channel)

    await_listener_connected(name)

    pool = Bier.Registry.via(name, Postgrex)
    table = "notify_probe_#{System.unique_integer([:positive])}"
    {:ok, _} = Postgrex.query(pool, "CREATE TABLE test.#{table} (id integer)", [])

    {:ok, _} =
      Postgrex.query(
        pool,
        "GRANT SELECT ON test.#{table} TO postgrest_test_anonymous",
        []
      )

    # Stale cache: the API does not know the table yet.
    assert Req.get!("http://127.0.0.1:#{port}/#{table}", retry: false).status == 404

    ref = attach_load_stop()
    notify(name, channel, "reload schema")
    assert_receive {@load_stop, ^ref, %{duration: _}, %{instance: ^name}}, 5_000

    assert Req.get!("http://127.0.0.1:#{port}/#{table}", retry: false).status == 200

    {:ok, _} = Postgrex.query(pool, "DROP TABLE test.#{table}", [])
  end

  test "an empty payload also reloads (PostgREST: empty = schema + config)" do
    channel = unique_channel()
    %{name: name} = start_instance(db_channel: channel)
    await_listener_connected(name)

    ref = attach_load_stop()
    notify(name, channel, "")
    assert_receive {@load_stop, ^ref, %{duration: _}, %{instance: ^name}}, 5_000
  end

  test "'reload config' is a logged no-op and does not reload" do
    channel = unique_channel()
    %{name: name} = start_instance(db_channel: channel)
    await_listener_connected(name)

    ref = attach_load_stop()

    log =
      capture_log(fn ->
        notify(name, channel, "reload config")
        refute_receive {@load_stop, ^ref, _, %{instance: ^name}}, 1_000
      end)

    assert log =~ "reload config"
  end

  test "an unknown payload is ignored" do
    channel = unique_channel()
    %{name: name} = start_instance(db_channel: channel)
    await_listener_connected(name)

    ref = attach_load_stop()
    notify(name, channel, "reload everything!!")
    refute_receive {@load_stop, ^ref, _, %{instance: ^name}}, 1_000
  end

  test "db_channel_enabled: false starts no listener" do
    %{name: name} = start_instance(db_channel_enabled: false)

    assert Bier.Registry.whereis(name, Bier.SchemaCacheListener) == nil
  end

  test "a NOTIFY burst is coalesced into few reloads" do
    channel = unique_channel()
    %{name: name} = start_instance(db_channel: channel)
    await_listener_connected(name)

    ref = attach_load_stop()

    # Ten separate queries = ten separate transactions = ten real
    # notifications. (A single `SELECT pg_notify(...) FROM generate_series`
    # would NOT work: Postgres dedupes identical channel+payload
    # notifications within one transaction down to a single delivery.)
    for _ <- 1..10, do: notify(name, channel, "reload schema")

    assert_receive {@load_stop, ^ref, _, %{instance: ^name}}, 5_000

    # Soft upper bound: delivery timing can split the burst, but 10 separate
    # reloads would mean coalescing is broken.
    extra =
      Enum.count(1..9, fn _ ->
        receive do
          {@load_stop, ^ref, _, %{instance: ^name}} -> true
        after
          300 -> false
        end
      end)

    assert extra <= 4
  end
end
