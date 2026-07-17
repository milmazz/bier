# Realtime events (SSE)

Bier can bridge PostgreSQL's `LISTEN`/`NOTIFY` to browsers and other HTTP
clients as [Server-Sent Events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events).
Anything in your database that runs `NOTIFY` — a trigger, a function, plain
application code — becomes a live event stream, with no extra service to
deploy. PostgREST has no equivalent.

## Configuration

The feature is off by default. Enabling it means allowlisting channels:

```elixir
children = [
  {Bier,
   name: MyApp.Bier,
   router: [port: 4040, scheme: :http],
   events_channels: ["orders", "chat"]}
]
```

| Option | Default | Meaning |
|---|---|---|
| `events_channels` | `[]` | Channels clients may subscribe to. Empty = feature disabled. |
| `events_path` | `"events"` | Reserved top-level path segment. Change it if you expose a relation named `events`. |
| `events_heartbeat_interval` | `15_000` | ms of silence before a `: keepalive` comment is sent. |

While enabled, `GET /<events_path>` no longer resolves as a relation — pick
a different `events_path` if that collides with one of your tables.

## Subscribing

One connection can multiplex any number of allowlisted channels; each NOTIFY
arrives with the channel name in SSE's native `event:` field and the payload
verbatim in `data:`.

```bash
curl -N "http://localhost:4040/events?channel=orders,chat"
```

```
event: orders
data: {"id": 42}
```

In the browser:

```javascript
const es = new EventSource("/events?channel=orders,chat");
es.addEventListener("orders", (e) => console.log(JSON.parse(e.data)));
es.addEventListener("chat", (e) => console.log(e.data));
```

Emit events from SQL:

```sql
NOTIFY orders, '{"id": 42}';
-- or, parameterizable:
SELECT pg_notify('orders', json_build_object('id', new.id)::text);
```

## Authentication

The endpoint uses the instance's standard JWT gate: when `jwt_secret` or
`db_anon_role` is configured, subscriptions are authenticated exactly like
API requests. Because the browser `EventSource` API cannot set headers, this
endpoint also accepts the token as a query parameter — the `Authorization`
header wins when both are present:

```javascript
const es = new EventSource(`/events?channel=orders&access_token=${jwt}`);
```

Note that query strings tend to end up in server logs; prefer the
`Authorization` header for non-browser clients.

The token is verified once, at connect time — the SSE connection is then
held open indefinitely and is **not** re-checked against the token's `exp`.
A long-lived stream can therefore outlive the JWT that opened it: a token
that expires five minutes after connecting does not cause the stream to
close five minutes later. Bounding stream lifetime by `exp` (closing or
requiring reauthentication when the token expires) is possible future
hardening, not implemented in v1.

## Errors

Errors use the PostgREST envelope with Bier-specific codes. Auth is checked
before channel validation, so on a JWT-protected instance a tokenless
request is always 401 regardless of whether the requested channel exists:

| Status | Code | When |
|---|---|---|
| 401 | `PGRST3xx` | JWT missing/invalid, same as the rest of the API. Checked first. |
| 400 | `BIER002` | No `channel` query parameter. |
| 404 | `BIER001` | A requested channel is not in `events_channels`. |
| 406 | `PGRST107` | `Accept` excludes `text/event-stream`. |
| 405 | `PGRST117` | Any method other than `GET` or `OPTIONS`. |

`OPTIONS /<events_path>` never reaches this endpoint's handler at all: the
router's generic OPTIONS handling (the same one every relation gets)
answers it with `200` (and, when a relation of that name exists, an
`Allow` header) before dispatch reaches `Bier.Events`, so CORS preflight
requests against the events endpoint work normally.

## Delivery semantics and limits

Be aware of what `LISTEN`/`NOTIFY` actually guarantees — Bier does not
pretend otherwise:

* **At-most-once.** Events fired while a client (or Bier's listener
  connection) is disconnected are lost. Clients receive a `retry:` hint and
  `EventSource` reconnects automatically, but nothing is replayed.
* **8000-byte payloads.** Postgres rejects larger NOTIFY payloads. For big
  rows, notify a key and fetch the row through the regular API
  (see the tutorial for the pattern).
* **Ordering** follows Postgres's notification queue per connection.
* **Slow clients buffer in their own mailbox.** Delivery to each subscriber
  is a plain Erlang message send; if a client reads slower than events
  arrive, the backlog piles up in that subscriber's Bandit connection
  process mailbox. This is unbounded today and affects only that one
  subscriber — the listener process and every other subscriber are
  unaffected. A mailbox-size guard (dropping or disconnecting a subscriber
  that falls too far behind) is possible future hardening, not implemented
  in v1.

## Telemetry

* `[:bier, :events, :subscribe, :start | :stop]` — one span per SSE
  connection (`:stop` carries `:duration`, `:delivered`, and `:reason` — the
  chunk-write error that ended the stream, e.g. a client disconnect).
* `[:bier, :events, :notification]` — per NOTIFY, with the `:subscribers`
  count reached.
* `[:bier, :events, :listener]` — `:status` of `:connected` /
  `:disconnected`; alert on this to spot gap windows.
