defmodule Bier.AdminServerTest do
  @moduledoc """
  Boots a dedicated Bier instance with an admin server against the test DB and
  exercises the health endpoints over HTTP. Not async: it binds real ports and
  runs DB introspection at boot.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  setup do
    api_port = free_port()
    admin_port = free_port()

    opts =
      [
        name: :"admin_it_#{System.unique_integer([:positive])}",
        router: [port: api_port, scheme: :http],
        admin_server_port: admin_port
      ] ++ Bier.ConformanceServer.base_opts()

    start_supervised!({Bier, opts})
    wait_until_listening(admin_port)

    %{admin_port: admin_port}
  end

  test "GET /live returns 200", %{admin_port: admin_port} do
    resp = Req.get!("http://127.0.0.1:#{admin_port}/live", retry: false)
    assert resp.status == 200
  end

  test "GET /ready returns 200 once the schema cache is populated", %{admin_port: admin_port} do
    resp = Req.get!("http://127.0.0.1:#{admin_port}/ready", retry: false)
    assert resp.status == 200
  end

  test "unknown admin paths return 404", %{admin_port: admin_port} do
    resp = Req.get!("http://127.0.0.1:#{admin_port}/nope", retry: false)
    assert resp.status == 404
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
        raise "admin server did not come up on port #{port}: #{inspect(reason)}"
    end
  end
end
