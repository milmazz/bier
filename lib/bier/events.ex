defmodule Bier.Events do
  @moduledoc """
  Request handler for the realtime events endpoint (`GET /<events_path>`).

  Bridges Postgres NOTIFY to Server-Sent Events: authenticates with the
  instance's standard JWT gate FIRST (a tokenless request on a JWT-protected
  instance is 401 regardless of channel validity — this prevents an
  unauthenticated channel-enumeration oracle), then validates the requested
  channels against the `events_channels` allowlist, then holds the
  connection open inside the Bandit connection process, relaying
  `{:bier_event, channel, payload}` messages from `Bier.Events.Listener` as
  SSE frames.

  Delivery is fire-and-forget (at-most-once): NOTIFY is ephemeral, so events
  fired while a client is disconnected are lost. Clients get a `retry:` hint
  and periodic keepalive comments; reconnection does not replay.
  """

  import Plug.Conn

  alias Bier.Events.SSE
  alias Bier.Plugs.ActionController

  @doc """
  True when this request targets the events endpoint: the feature is enabled
  (non-empty allowlist) and the path is exactly the configured segment.
  """
  @spec handles?(Plug.Conn.t(), Bier.Config.t()) :: boolean()
  def handles?(%Plug.Conn{path_info: [segment]}, config) do
    # Relation resolution percent-decodes its segment too (see
    # `Bier.Plugs.ActionController`'s `decode_segment/1`); the events
    # reservation must agree, e.g. `/event%73` also matches `events_path`.
    config.events_channels != [] and URI.decode(segment) == config.events_path
  end

  def handles?(_conn, _config), do: false

  @doc """
  Handle a subscription request. Returns the streaming `Plug.Conn` (which
  only comes back once the client disconnects) or an `{:error, reason}` for
  `Bier.Plugs.FallbackController`.
  """
  @spec handle(Plug.Conn.t(), Bier.Config.t()) :: Plug.Conn.t() | {:error, term()}
  def handle(%Plug.Conn{method: "GET"} = conn, config) do
    with {:ok, conn} <- ActionController.maybe_auth(bearer_fallback(conn), config),
         {:ok, channels} <- parse_channels(conn),
         :ok <- authorize(channels, config),
         :ok <- negotiate(conn) do
      stream(conn, config, channels)
    end
  end

  def handle(_conn, _config), do: {:error, :method_not_allowed}

  # Collect every `channel` query param, each split on commas, deduplicated.
  # Repeated params and comma lists are equivalent. No usable channel -> 400.
  defp parse_channels(conn) do
    channels =
      conn.query_string
      |> URI.query_decoder()
      |> Enum.flat_map(fn
        {"channel", value} -> String.split(value, ",", trim: true)
        _other -> []
      end)
      |> Enum.uniq()

    case channels do
      [] -> {:error, :events_missing_channel}
      channels -> {:ok, channels}
    end
  end

  defp authorize(channels, config) do
    case Enum.find(channels, &(&1 not in config.events_channels)) do
      nil -> :ok
      unknown -> {:error, {:events_unknown_channel, unknown}}
    end
  end

  # The browser EventSource API cannot set request headers, so this endpoint
  # (only) also accepts the JWT as an `access_token` query param. The header
  # wins when both are present; the fallback is materialized as a synthetic
  # Authorization header so Bier.Auth stays the single verification path.
  defp bearer_fallback(conn) do
    with [] <- get_req_header(conn, "authorization"),
         token when is_binary(token) and token != "" <- access_token(conn) do
      put_req_header(conn, "authorization", "Bearer " <> token)
    else
      _ -> conn
    end
  end

  defp access_token(conn) do
    conn.query_string
    |> URI.query_decoder()
    |> Enum.find_value(fn
      {"access_token", value} -> value
      _other -> nil
    end)
  end

  # The only producer here is text/event-stream; a missing Accept, a wildcard,
  # or text/* admits it. Anything else is PostgREST's 406 (PGRST107).
  defp negotiate(conn) do
    case get_req_header(conn, "accept") do
      [] ->
        :ok

      [accept | _] ->
        if accepts_event_stream?(accept), do: :ok, else: {:error, {:not_acceptable, accept}}
    end
  end

  defp accepts_event_stream?(accept) do
    accept
    |> String.split(",")
    |> Enum.map(fn entry -> entry |> String.split(";") |> hd() |> String.trim() end)
    |> Enum.any?(&(&1 in ["*/*", "text/*", "text/event-stream", ""]))
  end

  defp stream(conn, config, channels) do
    metadata = %{instance: config.name, channels: channels}
    start = Bier.Telemetry.events_subscribe_start(metadata)

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream; charset=utf-8")
      |> put_resp_header("cache-control", "no-store")
      # Stops buffering reverse proxies (nginx et al.) from absorbing frames.
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    case chunk(conn, SSE.preamble()) do
      {:ok, conn} ->
        Enum.each(channels, &Bier.Events.Registry.register(config.name, &1))
        loop(conn, config.events_heartbeat_interval, 0, start, metadata)

      {:error, reason} ->
        finish(conn, 0, start, Map.put(metadata, :reason, reason))
    end
  end

  # Runs in the Bandit connection process. Registry entries die with it, so
  # there is no explicit unsubscribe. A failed write (client gone) ends the
  # loop; detection of a silent disconnect is bounded by the heartbeat.
  defp loop(conn, heartbeat, delivered, start, metadata) do
    receive do
      {:bier_event, channel, payload} ->
        case chunk(conn, SSE.frame(channel, payload)) do
          {:ok, conn} ->
            loop(conn, heartbeat, delivered + 1, start, metadata)

          {:error, reason} ->
            finish(conn, delivered, start, Map.put(metadata, :reason, reason))
        end
    after
      heartbeat ->
        case chunk(conn, SSE.heartbeat()) do
          {:ok, conn} ->
            loop(conn, heartbeat, delivered, start, metadata)

          {:error, reason} ->
            finish(conn, delivered, start, Map.put(metadata, :reason, reason))
        end
    end
  end

  defp finish(conn, delivered, start, metadata) do
    Bier.Telemetry.events_subscribe_stop(start, delivered, metadata)
    conn
  end
end
