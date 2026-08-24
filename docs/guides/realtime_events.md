# Realtime events (SSE)

Bier can bridge PostgreSQL's `LISTEN`/`NOTIFY` to browsers and other HTTP
clients as [Server-Sent Events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events).
Anything in your database that runs `NOTIFY` — a trigger, a function, plain
application code — becomes a live event stream, with no extra service to
deploy. PostgREST has no equivalent.

## Configuration

The feature is off by default. Enabling it means allowlisting channels,
naming a WAL publication (see [Change feed (WAL)](#change-feed-wal) below),
or both:

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
| `events_channels` | `[]` | NOTIFY channels clients may subscribe to. |
| `events_path` | `"events"` | Reserved top-level path segment. Change it if you expose a relation named `events`. |
| `events_heartbeat_interval` | `15_000` | ms of silence before a `: keepalive` comment is sent. |
| `events_publication` | `nil` | Name of an operator-created `PUBLICATION` to stream as a WAL change feed. |
| `events_buffer_size` | `1024` | Ring-buffer entries retained per table, for `Last-Event-ID` resume. |
| `events_max_tx_events` | `10_000` | Per-transaction event cap before the transaction is dropped and a reset is announced. |

The endpoint is enabled as soon as *either* `events_channels` lists a
channel or `events_publication` names a publication; with neither set the
whole endpoint stays off. While enabled, `GET /<events_path>` no longer
resolves as a relation — pick a different `events_path` if that collides
with one of your tables.

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
```

`pg_notify` is the parameterizable form, which is what you want when the
payload is built from a row — inside a trigger function, for instance:

```sql
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
hardening; it is not currently implemented.

## Errors

Errors use the PostgREST envelope with Bier-specific codes. Auth is checked
first, so on a JWT-protected instance a tokenless request is always 401
regardless of whether the requested channel or table exists — `table=`
subscriptions follow the same "auth before existence" ordering:

| Status | Code | When |
|---|---|---|
| 401 | `PGRST3xx` | JWT missing/invalid, same as the rest of the API. Checked first. |
| 400 | `BIER002` | Neither a `channel` nor a `table` query parameter was supplied. |
| 404 | `BIER001` | A requested channel is not in `events_channels`. |
| 404 | `BIER003` | A requested table doesn't exist, isn't in the configured publication, has RLS enabled, or leaves the role no `SELECT`-able column — one indistinguishable shape for all four (see [Change feed (WAL)](#change-feed-wal)); also returned for any `table=` request when `events_publication` isn't configured at all. |
| 400 | `42704` (raw `SQLSTATE`) | The JWT's role does not exist in `pg_roles` — surfaced like any other Postgres error (see the [API reference](api.md#errors)), never a 500 or a hang. |
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
  that falls too far behind) is possible future hardening; it is not
  currently implemented.

## Telemetry

* `[:bier, :events, :subscribe, :start | :stop]` — one span per SSE
  connection (`:stop` carries `:duration`, `:delivered`, and `:reason` — the
  chunk-write error that ended the stream, e.g. a client disconnect).
* `[:bier, :events, :notification]` — per NOTIFY, with the `:subscribers`
  count reached.
* `[:bier, :events, :listener]` — `:status` of `:connected` /
  `:disconnected`; alert on this to spot gap windows.

## Change feed (WAL)

Beyond bridging `NOTIFY`, the events endpoint can stream PostgreSQL's own
write-ahead log as a **change feed**: typed `INSERT`/`UPDATE`/`DELETE`/
`TRUNCATE` events with row images, no 8000-byte NOTIFY payload cap, no
triggers to write, and reconnects that resume instead of just missing
whatever happened while disconnected. This ships the feed itself; a future
"subscribe to a filtered query" layer on top is out of scope for now — v1
only streams whole tables.

### Enabling

Nothing is exposed until an operator creates a `PUBLICATION` and points
`events_publication` at it — Bier never runs DDL itself:

```sql
ALTER SYSTEM SET wal_level = logical;  -- needs a PostgreSQL restart
CREATE PUBLICATION bier_events FOR TABLE orders, order_items;
ALTER ROLE authenticator REPLICATION;
```

```elixir
children = [
  {Bier,
   name: MyApp.Bier,
   router: [port: 4040, scheme: :http],
   events_publication: "bier_events"}
]
```

Boot fails fast — the same style as `db_schemas` validation — unless all
three hold: `wal_level = logical`, the named publication exists, and the
connecting role has the `REPLICATION` attribute (or is a superuser). The
raised error names the exact statement to run for whichever precondition is
missing.

### Subscribing to tables

`table=` sits beside `channel=` on the very same query string and
connection — NOTIFY channels and WAL tables multiplex together:

```bash
curl -N "http://localhost:4040/events?table=orders"
curl -N "http://localhost:4040/events?channel=chat&table=orders,order_items"
```

An unqualified name (`orders`) resolves against the instance's default
schema (the first of `db_schemas`); a table in any other exposed schema
must be written qualified (`billing.orders`). The qualifier is split off at
the *first* dot only, so a table whose own name contains a literal `.`
cannot be addressed via `table=` in v1.

A table is subscribable only when it is in the publication, in an exposed
schema, has no RLS enabled, and the connecting role has `SELECT` on at
least one column — see [Errors](#errors) above for what an unmet condition
returns. Partitioned tables cannot be subscribed either: logical
replication routes changes through each child partition rather than the
parent, so a partitioned table's own name is refused the same way a
nonexistent one is.

### Frame format

`event:` is the subscription name exactly as written in `table=` (qualified
only if the client qualified it, or its schema isn't the default); `id:` is
a resume cursor; `data:` is one JSON object per row-level change:

```
event: orders
id: 0/1A2B3C40.2
data: {"type":"UPDATE","schema":"api","table":"orders",
       "commit_at":"2026-08-24T03:11:30.972793Z",
       "row":{"id":3,"name":"grace","payload":{"answer":42},"tags":"{a,b}"},
       "old":{"id":3},"old_kind":"key","unchanged":[]}
```

* `type` — `INSERT`, `UPDATE`, `DELETE`, or `TRUNCATE` (a `TRUNCATE` frame
  carries no `row`/`old`; a `DELETE` frame carries `old` but no `row`).
* `row` / `old` — new and previous column images, filtered down to the
  columns the subscriber's role may `SELECT`. `old_kind` says how much of
  `old` was actually logged (see
  [`REPLICA IDENTITY` and `old`](#replica-identity-and-old) below); `old` is
  absent entirely when nothing was logged.
* `unchanged` — TOAST columns an `UPDATE` did not rewrite, so PostgreSQL
  never logged their new value; they are listed here by name and left out
  of `row` rather than guessed at.

### Value typing

Values convert through a fixed OID map — no extra query per event:

| Postgres type | JSON representation |
|---|---|
| `boolean` | `true` / `false` |
| `int2`, `int4`, `int8` | number |
| `float4`, `float8` | number (`NaN`/`Infinity`/`-Infinity` render as strings — JSON has no spelling for them) |
| `json`, `jsonb` | the embedded JSON value |
| everything else — `text`, timestamps, `uuid`, arrays, `numeric`, ... | the Postgres text representation, as a JSON string |

Two caveats worth knowing up front: `numeric` renders as a JSON *string*,
not a number — a deliberate divergence from the REST API's own JSON
rendering, since a JSON number cannot carry arbitrary precision without
silent rounding — and arrays render as PostgreSQL's own text form (e.g.
`"{a,b}"`), unparsed, rather than as a JSON array. Both extend without
breaking existing consumers, so treat them as v1 behavior rather than a
permanent contract.

### `REPLICA IDENTITY` and `old`

How much of the previous row a change carries is entirely the table's
`REPLICA IDENTITY`, an ordinary PostgreSQL setting the operator controls:

```sql
ALTER TABLE orders REPLICA IDENTITY FULL;    -- old carries every column ("full")
ALTER TABLE orders REPLICA IDENTITY DEFAULT; -- old carries only the primary key ("key")
ALTER TABLE orders REPLICA IDENTITY NOTHING; -- no old image logged at all
```

Under `NOTHING`, a `DELETE` frame carries no `old` at all — there is
nothing left to say *which* row was removed beyond the event having fired.

### Resume and reset

Every frame's `id:` is a cursor — `<commit LSN>.<sequence within that
transaction>`. LSNs are global and monotonically increasing, so **one
cursor covers every subscribed table on the connection**, exactly like
SSE's own single `Last-Event-ID`.

Reconnecting with `Last-Event-ID` (which `EventSource` sends automatically
on its own reconnects) replays everything strictly after that cursor, then
continues live. A client that cannot set arbitrary headers on the *first*
connect — `EventSource` cannot — may instead pass `?last_event_id=...`; the
header wins whenever both are present. A cursor that fails to parse
(garbled, wrong shape) is not a protocol error: the stream just starts at
the live head, same as supplying no cursor at all.

A cursor that *does* parse but can no longer be honored — evicted from the
ring buffer, or predating the current generation — gets an explicit control
frame instead of a silent gap, then the live head:

```
event: bier:reset
data: {"reason":"history_evicted"}
```

`bier:` is a reserved `event:` prefix that can never collide with a channel
or table name. v1 defines exactly three reset reasons:

| Reason | When |
|---|---|
| `stream_restarted` | The replication consumer (re)connected — a fresh temporary slot always begins at the current LSN — so every currently-open table subscriber gets this pushed live, mid-stream. |
| `history_evicted` | A connection resumes with a cursor the ring buffer can no longer replay: it aged out, an oversized transaction dropped that table's history, or it predates the consumer's current generation. |
| `transaction_too_large` | A single transaction exceeded `events_max_tx_events`; its events are dropped rather than delivered, and every table it touched gets this pushed live (see [Limits](#limits)). |

A subscription naming more than one table resets **as a whole** the moment
any single one of them has lost history — not just that table. Client
contract on any `bier:reset`: it means "some history is gone," not
"something is wrong" — re-bootstrap with a plain `GET` (dropping
`Last-Event-ID`) and keep listening; the SSE connection itself stays open
across a reset.

Delivery promise: **in-order, exactly-once while connected; at-least-once
across reconnects within the buffer window (dedupe by `id`); explicit reset
beyond it.** Every degradation is announced, never silent.

### Connection lifecycle

A response carrying any `table=` subscription also sends `Connection:
close` — a NOTIFY-only `channel=` response does not. The WAL stream can end
on its own at any moment (a consumer restart, or a schema-cache reload
finding the subscriber's role lost `SELECT`), so the connection is declared
non-keepalive up front rather than handed back to a pool as if it were
reusable.

A revoked subscription's stream simply **ends** — no `bier:reset`, no error
frame, because a reset only ever means "history is gone," never "you're no
longer authorized." Reconnecting re-authorizes from scratch and, if the
privilege is still gone, gets the ordinary `BIER003` refusal (see
[Errors](#errors) above) instead of a stream.

### Limits

* **One temporary replication slot per instance**, minted at boot and
  re-minted on every consumer restart; it counts against PostgreSQL's
  `max_replication_slots` (default `10`) like any other slot.
* **RLS tables refuse subscription** in v1 — per-event row-security
  evaluation is future work.
* **Partitioned tables cannot be subscribed** — refused the same way a
  nonexistent table is (see
  [Subscribing to tables](#subscribing-to-tables) above).
* **Table names containing a literal `.` are unaddressable** via `table=` —
  the qualifier is split off at the first dot only.
* **A multi-table subscription resets as a whole** when any one of its
  tables loses history (see [Resume and reset](#resume-and-reset) above).
* **`REPLICA IDENTITY` governs `old`** — see above.
* A bier restart always starts a fresh replication slot at the current LSN;
  there is no cross-restart resume in v1 (a possible future addition), only
  the in-process ring buffer described above.
