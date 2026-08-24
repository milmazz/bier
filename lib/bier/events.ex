defmodule Bier.Events do
  @moduledoc """
  Request handler for the realtime events endpoint (`GET /<events_path>`).

  Bridges Postgres NOTIFY, and the WAL change feed, to Server-Sent Events:
  authenticates with the instance's standard JWT gate FIRST (a tokenless
  request on a JWT-protected instance is 401 regardless of subscription
  validity — this prevents an unauthenticated channel/table-enumeration
  oracle), then validates the requested `channel=` subscriptions against the
  `events_channels` allowlist and the requested `table=` subscriptions
  against `db_schemas` exposure and `Bier.Wal.Authorize` (publication
  membership + RLS + per-role column grants — the same uniform-refusal shape
  so the endpoint cannot be used as an existence oracle either), then holds
  the connection open inside the Bandit connection process, relaying
  `{:bier_event, channel, payload}`
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

  # A subscriber that stops reading (a slow client, or a dead TCP peer the
  # OS hasn't noticed yet) lets WAL frames pile up in this process's own
  # mailbox — unlike NOTIFY, which is fire-and-forget and never backs up.
  # Past this mark the connection is closed instead of growing our heap
  # unbounded; the client reconnects with `Last-Event-ID` and replays from
  # `Bier.Wal.Buffer`'s ring instead.
  @max_queue 1_000

  @doc false
  def queue_overloaded? do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)
    len > @max_queue
  end

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
         role = resolve_role(conn),
         {:ok, columns} <- authorize_tables(conn, tables, config, role),
         :ok <- negotiate(conn) do
      stream(conn, config, channels, tables, columns, role)
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

  defp resolve_role(conn) do
    case conn.assigns[:bier_auth] do
      %{role: role} -> role
      nil -> nil
    end
  end

  defp authorize_tables(_conn, [], _config, _role), do: {:ok, %{}}

  # The refusals below are byte-identical, but they are not all equally
  # EXPENSIVE: the exposure/reserved-name gate and the `events_publication:
  # nil` gate answer with no database round trip, while the
  # publication/RLS/privilege gate costs one. A determined observer can time
  # the difference and learn which gate fired — that leaks configuration
  # (whether a schema is exposed, whether the feature is on), never data or
  # the existence of a table. Equalising it would mean issuing a pointless
  # query on the cheap paths; the trade is deliberate and recorded here so
  # the "one indistinguishable shape" claim is not read as stronger than it
  # is.
  #
  # `table=` may only reference schemas this instance actually exposes
  # (`db_schemas`) — a request naming an unexposed schema is refused before
  # anything else (no DB round trip, no publication check), through the
  # SAME uniform shape as every other refusal below: the first offending
  # table in request order, so a qualified name still can't be used to
  # probe which schemas are configured.
  defp authorize_tables(conn, tables, config, role) do
    case Enum.find(tables, &refused_outright?(&1, config)) do
      {schema, table} -> {:error, {:events_unknown_table, schema <> "." <> table}}
      nil -> authorize_published_tables(conn, tables, config, role)
    end
  end

  # Refused before any database work, through the same uniform shape as
  # every other refusal: a schema this instance does not expose, or a table
  # whose name would claim the `bier:` prefix the stream reserves for its own
  # control frames (`event: bier:reset`). `events_channels` is held to the
  # same reservation in `Bier.Config`; this is the half of it that cannot be
  # checked at boot, because the name comes from the database.
  defp refused_outright?({schema, table}, config),
    do: schema not in config.db_schemas or String.starts_with?(table, "bier:")

  # WAL table subscriptions require `events_publication`. `tables` is
  # guaranteed non-empty here (the `[]` clause on `authorize_tables/4`
  # precedes it), so naming the first REQUESTED table renders through the
  # exact same `{:events_unknown_table, "schema.table"}` shape and BIER003
  # envelope as an unpublished/RLS-enabled/unprivileged table — the client
  # only ever sees its own table name echoed back, the same way it would if
  # the publication were configured, so this still can't be used to learn
  # whether table subscriptions are enabled at all.
  defp authorize_published_tables(
         _conn,
         [{schema, table} | _],
         %{events_publication: nil},
         _role
       ),
       do: {:error, {:events_unknown_table, schema <> "." <> table}}

  defp authorize_published_tables(_conn, tables, config, role) do
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

  defp stream(conn, config, channels, tables, columns, role) do
    metadata = %{instance: config.name, channels: channels, tables: tables}
    start = Bier.Telemetry.events_subscribe_start(metadata)

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream; charset=utf-8")
      |> put_resp_header("cache-control", "no-store")
      # Stops buffering reverse proxies (nginx et al.) from absorbing frames.
      |> put_resp_header("x-accel-buffering", "no")
      |> put_recheckable_close_header(tables)
      |> send_chunked(200)

    case chunk(conn, SSE.preamble()) do
      {:ok, conn} ->
        schedule_token_expiry(conn)
        Enum.each(channels, &Bier.Events.Registry.register(config.name, &1))
        Enum.each(tables, &Bier.Events.Registry.register_table(config.name, &1, role))

        sub = %{
          columns: columns,
          tables: tables,
          names: table_names(tables, config)
        }

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

  # Headers are flushed right here (send_chunked/2 below), before `loop/6`
  # learns why the stream eventually ends — so keepalive can't be decided
  # at `finish/4` time; it has to be declared once, up front. But only WAL
  # table subscribers can ever receive `{:bier_wal_recheck}` (pure NOTIFY
  # connections aren't registered in `table_subscribers/1` — see
  # `Bier.Wal.notify_recheck/1`), so a channel-only subscription has
  # nothing to gain from declaring the connection non-keepalive: it forces
  # a fresh TCP/TLS handshake on every reconnect of the already-shipped
  # NOTIFY endpoint for no benefit. Scope the header to `tables != []`.
  defp put_recheckable_close_header(conn, []), do: conn

  defp put_recheckable_close_header(conn, _tables) do
    # `connection` is a hop-by-hop header: RFC 9113 §8.2.2 makes any HTTP/2
    # message carrying one malformed, and Bandit passes plug response
    # headers through verbatim on h2 (only cookies are special-cased). A
    # browser `EventSource` against an instance on `scheme: :https` — where
    # Bandit advertises h2 via ALPN — would therefore reset the stream with
    # ERR_HTTP2_PROTOCOL_ERROR every time. Scope it to HTTP/1.1, the only
    # protocol where it is both legal and load-bearing.
    case get_http_protocol(conn) do
      :"HTTP/1.1" -> put_resp_header(conn, "connection", "close")
      _other -> conn
    end
  end

  # The `event:` field for each subscribed table: derived from the
  # RESOLVED schema, not from how the client spelled it — qualified iff
  # that schema differs from the instance's default, so a redundant
  # `table=<default_schema>.orders` still renders as unqualified `orders`.
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
  # since `authorize_tables/4` already refuses table subscriptions there.
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

  # A subscription is one request that can outlive its own credential by
  # days: the JWT is verified at connect and never looked at again, so a
  # token that expired — or a user who was deprovisioned — would keep
  # receiving row images for as long as the socket stayed open. Every other
  # endpoint re-validates `exp` on every request; this is that check's
  # equivalent for a long-lived stream. The client reconnects (EventSource
  # does so on its own) and either presents a fresh token or gets the 401 it
  # has been owed.
  #
  # `@token_skew_seconds` mirrors `Bier.JWT`'s own allowance, so the stream
  # closes at exactly the moment a fresh request with the same token would
  # start being refused. A subscription with no token, or a token with no
  # `exp`, has no deadline — the same semantics the request path gives them.
  @token_skew_seconds 30

  defp schedule_token_expiry(conn) do
    with %{claims_json: claims_json} <- conn.assigns[:bier_auth],
         {:ok, %{"exp" => exp}} when is_number(exp) <- decode_claims(claims_json) do
      deadline = trunc((exp + @token_skew_seconds) * 1000) - System.system_time(:millisecond)
      Process.send_after(self(), :bier_token_expired, max(deadline, 0))
    end

    :ok
  end

  defp decode_claims(claims_json) do
    case Bier.json_library().decode(claims_json) do
      {:ok, claims} when is_map(claims) -> {:ok, claims}
      _other -> :error
    end
  rescue
    _error -> :error
  end

  # Runs in the Bandit connection process. Registry entries die with it, so
  # there is no explicit unsubscribe. A failed write (client gone) ends the
  # loop; detection of a silent disconnect is bounded by the heartbeat.
  # `sub` (`%{columns, tables, names, role}`) is the per-subscriber WAL
  # state: the column allowlist per table, the subscribed table keys, their
  # rendered `event:` names, and the role authorization was last checked
  # against (remembered so a later `{:bier_wal_recheck}` can re-run the
  # exact same check).
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
        wal_event = {table_key, cursor, event}
        deliver_wal_event(conn, config, sub, delivered, start, metadata, wal_event)

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

      {:bier_wal_recheck, verdict} ->
        recheck(conn, config, sub, delivered, start, metadata, verdict)

      :bier_token_expired ->
        finish(conn, delivered, start, Map.put(metadata, :reason, :token_expired))
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

  # Split out of `loop/6`'s `{:bier_wal_event, ...}` clause to keep it
  # under credo's complexity threshold. A subscriber whose mailbox has
  # backed up past `queue_overloaded?/0`'s high-water mark is cut loose
  # here, before rendering or writing anything: the client reconnects and
  # resumes via `Last-Event-ID` instead of this process growing its heap
  # forever behind a slow (or dead) peer.
  defp deliver_wal_event(conn, config, sub, delivered, start, metadata, wal_event) do
    {table_key, cursor, event} = wal_event

    if queue_overloaded?() do
      finish(conn, delivered, start, Map.put(metadata, :reason, :overloaded))
    else
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
    end
  end

  # A schema reload is the signal that privileges may have changed under a
  # live subscriber. `Bier.Wal.notify_recheck/1` re-runs the subscribe-time
  # check centrally — once per distinct role, against the union of that
  # role's tables — and pushes each subscriber the verdict, so this clause
  # only applies it. Doing the query here instead would mean one checkout
  # per subscriber against a pool of `pool_size` (default 10) every time
  # anything reloaded the schema cache.
  #
  # `{:ok, columns}` continues with the FRESH map: grants may merely have
  # narrowed (a partial-grant role losing one of several visible columns),
  # and reusing the remembered map would keep streaming a column the role
  # can no longer see. `:revoked` closes the stream rather than keep leaking
  # rows. `:keep` means the check could not be completed (pool contention,
  # not evidence of lost privilege), so the subscription stands and the next
  # reload gets another chance.
  #
  # A pure NOTIFY connection (`sub.tables == []`) is never registered as a
  # table subscriber, so it cannot receive any of these.
  defp recheck(conn, config, sub, delivered, start, metadata, verdict) do
    case verdict do
      {:ok, columns} ->
        loop(conn, config, %{sub | columns: columns}, delivered, start, metadata)

      :keep ->
        loop(conn, config, sub, delivered, start, metadata)

      :revoked ->
        finish(conn, delivered, start, Map.put(metadata, :reason, :revoked))
    end
  end

  defp finish(conn, delivered, start, metadata) do
    Bier.Telemetry.events_subscribe_stop(start, delivered, metadata)
    conn
  end
end
