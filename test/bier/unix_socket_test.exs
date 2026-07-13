defmodule Bier.UnixSocketTest do
  @moduledoc """
  Boots a dedicated Bier instance bound to a Unix domain socket
  (server-unix-socket) against the test DB and verifies the socket file gets
  the configured mode (server-unix-socket-mode) and actually serves HTTP.
  Not async: it binds a real listener and runs DB introspection at boot.
  """
  use ExUnit.Case, async: false

  import Bitwise

  @moduletag :integration

  setup do
    path = Path.join(System.tmp_dir!(), "bier_it_#{System.unique_integer([:positive])}.sock")

    opts =
      [
        name: :"unix_socket_it_#{System.unique_integer([:positive])}",
        router: [port: Bier.TestPorts.free_port(), scheme: :http],
        server_unix_socket: path,
        server_unix_socket_mode: "660"
      ] ++ Bier.ConformanceServer.base_opts()

    start_supervised!({Bier, opts})
    wait_until_socket_ready(path)
    on_exit(fn -> File.rm(path) end)

    %{path: path}
  end

  test "the socket file carries the configured mode", %{path: path} do
    # The chmod runs right after the listener binds; poll briefly so the
    # ready-to-connect signal racing the chmod cannot flake the assertion.
    assert wait_for_mode(path, 0o660), "socket mode never became 660"
  end

  test "the instance serves HTTP over the socket", %{path: path} do
    {:ok, sock} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false])

    :ok =
      :gen_tcp.send(sock, "GET / HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n")

    assert {:ok, "HTTP/1.1 200" <> _rest} = :gen_tcp.recv(sock, 0, 5_000)
    :gen_tcp.close(sock)
  end

  defp wait_until_socket_ready(path, retries \\ 100) do
    case :gen_tcp.connect({:local, path}, 0, [:binary, active: false]) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :ok

      {:error, _reason} when retries > 0 ->
        Process.sleep(20)
        wait_until_socket_ready(path, retries - 1)

      {:error, reason} ->
        raise "socket #{path} never became ready: #{inspect(reason)}"
    end
  end

  defp wait_for_mode(path, mode, retries \\ 50) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: actual}} when (actual &&& 0o777) == mode ->
        true

      _other when retries > 0 ->
        Process.sleep(20)
        wait_for_mode(path, mode, retries - 1)

      _other ->
        false
    end
  end
end
