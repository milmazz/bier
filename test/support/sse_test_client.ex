defmodule Bier.SSETestClient do
  @moduledoc """
  Raw `:gen_tcp` SSE client helpers for the realtime events tests.

  The SSE response intentionally never ends, so Req cannot drive the
  streaming assertions; a raw socket can. Chunked transfer framing
  (sizes/CRLFs) is tolerated by substring matching in `recv_until/3`.
  """

  import ExUnit.Assertions

  @doc "Open a socket and send a GET with an SSE Accept header."
  def connect_sse(port, path) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)

    :ok =
      :gen_tcp.send(
        sock,
        "GET #{path} HTTP/1.1\r\nhost: 127.0.0.1\r\naccept: text/event-stream\r\n\r\n"
      )

    sock
  end

  @doc "Collect bytes until the accumulated stream contains `pattern`."
  def recv_until(sock, pattern, acc \\ "") do
    if acc =~ pattern do
      acc
    else
      case :gen_tcp.recv(sock, 0, 3_000) do
        {:ok, data} ->
          recv_until(sock, pattern, acc <> data)

        {:error, reason} ->
          flunk("waiting for #{inspect(pattern)}, got #{inspect(acc)} (#{inspect(reason)})")
      end
    end
  end

  @doc "Fire pg_notify through the instance's request pool."
  def notify(name, channel, payload) do
    pool = Bier.Registry.via(name, Postgrex)
    Postgrex.query!(pool, "SELECT pg_notify($1, $2)", [channel, payload])
  end

  @doc "Poll `fun` until truthy (10ms interval), flunking after `retries`."
  def wait_until(fun, retries \\ 100) do
    cond do
      fun.() ->
        :ok

      retries == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(10)
        wait_until(fun, retries - 1)
    end
  end

  @doc """
  Poll the named instance's `Bier.Events.Listener` until its dedicated
  `Postgrex.Notifications` connection is up (10ms interval), flunking after
  `retries`.

  `Bier.Events.Listener` opens its LISTEN connection asynchronously (see its
  `handle_continue(:connect)`), and NOTIFY only reaches backends that have
  already issued LISTEN — firing one too early silently drops the event
  (fire-and-forget by design) and a test would otherwise hang on heartbeats
  until ExUnit's timeout. Call this after registering an SSE subscriber and
  before firing `notify/3`.
  """
  def wait_until_listener_connected(name, retries \\ 300) do
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

  @doc "Hand-sign an HS256 JWT (no deps) for auth tests."
  def sign_hs256(claims, secret) do
    encode = fn map ->
      map |> Bier.json_library().encode!() |> Base.url_encode64(padding: false)
    end

    header = encode.(%{"alg" => "HS256", "typ" => "JWT"})
    payload = encode.(claims)

    signature =
      :crypto.mac(:hmac, :sha256, secret, header <> "." <> payload)
      |> Base.url_encode64(padding: false)

    header <> "." <> payload <> "." <> signature
  end
end
