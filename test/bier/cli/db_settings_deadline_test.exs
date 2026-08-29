defmodule Bier.CLI.DbSettingsDeadlineTest do
  # No database role setup: these tests point at a socket that is deliberately
  # not Postgres, so they need nothing from the cluster.
  use ExUnit.Case, async: false

  alias Bier.CLI.DbSettings

  # A listener that accepts the TCP connection and then says nothing — a stale
  # port-forward, a wrong-service port, or a Postgres wedged before the startup
  # packet. The TCP probe passes (something *is* listening), so this is the one
  # path that reaches Postgrex's handshake.
  #
  # The listen socket is owned by the test process: when the test ends the
  # socket closes, the pending accept returns `{:error, :closed}`, and the
  # acceptor stops with it. No on_exit is needed, and one that killed the
  # acceptor would be running after both were already gone.
  defp silent_endpoint! do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    spawn(fn ->
      Stream.repeatedly(fn -> :gen_tcp.accept(listen) end)
      |> Enum.take_while(&match?({:ok, _}, &1))
    end)

    port
  end

  defp env_for(port) do
    %{
      "PGHOST" => "127.0.0.1",
      "PGPORT" => Integer.to_string(port),
      "PGDATABASE" => "bier_does_not_exist",
      "PGUSER" => "bier_does_not_exist"
    }
  end

  defp resolved(env) do
    {:ok, resolved} = Bier.CLI.Config.load(env, nil, %{})
    resolved
  end

  test "no transport timeout may outlive the acquisition deadline" do
    env = env_for(5432)
    opts = DbSettings.connect_opts(resolved(env), env)
    deadline = DbSettings.acquire_deadline_ms()

    # `==`, not `<=`: this also pins the merge direction. Under `++` anything
    # connection_opts/2 resolved would have outranked the acquisition bounds.
    assert opts[:timeout] == deadline

    # connect and handshake run serially per endpoint, so it is their sum that
    # has to fit the budget, not each of them individually.
    assert opts[:connect_timeout] + opts[:handshake_timeout] <= deadline

    # Without this the teardown outlives the wait it is tearing down.
    assert opts[:shutdown] == :brutal_kill
  end

  @tag capture_log: true
  test "an endpoint that accepts but never handshakes gives up at the deadline" do
    env = env_for(silent_endpoint!())

    {elapsed_us, result} = :timer.tc(fn -> DbSettings.fetch(resolved(env), env) end)
    elapsed_ms = div(elapsed_us, 1000)

    assert {:error, message} = result

    # Two independent overshoots used to land here, each just past 15s:
    # Postgrex's own 15s handshake timeout, and — once the retry loop had
    # correctly given up at 10s — a `GenServer.stop/1` that sat on the wedged
    # connection until the pool supervisor's 5s child shutdown killed it.
    # Bounding against the module's own budget catches both; a bare 15_000
    # would have let each through by single-digit milliseconds.
    assert elapsed_ms < DbSettings.acquire_deadline_ms() + 2_000,
           "expected the deadline to bound the wait, took #{elapsed_ms}ms"

    # The bare DBConnection message reports the ~1s queue drop of the last
    # checkout, understating a ten-second wait by an order of magnitude.
    assert message =~ ~r/gave up after \d+ms/
    assert message =~ "in-database config (db-config)"
  end
end
