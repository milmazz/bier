# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- `db_aggregates_enabled` (PostgREST `db-aggregates-enabled`,
  `PGRST_DB_AGGREGATES_ENABLED`, default `false`): gates aggregate functions in
  a request's `select`. When off, any aggregate — including one inside a spread
  embed — is rejected with 400 `PGRST123`, matching PostgREST v16. When on,
  aggregates on a one-to-many or many-to-many spread are rejected with 400
  `PGRST127`. Settable from the environment, the config file, the CLI flag and
  — as upstream's `dbSettingsNames` allows — the in-database config source.
- Aggregates inside spread embeds now hoist the enclosing `GROUP BY`, so
  `select=total:amount.sum(),...category(owner)` groups by the spread's columns
  instead of erroring or returning ungrouped rows.
- WAL change feed on the events endpoint: with `events_publication` naming an
  operator-created publication, `GET /events?table=<name>` streams typed
  INSERT/UPDATE/DELETE/TRUNCATE events with row images over SSE — no NOTIFY
  payload cap, no triggers. Frames carry an LSN cursor (`id:`) and reconnects
  resume via `Last-Event-ID` within a bounded in-memory window; anything the
  server can no longer replay is announced with an explicit `bier:reset`
  frame, never silently skipped. Subscriptions require SELECT on the table
  (column images are filtered per role) and a role the authenticator may
  actually assume; tables with RLS refuse subscription in this release. Boot
  fails fast (with remediation hints) unless `wal_level=logical`, the
  publication exists, and the role has REPLICATION. A response carrying a
  table subscription also sends `Connection: close` over HTTP/1.1 (the WAL
  stream can end at any time, unlike a NOTIFY-only response; the header is
  malformed in HTTP/2 and is omitted there). An unknown, non-table,
  unpublished, RLS-enabled, unexposed, or unprivileged table all refuse with
  the same 404 (`BIER003`), so the endpoint cannot be used as an existence
  or privilege oracle. (The refusals are byte-identical but not
  time-identical: configuration-only refusals skip the database round trip
  the catalog checks cost, a gap that reveals only configuration.) A
  transaction over `events_max_tx_events`, or over a fixed 64 MiB of decoded
  column values, is dropped with a `transaction_too_large` reset.
