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

  Channel delivery is fire-and-forget (at-most-once): NOTIFY is ephemeral, so
  a `channel=` event fired while a client is disconnected is lost. Table
  delivery is different: `Bier.Wal.Buffer` retains a bounded ring of recent
  history per table, and a reconnecting client that sends `Last-Event-ID`
  (as a header, or a `last_event_id` query param for clients that cannot set
  arbitrary headers — the header wins when both are present) has it replayed
  before rejoining the live stream. A cursor the buffer can no longer honor
  — evicted by the ring, dropped, or from before a bier restart — gets an
  explicit `bier:reset` frame instead of a silent gap; a missing or
  malformed id just starts at the live head. Clients also get a `retry:`
  hint and periodic keepalive comments.
  """

  import Plug.Conn

  alias Bier.Events.SSE
  alias Bier.Plugs.ActionController
  alias Bier.Wal.{Authorize, Buffer, Cursor, Render}

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

  # WAL table subscriptions require `events_publication`. `tables` is
  # guaranteed non-empty here (the `[]` clause above precedes this one), so
  # naming the first REQUESTED table renders through the exact same
  # `{:events_unknown_table, "schema.table"}` shape and BIER003 envelope as
  # an unpublished/RLS-enabled/unprivileged table — the client only ever
  # sees its own table name echoed back, the same way it would if the
  # publication were configured, so this still can't be used to learn
  # whether table subscriptions are enabled at all.
  defp authorize_tables(_conn, [{schema, table} | _], %{events_publication: nil}),
    do: {:error, {:events_unknown_table, schema <> "." <> table}}

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
    # privilege` then raises `undefined_object`); a checked-out connection
    # can also be lost/time out mid-check. Surface both through the ordinary
    # Postgrex/DBConnection error paths (FallbackController already maps
    # both) instead of crashing to a raw 500.
    error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, error}
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

        # Registration happens BEFORE replay, so an event landing while
        # history is being replayed is already queued in this process's
        # mailbox and gets delivered again by `loop/6` right after — an
        # accepted, documented at-least-once duplicate window (the client
        # dedupes by `id:`), not a gap.
        case resume(conn, config, sub) do
          {:live, conn, delivered} ->
            loop(conn, config, sub, delivered, start, metadata)

          {:error, reason, delivered} ->
            finish(conn, delivered, start, Map.put(metadata, :reason, reason))
        end

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

  # `Last-Event-ID` (header, then `last_event_id` query param fallback) is
  # resolved into either the live head or replayed history. Returns
  # `{:live, conn, delivered}` — `delivered` counts frames written here so
  # the caller's telemetry stays accurate whether resume replayed history,
  # sent a reset, or did neither — or `{:error, reason, delivered}` on a
  # write failure (mirrors the preamble's own `chunk/2` error shape).
  defp resume(conn, config, sub) do
    case last_event_id(conn) do
      nil ->
        {:live, conn, 0}

      raw ->
        case Cursor.parse(raw) do
          # A malformed id is not a protocol error; start at the live head.
          :error -> {:live, conn, 0}
          {:ok, cursor} -> replay(conn, config, sub, cursor)
        end
    end
  end

  # Nothing to replay for a channel-only subscription: skip the Buffer
  # entirely rather than calling `Buffer.generation/1`, which would crash
  # (no Buffer process exists) on an instance with WAL disabled entirely
  # (`events_publication: nil`) — the only shape a table-less `sub` can have,
  # since `authorize_tables/3` already refuses table subscriptions there.
  defp replay(conn, _config, %{tables: []}, _cursor), do: {:live, conn, 0}

  defp replay(conn, config, sub, cursor) do
    name = config.name
    generation = Buffer.generation(name)

    case Buffer.replay_after(name, sub.tables, cursor, generation) do
      :reset ->
        payload = Bier.json_library().encode!(%{"reason" => "history_evicted"})

        case chunk_or_halt(conn, SSE.frame("bier:reset", payload)) do
          {:live, conn} -> {:live, conn, 0}
          {:error, reason} -> {:error, reason, 0}
        end

      {:ok, entries} ->
        Enum.reduce_while(entries, {:live, conn, 0}, fn {c, table_key, event},
                                                        {:live, conn, delivered} ->
          allowed = Map.fetch!(sub.columns, table_key)
          json = Render.data(event, event.commit_at, allowed)
          name = Map.fetch!(sub.names, table_key)
          frame = SSE.frame(name, Bier.json_library().encode!(json), Cursor.encode(c))

          case chunk_or_halt(conn, frame) do
            {:live, conn} -> {:cont, {:live, conn, delivered + 1}}
            {:error, reason} -> {:halt, {:error, reason, delivered}}
          end
        end)
    end
  end

  defp chunk_or_halt(conn, iodata) do
    case chunk(conn, iodata) do
      {:ok, conn} -> {:live, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  # The browser EventSource API cannot set arbitrary headers on the FIRST
  # connect either, so this endpoint also accepts the resume cursor as a
  # `last_event_id` query param; browsers DO send `Last-Event-ID` on their
  # own automatic reconnects, so the header wins whenever both are present.
  defp last_event_id(conn) do
    case get_req_header(conn, "last-event-id") do
      [id | _] ->
        id

      [] ->
        conn.query_string
        |> URI.query_decoder()
        |> Enum.find_value(fn
          {"last_event_id", value} -> value
          _other -> nil
        end)
    end
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
