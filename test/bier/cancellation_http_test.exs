defmodule Bier.CancellationHttpTest do
  @moduledoc """
  Boots a dedicated Bier instance against a `cancellation_it` schema whose
  relations sleep server-side (`pg_sleep`), then closes the raw client socket
  mid-query and asserts the backend query is cancelled — it must disappear
  from `pg_stat_activity` well before its 10s natural completion.

  `pool_size: 1` makes connection leaks observable: after a cancellation the
  single pool connection must come back clean for the next request.
  Not async: real ports + DB.
  """
  use ExUnit.Case, async: false

  import Bier.SSETestClient, only: [wait_until: 1, wait_until: 2]

  alias Bier.TestPorts

  @moduletag :integration

  @schema "cancellation_it"
  @nap_marker ~s("cancellation_it"."nap")

  setup_all do
    base = Bier.ConformanceServer.base_opts()

    db =
      start_supervised!(
        {Postgrex,
         hostname: base[:hostname],
         port: base[:port],
         database: base[:database],
         username: base[:username],
         password: base[:password]}
      )

    Postgrex.query!(db, "DROP SCHEMA IF EXISTS #{@schema} CASCADE", [])
    Postgrex.query!(db, "CREATE SCHEMA #{@schema}", [])
    Postgrex.query!(db, "CREATE VIEW #{@schema}.nap AS SELECT 1 AS id FROM pg_sleep(10)", [])
    Postgrex.query!(db, "CREATE VIEW #{@schema}.ok AS SELECT 1 AS id", [])

    Postgrex.query!(
      db,
      "CREATE FUNCTION #{@schema}.nap_fn() RETURNS integer " <>
        "LANGUAGE sql AS 'SELECT 1 FROM pg_sleep(10)'",
      []
    )

    Postgrex.query!(db, "CREATE TABLE #{@schema}.items (id integer PRIMARY KEY)", [])
    Postgrex.query!(db, "INSERT INTO #{@schema}.items VALUES (1)", [])

    Postgrex.query!(
      db,
      "CREATE FUNCTION #{@schema}.nap_trigger() RETURNS trigger LANGUAGE plpgsql " <>
        "AS $$ BEGIN PERFORM pg_sleep(10); RETURN OLD; END $$",
      []
    )

    Postgrex.query!(
      db,
      "CREATE TRIGGER items_nap BEFORE DELETE ON #{@schema}.items " <>
        "FOR EACH ROW EXECUTE FUNCTION #{@schema}.nap_trigger()",
      []
    )

    %{db: db}
  end

  setup ctx do
    base = Bier.ConformanceServer.base_opts()
    port = TestPorts.free_port()
    name = :"cancellation_http_#{System.unique_integer([:positive])}"

    opts = [
      name: name,
      router: [port: port, scheme: :http],
      hostname: base[:hostname],
      port: base[:port],
      database: base[:database],
      username: base[:username],
      password: base[:password],
      pool_size: 1,
      db_schemas: [@schema],
      server_timing_enabled: true,
      cancel_on_disconnect: Map.get(ctx, :cancel_on_disconnect, true)
    ]

    start_supervised!({Bier, opts})
    TestPorts.wait_until_listening(port)

    %{port: port, name: name}
  end

  test "closing the client socket cancels the in-flight read query", ctx do
    ref = :telemetry_test.attach_event_handlers(self(), [[:bier, :query, :cancelled]])
    name = ctx.name

    sock =
      send_request(ctx.port, "GET /nap HTTP/1.1\r\nhost: 127.0.0.1\r\naccept: */*\r\n\r\n")

    wait_until(fn -> active_queries(ctx.db, @nap_marker) == 1 end)
    :ok = :gen_tcp.close(sock)

    # 3s budget << the view's 10s pg_sleep: only a real backend cancel passes.
    wait_until(fn -> active_queries(ctx.db, @nap_marker) == 0 end, 300)

    assert_receive {[:bier, :query, :cancelled], ^ref, %{count: 1}, %{instance: ^name}}, 1_000

    # The (single) pool connection must come back clean after the cancel.
    wait_until(
      fn ->
        match?(
          {:ok, %{status: 200}},
          Req.get("http://127.0.0.1:#{ctx.port}/ok", retry: false)
        )
      end,
      500
    )
  end

  test "closing the client socket cancels the in-flight RPC call", ctx do
    sock =
      send_request(
        ctx.port,
        "POST /rpc/nap_fn HTTP/1.1\r\nhost: 127.0.0.1\r\naccept: */*\r\n" <>
          "content-type: application/json\r\ncontent-length: 2\r\n\r\n{}"
      )

    wait_until(fn -> active_queries(ctx.db, "nap_fn") == 1 end)
    :ok = :gen_tcp.close(sock)

    wait_until(fn -> active_queries(ctx.db, "nap_fn") == 0 end, 300)
  end

  test "closing the client socket cancels the in-flight mutation and rolls it back", ctx do
    sock =
      send_request(
        ctx.port,
        "DELETE /items?id=eq.1 HTTP/1.1\r\nhost: 127.0.0.1\r\naccept: */*\r\n\r\n"
      )

    marker = ~s("cancellation_it"."items")
    wait_until(fn -> active_queries(ctx.db, marker) == 1 end)
    :ok = :gen_tcp.close(sock)

    wait_until(fn -> active_queries(ctx.db, marker) == 0 end, 300)

    # The cancelled transaction must have rolled back: the row survives.
    %Postgrex.Result{rows: [[1]]} =
      Postgrex.query!(ctx.db, "SELECT count(*) FROM #{@schema}.items WHERE id = 1", [])
  end

  @tag cancel_on_disconnect: false
  test "cancel_on_disconnect: false leaves the backend query running", ctx do
    sock =
      send_request(ctx.port, "GET /nap HTTP/1.1\r\nhost: 127.0.0.1\r\naccept: */*\r\n\r\n")

    wait_until(fn -> active_queries(ctx.db, @nap_marker) == 1 end)
    :ok = :gen_tcp.close(sock)

    # With cancellation opted out, the disconnect must NOT touch the query.
    Process.sleep(1_500)
    assert active_queries(ctx.db, @nap_marker) == 1
  end

  test "Server-Timing phases measured under the watcher still reach the header", ctx do
    # The executor runs inside the watcher task; its :plan/:transaction phases
    # must be merged back into the request process or the header loses them.
    resp = Req.get!("http://127.0.0.1:#{ctx.port}/ok", retry: false)

    assert resp.status == 200
    [timing] = resp.headers["server-timing"]
    assert [_, dur] = Regex.run(~r/transaction;dur=([\d.]+)/, timing)
    assert String.to_float(dur) > 0.0
  end

  # ---- helpers -------------------------------------------------------------

  defp send_request(port, request) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)
    :ok = :gen_tcp.send(sock, request)
    sock
  end

  # Count backend processes actively running a query that mentions `marker`.
  # Our own polling backend is excluded by pid; idle pool connections are
  # excluded by state.
  defp active_queries(db, marker) do
    %Postgrex.Result{rows: [[n]]} =
      Postgrex.query!(
        db,
        "SELECT count(*) FROM pg_stat_activity " <>
          "WHERE state = 'active' AND pid <> pg_backend_pid() AND query LIKE $1",
        ["%" <> marker <> "%"]
      )

    n
  end
end
