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

## Errors

Errors use the PostgREST envelope with Bier-specific codes:

| Status | Code | When |
|---|---|---|
| 400 | `BIER002` | No `channel` query parameter. |
| 404 | `BIER001` | A requested channel is not in `events_channels`. |
| 401 | `PGRST3xx` | JWT missing/invalid, same as the rest of the API. |
| 406 | `PGRST107` | `Accept` excludes `text/event-stream`. |
| 405 | `PGRST117` | Any method other than `GET`. |

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

## Telemetry

* `[:bier, :events, :subscribe, :start | :stop]` — one span per SSE
  connection (`:stop` carries `:duration` and `:delivered`).
* `[:bier, :events, :notification]` — per NOTIFY, with the `:subscribers`
  count reached.
* `[:bier, :events, :listener]` — `:status` of `:connected` /
  `:disconnected`; alert on this to spot gap windows.
