defmodule Bier.CLI.DbSettingsDeadlineTest do
  # Points at sockets that are deliberately not Postgres, plus one proxy in
  # front of the real cluster. `async: false` because the proxies bind ports and
  # the end-to-end cases are wall-clock assertions.
  use ExUnit.Case, async: false

  alias Bier.CLI.DbSettings

  defp pg_env(port) do
    %{
      "PGHOST" => "127.0.0.1",
      "PGPORT" => Integer.to_string(port),
      "PGDATABASE" => System.get_env("PGDATABASE") || "bier_test",
      "PGUSER" => System.get_env("PGUSER") || System.get_env("USER") || "postgres"
    }
    |> then(fn env ->
      case System.get_env("PGPASSWORD") do
        nil -> env
        pw -> Map.put(env, "PGPASSWORD", pw)
      end
    end)
  end

  defp resolved(env) do
    {:ok, resolved} = Bier.CLI.Config.load(env, nil, %{})
    resolved
  end

  defp listen! do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    {listen, port}
  end

  # Accepts the TCP connection and then says nothing — a stale port-forward, a
  # wrong-service port, a Postgres wedged before the startup packet. The probe
  # passes, so this is the shape that reaches Postgrex's handshake.
  #
  # The listen socket is owned by the test process, so when the test ends the
  # socket closes, the pending accept returns `{:error, :closed}`, and the
  # acceptor stops with it.
  defp silent_endpoint! do
    {listen, port} = listen!()

    spawn(fn ->
      Stream.repeatedly(fn -> :gen_tcp.accept(listen) end)
      |> Enum.take_while(&match?({:ok, _}, &1))
    end)

    port
  end

  # Proxies to the real cluster until it sees the config query go out, then
  # goes silent with both sockets open: the handshake completes, the query never
  # answers. Structurally different from the silent endpoint, and the only shape
  # that exercises the query bound.
  defp stalling_endpoint! do
    {listen, port} = listen!()
    upstream = String.to_integer(System.get_env("PGPORT") || "5432")

    spawn(fn -> accept_loop(listen, upstream) end)

    port
  end

  defp accept_loop(listen, upstream) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        {:ok, server} = :gen_tcp.connect(~c"127.0.0.1", upstream, [:binary, active: false])
        spawn(fn -> pump(server, client, :from_server) end)
        spawn(fn -> pump(client, server, :from_client) end)
        accept_loop(listen, upstream)

      {:error, _closed} ->
        :ok
    end
  end

  defp pump(from, to, direction) do
    case :gen_tcp.recv(from, 0, 60_000) do
      {:ok, data} ->
        stall? =
          direction == :from_client and
            :binary.match(data, "pg_db_role_setting") != :nomatch

        unless stall? do
          :gen_tcp.send(to, data)
          pump(from, to, direction)
        end

      {:error, _} ->
        :ok
    end
  end

  describe "acquisition bounds" do
    test "no transport bound may outlive the deadline, and the teardown cannot either" do
      env = pg_env(5432)
      opts = DbSettings.connect_opts(resolved(env), env)
      deadline = DbSettings.acquire_deadline_ms()

      # connect and handshake run serially, so it is their sum that has to fit.
      assert opts[:connect_timeout] + opts[:handshake_timeout] <= deadline

      # The handshake window carries the real work — TLS, auth, role GUCs, and
      # the pg_type bootstrap on a cold process — so it must not be the smaller
      # half. An even split rejected servers that merely handshake slowly.
      assert opts[:handshake_timeout] > opts[:connect_timeout]

      # Not a query bound (db_connection reads that from the call opts); this
      # one bounds the cancel_request the disconnect path opens on a fresh
      # socket, which otherwise ran on the 15s default after the query had
      # already been cut off at the budget.
      assert opts[:timeout] <= deadline

      # A connection wedged mid-handshake ignores a graceful stop, so without
      # this the teardown outlives the wait it is tearing down. This assertion,
      # not the wall-clock one below, is what reliably pins it.
      assert opts[:shutdown] == :brutal_kill
    end
  end

  describe "endpoints that never answer" do
    @tag capture_log: true
    test "one that accepts but never handshakes gives up at the deadline" do
      env = pg_env(silent_endpoint!())

      {elapsed_us, result} = :timer.tc(fn -> DbSettings.fetch(resolved(env), env) end)
      elapsed_ms = div(elapsed_us, 1000)

      assert {:error, message} = result
      assert message =~ ~r/gave up after \d+ms/
      assert message =~ "in-database config (db-config)"

      # Pre-fix this ran to ~15s on Postgrex's own handshake default.
      assert elapsed_ms < DbSettings.acquire_deadline_ms() + 2_500,
             "expected the deadline to bound the wait, took #{elapsed_ms}ms"
    end

    @tag capture_log: true
    test "one that completes the handshake and then stalls is bounded too" do
      env = pg_env(stalling_endpoint!())

      {elapsed_us, result} = :timer.tc(fn -> DbSettings.fetch(resolved(env), env) end)
      elapsed_ms = div(elapsed_us, 1000)

      assert {:error, _message} = result

      # This shape had no coverage and no bound: db_connection reads :timeout
      # and :checkout_retries from the call opts, so one query ran on the 15s
      # default and was retried three more times — 60s against a 10s budget.
      # Measured 60090ms before, 12006ms after.
      assert elapsed_ms < DbSettings.acquire_deadline_ms() + 2_500,
             "expected the deadline to bound the wait, took #{elapsed_ms}ms"
    end
  end
end
