# SSE Realtime Events — Design

**Issue:** [#81](https://github.com/milmazz/bier/issues/81)
**Date:** 2026-07-16
**Status:** Approved design, pre-implementation

## Summary

A config-gated Server-Sent Events endpoint on the main API that bridges
PostgreSQL `LISTEN`/`NOTIFY` to HTTP streaming clients. This is a raw
notification bridge: the database author decides what to `NOTIFY` (triggers,
application code); bier relays payloads verbatim. It is bier's flagship
differentiator versus PostgREST, where this has been requested since 2019
(PostgREST/postgrest#1388, #4746) and never landed because a stateless
request/response architecture fights long-lived streaming connections.

Out of scope for v1 (explicitly): table change feeds / auto-installed
triggers, replay or durable delivery, logical decoding, a DB-function
channel authorizer (the config is shaped so one can slot in later).

## Decisions

| Question | Decision |
|---|---|
| Scope | Raw NOTIFY→SSE bridge; payloads relayed verbatim |
| Placement | Main API server, config-gated path segment (default `events`), off by default |
| Authorization | Static channel allowlist + the instance's standard JWT gate |
| Delivery semantics | Fire-and-forget (at-most-once); heartbeats + `retry:` hint; no replay |
| Wire shape | One multiplexed connection; SSE `event:` field = channel, `data:` = payload |
| Fan-out topology | One shared listener GenServer per instance + duplicate-keys Registry dispatch |

## Configuration

Three new keys in `Bier.schema/0` (NimbleOptions, flat `events_*` style):

| Key | Type | Default | Meaning |
|---|---|---|---|
| `events_channels` | list of strings | `[]` | Allowlisted channels. **Feature switch**: empty = fully disabled, zero routing impact. Names are `quote_ident`-quoted at LISTEN time, so any valid Postgres channel name works. |
| `events_path` | string | `"events"` | Reserved top-level path segment, only reserved while the feature is on. Users with an `events` relation pick another prefix. |
| `events_heartbeat_interval` | pos. integer (ms) | `15_000` | Silence interval before a keepalive comment is written. Exists for proxy tuning and for tests to shrink. |

A future `events_authorizer` (e.g. `{:function, "api.can_subscribe"}`) can be
added without breaking these keys.

## Components

All new code lives under a `Bier.Events` namespace.

1. **`Bier.Events.Registry`** — a plain `Registry` with `keys: :duplicate`,
   started in `Bier.Application` next to `Bier.Registry` (same rationale:
   node-shared infrastructure; per-instance entries). Subscribers register
   under `{instance_name, channel}`; process death auto-cleans entries, so
   there is no unsubscribe bookkeeping.
2. **`Bier.Events.Listener`** — per-instance GenServer cloned from
   `Bier.SchemaCacheListener`'s connection-ownership pattern: dedicated
   `Postgrex.Notifications` connection (`sync_connect: true`,
   `auto_reconnect: false`), traps exits, exponential backoff 500 ms → 30 s.
   On connect it LISTENs on **every** allowlisted channel (the allowlist is
   static, so no dynamic listen/unlisten refcounting exists). On
   `{:notification, _, _, channel, payload}` it calls `Registry.dispatch/3`
   on `{name, channel}`, sending `{:bier_event, channel, payload}` to each
   subscriber. No other state.
3. **`Bier.Events.SSE`** — pure frame-encoding functions: event/data
   framing, multi-line payload splitting, heartbeat comment, `retry:` hint.
   No process machinery; unit-testable in isolation.
4. **`Bier.Events`** — the request handler invoked from
   `Bier.Plugs.ActionController.dispatch/3`: validates and authorizes the
   subscription, then owns the chunked-response loop inside the Bandit
   connection process.

### Supervision

The listener joins the `Bier` supervisor's children gated the same way
`listener_children/1` gates `SchemaCacheListener`: present only when
`events_channels != []`, started after the Postgrex pool. It is a
**separate** connection from the schema-cache listener — sharing one LISTEN
connection would couple schema-reload semantics to a user-facing feature to
save a single connection. A database outage never crash-loops the instance:
the listener backs off and retries while connected SSE clients receive
nothing (permitted by the fire-and-forget contract).

## Request flow

**Routing.** One new clause in `ActionController.dispatch/3`, checked before
relation dispatch: matches when `config.events_channels != []` and
`conn.path_info == [config.events_path]`. Feature off → clause never
matches → an `events` relation keeps working exactly as today. Only `GET`
is accepted; other methods → `405` via the existing FallbackController path.

**Validation order:**

1. **Parse channels** — every `channel` query param, each split on commas
   (`?channel=chat,jobs` and `?channel=chat&channel=jobs` both work).
   No `channel` param, or an empty value → `400` with code `BIER002`.
2. **Authorize** — every requested channel must be in `events_channels`;
   first miss → `404` with code `BIER001` (details name the rejected
   channel). Both are new `FallbackController.call/2` clauses using the
   standard `{code, message, details, hint}` envelope with a `BIER`-prefixed
   code namespace — never colliding with present or future `PGRST*` codes.
   `405`/`406` reuse the existing `:method_not_allowed` /
   `:not_acceptable` mappings.
3. **Authenticate** — reuse `ActionController.maybe_auth/2` (same JWT
   verification, same 401 envelope). SSE-specific addition, this endpoint
   only: token resolution is `Authorization` header first, then an
   `access_token` query param fallback — the browser `EventSource` API
   cannot set headers, so without the fallback browser clients cannot
   authenticate. The role is used for authentication only in v1; no query
   runs on behalf of the subscriber.
4. **Negotiate** — `Accept` must admit `text/event-stream` (`*/*` and a
   missing header count) → else `406`.

**The stream.** The handler sends `200` via `send_chunked` with:

```
content-type: text/event-stream; charset=utf-8
cache-control: no-store
x-accel-buffering: no
```

writes an opening `retry: 3000` hint plus a `: connected` comment frame,
registers itself in `Bier.Events.Registry` under `{name, channel}` for each
requested channel, and enters a receive loop in the Bandit connection
process:

- `{:bier_event, channel, payload}` → one SSE frame; `event:` is the
  channel, `data:` is the payload **verbatim**:

  ```
  event: chat
  data: {"user":"ana","msg":"hi"}

  ```

  A payload containing newlines is split across consecutive `data:` lines
  (per the SSE spec; clients reassemble losslessly). An empty payload still
  emits a `data:` line so the client event fires.
- `events_heartbeat_interval` of silence → `: keepalive` comment.
- Any chunk write returning `{:error, _}` → exit the loop normally;
  Registry entries auto-clean on process exit.

Disconnect detection is bounded by the heartbeat interval (a dead client
costs at most one wasted write per interval). Slow clients hurt only
themselves: `Registry.dispatch` sends plain messages, so backpressure lands
in that subscriber's mailbox and socket, never in the listener or other
subscribers. A mailbox-size guard on heartbeat ticks is documented future
hardening, not implemented in v1.

Compression is already disabled instance-wide (`compress: false` in
`Bier.HttpServerStarter`), which SSE requires — no change needed.

## Failure modes

- **Listener loses its connection** — backoff/reconnect like
  `SchemaCacheListener`; subscribers stay connected and silently miss events
  in the gap (the documented contract; no catch-up exists or is attempted).
  `Logger.warning` on drop and reconnect.
- **Listener crashes** — supervised restart re-LISTENs everything.
  Subscribers are unaffected (Bandit processes registered in the Registry,
  not linked to the listener).
- **NOTIFY payload > 8000 bytes** — Postgres rejects it at `NOTIFY` time; it
  can never reach bier. Documented with the standard workaround: notify a
  key, fetch the row through the regular API.
- **Instance shutdown** — Bandit's supervisor tears down connection
  processes; nothing special.

## Telemetry

Extends the `[:bier, …]` conventions in `Bier.Telemetry`:

- `[:bier, :events, :subscribe]` — start/stop span per SSE connection;
  metadata: instance, channels, disconnect reason; stop measurements include
  events delivered.
- `[:bier, :events, :notification]` — per NOTIFY dispatched; measurement:
  subscriber count (0 reveals orphaned channels).
- `[:bier, :events, :listener]` — `:connected` / `:disconnected`, for
  alerting on gap windows.

## Testing

All additive; `spec/**` and `test/conformance/**` untouched (frozen ground
truth).

- **Unit** — `Bier.Events.SSE` frame encoding (multi-line payloads, empty
  payload, heartbeat, retry hint); channel param parsing; allowlist
  rejection.
- **Integration** — new `test/bier/events_test.exs` with a dedicated test
  instance (`events_channels` configured, heartbeat shrunk to ~50 ms):
  subscribe with Req streaming (`into:`), fire `NOTIFY` via a plain Postgrex
  query, assert the frame; multiplexing across two channels via the `event:`
  field; `400`/`404`/`401`/`405`/`406` envelopes; heartbeat arrival; client
  disconnect → Registry entry removed; JWT via `access_token` query param.
- **Resilience** — kill the listener's notifications connection; assert
  reconnect and re-LISTEN.

## Documentation

- New guide `docs/guides/realtime_events.md`, added to the ExDoc `extras`
  in `mix.exs` (Reference group): configuration, browser `EventSource` and
  `curl` examples, the auth story including the `access_token` fallback, and
  an honest "delivery semantics & limits" section (fire-and-forget, 8 KB
  payload cap, notify-key-then-fetch pattern).
- New tutorial `docs/tutorials/realtime.md` (Tutorials group), continuing
  the brewery storyline from `docs/tutorials/brewery.sql`: a trigger on new
  orders (`NOTIFY new_orders, row id`) driving a live orders board via
  `EventSource`, ending with a pointer to the guide.
- Comment on issue #81 linking this spec once committed.
