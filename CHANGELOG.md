# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

- The per-request auth preamble (role switch, `request.*` GUCs, `search_path`,
  `app.settings.*`) is now applied as a single batched `SELECT set_config(…)`
  statement instead of one statement per setting, cutting ~10 database round
  trips per authenticated request to 4 and roughly halving p50 latency under
  load. The role is set via `set_config('role', …, true)` — exactly what
  PostgREST executes — so role-switch error shapes now match upstream too.
- **Conformance target moved from PostgREST v14.12 to v16.0.** The frozen
  suite was re-synced area by area and all 759 active cases pass again. The
  behavior changes that came with it are the four entries below.
- **Breaking:** `jwt_role_claim_key` is now an [RFC 9535][] JSON Path instead
  of PostgREST's old leading-dot JSPath DSL, matching v16.0. Every expression
  starts with the root identifier `$` (default `$.role`), non-identifier
  member names need bracket selectors (`$.roles["write-role"]`), and the
  DSL's `^==`/`==^`/`*==` operators are replaced by `search()`
  (`$.roles[?search(@, "^app_")]`). A v14.12-style value such as `.role`
  aborts startup (#93).
- **Breaking:** `db_schemas` rejects `pg_catalog` and `information_schema` at
  startup, matching v16.0 (#96).
- `Prefer: timezone=<tz>` now passes the value straight to PostgreSQL:
  numeric UTC offsets (`+05:30`, `-4`) are accepted, and an invalid zone is a
  400 / `22023` regardless of `handling` (v14.12 silently ignored it, or
  raised `PGRST122` under `handling=strict`) (#94).
- Added `client_error_verbosity` (PostgREST `client-error-verbosity`, new in
  v16.0): `"minimal"` reduces every error body to `{code, message}`, omitting
  `details`/`hint`.
- Added `url_use_legacy_target_names` (PostgREST
  `url-use-legacy-target-names`, new in v16.0, default `true`): a filter,
  order or limit may still address an aliased embed by its relation name, and
  the response then carries a deprecation `Warning: 299 …` header; set it to
  `false` to make the alias the only accepted spelling (400 `PGRST108`
  otherwise) (#95).
- Every non-error response now carries a default
  `Vary: Accept, Prefer, Range` header, matching v16.0.
- Realtime events: config-gated SSE endpoint bridging Postgres LISTEN/NOTIFY
  (`events_channels`, `events_path`, `events_heartbeat_interval`) (#81).
- `application/geo+json` broadened from relation reads to also cover
  mutations (with `Prefer: return=representation`), `/rpc/*`, and embedded
  reads, whenever the PostGIS extension is installed (#63).
- **Behavior note:** response bodies are now byte-identical to PostgREST
  (verified at v14.12, and again against the v16.0 re-sync), including its
  `, \n ` row separator between top-level JSON array
  elements and jsonb-styled embed internals — this shifts `Content-Length` on
  any multi-row response compared to earlier Bier versions (#31).
- **Breaking:** `Location` is no longer emitted on `POST`/`PUT` responses for
  `Prefer: return=representation` or `return=minimal` — only
  `return=headers-only` carries it now, matching PostgREST 14.12 (hosts that
  read `Location` after a plain `POST` must switch to `return=headers-only`).
- The empty-payload mutation short-circuit now carries a `Content-Range` of
  `*/*` (`*/0` under `Prefer: count=exact`).
- Scalar/composite RPC responses always carry `Content-Range` (`0-0/*`
  without a count preference).
- `Content-Profile` is echoed on success responses whenever more than one
  schema is exposed and the profile-schema model is not configured.
- Added `jwt_role_claim_key` (PostgREST `jwt-role-claim-key`, alias
  `role-claim-key`): a path selecting the database role inside the JWT
  claims — nested keys, array indexes and filter expressions are supported;
  an invalid expression aborts startup (#49). Its grammar moved to RFC 9535
  JSON Path with the v16.0 re-sync — see the breaking entry above (#93).
- Added `jwt_secret_is_base64` (PostgREST `jwt-secret-is-base64`, alias
  `secret-is-base64`): the JWT secret is base64-decoded before use (URL-safe
  characters accepted); an undecodable secret aborts startup (#49).
- **Perf:** reads no longer compute `count(*) OVER()` unless the request's
  count mode consumes it (table reads: `Prefer: count=exact|estimated`; RPC:
  any mode but `none`; mutations: never) — filtered pages with a `limit` get
  their fast plan back instead of scanning the whole filtered set. The
  `application/vnd.pgrst.plan` output now reflects the request's count mode
  (#67).
- Added an HTTP benchmark harness (`bench/http/`) that measures Bier against
  PostgREST v14.12 head-to-head with k6 under matched configuration; results
  and methodology in `bench/http/REPORT.md`.
- Added `server_host` (PostgREST `server-host`): the listener bind address as
  a Warp-style host preference (`!4` default, `!6`/`*6`, `*`, IP literals,
  resolvable host names), honored by both the API and admin listeners (#49).
- Added `server_unix_socket` / `server_unix_socket_mode` (PostgREST
  `server-unix-socket(-mode)`): serve the API on a Unix domain socket instead
  of a TCP port, applying the octal file mode (600–777) to the socket file;
  an invalid mode aborts startup (#49).
- Added `openapi_server_proxy_uri` (PostgREST `openapi-server-proxy-uri`):
  the generated OpenAPI document advertises the proxy's scheme/host/port/path
  as `schemes`/`host`/`basePath`; a malformed URI aborts startup (#49).
- Added `app_settings` (PostgREST `app.settings.*`,
  `PGRST_APP_SETTINGS_<NAME>`): arbitrary `app.settings.<name>` GUCs set
  transaction-locally on requests running with the auth context (#49).
- Added `db_pool_max_idletime` (PostgREST `db-pool-max-idletime`, alias
  `db-pool-timeout`) mapping onto the connection pool's idle-interval knob,
  and the CLI now models `db-pool` (pool size) (#49).
- The CLI grew `--example`/`-e`, printing a loadable config template with
  every implemented key at its default; `--dump-config` now covers the full
  implemented key table (conformance cases 1705/1707/1714/1715/1716/1727/1729
  are active) (#49).

Nothing has been published to Hex yet. Current state of the library:

- RESTful API generated at boot from PostgreSQL introspection (`pg_catalog`),
  heavily inspired by [PostgREST](https://postgrest.org) and driven by a
  conformance suite frozen from PostgREST v16.0.
- Reads, mutations (insert/update/upsert/delete), and `/rpc/*` function calls
  compiled into a single parameterized SQL statement per request.
- JWT authentication (HS/RS/ES/PS/EdDSA via JOSE) with role switching and
  request-scoped GUCs.
- Schema-cache reload via `LISTEN`/`NOTIFY` and `Bier.reload_schema_cache/1`.
- Multiple named instances per BEAM node, each with its own connection pool,
  runtime-built router, and Bandit server.
- Standalone PostgREST-compatible CLI (`PGRST_*` env), `mix release` target,
  and Dockerfile.

[RFC 9535]: https://www.rfc-editor.org/rfc/rfc9535