- WAL change feed: partitioned tables can be subscribed (#140).
  `GET /events?table=orders` on a partitioned `orders` streams every
  partition's changes named after the root (`event: orders`), whether or
  not the publication sets `publish_via_partition_root`. With it off, each
  partition change is also delivered to the leaf's own subscribers, as a
  separate event with its own cursor. The root's privileges, column grants
  and RLS flag decide the subscription. The root must itself be in the
  publication, by name, through `TABLES IN SCHEMA`, or `FOR ALL TABLES`.
  An intermediate partitioned table is refused with `404 BIER003`, and so
  is a leaf partition when the publication publishes via the root
  (PostgreSQL never names that leaf). A partition change counts twice
  toward `events_max_tx_events` when it is fanned out.
- `events_publication` is validated at boot: it must be a non-empty
  identifier of at most 63 bytes with no quotes, backslashes, or null bytes.
- `bier:` is a reserved `event:` prefix: `events_channels` entries claiming
  it are refused at boot, and a `table=` subscription naming such a table is
  refused like any other unavailable table. Without the reservation a
  channel or table could emit a frame a client reads as a control message.
- `db_schemas` is validated at boot: the list must be non-empty and no entry
  may be blank. An empty list previously aborted the schema-cache load with an
  opaque `FunctionClauseError` behind a PGRST002 log, and a blank entry booted
  a working instance whose default schema silently resolved nothing. Both are
  Bier-only rules — PostgREST's comma-separated `db-schemas` cannot express an
  empty list — so they run at boot only and `--dump-config` still prints
  whatever it parsed (#143).
- `jwt_role_claim_key` accepts the pre-v16 leading-dot JSPath syntax again
  (`.roles.user_role`, `."https://x"[0]`, `.roles[?(@ ^== "app_")]`), as
  PostgREST v16.2 ([PostgREST#5171][pgrst-5171]) does: a value the RFC 9535
  parser rejects falls back to the old grammar — keys, quoted keys, indexes and
  one trailing `==`/`!=`/`^==`/`==^`/`*==` string filter — and the role is the
  first match. Such a value logs a deprecation `WARNING` at boot (also written
  to stderr by `--dump-config`) and dumps with every key quoted
  (`."roles"."user_role"`). A value neither grammar accepts stays fatal.
- `jwt-cache-max-entries` can be set from the in-database config source
  (`ALTER ROLE … SET pgrst.jwt_cache_max_entries`), matching PostgREST v16.4
  ([PostgREST#5269][pgrst-5269]), whose `dbSettingsNames` previously listed a
  key no parser reads in its place.

PGRST200 ("Could not find a relationship…") errors now carry PostgREST's fuzzy
`hint`, which was previously always `null`. It is a suggestion computed off the
schema cache rather than an echo of the request's own `!hint`: a near-miss child
drawn from the origin's own relationships when the origin participates in any,
and a near-miss parent drawn from the relationships map's keys when it does not
(`Error.hs` L320-331). Both sit at fuzzyset's default 0.33 minimum score —
markedly more permissive than the 0.75 gate PGRST205's table hint uses — with
the exact-hit short-circuit and `< 1.0` guard reproduced, so an embed naming a
relation that really is related still yields no hint (cases 1527/1529/1530).

### Changed

- **Breaking:** aggregate functions in `select` are now **disabled by default**.
  They were previously always available; PostgREST v16 defaults
  `db-aggregates-enabled` to off and answers 400 `PGRST123`, and Bier now
  matches. Set `db_aggregates_enabled: true` (or
  `PGRST_DB_AGGREGATES_ENABLED=true`) to restore the old behavior.
- **Breaking (API):** `Bier.CLI.run/2` performs the `--ready` health check
  itself and returns a result map like every other command, instead of handing
  the caller a `{:ready, url}` directive to probe. In `Bier.Embed`, `group_by`
  takes a fourth argument and `build_row_select` returns a 4-tuple carrying the
  aggregate metadata.

- SSE subscriptions are now bounded by their JWT's `exp` (with the same 30s
  skew allowance the request path uses) instead of living on indefinitely
  after the token that authorized them expired. The `[:bier, :events,
  :subscribe, :stop]` span reports this as `:reason` `:token_expired`.
- `BIER002`'s message and hint now mention `table=` alongside `channel=`.
- Subscriptions are re-authorized centrally after a schema reload — one
  query per distinct role over the union of that role's subscribed tables,
  rather than one per subscriber — so a reload applies immediately without
  queueing a checkout per subscriber against the connection pool.
- The WAL ring buffer stores each table's column metadata once instead of on
  every buffered entry. A DDL that changes a table's columns now invalidates
  that table's buffered history, so a client resuming across the change gets
  an announced `bier:reset` rather than rows labelled with the wrong
  columns.
- `Last-Event-ID` is validated more strictly: LSN halves must fit in 32
  bits, signs are rejected, and oversized input is refused before parsing.
  An unparseable cursor still just starts the stream at the live head.
- A stream the server ends on its own now says why first, with a terminal
  `event: bier:closed` frame (no `id:`) whose `reason` is `revoked` (the
  role's privileges were revoked), `token_expired` (the JWT reached its
  `exp`) or `feed_stopped` (the WAL feed was given up on, below), instead of
  closing silently. Without it a client could not tell any of these from a
  network drop, and `EventSource` reconnected into a refusal — any response
  other than `200 text/event-stream` is fatal to it — and stopped for good.
  Deliberately not `bier:reset`, which only ever means "history is gone"
  (#150).
- The WAL change feed runs under its own `Bier.Wal.Supervisor`
  (`:rest_for_one` over the ring buffer and the consumer, with its own restart
  budget of 5 in 30s) instead of directly under the instance supervisor.
  Consumer crashes no longer spend the instance's budget — a fourth within
  five seconds used to take the whole instance down, HTTP server included. A
  ring-buffer crash now restarts the consumer with it, so subscribers get a
  `stream_restarted` reset. Boot-time feed validation moved from
  `Bier.HttpServerStarter` into the new supervisor, still failing boot with
  the same remediation messages; with the database down at boot it is now the
  first step to fail, and logs the same `PGRST002` the schema-cache load
  does (#150).
- A feed that keeps crashing (a sixth restart within 30s) is given up on
  alone, with the API still serving — and announced rather than silent: it is
  logged at error level and emits the new `[:bier, :wal, :feed, :stopped]`
  telemetry event, every live subscription with a `table=` in it (including a
  mixed `channel=`+`table=` one) ends with `bier:closed` `feed_stopped`, and
  new `table=` subscriptions and `Last-Event-ID` resumes are refused with the
  new `503 BIER004` until the instance is restarted. `channel=` streams are
  unaffected, and the admin `/ready` endpoint does not reflect the feed
  (#150).
- A schema reload revokes a live table subscription only on a confirmed
  privilege loss. A role that was dropped (`42704`) still revokes; any other
  database error during the re-check (a statement timeout, a cancelled query,
  a failover) now keeps the subscription for the next reload to re-check,
  instead of closing every subscriber of that role (#150).

### Fixed

- A client resuming with `Last-Event-ID` after a consumer restart was told
  `bier:reset` `history_evicted`; it now gets `stream_restarted`, the same
  reason the live stream announces. On resume, `history_evicted` is reserved
  for a cursor from the current stream that a table's ring buffer has since
  lost; it is also still pushed live for the tables of a transaction the ring
  buffer was momentarily unable to record (#150).
- A `Last-Event-ID` resume whose ring buffer died mid-replay crashed the
  request after its `200` was sent; it now degrades to a `bier:reset`
  `stream_restarted` (#150).
- The WAL consumer discards a partially assembled transaction as soon as the
  replication connection drops (and again on reconnect), instead of holding it
  on its heap for the whole outage or backoff (#150).
- A spread embed whose columns fed an aggregate leaked a raw PostgreSQL
  `42803` (`must appear in the GROUP BY clause`) to the client.
- A `select` shape a mutation could not render — an aggregate inside a to-many
  spread (`PGRST127`), a filter on an unselected embed (`PGRST108`), a related
  order on a to-many (`PGRST118`) — raised a `MatchError` and answered 500. The
  mutation paths now return the same 400 the read path does.
- Only PostgREST's five aggregate functions (`avg`, `count`, `max`, `min`,
  `sum`) are accepted in `select`. Any other name parsed as an aggregate and
  reached SQL as a function call, so `?select=id.pg_sleep()` invoked it once per
  row; it is now a 400 `PGRST100` select parse error, as upstream gives.
- `--ready` distinguishes an unparseable admin-server URL (`invalid url`) from a
  refused connection, instead of collapsing every transport failure into
  `connection refused`.
- `--dump-config` no longer comes back empty when the database is momentarily
  out of connection slots: the in-database config read retries a checkout the
  pool dropped as backpressure, up to the acquisition deadline. An endpoint
  nothing is listening on still fails immediately, now naming the host and port.
- Request text that is not valid UTF-8 — a query parameter whose percent-escape
  decodes to invalid bytes (e.g. `?channel=%e2%28%a1`), or a `text/csv` body
  whose header row carries them with no escaping at all — no longer crashes the
  error response it triggers: the stdlib `JSON` encoder rejects non-UTF-8
  binaries outright, and an unknown channel/table/column echoes the client's own
  (invalid) input back in `message`/`details`. `Bier.ErrorPayload` — the single
  choke point every error body serializes through — now scrubs invalid byte
  sequences, in keys and in nested `details` structures alike, before encoding,
  instead of letting the request answer a raw 500 (#142).

A nested *empty embed* inside a spread (`...processes(process_costs())`) now
answers 400 `42703` like PostgREST, instead of silently contributing nothing.
`generateSpreadSelectFields`'s `JsonEmbed` branch names one spread field per
embedded relation unconditionally, never consulting the `rsEmptyEmbed` flag the
non-spread path computes, so the projection references a column the LATERAL
never projects. The nested empty *spread* spelling
(`...processes(...process_costs())`) takes the other branch and is unaffected,
still answering 200 (cases 11139/11140). Spread LATERALs are now named with
PostgREST's deterministic `<parent>_<relation>_<depth>` `relAggAlias` formula
(`Plan.hs` L541), which is what the `42703` message quotes back.

Conformance `spec/` bumped to `v16.0.0-suite.5`, which adds the 39
spread/aggregate cases 11100–11138 and the four `--ready` health-check cases
1745–1748, then the seven cases the upstream v16.0 → v16.2 re-sync ranked —
`db-aggregates-enabled` via the in-database config source (1749), the
resolved-empty spread projections (11139–11140), and PGRST200's fuzzy parent
hint (1527–1530) — taking the tree to 812 cases. Upstream's own `PIN` stays at
PostgREST v16.0; the one v16.2 drift the re-sync found (case 1711,
`jwt-role-claim-key` validation) is recorded upstream, not folded. Cases 1771
and 11125 are recorded as deliberate divergences (#122, #138); 11125 pins
upstream's tolerance of an unbalanced trailing `)` in `select`, which Bier
rejects with 400 `PGRST100`.

Conformance `spec/` bumped to `v16.4.0-suite.2`, which moves the upstream pin
from PostgREST v16.0 to **v16.4** and takes the tree from 812 to 832 cases:
the deprecated JSPath `jwt-role-claim-key` (11700–11706, 11819–11821, with
1711 rewritten to a value neither grammar accepts), `jwt-cache-max-entries`
via the in-database source (11707), the root document of a mixed-case schema
(1690 — Bier already compared schema names as text rather than through an
unquoted `::regnamespace` cast, so it needed only its harness variant), the
unresolvable empty embeds (11141–11144) and the alias an embedded `42703`
names (1531–1534). All 827 active cases pass.

- An empty embed (`rel()`) whose relationship does not resolve now answers
  400 `PGRST200`, like any other embed, instead of 200 — or, nested in a
  spread, a phantom-column `42703`. PostgREST resolves every embed before it
  looks at the embed's select list (cases 11141–11144, #161).
- An embed's internal table alias is now PostgREST's `<table>_<depth>`, and a
  many-to-many embed reads its bare table, so an unknown column inside an
  embed names the same relation upstream's `42703` does
  (`column factories_1.banana does not exist`) instead of a counter-based
  name that changed with unrelated sibling embeds (cases 1531–1534, #162).

- The in-database config read no longer overshoots its own acquisition
  deadline. Two shapes escaped it. An endpoint that accepts the TCP connection
  but never completes the Postgres handshake ran to ~15s against a 10s budget:
  the retry loop gave up on time, but tearing down the wedged connection waited
  on its handshake, capped only by the pool supervisor's 5s child shutdown. And
  a server that completes the handshake and then stalls ran to ~60s, because
  db_connection reads `:timeout` and `:checkout_retries` from the call options,
  not from the pool's start options, so one query ran on the 15s default and
  was retried three more times. The read now derives every bound from the same
  budget, passes the remaining budget at the query call site, and tears the
  pool down with `:brutal_kill`; both shapes finish in ~10-12s. The error also
  leads with the time actually spent rather than the ~1s queue drop of the last
  checkout (#149).

[pgrst-5171]: https://github.com/PostgREST/postgrest/pull/5171
[pgrst-5269]: https://github.com/PostgREST/postgrest/pull/5269

## v0.2.0 — 2026-08-23

### Added

- `db_prepared_statements` (PostgREST `db-prepared-statements`,
  `PGRST_DB_PREPARED_STATEMENTS`, default `true`): the hot-path statements —
  the auth preamble, reads, mutations, and RPC — are cached as named prepared
  statements on each pool connection, skipping the parse step when a query
  shape repeats. Set it to `false` behind a transaction-mode pooler such as
  PgBouncer (#127).

### Changed

- Typed filter values and RPC scalar arguments are now bound as parameters
  (`($n::text)::<type>`) instead of being inlined as escaped literals
  (`'<v>'::<type>`). The server-side coercion — and every error it can
  raise — is identical (PostgreSQL I/O-conversion casts), the conformance
  suite is byte-for-byte unchanged, and it matches the SQL PostgREST
  executes (`"id" = $1`). This is what makes the statement cache effective:
  requests differing only in their values now share one SQL text (#127).

### Fixed

- PGRST205/PGRST202 not-found errors (and their "Perhaps you meant" hints)
  now qualify the missing table/function with the request's active schema,
  matching real PostgREST (`Error.hs` builds `qi <> "." <> name` from the
  resolved profile). Previously area-mirror schemas were reported as
  `test.<name>` — an assumption the conformance suite's oracle disproved.
  Conformance `spec/` bumped to `v16.0.0-suite.3`, which pins the corrected
  behavior (cases 1360/1368/1373).

## v0.1.0 — 2026-08-18

First release. Bier serves a RESTful API generated at boot from PostgreSQL
introspection, reproducing the request/response behavior of
[PostgREST](https://postgrest.org) v16.0.

### The API surface

- Reads with the full PostgREST query grammar: `select` (columns, aliases,
  casts, JSON paths, computed columns, aggregates), horizontal filters and
  the operator set, logical trees (`and`/`or`, negation, nesting),
  quantifiers, ordering, `limit`/`offset` and `Range` pagination, and
  resource embedding (many-to-one, one-to-many, many-to-many, `!inner`,
  spread, aliases, disambiguation).
- Mutations — `POST` insert, `PATCH` update, `PUT` single-row upsert,
  `DELETE` — with `Prefer: return=`, `resolution=`, `missing=default`,
  `handling=strict` and `max-affected=`.
- `/rpc/<function>` calls over `GET`/`HEAD`/`POST`, rendering every routine
  return kind (scalar, composite, `SETOF`, `TABLE(...)`, `void`).
- Every request compiled into a **single parameterized SQL statement** whose
  response bodies are byte-identical to PostgREST's, row separators and
  embedded-JSON internals included.
- Content negotiation across `application/json`, `text/csv`,
  `application/geo+json` (relations, mutations, RPC and embedded reads,
  wherever PostGIS is installed), the `vnd.pgrst.object`/`array` variants
  with `nulls=stripped`, and `vnd.pgrst.plan`.
- `Prefer: timezone=<tz>` for per-request `timestamptz` rendering, including
  numeric UTC offsets.
- A generated OpenAPI document at the root, with per-role privilege
  filtering, an opt-in OpenAPI 3.0.3 emitter (`openapi_version: "3.0"`, a
  Bier extension), and `db_root_spec` to replace it wholesale.

### Authentication

- JWT verification through JOSE: HS256/384/512, plus RS/ES/PS/EdDSA from a
  JWK or JWK Set, with the algorithm family decided by the key's shape rather
  than the token's `alg` header.
- Role switching and request-scoped GUCs (`request.jwt.claims`, headers,
  cookies, `app.settings.*`), applied as a single batched
  `SELECT set_config(…)` statement per request — one database round trip
  for the whole preamble, the same shape PostgREST executes.
- `jwt_role_claim_key` as an [RFC 9535][] JSON Path into the claims,
  `jwt_secret_is_base64`, `jwt_aud`, and a per-instance verification cache.
- `db_pre_request`, run inside the request transaction before the main query.

### Operations

- Multiple named instances per BEAM node, each with its own configuration,
  connection pool, runtime-built router, and Bandit server.
- Schema-cache reload over `LISTEN`/`NOTIFY` and `Bier.reload_schema_cache/1`;
  a failed reload leaves the previous snapshot serving.
- Standalone operation with no host application: PostgREST-compatible
  `PGRST_*` environment variables, a config-file parser, the in-database
  (`ALTER ROLE … SET pgrst.*`) configuration source, a `bier` escript with
  `--dump-config`/`--example`, a `mix release` target, and a Dockerfile.
- Observability: `:telemetry` events for requests, schema-cache loads, pool
  status, JWT cache and SSE; an Apache-combined access log gated by
  `log_level`, with optional `log_query`; `Server-Timing`; a trace-header
  passthrough; and `/live` + `/ready` on an optional admin listener.
- Query cancellation at the PostgreSQL backend when the HTTP client
  disconnects (`cancel_on_disconnect`, on by default) — something PostgREST
  cannot do.

### Beyond PostgREST

- **Realtime events**: a config-gated SSE endpoint bridging Postgres
  `LISTEN`/`NOTIFY` to browsers (`events_channels`, `events_path`,
  `events_heartbeat_interval`). PostgREST has no equivalent.
- **`Vary: Origin`** on CORS responses that echo the request's `Origin`, which
  upstream omits.
- **RFC 4180 CSV quoting**, where upstream emits malformed CSV for values
  containing quotes or newlines.
- **`Server: bier/<version>`** and an OpenAPI `info.version` reporting Bier's
  own version. The PostgREST dialect is advertised through the document's
  `externalDocs` instead.

The README's "Deliberate divergences from PostgREST" section is the
authoritative list; everything else is intended to match upstream byte for
byte.

[RFC 9535]: https://www.rfc-editor.org/rfc/rfc9535
