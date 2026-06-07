defmodule Bier.TestPorts do
  @moduledoc """
  Port helpers shared by tests that boot real Bandit listeners.
  """

  @doc """
  Returns a currently-free TCP port on the loopback interface.

  TOCTOU: there is a tiny window between closing this probe socket and the
  caller binding the port. Acceptable for a single suite run; avoid parallel
  suite runs on one host.
  """
  def free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
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
