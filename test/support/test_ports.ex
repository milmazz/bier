defmodule Bier.TestPorts do
  @moduledoc """
  Port helpers shared by tests that boot real Bandit listeners.
  """

  # Deliberately BELOW every common ephemeral range (macOS starts at 49152,
  # Linux typically at 32768). Asking the kernel for port 0 hands back a port
  # from that ephemeral range — which is also where every OUTGOING connection
  # this suite makes (Postgrex to 5432, Req and :gen_tcp to the test servers)
  # gets its local port from. That is what made the old implementation flaky:
  # between closing the probe socket and Bandit binding the port, an outgoing
  # connection could be assigned the very same number, and the instance died
  # with :eaddrinuse. Ports down here are never handed out that way, so only
  # a real listener can take one.
  @port_base 20_000
  @port_range 10_000
  @max_attempts 100

  @doc """
  Returns a TCP port on the loopback interface that nothing is listening on
  and that this suite has not already handed out.

  A bind probe alone is not enough to keep two callers apart: the probe
  socket has to be closed before the port is returned (the caller is the one
  that binds it, later), so two concurrent callers would happily probe and
  return the SAME port — which is how a test that needs two ports ended up
  with `admin_server_port` equal to `router[:port]`. Ports are therefore also
  reserved in a registry that lives as long as the suite, and a reserved port
  is never offered again.

  A residual TOCTOU remains against processes OUTSIDE this VM binding the
  same port in the same instant, which in practice means another suite run on
  the same host. Avoid that.
  """
  def free_port, do: claim(reservations(), 0)

  defp claim(_agent, attempts) when attempts >= @max_attempts do
    raise "could not find a free port in #{@port_base}..#{@port_base + @port_range} " <>
            "after #{@max_attempts} attempts"
  end

  defp claim(agent, attempts) do
    port = @port_base + :rand.uniform(@port_range) - 1

    if reserve(agent, port) and bindable?(port) do
      port
    else
      claim(agent, attempts + 1)
    end
  end

  # Serialized through the agent, so exactly one caller can win a given port.
  # A port that turns out not to be bindable stays reserved: it is held by
  # something outside this VM and must not be offered again either.
  defp reserve(agent, port) do
    Agent.get_and_update(agent, fn taken ->
      if MapSet.member?(taken, port),
        do: {false, taken},
        else: {true, MapSet.put(taken, port)}
    end)
  end

  # No `reuseaddr`: the bind must genuinely fail if anything holds the port,
  # since that failure IS the check.
  defp bindable?(port) do
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}]) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      {:error, _taken} ->
        false
    end
  end

  # Lazily started singleton: `Agent.start/2` with a name resolves the race
  # between concurrent first callers into `{:error, {:already_started, pid}}`,
  # so no test_helper wiring is needed. Unlinked on purpose — the first
  # caller's test process must not take the registry down with it when it
  # finishes.
  defp reservations do
    case Agent.start(fn -> MapSet.new() end, name: __MODULE__.Reservations) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @doc """
  Blocks until something is listening on `port`, or raises after exhausting
  `retries`. Each attempt: up to ~10ms connect + 20ms sleep ≈ 30ms; 100 retries
  ≈ 3s ceiling.
  """
  def wait_until_listening(port, retries \\ 100) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 10) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :ok

      {:error, _} when retries > 0 ->
        Process.sleep(20)
        wait_until_listening(port, retries - 1)

      {:error, reason} ->
        raise "port #{port} did not come up: #{inspect(reason)}"
    end
  end
end
