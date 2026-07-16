defmodule Bier.EventsHttpTest do
  @moduledoc """
  Boots a dedicated Bier instance with events enabled and exercises the SSE
  endpoint over real HTTP. Streaming assertions use a raw :gen_tcp client
  because the response intentionally never ends. Not async: real ports + DB.
  """
  use ExUnit.Case, async: false

  import Bier.SSETestClient

  alias Bier.TestPorts

  @moduletag :integration

  @channels ["events_it_chat", "events_it_jobs"]

  setup do
    port = TestPorts.free_port()
    name = :"events_http_#{System.unique_integer([:positive])}"

    opts =
      [
        name: name,
        router: [port: port, scheme: :http],
        events_channels: @channels,
        events_heartbeat_interval: 50
      ] ++ Bier.ConformanceServer.base_opts()

    start_supervised!({Bier, opts})
    TestPorts.wait_until_listening(port)

    %{port: port, name: name}
  end

  # ---- error paths (plain requests, no streaming needed) -------------------

  test "GET /events without a channel param is 400 BIER002", %{port: port} do
    resp = Req.get!("http://127.0.0.1:#{port}/events", retry: false)
    assert resp.status == 400
    assert resp.body["code"] == "BIER002"
  end

  test "GET /events with a channel outside the allowlist is 404 BIER001", %{port: port} do
    resp = Req.get!("http://127.0.0.1:#{port}/events?channel=nope", retry: false)
    assert resp.status == 404
    assert resp.body["code"] == "BIER001"
    assert resp.body["details"] =~ "nope"
  end

  test "one bad channel among good ones is still 404", %{port: port} do
    resp =
      Req.get!("http://127.0.0.1:#{port}/events?channel=events_it_chat,nope", retry: false)

    assert resp.status == 404
    assert resp.body["code"] == "BIER001"
  end

  test "POST /events is 405", %{port: port} do
    resp = Req.post!("http://127.0.0.1:#{port}/events?channel=events_it_chat", retry: false)
    assert resp.status == 405
  end

  test "an Accept that excludes text/event-stream is 406", %{port: port} do
    resp =
      Req.get!("http://127.0.0.1:#{port}/events?channel=events_it_chat",
        headers: [accept: "application/xml"],
        retry: false
      )

    assert resp.status == 406
    assert resp.body["code"] == "PGRST107"
  end

  test "other relations keep resolving normally while events are enabled", %{port: port} do
    # The events instance reserves only /events; everything else is untouched.
    resp = Req.get!("http://127.0.0.1:#{port}/complex_items?select=id&limit=1", retry: false)
    assert resp.status == 200
  end

  # ---- streaming happy path -------------------------------------------------

  test "subscribing streams NOTIFY payloads as SSE frames", %{port: port, name: name} do
    sock = connect_sse(port, "/events?channel=events_it_chat")
    head = recv_until(sock, ": connected")
    assert head =~ "200 OK"
    assert head =~ "text/event-stream"
    assert head =~ "retry: 3000"

    wait_until(fn -> Bier.Events.Registry.subscriber_count(name, "events_it_chat") == 1 end)
    # Bier.Events.Listener opens its dedicated LISTEN connection asynchronously
    # (see its handle_continue(:connect)); under full-suite load it can still
    # be connecting when the SSE subscriber has already registered. NOTIFY
    # only reaches backends that have already issued LISTEN, so firing it too
    # early silently drops the event (fire-and-forget by design) and the test
    # would hang on heartbeats until ExUnit's timeout. Wait for the listener
    # itself to be connected first, mirroring
    # `Bier.Events.ListenerTest.wait_until_connected/2`.
    wait_until_listener_connected(name)
    notify(name, "events_it_chat", ~s({"msg":"hi"}))

    frames = recv_until(sock, "data:")
    assert frames =~ "event: events_it_chat"
    assert frames =~ ~s(data: {"msg":"hi"})

    :gen_tcp.close(sock)
  end

  defp wait_until_listener_connected(name, retries \\ 300) do
    state = :sys.get_state(Bier.Registry.via(name, Bier.Events.Listener))

    cond do
      is_pid(state.notifications) and Process.alive?(state.notifications) ->
        :ok

      retries > 0 ->
        Process.sleep(10)
        wait_until_listener_connected(name, retries - 1)

      true ->
        flunk("events listener for #{inspect(name)} never connected: #{inspect(state)}")
    end
  end
end
