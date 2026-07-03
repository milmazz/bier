# Schema-Cache Reload via LISTEN/NOTIFY — Design

- **Date:** 2026-07-03
- **Issue:** [#29 — [feature] Schema-cache reload via LISTEN/NOTIFY (db-channel)](https://github.com/milmazz/bier/issues/29)
- **Status:** Approved (decisions locked during brainstorm with the project owner)
- **Implementation plan:** `docs/superpowers/plans/2026-07-03-schema-cache-reload.md`

## Problem

Bier introspects the database exactly once, at boot (`Bier.HttpServerStarter.init/1`),
and never re-introspects. Any DDL change — a new table, column, or foreign key —
is invisible until the instance restarts. PostgREST reloads its schema cache on
demand via `NOTIFY pgrst, 'reload schema'` on a configurable channel
(`db-channel`, gated by `db-channel-enabled`) or via SIGUSR1. This is the
standing TODO in `lib/bier/http_server_starter.ex` and a `DEFERRED` scope
decision in `spec/COVERAGE.md` (`schema_cache` and `listener` pages).

## Key insight: the router does not need rebuilding

Issue #29 asks to "re-run introspection **and rebuild the per-instance Router**
… atomically, without dropping in-flight requests" and to "decide the
rebuild/swap mechanism" for the `Module.create/3`-generated router. That
requirement is **obsolete**: since the router became a thin catch-all,
`Bier.RouterBuilder.build/2` ignores its `_db_structure` argument entirely —
every request resolves `{schema, relation}` at request time from the
`:persistent_term` cache. A reload is therefore **only a data swap**: re-run
introspection, atomically replace the cached snapshot. No module regeneration,
no version suffix, no Bandit restart, and in-flight requests are untouched by
construction.

## Goals

1. `NOTIFY <db_channel>, 'reload schema'` re-runs introspection and atomically
   swaps the instance's schema cache, PostgREST-compatibly.
2. New config options `db_channel` (default `"pgrst"`) and `db_channel_enabled`
   (default `true`), with `PGRST_DB_CHANNEL` / `PGRST_DB_CHANNEL_ENABLED` CLI
   parity.
3. A programmatic API — `Bier.reload_schema_cache/1` — the in-BEAM equivalent
   of PostgREST's SIGUSR1, working whether or not the listener is enabled.
4. A reload failure never degrades a serving instance: the previous snapshot
   stays in place.
5. A database outage never crash-loops the instance's supervisor.

## Non-goals (explicitly out of scope for v1)

- **`reload config`.** PostgREST's listener also accepts `'reload config'`
  (and an empty payload means "reload both"). Bier's config is supplied by the
  host application at `Bier.start_link/1`, so there is nothing to re-read;
  `'reload config'` is a **logged no-op** (owner decision). Re-reading
  in-database `pgrst.*` role settings can be a follow-up.
- **SIGUSR1.** OS-signal handling only makes sense for the standalone
  CLI/escript; `Bier.reload_schema_cache/1` is the library-level equivalent.
  Deferred.
- **Conformance cases.** `spec/COVERAGE.md` keeps `schema_cache` / `listener`
  DEFERRED: there is no reload-signal conformance harness, and `spec/**` plus
  the harness under `test/support/` are frozen ground truth. Coverage lands as
  regular ExUnit tests in **new files** under `test/bier/` instead.
- **The DDL `event_trigger`.** PostgREST documents an optional user-side
  event trigger that auto-NOTIFYs on every DDL change. Bier documents the same
  SQL snippet in the README; it is not created by the library.

## Decisions made during the brainstorm

| # | Decision | Choice |
|---|----------|--------|
| 1 | Default for `db_channel_enabled` | **`true`** — PostgREST parity (owner reversed an earlier `false` decision) |
| 2 | Four `:persistent_term` keys vs. one | **Single key** holding one struct — the atomic swap is the point of the feature; refactor is bundled |
| 3 | `'reload config'` payload | **Logged no-op** in v1 |
| 4 | Listener supervision placement | **Option A** — static, config-gated child of the `Bier` supervisor that owns its connection and reconnects with internal exponential backoff |
| 5 | Development method | **TDD** — red before green for every step |

### Decision 4 trade-offs, as discussed

- **Option A — static child of the `Bier` supervisor** *(chosen)*: membership
  is decided by validated config (same pattern as the admin server); the
  listener has no dependency on introspection results, so nothing justifies
  deferred starting. The one hazard — a crash-looping listener exceeding the
  supervisor's restart intensity and killing the whole instance, HTTP included —
  is **designed away** rather than contained: the listener never crashes on
  connection failure; it retries internally with exponential backoff.
- **Option B — started by `HttpServerStarter` under the per-instance
  `DynamicSupervisor`** (next to Bandit): sequencing after boot introspection
  comes free, but it does not isolate failures (a listener crash-loop kills
  the DynamicSupervisor **and Bandit with it**), membership becomes
  runtime-imperative, and an `HttpServerStarter` restart must dodge duplicate
  listeners. Rejected.
- **Option C — dedicated wrapper supervisor** with tuned restart intensity:
  real blast-radius isolation, but it is a permanent extra supervision layer
  that treats a symptom which only exists if the listener crashes on
  disconnect. Rejected in favor of not crashing.

## Architecture

Four small units, each independently testable:

```
Bier (Supervisor, per instance)
├── Postgrex pool                (existing)
├── DynamicSupervisor → Bandit   (existing)
├── Bier.HttpServerStarter       (existing — now delegates to Bier.SchemaCache)
├── Bier.SchemaCacheListener     (NEW — only when db_channel_enabled)
└── admin Bandit                 (existing, optional)
```

### 1. `Bier.SchemaCache` (new module — snapshot owner)

The introspection snapshot becomes one struct in one `:persistent_term` entry:

- Key: `{Bier, :schema_cache, name}` (replaces the four keys
  `{Bier, :relations | :functions | :media_handlers | :schema_comment, name}`).
- Value: `%Bier.SchemaCache{relations: %{}, functions: %{}, media_handlers: [],
  schema_comment: nil}`.
- API: `load!/3` (runs the four `Bier.Introspection` queries inside the
  existing `[:bier, :schema_cache, :load, *]` telemetry span), `put/2`
  (atomic swap), `get/1`, `relations/1`, `functions/1`, `media_handlers/1`,
  `schema_comment/1`, `loaded?/1`, and `reload/1`.

**Why single-key:** with four separate `put`s, a request in flight during a
reload can read new relations but old functions. One term makes the swap
atomic — a reader sees the old snapshot or the new one, never a mix.
`:persistent_term.put/2` on an existing key triggers a global GC pass, which
is acceptable at reload frequency (DDL changes) and is documented on the
module.

All ten existing read sites (`ActionController` ×3, `Rpc` ×2, `Mutation`,
`Plan`, `CustomMedia`, `Health`, plus the OpenAPI builder) route through the
new accessors. The OpenAPI builder reads **one** `get/1` snapshot, gaining the
atomicity the old code lacked.

### 2. `Bier.SchemaCacheListener` (new module — the `db-channel` transport)

A `GenServer`, registered as `Bier.Registry.via(name, Bier.SchemaCacheListener)`,
started as a static child **after** `Bier.HttpServerStarter` (so the boot load
has already happened) and only when `db_channel_enabled`.

- Owns a **dedicated** `Postgrex.Notifications` connection (`LISTEN` cannot go
  through the request pool), built from `Bier.postgrex_opts/1` minus
  `:name`/`:pool_size`, with `sync_connect: true` and `auto_reconnect: false`.
- **Connection lifecycle:** the listener traps exits. A failed connect
  (`{:error, reason}` from `start_link`) or a lost connection (`:EXIT` from the
  linked notifications process) schedules a reconnect via
  `Process.send_after/3` with exponential backoff (500 ms doubling to a 30 s
  cap, reset on success). The listener process itself never dies from DB
  unavailability, so the instance's supervisor never sees restart pressure.
  This follows Postgrex's own documented recommendation to avoid
  `auto_reconnect` in favor of monitoring and re-subscribing.
- **Reload-on-re-LISTEN:** notifications sent while disconnected are lost
  forever, so after every **re**-connect the listener reloads unconditionally
  (PostgREST does the same on reconnection). The very first connect skips this
  — boot introspection just ran.
- **Payload dispatch** (exact match, PostgREST semantics):
  - `"reload schema"` → coalesce + reload;
  - `""` (empty = PostgREST's "reload schema **and** config") → coalesce +
    reload (the config half is a no-op per Decision 3);
  - `"reload config"` → `Logger.info` no-op;
  - anything else → `Logger.debug`, ignored.
- **Coalescing:** before reloading, drain every already-queued reload signal
  from the mailbox, so a migration that fires N NOTIFYs (e.g. via a DDL event
  trigger) causes one introspection run, not N.
- **Failure keeps the old cache:** the swap happens only after a fully
  successful introspection; a failed reload logs an error (and emits the
  telemetry span's `:exception` event) and leaves the previous snapshot
  serving. Consequently `/ready` stays 200 on a failed reload — the instance
  is still serving a valid (stale) cache.

### 3. Configuration

Library options (`Bier.schema/0`, validated into `Bier.Config`):

| Option | Type | Default | PostgREST key |
|--------|------|---------|---------------|
| `db_channel` | `:string` | `"pgrst"` | `db-channel` |
| `db_channel_enabled` | `:boolean` | `true` | `db-channel-enabled` |

`Bier.Config.new!/2` additionally validates `db_channel` as non-empty and at
most 63 bytes (the Postgres identifier limit). `Postgrex.Notifications.listen/3`
enforces the same bound at runtime by raising — validating at boot converts a
would-be listener crash-loop into a fast, clear `ArgumentError`. (PostgREST
does not validate this key; the check is library-enforced, like the
admin-port collision rule.)

CLI (`Bier.CLI.Config.spec/0`): new entries `db-channel` /
`PGRST_DB_CHANNEL` (kind `:string`, default `"pgrst"`) and
`db-channel-enabled` / `PGRST_DB_CHANNEL_ENABLED` (kind `:bool`, default
`true`), mapped in `to_start_opts/1`. `--dump-config` output stays correct for
free — `dump/1` sorts keys alphabetically.

### 4. Public API

`Bier.reload_schema_cache(name)` — delegates to `Bier.SchemaCache.reload/1`:
resolves the instance's config and pool from `Bier.Registry`, re-runs
`load!/3`, swaps on success. Returns `:ok`, `{:error, :unknown_instance}` for
an unregistered name, or `{:error, reason}` on introspection failure (old
snapshot kept). Works with the listener disabled — hosts can wire it to deploy
hooks, admin endpoints, or their own signal handling.

## Telemetry

No new events. Every reload reuses the existing
`[:bier, :schema_cache, :load, :start | :stop | :exception]` span (metadata:
`:instance`, `:schemas`; `:stop` carries `:relation_count`), so host metrics
for boot loads automatically cover reloads — mirroring PostgREST's
`pgrst_schema_cache_loads_total{status}`.

## Error handling summary

| Failure | Behavior |
|---------|----------|
| DB unreachable at listener boot | Listener stays up, retries with backoff (500 ms → 30 s cap); instance serves normally |
| LISTEN connection drops | Same backoff; on re-LISTEN, unconditional reload catches up on missed signals |
| Introspection fails during reload | `{:error, reason}` logged; previous snapshot keeps serving; `/ready` stays 200; telemetry `:exception` emitted |
| `db_channel` empty or > 63 bytes | `ArgumentError` at `Bier.start_link/1` (fail fast, no runtime crash-loop) |
| NOTIFY burst (N signals) | Coalesced into one reload |
| `reload config` / unknown payload | Logged no-op / ignored with debug log |

## Testing strategy

Constraints: `test/support/**`, `test/conformance/**`, and `spec/**` are
frozen. All new coverage lands in **new files** under `test/bier/`, following
the `admin_server_test.exs` precedent (dedicated instances on free ports
against the `bier_test` fixture DB, `Bier.ConformanceServer.base_opts/0` for
credentials).

- **Unit:** `Bier.SchemaCache` accessors and atomic single-key swap;
  `db_channel`/`db_channel_enabled` validation; CLI mapping.
- **Integration** (`test/bier/schema_cache_listener_test.exs`): boot a
  dedicated instance with a **unique channel name** (never `"pgrst"` — the
  shared conformance instance now listens there by default), `CREATE TABLE` +
  `GRANT SELECT`, assert 404, `NOTIFY <channel>, 'reload schema'`, await the
  `[:bier, :schema_cache, :load, :stop]` telemetry event via
  `:telemetry_test.attach_event_handlers/2` (deterministic — no sleeps for the
  positive path), assert 200. Plus: `'reload config'` logged no-op, unknown
  payload ignored, `db_channel_enabled: false` starts no listener, public-API
  reload, soft coalescing bound.
- **Failure-keeps-cache** is structural (the swap is written only after
  `load!/3` returns) and its rescue branch is exercised by the
  unknown-instance test; no deterministic in-suite fault-injection point
  exists without mocking, and the design accepts that.
- **Regression net:** the untouched 532-case frozen conformance suite must
  stay green after the read-site migration.
- `test/bier/health_test.exs` (pre-existing) writes the **old**
  `{Bier, :relations, name}` key and asserts `refute ready?` in both tests;
  after the migration that write is inert and both tests still pass unchanged
  — verified against its source; the file is not edited.

## Operational notes

- Enabling by default costs **one extra DB connection per instance**. In the
  conformance suite (shared instance + ~18 variants) that is ~19 extra
  connections on top of ~46 pooled ones — comfortably inside Postgres'
  default `max_connections = 100`, but worth remembering when adding variants.
- Multiple Bier instances on the same database and channel each hold their own
  LISTEN connection; one `NOTIFY` reloads all of them — same as running
  several PostgREST replicas.
- Channel names are case-sensitive on the Postgres side;
  `Postgrex.Notifications` quotes the channel it LISTENs on. `NOTIFY pgrst`
  (unquoted, lowercased by Postgres) matches the default `"pgrst"`.

## Documentation to ship with the change

- README: a "Schema-cache reload" subsection (NOTIFY usage, the two options,
  `Bier.reload_schema_cache/1`, PostgREST's optional DDL `event_trigger`
  snippet) and a listener mention in the boot-flow narrative; update the
  feature-gap list (line 284).
- CLAUDE.md: remove "schema-cache reload" from the known-gaps sentence; extend
  the boot-sequence description with `Bier.SchemaCache` and the listener.
- Moduledocs on both new modules (they are the reference for semantics).
- `spec/COVERAGE.md` stays frozen and untouched — conformance cases remain
  deferred; this ships as a library feature per the issue.
