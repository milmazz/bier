defmodule Bier.Wal.EventsHttpTest do
  @moduledoc """
  HTTP-level tests for `table=` subscriptions on the `/events` SSE endpoint:
  WAL events multiplexed with NOTIFY `channel=` subscriptions on the same
  connection, the uniform 404 for unknown/unpublished/RLS-enabled/
  unprivileged tables, per-role column filtering, and content negotiation.

  Reuses Task 5/6's scratch-schema + publication setup shape. Not async:
  real ports, a real replication slot, and DB-global publication state.
  """
  use ExUnit.Case, async: false

  alias Bier.SSETestClient
  alias Bier.TestPorts

  @moduletag :integration

  @schema "wal_http_test"
  # A second scratch schema, deliberately NOT listed in the instance's
  # `db_schemas` below (which is `[@schema]` only), with a table added to
  # the SAME publication — proves the `db_schemas` exposure gate refuses a
  # published, RLS-free, fully-privileged table anyway, purely because its
  # schema isn't one the instance exposes.
  @other_schema "wal_http_other"
  @pub "wal_http_pub"
  @jwt_secret "reallyreallyreallyreallyverysafe"

  setup do
    # A dedicated connection just for setup/teardown DDL and mutations (see
    # Bier.Wal.ConsumerTest's own note on the shared connection budget).
    {:ok, db} =
      Postgrex.start_link(Keyword.put(Bier.ConformanceServer.base_opts(), :pool_size, 1))

    Postgrex.query!(db, "DROP SCHEMA IF EXISTS #{@schema} CASCADE", [])
    Postgrex.query!(db, "CREATE SCHEMA #{@schema}", [])
    Postgrex.query!(db, "CREATE TABLE #{@schema}.orders (id serial PRIMARY KEY, note text)", [])
    Postgrex.query!(db, "CREATE TABLE #{@schema}.hidden (id int)", [])
    Postgrex.query!(db, "CREATE TABLE #{@schema}.locked (id int)", [])
    Postgrex.query!(db, "ALTER TABLE #{@schema}.locked ENABLE ROW LEVEL SECURITY", [])
    Postgrex.query!(db, "DROP SCHEMA IF EXISTS #{@other_schema} CASCADE", [])
    Postgrex.query!(db, "CREATE SCHEMA #{@other_schema}", [])
    Postgrex.query!(db, "CREATE TABLE #{@other_schema}.orders (id serial PRIMARY KEY)", [])
    Postgrex.query!(db, "DROP PUBLICATION IF EXISTS #{@pub}", [])

    Postgrex.query!(
      db,
      "CREATE PUBLICATION #{@pub} FOR TABLE #{@schema}.orders, #{@schema}.locked, " <>
        "#{@other_schema}.orders",
      []
    )

    # postgrest_test_anonymous exists from the fixture chain; grant narrowly
    # (Task 6's shape) so the column-filtering test has something to prove.
    Postgrex.query!(db, "GRANT USAGE ON SCHEMA #{@schema} TO postgrest_test_anonymous", [])

    Postgrex.query!(
      db,
      "GRANT SELECT (id) ON #{@schema}.orders TO postgrest_test_anonymous",
      []
    )

    on_exit(fn ->
      {:ok, cleanup} =
        Postgrex.start_link(Keyword.put(Bier.ConformanceServer.base_opts(), :pool_size, 1))

      Postgrex.query!(cleanup, "DROP PUBLICATION IF EXISTS #{@pub}", [])
      Postgrex.query!(cleanup, "DROP SCHEMA IF EXISTS #{@schema} CASCADE", [])
      Postgrex.query!(cleanup, "DROP SCHEMA IF EXISTS #{@other_schema} CASCADE", [])
    end)

    port = TestPorts.free_port()
    name = :"wal_http_#{System.unique_integer([:positive])}"

    opts =
      Bier.ConformanceServer.base_opts()
      |> Keyword.merge(
        name: name,
        pool_size: 2,
        db_schemas: [@schema],
        db_channel_enabled: false,
        events_publication: @pub,
        events_channels: ["chat"],
        events_heartbeat_interval: 50,
        # Deliberately tiny so the overflow test can force a real
        # events_max_tx_events breach with a handful of rows instead of
        # thousands.
        events_max_tx_events: 5,
        router: [port: port, scheme: :http]
      )

    start_supervised!({Bier, opts})
    TestPorts.wait_until_listening(port)
    wait_wal_streaming(db, name)

    %{db: db, port: port, name: name}
  end

  # Boots a second, auth-configured instance against the same scratch
  # schema/publication (jwt_secret + db_anon_role, as
  # `test/bier/access_log_http_test.exs` boots its auth variant).
  defp start_auth_instance! do
    port = TestPorts.free_port()
    name = :"wal_http_auth_#{System.unique_integer([:positive])}"

    opts =
      Bier.ConformanceServer.base_opts()
      |> Keyword.merge(
        name: name,
        pool_size: 2,
        db_schemas: [@schema],
        db_channel_enabled: false,
        events_publication: @pub,
        events_heartbeat_interval: 50,
        db_anon_role: "postgrest_test_anonymous",
        jwt_secret: @jwt_secret,
        router: [port: port, scheme: :http]
      )

    start_supervised!({Bier, opts})
    TestPorts.wait_until_listening(port)
    %{port: port, name: name}
  end

  # Boots a fourth instance with a deliberately tiny `events_buffer_size` so
  # a couple of inserts force real ring-buffer eviction. This is the only
  # way to manufacture a legitimately "evicted" cursor: an untouched
  # table's history is never stale (Buffer.stale?/3's `nil -> false`
  # clause), so a bare, never-seen cursor alone does NOT produce a reset —
  # only an actual drop or eviction older than the requested cursor does
  # (see `Bier.Wal.BufferTest`'s "a cursor older than a wrapped table's
  # history resets").
  defp start_small_buffer_instance! do
    port = TestPorts.free_port()
    name = :"wal_http_smallbuf_#{System.unique_integer([:positive])}"

    opts =
      Bier.ConformanceServer.base_opts()
      |> Keyword.merge(
        name: name,
        pool_size: 2,
        db_schemas: [@schema],
        db_channel_enabled: false,
        events_publication: @pub,
        events_heartbeat_interval: 50,
        events_buffer_size: 1,
        router: [port: port, scheme: :http]
      )

    start_supervised!({Bier, opts})
    TestPorts.wait_until_listening(port)
    %{port: port, name: name}
  end

  # Boots a third instance with `events_publication` unset entirely (nil) —
  # `events_channels` stays non-empty so `/events` is still routed at all —
  # to prove the "table subscriptions disabled" refusal renders exactly like
  # every other table refusal (Important finding #1).
  defp start_publication_disabled_instance! do
    port = TestPorts.free_port()
    name = :"wal_http_nopub_#{System.unique_integer([:positive])}"

    opts =
      Bier.ConformanceServer.base_opts()
      |> Keyword.merge(
        name: name,
        pool_size: 1,
        db_schemas: [@schema],
        db_channel_enabled: false,
        events_channels: ["chat"],
        router: [port: port, scheme: :http]
      )

    start_supervised!({Bier, opts})
    TestPorts.wait_until_listening(port)
    port
  end

  # Waits for THIS instance's own replication slot specifically (not just
  # "some" consumer streaming): a test may run a second Bier instance
  # concurrently (see `start_auth_instance!/0`), and `Bier.Wal.Consumer`
  # mints its temporary slot name from `phash2(instance_name)`, so scoping by
  # that prefix disambiguates which consumer is actually ready. Firing a
  # mutation before the target instance's slot is streaming would silently
  # drop the event (fire-and-forget by design) and hang the test on
  # heartbeats until ExUnit's timeout.
  defp wait_wal_streaming(db, name) do
    prefix = "bier_#{:erlang.phash2(name)}_%"

    SSETestClient.wait_until(fn ->
      %{rows: rows} =
        Postgrex.query!(
          db,
          """
          SELECT 1 FROM pg_stat_replication sr
          JOIN pg_replication_slots rs ON rs.active_pid = sr.pid
          WHERE rs.slot_name LIKE $1 AND sr.state = 'streaming'
          """,
          [prefix]
        )

      rows != []
    end)
  end

  # A revoked/closed stream still writes the chunked terminator
  # ("0\r\n\r\n") — and possibly an interleaving keepalive comment — before
  # Bandit closes the TCP connection, so a single `:gen_tcp.recv/3` can
  # observe that trailing data instead of the close. Drain until the peer
  # actually closes (or flunk on an unexpected data frame, which would mean
  # the stream kept delivering instead of ending).
  defp assert_socket_closes(sock, deadline \\ 5_000) do
    case :gen_tcp.recv(sock, 0, deadline) do
      {:error, :closed} ->
        :ok

      {:ok, data} ->
        refute data =~ "data: {", "stream kept delivering: #{inspect(data)}"
        assert_socket_closes(sock, deadline)

      {:error, reason} ->
        flunk("expected the socket to close, got #{inspect(reason)}")
    end
  end

  test "insert arrives as a typed frame with an id", %{db: db, port: port} do
    sock = SSETestClient.connect_sse(port, "/events?table=orders")
    SSETestClient.recv_until(sock, ": connected")

    Postgrex.query!(db, "INSERT INTO #{@schema}.orders (note) VALUES ('hello')", [])

    # "data: {" (not "\n\n") — a `: keepalive\n\n` heartbeat frame satisfies
    # "\n\n" too, so on a slow WAL round trip that ambiguous pattern can
    # return a keepalive instead of the event this test is waiting for.
    frame = SSETestClient.recv_until(sock, "data: {")
    assert frame =~ "event: orders\n"
    assert frame =~ ~r/id: [0-9A-F]+\/[0-9A-F]+\.0\n/
    data = frame |> String.split("data: ") |> List.last() |> String.trim() |> JSON.decode!()
    assert data["type"] == "INSERT"
    assert data["schema"] == @schema and data["table"] == "orders"
    assert data["row"]["note"] == "hello"
  end

  test "qualified names and channel+table multiplex on one connection", %{
    db: db,
    port: port,
    name: name
  } do
    sock = SSETestClient.connect_sse(port, "/events?channel=chat&table=#{@schema}.orders")

    SSETestClient.recv_until(sock, ": connected")

    SSETestClient.wait_until(fn -> Bier.Events.Registry.subscriber_count(name, "chat") == 1 end)
    SSETestClient.wait_until_listener_connected(name)
    SSETestClient.notify(name, "chat", ~s({"msg":"hi"}))
    # "data: {" — same ambiguity as above; the chat payload is also a JSON
    # object, so this discriminates from a keepalive just as well.
    chat = SSETestClient.recv_until(sock, "data: {")
    assert chat =~ "event: chat\n"

    Postgrex.query!(db, "INSERT INTO #{@schema}.orders (note) VALUES ('mux')", [])
    wal = SSETestClient.recv_until(sock, "data: {")
    # Qualified subscription => qualified event name: db_schemas is
    # [@schema] here, so @schema IS the default and the canonical name is
    # unqualified (table_names/2 only qualifies when schema != default).
    assert wal =~ "event: orders\n" and wal =~ ~s("note":"mux")
  end

  test "connection: close is scoped to WAL table subscriptions, not pure NOTIFY", %{port: port} do
    # Only a table subscriber can ever be sent `{:bier_wal_recheck}` (see
    # `Bier.Wal.notify_recheck/1` — it targets `table_subscribers/1`
    # specifically), so only a table response needs the connection declared
    # non-keepalive up front. A channel-only response on this same
    # WAL-enabled instance must NOT pay that cost on every reconnect.
    channel_sock = SSETestClient.connect_sse(port, "/events?channel=chat")
    channel_frame = SSETestClient.recv_until(channel_sock, ": connected")
    refute channel_frame =~ ~r/connection:\s*close/i

    table_sock = SSETestClient.connect_sse(port, "/events?table=orders")
    table_frame = SSETestClient.recv_until(table_sock, ": connected")
    assert table_frame =~ ~r/connection:\s*close/i
  end

  test "unknown / unpublished / RLS / unexposed-schema / publication-disabled tables get " <>
         "the uniform 404 payload",
       %{port: port} do
    # {query-string `table=` value, the "schema.table" identifier the error
    # envelope will echo back}. The fourth case is qualified and names a
    # table that IS in the publication, has no RLS, and the connecting role
    # (nil here — falls back to the pool's own privileged user) can select
    # from — the only thing wrong with it is that `@other_schema` isn't in
    # this instance's `db_schemas`, proving that gate on its own.
    cases = [
      {"missing", "#{@schema}.missing"},
      {"hidden", "#{@schema}.hidden"},
      {"locked", "#{@schema}.locked"},
      {"#{@other_schema}.orders", "#{@other_schema}.orders"}
    ]

    bodies =
      for {query, identifier} <- cases do
        resp = Req.get!("http://127.0.0.1:#{port}/events?table=#{query}", retry: false)
        assert resp.status == 404
        # Normalize the "schema.table" identifier out so the envelopes must
        # otherwise be equal (String.replace/3 replaces every occurrence by
        # default).
        resp.body |> Bier.json_library().encode!() |> String.replace(identifier, "T")
      end

    disabled_port = start_publication_disabled_instance!()

    disabled_resp =
      Req.get!("http://127.0.0.1:#{disabled_port}/events?table=orders", retry: false)

    assert disabled_resp.status == 404

    disabled_body =
      disabled_resp.body
      |> Bier.json_library().encode!()
      |> String.replace("#{@schema}.orders", "T")

    assert [b, b, b, b] = bodies, "the four refusals must be indistinguishable"

    assert disabled_body == b,
           "a disabled-publication refusal must be indistinguishable from the others too"
  end

  test "a role with partial column grants sees only its columns", %{db: db} do
    %{port: port, name: auth_name} = start_auth_instance!()
    wait_wal_streaming(db, auth_name)
    token = SSETestClient.sign_hs256(%{"role" => "postgrest_test_anonymous"}, @jwt_secret)

    sock = SSETestClient.connect_sse(port, "/events?table=orders&access_token=#{token}")

    SSETestClient.recv_until(sock, ": connected")
    Postgrex.query!(db, "INSERT INTO #{@schema}.orders (id, note) VALUES (7, 'secret')", [])

    # "data: {" — same keepalive ambiguity as the other WAL-streaming tests.
    frame = SSETestClient.recv_until(sock, "data: {")
    data = frame |> String.split("data: ") |> List.last() |> String.trim() |> JSON.decode!()
    assert data["row"] == %{"id" => 7}
    refute frame =~ "secret"
  end

  test "a JWT carrying a role absent from pg_roles fails without a raw 500", %{} do
    %{port: auth_port} = start_auth_instance!()
    token = SSETestClient.sign_hs256(%{"role" => "wal_http_bogus_role_zzz"}, @jwt_secret)

    resp =
      Req.get!("http://127.0.0.1:#{auth_port}/events?table=orders&access_token=#{token}",
        retry: false
      )

    # `has_column_privilege` raises 42704 (undefined_object) for a role
    # absent from pg_roles; Bier.PgError has no specific 42704 clause so it
    # falls through to the generic SQLSTATE mapping's `true -> 400` branch.
    # Pinned here by direct observation against a live Postgres (verified in
    # the task report), not guessed.
    assert resp.status == 400
    assert resp.body["code"] == "42704"
    assert resp.body["message"] =~ "does not exist"
  end

  test "GET with an Accept that refuses text/event-stream is 406", %{port: port} do
    resp =
      Req.get!("http://127.0.0.1:#{port}/events?table=orders",
        headers: [{"accept", "application/json"}],
        retry: false
      )

    assert resp.status == 406
  end

  test "reconnecting with the last id replays missed events", %{db: db, port: port} do
    sock = SSETestClient.connect_sse(port, "/events?table=orders")
    SSETestClient.recv_until(sock, ": connected")
    Postgrex.query!(db, "INSERT INTO #{@schema}.orders (note) VALUES ('one')", [])
    frame = SSETestClient.recv_until(sock, "data: {")
    [_, id] = Regex.run(~r/id: ([^\n]+)\n/, frame)
    :gen_tcp.close(sock)

    # Missed while disconnected.
    Postgrex.query!(db, "INSERT INTO #{@schema}.orders (note) VALUES ('two')", [])

    sock2 = SSETestClient.connect_sse(port, "/events?table=orders&last_event_id=#{id}")
    replay = SSETestClient.recv_until(sock2, "data: {")

    data = replay |> String.split("data: ") |> List.last() |> String.trim() |> JSON.decode!()
    assert data["row"]["note"] == "two"
  end

  test "an unknown cursor produces an immediate bier:reset", %{db: db} do
    %{port: port, name: name} = start_small_buffer_instance!()
    wait_wal_streaming(db, name)

    # Establish a live spectator and wait for BOTH inserts to have flowed
    # through the consumer before probing for a reset: with
    # `events_buffer_size: 1` the second insert evicts the first, which is
    # what makes any cursor at or before it legitimately "history_evicted".
    spectator = SSETestClient.connect_sse(port, "/events?table=orders")
    SSETestClient.recv_until(spectator, ": connected")
    Postgrex.query!(db, "INSERT INTO #{@schema}.orders (note) VALUES ('evict-1')", [])
    SSETestClient.recv_until(spectator, "data: {")
    Postgrex.query!(db, "INSERT INTO #{@schema}.orders (note) VALUES ('evict-2')", [])
    SSETestClient.recv_until(spectator, "data: {")

    # A real LSN's high 32 bits stay 0 for a local test cluster's lifetime
    # (crossing to 1 needs 4 GiB of WAL past cursor 0), so `0/1.0` compares
    # strictly less than any real post-insert cursor here — genuinely
    # "ancient" rather than merely unfamiliar to the buffer.
    sock = SSETestClient.connect_sse(port, "/events?table=orders&last_event_id=0/1.0")
    frame = SSETestClient.recv_until(sock, "data: {")
    assert frame =~ "event: bier:reset\n"

    data = frame |> String.split("data: ") |> List.last() |> String.trim() |> JSON.decode!()
    assert data["reason"] == "history_evicted"
  end

  test "a malformed cursor is treated as no cursor (live head)", %{db: db, port: port} do
    sock = SSETestClient.connect_sse(port, "/events?table=orders&last_event_id=garbage")
    SSETestClient.recv_until(sock, ": connected")
    Postgrex.query!(db, "INSERT INTO #{@schema}.orders (note) VALUES ('after')", [])
    frame = SSETestClient.recv_until(sock, "data: {")
    assert frame =~ "after"
  end

  test "killing the consumer mid-stream delivers stream_restarted", %{port: port, name: name} do
    sock = SSETestClient.connect_sse(port, "/events?table=orders")
    SSETestClient.recv_until(sock, ": connected")

    [{pid, _}] = Registry.lookup(Bier.Registry, {name, Bier.Wal.Consumer})
    Process.exit(pid, :kill)

    frame = SSETestClient.recv_until(sock, "data: {")
    assert frame =~ "event: bier:reset\n"

    data = frame |> String.split("data: ") |> List.last() |> String.trim() |> JSON.decode!()
    assert data["reason"] == "stream_restarted"
  end

  test "replay does not leak filtered columns for a partial-grant role", %{db: db} do
    %{port: port, name: auth_name} = start_auth_instance!()
    wait_wal_streaming(db, auth_name)
    token = SSETestClient.sign_hs256(%{"role" => "postgrest_test_anonymous"}, @jwt_secret)

    sock = SSETestClient.connect_sse(port, "/events?table=orders&access_token=#{token}")
    SSETestClient.recv_until(sock, ": connected")
    Postgrex.query!(db, "INSERT INTO #{@schema}.orders (id, note) VALUES (101, 'baseline')", [])
    frame = SSETestClient.recv_until(sock, "data: {")
    [_, id] = Regex.run(~r/id: ([^\n]+)\n/, frame)
    :gen_tcp.close(sock)

    # Missed while disconnected — the row a partial-grant role must NOT see
    # `note` for, replayed from the buffer this time instead of delivered
    # live.
    Postgrex.query!(db, "INSERT INTO #{@schema}.orders (id, note) VALUES (102, 'top-secret')", [])

    sock2 =
      SSETestClient.connect_sse(
        port,
        "/events?table=orders&access_token=#{token}&last_event_id=#{id}"
      )

    replay = SSETestClient.recv_until(sock2, "data: {")
    refute replay =~ "top-secret"

    data = replay |> String.split("data: ") |> List.last() |> String.trim() |> JSON.decode!()
    assert data["row"] == %{"id" => 102}
  end

  test "revoking SELECT closes the stream on the next schema reload", %{db: db} do
    %{port: port, name: auth_name} = start_auth_instance!()
    wait_wal_streaming(db, auth_name)
    token = SSETestClient.sign_hs256(%{"role" => "postgrest_test_anonymous"}, @jwt_secret)

    sock = SSETestClient.connect_sse(port, "/events?table=orders&access_token=#{token}")
    SSETestClient.recv_until(sock, ": connected")

    # The fixture role is shared with other tests (e.g. the partial-grant
    # tests above), so the revoke must be undone even if an assertion below
    # fails — a fresh connection, since `db` is only guaranteed alive for
    # the duration of this test process (same convention as setup/0's own
    # on_exit).
    on_exit(fn ->
      {:ok, cleanup} =
        Postgrex.start_link(Keyword.put(Bier.ConformanceServer.base_opts(), :pool_size, 1))

      Postgrex.query!(
        cleanup,
        "GRANT SELECT (id) ON #{@schema}.orders TO postgrest_test_anonymous",
        []
      )
    end)

    # Only column `id` was ever granted (see setup/0); revoking it leaves the
    # role with zero SELECT-able columns on `orders`, so the next reload's
    # recheck must find `Authorize.check/4` failing and close the stream.
    Postgrex.query!(
      db,
      "REVOKE SELECT (id) ON #{@schema}.orders FROM postgrest_test_anonymous",
      []
    )

    :ok = Bier.reload_schema_cache(auth_name)

    # The stream must end rather than keep leaking rows to a subscriber
    # whose privileges were just revoked. Bandit still writes the chunked
    # terminator ("0\r\n\r\n") before closing the TCP connection, so drain
    # that (and any interleaving keepalive) before asserting the eventual
    # `:closed` — a single recv can otherwise observe the terminator instead
    # of the close.
    assert_socket_closes(sock)
  end

  test "a schema reload with unchanged grants leaves the stream open and delivering", %{db: db} do
    %{port: port, name: auth_name} = start_auth_instance!()
    wait_wal_streaming(db, auth_name)
    token = SSETestClient.sign_hs256(%{"role" => "postgrest_test_anonymous"}, @jwt_secret)

    sock = SSETestClient.connect_sse(port, "/events?table=orders&access_token=#{token}")
    SSETestClient.recv_until(sock, ": connected")

    :ok = Bier.reload_schema_cache(auth_name)

    Postgrex.query!(
      db,
      "INSERT INTO #{@schema}.orders (id, note) VALUES (301, 'still-open')",
      []
    )

    # "data: {" — same keepalive ambiguity as the other WAL-streaming tests.
    frame = SSETestClient.recv_until(sock, "data: {")
    data = frame |> String.split("data: ") |> List.last() |> String.trim() |> JSON.decode!()
    assert data["row"] == %{"id" => 301}
  end

  test "a transaction beyond events_max_tx_events resets the live stream and any earlier cursor",
       %{db: db, port: port} do
    sock = SSETestClient.connect_sse(port, "/events?table=orders")
    SSETestClient.recv_until(sock, ": connected")

    # A baseline event before the overflow, whose id becomes a cursor that
    # the overflow must invalidate below.
    Postgrex.query!(db, "INSERT INTO #{@schema}.orders (note) VALUES ('baseline')", [])
    baseline = SSETestClient.recv_until(sock, "data: {")
    [_, id] = Regex.run(~r/id: ([^\n]+)\n/, baseline)

    # One transaction, 20 insert events — well over the cap of 5 set on this
    # instance in setup/0.
    Postgrex.query!(
      db,
      "INSERT INTO #{@schema}.orders (note) SELECT 'bulk' FROM generate_series(1, 20)",
      []
    )

    frame = SSETestClient.recv_until(sock, "data: {")
    assert frame =~ "event: bier:reset\n"

    data = frame |> String.split("data: ") |> List.last() |> String.trim() |> JSON.decode!()
    assert data["reason"] == "transaction_too_large"

    # New wire behavior beyond the live reset above: `Bier.Wal.Consumer`
    # drops the whole table's buffered history on overflow (Task 5,
    # exercised at the registry-message level in Bier.Wal.ConsumerTest), so
    # a reconnect with a cursor from BEFORE the overflow must also get an
    # explicit reset — end to end over the wire — rather than replaying
    # nothing or hanging.
    sock2 = SSETestClient.connect_sse(port, "/events?table=orders&last_event_id=#{id}")
    reset = SSETestClient.recv_until(sock2, "data: {")
    assert reset =~ "event: bier:reset\n"

    reset_data =
      reset |> String.split("data: ") |> List.last() |> String.trim() |> JSON.decode!()

    assert reset_data["reason"] == "history_evicted"
  end
end
