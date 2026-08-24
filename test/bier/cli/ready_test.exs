defmodule Bier.CLI.ReadyTest do
  use ExUnit.Case, async: true

  alias Bier.CLI.Ready

  # Minimal admin-server stand-in: /ready answers with whatever status the
  # test asked for. Lets the client be exercised without booting a full Bier
  # instance (no DB dependency).
  defmodule StubAdmin do
    @behaviour Plug

    @impl Plug
    def init(status), do: status

    @impl Plug
    def call(%Plug.Conn{path_info: ["ready"]} = conn, status) do
      Plug.Conn.send_resp(conn, status, "")
    end

    @impl Plug
    def call(conn, _status), do: Plug.Conn.send_resp(conn, 404, "")
  end

  defp start_stub(status) do
    pid = start_supervised!({Bandit, plug: {StubAdmin, status}, scheme: :http, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  # Delegates to the shared helper rather than re-probing an ephemeral
  # port: those come from the same range the suite's own outgoing
  # connections use, so one could be taken between the probe closing and
  # this instance binding it — an :eaddrinuse that surfaces as an
  # unrelated test failure. `Bier.TestPorts` also reserves what it hands
  # out, so two callers cannot receive the same port.
  defp free_port, do: Bier.TestPorts.free_port()

  test "a 2xx /ready prints OK with the URL and exits 0" do
    port = start_stub(200)
    url = "http://localhost:#{port}/ready"

    assert Ready.check(url) == %{stdout: "OK: #{url}\n", stderr: "", exit: 0}
  end

  test "a non-2xx /ready prints the URL as an error and exits 1" do
    port = start_stub(503)
    url = "http://localhost:#{port}/ready"

    assert Ready.check(url) == %{stdout: "", stderr: "ERROR: #{url}\n", exit: 1}
  end

  test "a refused connection reports it with the URL and exits 1" do
    url = "http://localhost:#{free_port()}/ready"

    assert Ready.check(url) == %{
             stdout: "",
             stderr: "ERROR: connection refused to #{url}\n",
             exit: 1
           }
  end
end
