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
| `events_max_tx_events` | `10_000` | Per-transaction event cap before the transaction is dropped and a reset is announced. A fixed, non-configurable 64 MiB cap on a transaction's accumulated event payload applies alongside it (see [Limits](#limits)). |

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

The token is verified at connect time, and the stream is then bounded by
its `exp` (plus the same 30s skew allowance the request path uses): when
the token lapses the stream ends with a terminal
`event: bier:closed` / `data: {"reason":"token_expired"}` frame (see
[Connection lifecycle](#connection-lifecycle)). Do **not** let `EventSource`
reconnect on its own after that: it would resend the same, now-expired
token, get a `401`, and give up for good. Close it and open a **new**
`EventSource` with a fresh token — passing the last `id:` it saw as
`?last_event_id=` to resume a table subscription where it left off. A token
without `exp` never expires the stream.

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
| 503 | `BIER004` | The instance's WAL change feed was given up on after repeated failures (see [Enabling](#enabling)): any request with a `table=` subscription — and so every `Last-Event-ID` resume — is refused until the instance is restarted. `channel=`-only requests are unaffected. Checked after authorization and the `BIER003` checks. |
| 404 | `BIER003` | A requested table doesn't exist, isn't a table the publication streams under its own name (a view, materialized view, or foreign table; a partitioned table whose publication isn't `publish_via_partition_root = true`; a partition whose changes are published under its partitioned ancestor — see [Partitioned tables](#partitioned-tables)), isn't in the configured publication, has RLS enabled, is in a schema outside `db_schemas`, leaves the role no `SELECT`-able column, or names a role the authenticator may not assume — one indistinguishable shape for every one of them (see [Change feed (WAL)](#change-feed-wal)); also returned for any `table=` request when `events_publication` isn't configured at all. |
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
  process mailbox, affecting only that one subscriber — the listener
  process and every other subscriber are unaffected. For `channel=`
  (NOTIFY) delivery this backlog is unbounded; a mailbox-size guard is
  possible future hardening and is not currently implemented. `table=`
  (WAL) delivery *is* guarded: a subscriber past ~1,000 queued frames is
  disconnected and resumes by cursor — see [Limits](#limits).

## Telemetry

* `[:bier, :events, :subscribe, :start | :stop]` — one span per SSE
  connection. `:stop` carries `:duration`, `:delivered`, and `:reason`:
  either a chunk-write error (a client disconnect, typically) or one of
  four deliberate terminations — `:overloaded` (the slow-subscriber guard
  below), `:revoked` (re-authorization found the role's privileges gone
  after a schema reload), `:token_expired` (the subscription outlived its
  JWT's `exp`), and `:feed_stopped` (the WAL change feed was given up on).
  The last three are the ones worth alerting on.
* `[:bier, :events, :notification]` — per NOTIFY, with the `:subscribers`
  count reached.
* `[:bier, :events, :listener]` — `:status` of `:connected` /
  `:disconnected`; alert on this to spot gap windows.
* `[:bier, :wal, :feed, :stopped]` — the WAL change feed was given up on
  (see [Enabling](#enabling)); measurement `%{count: 1}`, metadata
  `:instance` and `:reason`. At most once per instance lifetime. Alert on
  it: the HTTP API keeps serving, so nothing else goes red.

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

The feed runs under its own supervisor inside the instance
(`Bier.Wal.Supervisor`: the ring buffer, then the replication consumer), so
its failures stay its own. The consumer is built not to crash on anything
transient — a dropped connection reconnects, a failed slot creation retries
on a backoff — and when it does crash it restarts on that supervisor's
budget, never the instance's: the HTTP API, RPC and `channel=` events keep
serving throughout, and table subscribers get a `stream_restarted` reset
(see [Resume and reset](#resume-and-reset)). A crash of the ring buffer
restarts the consumer with it and ends in the same `stream_restarted`
reset — possibly preceded by a `history_evicted` one for tables whose
transaction committed in the instant the buffer was down.

Only a feed that keeps crashing — a sixth restart within thirty seconds —
is **given up on**. It then stays stopped for the rest of the instance's
life, without touching the API, and comes back only when the instance (or
its host application) is restarted. The give-up is never silent:

* it is logged at `error` level, naming the instance, the restart budget
  and the remedy, and emits `[:bier, :wal, :feed, :stopped]` (see
  [Telemetry](#telemetry));
* every live subscription with a `table=` in it — including one that mixes
  `channel=` and `table=`, whose table half can never deliver again — ends
  with `event: bier:closed` / `data: {"reason":"feed_stopped"}` (see
  [Connection lifecycle](#connection-lifecycle)); `channel=`-only streams
  carry on;
* new `table=` subscriptions and `Last-Event-ID` resumes are refused with
  `503 BIER004` (see [Errors](#errors)) instead of a stream that would
  never deliver.

The admin `/ready` endpoint does **not** reflect the feed: it reports
whether the API can serve, and the API still can. Watch the telemetry event
(or the error log) for the feed.

Individual consumer crashes are not all logged: one that raises leaves a
crash report, but a process killed outright (`:kill`) leaves nothing — the
reset its subscribers receive is the trace.

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
the *first* dot only, so a table whose own name contains a literal `.` must
always be written qualified (`billing.odd.name` resolves to schema
`billing`, table `odd.name`); the bare form is not addressable, because the
first dot would be read as the schema separator.

A table is subscribable only when it is in the publication, in an exposed
schema, has no RLS enabled, and the connecting role has `SELECT` on at
least one column — see [Errors](#errors) above for what an unmet condition
returns. In short, a table is subscribable when PostgreSQL's
`pg_publication_tables` lists it for the publication, because that is
exactly the name the replication stream reports its changes under.
Partitioned tables follow from that rule (see
[Partitioned tables](#partitioned-tables) below).

Every `table=` refusal is **byte-identical** — the same `404 BIER003` body
for a given request, whatever the reason — but **not time-identical**. A name in a schema outside
`db_schemas`, one using the reserved `bier:` prefix, and any `table=`
request when `events_publication` is not configured are all refused without
a database round trip; the existence, table-kind, publication, RLS,
privilege and role-membership checks all run in one query and cost one. A client timing refusals can therefore tell
"refused by the instance's configuration" from "checked against the
database". That is a deliberate trade: the round-trip gap reveals only
configuration the operator chose. The one query's own cost is not equalized
either, but bier adds no data- or existence-dependent branch around it.

### Partitioned tables

A partitioned table can be subscribed through a publication created
**`WITH (publish_via_partition_root = true)`**:

```sql
CREATE PUBLICATION bier_events FOR TABLE orders
  WITH (publish_via_partition_root = true);
```

```bash
curl -N "http://localhost:4040/events?table=orders"   # orders PARTITION BY ...
```

With that setting PostgreSQL reports every change in the partition tree,
at any depth, as the partitioned table: `event: orders` and
`"table":"orders"`, whichever partition the row is stored in. Bier relays the name
PostgreSQL gives each change and never looks up partition membership on
its own. PostgreSQL resolves the name against the catalog **as of that
change**, so `ATTACH PARTITION` and `DETACH PARTITION` take effect exactly
at the DDL's position in the stream:

* rows written to a table before it was attached never reach the
  partitioned table's subscribers;
* changes made to a partition before it was detached still do;
* after a detach, the table's changes stop unless it is published on its
  own.

What the publication setting means for each kind of table:

| | `publish_via_partition_root = true` | `false` (PostgreSQL's default) |
|---|---|---|
| The partitioned table | Subscribable: its changes are reported under its name. | Refused (`404 BIER003`). PostgreSQL reports its changes under the leaf partitions, so it would never receive anything. |
| A leaf partition | Refused (`404 BIER003`) whenever an ancestor is published, because PostgreSQL never names it. | Subscribable as an ordinary table, receiving its own changes under its own name. |

More precisely, the subscribable table is the **topmost published
ancestor**. If only an intermediate level of a multi-level tree is in the
publication, that intermediate table is subscribable, and its parent and
its own partitions are not. A `FOR TABLES IN SCHEMA` publication publishes
the tables in that schema: a partitioned table in an unpublished schema is
not subscribable, even though some of its partitions are in the published
one. Those partitions are then subscribable as themselves. In every case,
the rule is the one above: subscribable means listed in
`pg_publication_tables`.

**Authorization is the partitioned table's own**, the same as for a query
against it. Its `SELECT` and column grants decide whether the subscription
is allowed and which columns the frames carry, and its RLS flag refuses the
subscription. A grant on a partition does not make the partitioned table
subscribable, and RLS enabled on a partition alone does not refuse it. A
row filter or column list on the publication entry (PostgreSQL 15+)
applies as it does to any published table: rows the filter excludes are
never streamed, and columns outside the list never appear.

What the frames look like:

* **A cross-partition `UPDATE`** (one that moves a row into another
  partition) arrives as a `DELETE` followed by an `INSERT`, both under the
  partitioned table's name. That is how PostgreSQL logs it. There is no
  `UPDATE` frame for such a change.
* **`old` and `old_kind`** depend on two settings. The *partition's*
  `REPLICA IDENTITY` decides what PostgreSQL logs. The *partitioned
  table's* decides how that image is labelled (`"full"` or `"key"`). A
  `"key"` image is reduced to the partitioned table's identity columns.
  Give the partitioned table and every partition **the same** `REPLICA
  IDENTITY`. A mismatch either hides logged columns (`FULL` partition,
  `DEFAULT` parent) or reports a column that was never logged as `null`
  under `"full"` (`DEFAULT` partition, `FULL` parent, when the key
  changes). Bier checks this when the feed starts and logs a warning
  naming every partition whose identity differs from its partitioned
  table's. `USING INDEX` counts as a match only when the partition's
  identity index is a partition of the parent's. See
  [`REPLICA IDENTITY` and `old`](#replica-identity-and-old) below.
* **`TRUNCATE` of the partitioned table** arrives as one `TRUNCATE` frame
  naming it.
* **`TRUNCATE` of a single partition is never published.** PostgreSQL
  skips a `TRUNCATE` that names only partitions when publishing via the
  root. No event and no `bier:reset` reaches subscribers, who keep rows
  that no longer exist. Bier cannot detect it, because nothing arrives,
  and logs a warning when the feed starts with such a publication. If
  subscribers must see it, truncate the partitioned table itself, or
  `DELETE` from the partition, which streams row by row.
* **Unlogged and foreign partitions never stream**: an unlogged table
  writes no WAL, and a foreign table's rows live in another server.

### Frame format

`event:` is derived from the *resolved* schema, not from how the client
happened to spell it: qualified (`schema.table`) only when that resolved
schema differs from the default (the first of `db_schemas`), unqualified
otherwise — so a redundant `table=<default_schema>.orders` still yields
`event: orders`, exactly like an unqualified `table=orders` would. `id:` is
a resume cursor; `data:` is one JSON object per row-level change:

```
event: orders
id: 0/1A2B3C40.2
data: {"type":"UPDATE","schema":"api","table":"orders",
       "commit_at":"2026-08-24T03:11:30.972793Z",
       "row":{"id":3,"name":"grace","payload":{"answer":42},"tags":"{a,b}"},
       "old":{"id":3},"old_kind":"key","unchanged":[]}
```

(`data:` is wrapped above across four lines for readability only — on the
wire it is a single `data:` line, one complete JSON object with no
embedded newlines, per the SSE spec.)

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
ALTER TABLE orders REPLICA IDENTITY NOTHING; -- see below: mutations stop working instead
```

Under `DEFAULT` (and `USING INDEX`), `old` carries the identity columns and
*only* those: PostgreSQL nulls every other attribute before writing the old
tuple, so reporting them would be indistinguishable from columns that
genuinely held `NULL`. Note also that `DEFAULT` logs an old tuple **only
when the identity columns themselves changed** — an ordinary `UPDATE` that
leaves the primary key alone carries no `old` and no `old_kind` at all
(the keys are absent, not null). A `DELETE` always carries one. Under
`FULL` every column is logged, `old_kind` is `"full"`, and both
`UPDATE` and `DELETE` always carry a complete pre-image.

`NOTHING` is not a quieter version of `DEFAULT` — for a table in a
publication that publishes `UPDATE`/`DELETE` (the default), PostgreSQL
refuses the mutation outright at the SQL level: `UPDATE`/`DELETE` against
that table fails with `cannot update/delete from table "orders" because it
does not have a replica identity and publishes updates/deletes`. No frame
is ever produced, because the write itself never succeeds. In practice:
leave tables at the default identity (`old` carries the primary key) unless
you need the full previous row (`FULL`); reach for `NOTHING` only on a
table you also exclude from `UPDATE`/`DELETE` in the publication (e.g.
`FOR TABLE ... WITH (publish = 'insert')`).

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

A cursor that *does* parse but can no longer be honored gets an explicit
control frame instead of a silent gap, then the live head — for a cursor
minted before the consumer last restarted:

```
event: bier:reset
data: {"reason":"stream_restarted"}
```

and for one this stream did issue, but whose history the ring buffer has
since lost, `{"reason":"history_evicted"}` (see the table below).

`bier:` is a reserved `event:` prefix that can never collide with a channel
or table name; it spells the stream's control frames, `bier:reset` and
`bier:closed` (see [Connection lifecycle](#connection-lifecycle)). v1
defines exactly three reset reasons:

| Reason | When |
|---|---|
| `stream_restarted` | The replication consumer (re)connected — a fresh temporary slot always begins at the current LSN. Every currently-open table subscriber gets this pushed live, mid-stream, and a connection that resumes with a cursor minted before that restart gets it too: everything before the restart is gone, for every subscriber. |
| `history_evicted` | A connection resumes with a cursor from the current stream that the ring buffer can no longer replay: it aged out, an oversized transaction dropped that table's history, or a DDL changed the table's columns. History is still flowing — this subscription merely fell behind. Also pushed live, mid-stream, for the tables of a transaction that was delivered but could not be recorded for resume because the ring buffer was momentarily unavailable. |
| `transaction_too_large` | A single transaction exceeded `events_max_tx_events`, or accumulated more than 64 MiB of event payload; its events are dropped rather than delivered, and every table it touched gets this pushed live (see [Limits](#limits)). |

A subscription naming more than one table resets **as a whole** the moment
any single one of them has lost history — not just that table. Client
contract on any `bier:reset`: it means "some history is gone," not
"something is wrong" — re-bootstrap with a plain `GET` (dropping
`Last-Event-ID`) and keep listening; the SSE connection itself stays open
across a reset.

Delivery promise: **in-order, exactly-once while connected; at-least-once
across reconnects within the buffer window (dedupe by `id`); explicit reset
beyond it.** Every degradation is announced, never silent, with one
exception PostgreSQL imposes: a `TRUNCATE` of a single partition of a
table published `WITH (publish_via_partition_root = true)` is never
published at all, so nothing arrives to announce (see
[Partitioned tables](#partitioned-tables)).

### Connection lifecycle

A response carrying any `table=` subscription also sends `Connection:
close` — a NOTIFY-only `channel=` response does not. The server can end a
WAL stream on its own at any moment — a schema-cache reload finding the
subscriber's role lost its privileges, the token expiring, the feed being
given up on, or the subscriber falling too far behind (see
[Limits](#limits)) — so the connection is declared non-keepalive up front
rather than handed back to a pool as if it were reusable. A consumer
restart does **not** end the stream: it arrives as a `bier:reset` on a
connection that stays open.

When the server ends a stream deliberately, it says why first, with one
terminal frame, then closes the connection:

```
event: bier:closed
data: {"reason":"revoked"}
```

| Reason | When | What the client should do |
|---|---|---|
| `revoked` | A schema reload found the role no longer authorized for a subscribed table (its last visible column, the table's publication membership, or the table itself is gone), or the role itself was dropped. A failed or interrupted re-check never revokes — the subscription stands until a reload can actually confirm the loss. | Stop. Reconnecting gets the refusal instead of a stream — `404 BIER003`, or `400 42704` for a dropped role (see [Errors](#errors)). Subscribe again once access is restored. |
| `token_expired` | The JWT that opened the stream reached its `exp` (plus 30s skew). | Open a new `EventSource` with a fresh token, passing `?last_event_id=` to resume (see [Authentication](#authentication)). |
| `feed_stopped` | The instance's WAL change feed was given up on (see [Enabling](#enabling)). Also closes a subscription mixing `channel=` and `table=`. | Stop. Table subscriptions get `503 BIER004` until the instance is restarted; a `channel=`-only subscription still works. |

It is deliberately not a `bier:reset`: a reset only ever means "history is
gone, re-bootstrap and keep listening," and the connection stays open
across a reset but not across this. There is no `id:` — there is nothing
to resume from it.

A client that receives `bier:closed` should **stop the transport from
reconnecting on its own**. `bier:closed` is a named event, so it never
reaches `onmessage` — listen for it explicitly:

```javascript
es.addEventListener("bier:closed", (e) => {
  es.close();
  const { reason } = JSON.parse(e.data);
  // revoked / feed_stopped: stop; token_expired: reopen with a fresh token
});
```

Otherwise `EventSource` reconnects into the refusal, and it treats any
response other than `200` with `Content-Type: text/event-stream` as fatal
and stops retrying for good — a later re-grant, fresh token or restored
feed would never bring that subscription back on its own. Once the cause is
resolved, open a fresh subscription and re-bootstrap with a plain `GET`
exactly as after a `bier:reset` (or resume with `?last_event_id=` after a
`token_expired`).

### Limits

* **A transaction is also capped at 64 MiB of event payload** — the decoded
  column values pgoutput sends, new plus old row images (an `UPDATE` under
  `REPLICA IDENTITY FULL` counts both; unchanged TOASTed values and
  `TRUNCATE` count zero), not the size of the rendered frames. It applies
  independently of `events_max_tx_events` and is not configurable: it is a
  process-heap backstop, so a transaction of few but very wide rows (large
  `text`/`jsonb` values) can be dropped with `transaction_too_large` well
  before it reaches the event cap. Size `events_max_tx_events` with that
  ceiling in mind.
* **One temporary replication slot per instance**, minted at boot and
  re-minted on every consumer restart; it counts against PostgreSQL's
  `max_replication_slots` (default `10`) like any other slot.
* **RLS tables refuse subscription** in v1 — per-event row-security
  evaluation is future work.
* **Partitioned tables need `publish_via_partition_root = true`.** Without
  it, only their leaf partitions are subscribable. With it, the leaves are
  not, and a `TRUNCATE` of a single partition is never published (see
  [Partitioned tables](#partitioned-tables) above).
* **A table whose name begins with `bier:` cannot be subscribed** — that
  prefix is reserved for the stream's own control frames (`event:
  bier:reset`, `event: bier:closed`), and `events_channels` is held to the
  same reservation at boot.
* **Table names containing a literal `.` must be written schema-qualified**
  — the qualifier is split off at the first dot only, so the bare form is
  unaddressable.
* **A multi-table subscription resets as a whole** when any one of its
  tables loses history (see [Resume and reset](#resume-and-reset) above).
* **Connections that stop reading are disconnected** once ~1,000 frames
  back up in their mailbox — bounded memory by construction; reconnecting
  with the cursor resumes from the ring buffer.
* **`REPLICA IDENTITY` governs `old`** — see above.
* **The ring buffer retains history for every published table**, subscribed
  or not, so its footprint is `published tables × events_buffer_size`
  entries — not `events_buffer_size` overall. (Column metadata is stored
  once per table rather than per entry, so an entry costs about its row
  payload.) Scope the publication to the tables that are actually
  subscribable rather than reaching for `FOR ALL TABLES`.
* **A DDL that changes a table's columns invalidates that table's buffered
  history**, because entries retained from before the change were decoded
  against the old column list. A client resuming across such a change gets
  the ordinary `bier:reset` rather than mislabeled rows; live delivery is
  unaffected.
* **A privilege change reaches live subscribers on the next schema reload**,
  and does so immediately: the re-authorization runs centrally, one query
  per distinct role over the union of that role's subscribed tables, so it
  costs a handful of round trips however many subscribers there are. A
  subscription whose grants merely narrowed keeps streaming with the
  reduced column set; one that lost its last visible column, its
  publication membership, or its table is closed, after a terminal
  `bier:closed` frame (see [Connection lifecycle](#connection-lifecycle)).
* **A subscription ends when its JWT expires.** The token is verified at
  connect like any request; the stream is then bounded by that token's
  `exp` (plus the same 30s skew allowance the request path uses) rather
  than living on indefinitely, and ends with `bier:closed`
  `token_expired`. An `EventSource` reconnect would resend the expired
  token, so open a new one with a fresh token and `?last_event_id=` to
  resume by cursor.
* **`Connection: close` is only sent over HTTP/1.1.** The header is
  malformed in HTTP/2, so on an h2 connection it is omitted.
* A bier restart always starts a fresh replication slot at the current LSN;
  there is no cross-restart resume in v1 (a possible future addition), only
  the in-process ring buffer described above.
