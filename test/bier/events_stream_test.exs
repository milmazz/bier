defmodule Bier.EventsStreamTest do
  @moduledoc """
  Streaming edge cases for the SSE events endpoint: multiplexing, heartbeats,
  disconnect cleanup, and JWT auth (header + access_token fallback). Raw
  :gen_tcp client (Bier.SSETestClient), dedicated instances, not async.
  """
  use ExUnit.Case, async: false

  import Bier.SSETestClient

  alias Bier.TestPorts

  @moduletag :integration

  @secret String.duplicate("s", 32)

  defp boot(extra_opts) do
    port = TestPorts.free_port()
    name = :"events_stream_#{System.unique_integer([:positive])}"

    opts =
      [
        name: name,
        router: [port: port, scheme: :http],
        events_channels: ["events_it_chat", "events_it_jobs"],
        events_heartbeat_interval: 50
      ] ++ extra_opts ++ Bier.ConformanceServer.base_opts()

    start_supervised!({Bier, opts})
    TestPorts.wait_until_listening(port)
    {port, name}
  end

  test "one connection multiplexes several channels via the event: field" do
    {port, name} = boot([])
    sock = connect_sse(port, "/events?channel=events_it_chat,events_it_jobs")
    recv_until(sock, ": connected")

    wait_until(fn -> Bier.Events.Registry.subscriber_count(name, "events_it_jobs") == 1 end)
    wait_until_listener_connected(name)

    notify(name, "events_it_chat", "one")
    notify(name, "events_it_jobs", "two")

    stream = recv_until(sock, "data: two")
    assert stream =~ "event: events_it_chat\ndata: one"
    assert stream =~ "event: events_it_jobs\ndata: two"

    :gen_tcp.close(sock)
  end

  test "keepalive comments arrive during silence" do
    {port, name} = boot([])
    sock = connect_sse(port, "/events?channel=events_it_chat")
    recv_until(sock, ": connected")
    _ = name

    assert recv_until(sock, ": keepalive") =~ ": keepalive"
    :gen_tcp.close(sock)
  end

  test "closing the socket removes the registry entries" do
    {port, name} = boot([])
    sock = connect_sse(port, "/events?channel=events_it_chat")
    recv_until(sock, ": connected")

    wait_until(fn -> Bier.Events.Registry.subscriber_count(name, "events_it_chat") == 1 end)
    :gen_tcp.close(sock)

    # Detection is bounded by the 50ms heartbeat: the next write fails and the
    # connection process exits, taking its registry entries with it.
    wait_until(fn -> Bier.Events.Registry.subscriber_count(name, "events_it_chat") == 0 end)
  end

  test "with a jwt_secret and no anon role, a tokenless subscribe is 401" do
    {port, _name} = boot(jwt_secret: @secret)

    resp = Req.get!("http://127.0.0.1:#{port}/events?channel=events_it_chat", retry: false)
    assert resp.status == 401
    assert resp.body["code"] == "PGRST302"
  end

  # Pins the auth-before-allowlist ordering: unauthenticated requests must
  # fail with 401 regardless of channel validity, so a tokenless client
  # cannot use the 401 (auth issue) vs 404 (channel issue) response split to
  # enumerate which channels exist without ever presenting a token.
  test "with a jwt_secret, a tokenless subscribe to an UNKNOWN channel is still 401 (not 404)" do
    {port, _name} = boot(jwt_secret: @secret)

    resp = Req.get!("http://127.0.0.1:#{port}/events?channel=nope", retry: false)
    assert resp.status == 401
    assert resp.body["code"] == "PGRST302"
  end

  test "a valid JWT via the access_token query param opens the stream" do
    {port, _name} = boot(jwt_secret: @secret)
    token = sign_hs256(%{"role" => "events_subscriber"}, @secret)

    sock = connect_sse(port, "/events?channel=events_it_chat&access_token=#{token}")
    assert recv_until(sock, ": connected") =~ "200 OK"
    :gen_tcp.close(sock)
  end

  test "an invalid access_token is rejected like a bad bearer token" do
    {port, _name} = boot(jwt_secret: @secret)

    resp =
      Req.get!(
        "http://127.0.0.1:#{port}/events?channel=events_it_chat&access_token=not.a.jwt",
        retry: false
      )

    assert resp.status == 401
    assert resp.body["code"] == "PGRST301"
  end
end
