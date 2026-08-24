# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

- WAL change feed on the events endpoint: with `events_publication` naming an
  operator-created publication, `GET /events?table=<name>` streams typed
  INSERT/UPDATE/DELETE/TRUNCATE events with row images over SSE — no NOTIFY
  payload cap, no triggers. Frames carry an LSN cursor (`id:`) and reconnects
  resume via `Last-Event-ID` within a bounded in-memory window; anything the
  server can no longer replay is announced with an explicit `bier:reset`
  frame, never silently skipped. Subscriptions require SELECT on the table
  (column images are filtered per role); tables with RLS refuse subscription
  in this release. Boot fails fast (with remediation hints) unless
  `wal_level=logical`, the publication exists, and the role has REPLICATION.
  A response carrying a table subscription also sends `Connection: close`
  (the WAL stream can end at any time, unlike a NOTIFY-only response); an
  unknown, unpublished, RLS-enabled, or unprivileged table all refuse with
  the same 404 (`BIER003`), so the endpoint cannot be used as an existence
  or privilege oracle.

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
