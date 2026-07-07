defmodule Bier.PoolMonitorTest do
  @moduledoc """
  Exercises the `[:bier, :pool, :status]` gauge sampling (#36). The first
  sample is emitted synchronously as the monitor starts, so a handler attached
  before boot observes the pool without waiting a poll interval.
  """
  use ExUnit.Case, async: false

  test "boot emits [:bier, :pool, :status] with the pool gauges" do
    name = unique_name()

    # Attach BEFORE boot: the monitor emits its first sample during startup.
    ref = attach([[:bier, :pool, :status]], name)

    {:ok, pid} = start_instance(name)
    on_exit(fn -> stop(pid) end)

    assert_receive {^ref, [:bier, :pool, :status], measurements, %{instance: ^name}}

    assert %{max: max, available: available, waiting: waiting} = measurements
    assert max == Bier.Registry.config(name).pool_size
    assert is_integer(available) and available >= 0 and available <= max
    assert is_integer(waiting) and waiting >= 0
  end

  test "an unreachable pool skips the sample and keeps the monitor alive" do
    name = unique_name()
    ref = attach([[:bier, :pool, :status]], name)

    # No Postgrex pool is registered under this name: the sample call exits,
    # which the monitor swallows — no event, no crash.
    conf = %Bier.Config{name: name, pool_size: 3}
    {:ok, pid} = Bier.PoolMonitor.start_link(conf)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    refute_receive {^ref, [:bier, :pool, :status], _, _}, 200
    assert Process.alive?(pid)
  end

  # ---- helpers (same pattern as Bier.TelemetryTest) -------------------------

  defp unique_name do
    Module.concat(__MODULE__, "I#{System.unique_integer([:positive])}")
  end

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

  # The instance supervisor is linked to the test process, so it may already be
  # terminating by the time this on_exit cleanup runs; swallow the exit.
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
end
