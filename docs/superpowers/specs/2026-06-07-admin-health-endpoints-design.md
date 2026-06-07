# Admin health endpoints (`/live`, `/ready`) — Design

**Issue:** #30 — `[feature] Admin health endpoints /live and /ready`
**Date:** 2026-06-07
**Status:** Approved (brainstorming)

## Summary

PostgREST exposes an admin server (on `admin-server-port`) with health
endpoints `/live` and `/ready`. Bier has none. This adds a per-instance admin
HTTP server with `GET /live` and `GET /ready`, opt-in via a new
`admin_server_port` config field, plus the `admin-server-port` ≠ `server-port`
validation (the library-level enforcement that conformance case `1717` mirrors).

## Why this differs from PostgREST (the key decision)

PostgREST is one DB per process, so it has one admin server. Bier serves
**multiple DBs at once — one DB per `Bier` supervisor instance**, each with its
own `Bier.Config`. Health is therefore **inherently per-instance**: readiness is
computed against *that instance's* connection pool and *that instance's* schema
cache.

Three layouts were considered:

- **A — per-instance admin port (chosen).** Each instance gets its own
  `admin_server_port` → its own small Bandit listener serving only `/live` and
  `/ready`. Clean admin/API split, separately firewall-able, PostgREST-compatible
  root URLs preserved. Falls out naturally from the per-instance config model.
- **B — same port, reserved paths.** Reserve `/live` `/ready` on the main router
  so they shadow tables. Rejected: a table literally named `live`/`ready`
  becomes unreachable, the admin surface is publicly exposed, diverges from
  PostgREST.
- **C — namespace the API under `/api/`.** Rejected: Bier's reason for existing
  is **PostgREST conformance**; PostgREST serves resources at the root
  (`GET /tablename`, `GET /rpc/fn`, `GET /` for OpenAPI), and the whole
  `spec/conformance/` suite hits root paths. An `/api/` prefix would break URL
  parity and invalidate conformance, while still giving no ops separation.

**Namespace-collision detail that drives A:** `Bier.RouterBuilder.build/2`
produces a pure catch-all router — every request is handed to
`Bier.Plugs.ActionController`, which resolves the path to a `{schema, relation}`
lookup. So on the main port `GET /live` would be interpreted as a lookup for a
relation named `live`. A separate admin port avoids the collision entirely.

## Components

### 1. Config (`lib/bier.ex`, `lib/bier/config.ex`)

- New schema field `admin_server_port`: `{:or, [:pos_integer, nil]}`,
  default `env(:admin_server_port, nil)`. `nil` ⇒ no admin server (opt-in,
  matches PostgREST).
- Add `admin_server_port` to the `Bier.Config` struct and typespec.
- Cross-field validation in `Bier.Config.new!/2`, **after**
  `NimbleOptions.validate!`: when `admin_server_port` is set and equals
  `router[:port]`, raise with a message containing
  `admin-server-port cannot be the same as server-port`.

### 2. Supervision (`lib/bier.ex` `init/1`)

When `admin_server_port` is set, the `Bier` supervisor starts a **second Bandit
listener** as a child (alongside the existing pool, DynamicSupervisor, and
`HttpServerStarter`), bound to the admin port and serving
`Bier.Plugs.AdminRouter` — **not** the catch-all API router. The instance name
is threaded into the plug (via `init_opts`/assign) so it can resolve the pool and
schema cache from `Bier.Registry` / `:persistent_term`.

When `admin_server_port` is `nil`, no admin child is added.

### 3. `Bier.Plugs.AdminRouter` (new, `lib/bier/plugs/admin_router.ex`)

A minimal `Plug.Router` with exactly two routes; everything else → `404`.

- **`GET /live`** → `200` whenever the process is up. No DB access (pure
  liveness). Small body (e.g. empty or a tiny JSON ok marker via
  `Bier.json_library/0`).
- **`GET /ready`** → `200` only when **both** hold, else `503`:
  1. a lightweight `SELECT 1` over the per-instance Postgrex pool succeeds, **and**
  2. the schema cache `:persistent_term.get({Bier, :relations, name})` is
     populated (non-empty / present).

## Data flow

```
host app → {Bier, name: X, router: [port: 4040], admin_server_port: 4041}
  Bier.start_link → Config.new! (validates admin_server_port ≠ router port)
  Bier supervisor children:
    - Postgrex pool (registry: {X, Postgrex})
    - DynamicSupervisor
    - HttpServerStarter (builds API router, starts main Bandit on 4040)
    - Bandit(admin) on 4041 → Bier.Plugs.AdminRouter (name: X)   ← new, only if port set

GET :4041/live  → 200
GET :4041/ready → SELECT 1 on {X, Postgrex} AND persistent_term {Bier,:relations,X}
                  → 200 if both ok, else 503
```

## Error handling

- Config: equal admin/server port → raise at boot (fail fast), message matches
  case `1717` wording.
- `/ready`: any failure of the DB ping (raise/timeout) or an absent/empty schema
  cache → `503`. The check must not crash the router; failures are caught and
  mapped to `503`.

## Testing (TDD)

1. **Config unit test** (`test/bier/config_test.exs` or `test/bier_test.exs`):
   `Config.new!/2` raises when `admin_server_port == router[:port]`; accepts when
   they differ, and when `admin_server_port` is `nil`.
2. **Admin server integration test**: boot a `Bier` instance with an
   `admin_server_port` against the test DB; `GET /live` → `200`; `GET /ready` →
   `200` (DB up + cache populated).
3. **`/ready` unhealthy path**: `503` when the schema cache is absent for the
   instance (relations not populated in `:persistent_term`).

The conformance YAML suite is left untouched (case `1717` stays `:pending` — it
is a `--dump-config` CLI case and the harness has no CLI runner). Update the
`admin_server` note in `spec/COVERAGE.md` to record that `/live` `/ready` now
have integration coverage; the page stays **Partial** pending CLI + `/metrics`.

## Out of scope

- Prometheus `/metrics` endpoint (separate issue, built on `:telemetry`).
- CLI `--dump-config` runner for case `1717`.
- TLS for the admin listener.
