defmodule Bier.Events do
  @moduledoc """
  Request handler for the realtime events endpoint (`GET /<events_path>`).

  Bridges Postgres NOTIFY, and the WAL change feed, to Server-Sent Events:
  authenticates with the instance's standard JWT gate FIRST (a tokenless
  request on a JWT-protected instance is 401 regardless of subscription
  validity — this prevents an unauthenticated channel/table-enumeration
  oracle), then validates the requested `channel=` subscriptions against the
  `events_channels` allowlist and the requested `table=` subscriptions
  against `Bier.Wal.Authorize` (publication membership + RLS + per-role
  column grants — the same uniform-refusal shape so the endpoint cannot be
  used as an existence oracle either), then holds the connection open inside
  the Bandit connection process, relaying `{:bier_event, channel, payload}`
  messages from `Bier.Events.Listener` and `{:bier_wal_event, ...}` /
  `{:bier_wal_reset, ...}` messages from `Bier.Wal.Consumer` (via
  `Bier.Events.Registry`) as SSE frames.

  Delivery is fire-and-forget (at-most-once): NOTIFY is ephemeral, so events
  fired while a client is disconnected are lost. Clients get a `retry:` hint
  and periodic keepalive comments; reconnection does not replay.
  """

  import Plug.Conn

  alias Bier.Events.SSE
  alias Bier.Plugs.ActionController
  alias Bier.Wal.{Authorize, Cursor, Render}

  @doc """
  True when this request targets the events endpoint: the feature is enabled
  (a non-empty channel allowlist or a configured WAL publication) and the
  path is exactly the configured segment.
  """
  @spec handles?(Plug.Conn.t(), Bier.Config.t()) :: boolean()
  def handles?(%Plug.Conn{path_info: [segment]}, config) do
    # Relation resolution percent-decodes its segment too (see
    # `Bier.Plugs.ActionController`'s `decode_segment/1`); the events
    # reservation must agree, e.g. `/event%73` also matches `events_path`.
    (config.events_channels != [] or config.events_publication != nil) and
      URI.decode(segment) == config.events_path
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
         {:ok, channels, tables} <- parse_subscriptions(conn, config),
         :ok <- authorize(channels, config),
         {:ok, columns} <- authorize_tables(conn, tables, config),
         :ok <- negotiate(conn) do
      stream(conn, config, channels, tables, columns)
    end
  end

  def handle(_conn, _config), do: {:error, :method_not_allowed}

  # Collect every `channel`/`table` query param, each split on commas and
  # deduplicated. Repeated params and comma lists are equivalent. Tables
  # resolve to `{schema, name}`: an unqualified name resolves against the
  # first exposed schema, a qualified `schema.name` splits on the FIRST dot.
  # Subscriptions may be channels, tables, or both — only having neither is
  # the existing `:events_missing_channel` error.
  defp parse_subscriptions(conn, config) do
    params = URI.query_decoder(conn.query_string)

    channels = params |> collect("channel") |> Enum.uniq()

    tables =
      params
      |> collect("table")
      |> Enum.map(fn name ->
        case String.split(name, ".", parts: 2) do
          [table] -> {hd(config.db_schemas), table}
          [schema, table] -> {schema, table}
        end
      end)
      |> Enum.uniq()

    if channels == [] and tables == [] do
      {:error, :events_missing_channel}
    else
      {:ok, channels, tables}
    end
  end

  defp collect(params, key) do
    Enum.flat_map(params, fn
      {^key, value} -> String.split(value, ",", trim: true)
      _other -> []
    end)
  end

  defp authorize(channels, config) do
    case Enum.find(channels, &(&1 not in config.events_channels)) do
      nil -> :ok
      unknown -> {:error, {:events_unknown_channel, unknown}}
    end
  end

  defp authorize_tables(_conn, [], _config), do: {:ok, %{}}

  # WAL table subscriptions require `events_publication`; a `table=` request
  # against an instance with no publication configured shares the same
  # uniform refusal as an unpublished/unauthorized table (no oracle either
  # way — a client cannot tell "not enabled" from "not visible to you").
  defp authorize_tables(_conn, _tables, %{events_publication: nil}),
    do: {:error, {:events_unknown_table, "table subscriptions are not enabled"}}

  defp authorize_tables(conn, tables, config) do
    role =
      case conn.assigns[:bier_auth] do
        %{role: role} -> role
        nil -> nil
      end

    pool = Bier.Registry.via(config.name, Postgrex)
    Authorize.check(pool, role, config.events_publication, tables)
  rescue
    # A verified JWT can carry a role absent from pg_roles (`has_column_
    # privilege` then raises `undefined_object`); surface it through the
    # ordinary Postgrex-error path instead of a raw 500.
    error in Postgrex.Error -> {:error, error}
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

  defp stream(conn, config, channels, tables, columns) do
    metadata = %{instance: config.name, channels: channels, tables: tables}
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
        Enum.each(tables, &Bier.Events.Registry.register_table(config.name, &1))
        sub = %{columns: columns, tables: tables, names: table_names(tables, config)}
        loop(conn, config, sub, 0, start, metadata)

      {:error, reason} ->
        finish(conn, 0, start, Map.put(metadata, :reason, reason))
    end
  end

  # The `event:` field for each subscribed table: the name as subscribed
  # (qualified iff the client qualified it, or the schema is not the
  # instance's default).
  defp table_names(tables, config) do
    default = hd(config.db_schemas)

    Map.new(tables, fn {schema, table} = key ->
      {key, if(schema == default, do: table, else: schema <> "." <> table)}
    end)
  end

  # Runs in the Bandit connection process. Registry entries die with it, so
  # there is no explicit unsubscribe. A failed write (client gone) ends the
  # loop; detection of a silent disconnect is bounded by the heartbeat.
  # `sub` (`%{columns, tables, names}`) is the per-subscriber WAL state: the
  # column allowlist per table, the subscribed table keys, and their
  # rendered `event:` names.
  defp loop(conn, config, sub, delivered, start, metadata) do
    receive do
      {:bier_event, channel, payload} ->
        case chunk(conn, SSE.frame(channel, payload)) do
          {:ok, conn} ->
            loop(conn, config, sub, delivered + 1, start, metadata)

          {:error, reason} ->
            finish(conn, delivered, start, Map.put(metadata, :reason, reason))
        end

      {:bier_wal_event, table_key, cursor, event} ->
        allowed = Map.fetch!(sub.columns, table_key)
        json = Render.data(event, event.commit_at, allowed)
        payload = Bier.json_library().encode!(json)
        name = Map.fetch!(sub.names, table_key)
        frame = SSE.frame(name, payload, Cursor.encode(cursor))

        case chunk(conn, frame) do
          {:ok, conn} ->
            loop(conn, config, sub, delivered + 1, start, metadata)

          {:error, reason} ->
            finish(conn, delivered, start, Map.put(metadata, :reason, reason))
        end

      {:bier_wal_reset, reset_reason} ->
        payload = Bier.json_library().encode!(%{"reason" => reset_reason})

        # `bier:reset` carries no `id:` — there is nothing to resume from a
        # reset — and the loop keeps running: the client stays subscribed
        # across the consumer's reconnect.
        case chunk(conn, SSE.frame("bier:reset", payload)) do
          {:ok, conn} ->
            loop(conn, config, sub, delivered, start, metadata)

          {:error, reason} ->
            finish(conn, delivered, start, Map.put(metadata, :reason, reason))
        end
    after
      config.events_heartbeat_interval ->
        case chunk(conn, SSE.heartbeat()) do
          {:ok, conn} ->
            loop(conn, config, sub, delivered, start, metadata)

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
