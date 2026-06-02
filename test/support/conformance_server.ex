defmodule Bier.ConformanceServer do
  @moduledoc """
  Boots ONE shared Bier instance for the conformance suite and exposes its
  base URL. Started in test_helper.exs before ExUnit.start/1.
  """

  @instance __MODULE__.Instance
  @key {__MODULE__, :base_url}

  @doc "Start the shared instance on a free port and remember its base URL."
  def start! do
    if :persistent_term.get(@key, nil) != nil do
      raise "ConformanceServer.start!/0 called more than once — call it only from test_helper.exs"
    end

    port = free_port()
    {:ok, _pid} = Bier.start_link(name: @instance, router: [port: port, scheme: :http])
    base = "http://127.0.0.1:#{port}"
    wait_until_listening(port)
    :persistent_term.put(@key, base)
    base
  end

  @doc "Base URL of the shared instance (e.g. \"http://127.0.0.1:54321\")."
  def base_url, do: :persistent_term.get(@key)

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(sock)
    # TOCTOU: tiny window between closing this probe socket and Bandit binding.
    # Acceptable for a single suite run; avoid parallel suite runs on one host.
    :gen_tcp.close(sock)
    port
  end

  defp wait_until_listening(port, retries \\ 100) do
    # Each attempt: up to ~10ms connect + 20ms sleep ≈ 30ms; 100 retries ≈ 3s ceiling.
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 10) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :ok

      {:error, _} when retries > 0 ->
        Process.sleep(20)
        wait_until_listening(port, retries - 1)

      {:error, reason} ->
        raise "Bier conformance server did not come up on port #{port}: #{inspect(reason)}"
    end
  end
end
