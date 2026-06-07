defmodule Bier.TelemetryTest do
  @moduledoc """
  Exercises the `:telemetry` events Bier emits (#26).

  Each test boots its own short-lived Bier instance (a fresh DB introspection +
  Bandit server) and attaches a handler that only forwards events whose
  `metadata.instance` matches that instance's name. Because multiple Bier
  instances can run in one node, every event carries its originating instance
  name — these tests both rely on and verify that.
  """
  use ExUnit.Case, async: false

  # ---- request span --------------------------------------------------------

  test "a request emits [:bier, :request, :start | :stop] tagged with the instance" do
    name = unique_name()
    {base, _pid} = start_listening_instance(name)

    ref = attach([[:bier, :request, :start], [:bier, :request, :stop]], name)

    resp = Req.get!(base <> "/items", retry: false)
    assert resp.status == 200

    assert_receive {^ref, [:bier, :request, :start], start_meas, start_meta}
    assert %{system_time: _, monotonic_time: _} = start_meas
    assert %{instance: ^name, method: "GET", route: "/items"} = start_meta

    assert_receive {^ref, [:bier, :request, :stop], stop_meas, stop_meta}
    assert %{duration: duration} = stop_meas
    assert duration > 0

    assert %{
             instance: ^name,
             method: "GET",
             route: "/items",
             status: 200,
             schema: "test",
             relation: "items"
           } = stop_meta
  end

  # ---- schema-cache load span ----------------------------------------------

  test "boot emits [:bier, :schema_cache, :load, :start | :stop] with a relation count" do
    name = unique_name()

    # Attach BEFORE boot: the load span fires synchronously inside the instance's
    # startup, so the handler must already be in place to observe it.
    ref =
      attach([[:bier, :schema_cache, :load, :start], [:bier, :schema_cache, :load, :stop]], name)

    {:ok, pid} = start_instance(name)
    on_exit(fn -> stop(pid) end)

    assert_receive {^ref, [:bier, :schema_cache, :load, :start], _start_meas, start_meta}
    assert %{instance: ^name, schemas: schemas} = start_meta
    assert is_list(schemas) and schemas != []

    assert_receive {^ref, [:bier, :schema_cache, :load, :stop], stop_meas, stop_meta}
    assert %{duration: duration} = stop_meas
    assert duration > 0
    assert %{instance: ^name, status: :ok, relation_count: relation_count} = stop_meta
    assert relation_count > 0
  end

  # ---- helpers -------------------------------------------------------------

  defp unique_name do
    Module.concat(__MODULE__, "I#{System.unique_integer([:positive])}")
  end

  # Attach a handler forwarding the given events to the test process, but only
  # those originating from `name` so concurrent suites never bleed in. A captured
  # module function (not a closure) keeps telemetry from logging a perf warning.
  defp attach(events, name) do
    ref = make_ref()
    handler_id = {__MODULE__, ref}
    config = %{pid: self(), ref: ref, name: name}

    :telemetry.attach_many(handler_id, events, &__MODULE__.forward/4, config)
    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  @doc false
  def forward(event, measurements, metadata, %{pid: pid, ref: ref, name: name}) do
    if metadata[:instance] == name, do: send(pid, {ref, event, measurements, metadata})
  end

  defp start_instance(name) do
    port = free_port()

    Bier.start_link(
      [name: name, router: [port: port, scheme: :http]] ++ Bier.ConformanceServer.base_opts()
    )
  end

  defp start_listening_instance(name) do
    {:ok, pid} = start_instance(name)
    on_exit(fn -> stop(pid) end)
    port = Bier.Registry.config(name).router[:port]
    wait_until_listening(port)
    {"http://127.0.0.1:#{port}", pid}
  end

  # The instance supervisor is linked to the test process, so it may already be
  # terminating by the time this on_exit cleanup runs; `Supervisor.stop/1` then
  # exits rather than raising. Swallow both so cleanup never fails the test.
  defp stop(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp wait_until_listening(port, retries \\ 100) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 10) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :ok

      {:error, _} when retries > 0 ->
        Process.sleep(20)
        wait_until_listening(port, retries - 1)

      {:error, reason} ->
        raise "instance did not come up on port #{port}: #{inspect(reason)}"
    end
  end
end
