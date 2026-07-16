# JWT Verification Cache + `[:bier, :jwt_cache, …]` Telemetry — Design

- **Date:** 2026-07-14
- **Issue:** [#36 — [observability] Emit :telemetry events for the DB pool and JWT cache](https://github.com/milmazz/bier/issues/36)
- **Status:** Approved (decisions locked during brainstorm with the project owner)
- **Implementation plan:** `docs/superpowers/plans/2026-07-14-jwt-cache.md`
- **Follow-up filed:** [#74 — 30-second temporal-claim clock skew](https://github.com/milmazz/bier/issues/74) (out of scope here)

## Problem

Issue #36's pool half shipped (`Bier.PoolMonitor` + the checkout-timeout
counter); the remaining scope is the `[:bier, :jwt_cache, …]` event family
mirroring `pgrst_jwt_cache_requests_total` / `pgrst_jwt_cache_hits_total` /
`pgrst_jwt_cache_evictions_total`. There is nothing to instrument yet:
`Bier.JWT.verify/4` verifies every token from scratch on every request. The
issue itself prescribes the fold — *first* introduce a JWT verification cache,
*then* emit hit/miss/eviction events around it. This design does both and
closes #36.

## Upstream semantics being mirrored (PostgREST v14.12)

Pinned from `src/PostgREST/Auth/JwtCache.hs`, `src/PostgREST/Auth/Jwt.hs`, and
`src/PostgREST/Metrics.hs` at v14.12:

1. **Cache key** is the raw token bytes; the **cached value** is the decoded
   claims object. Only the expensive half — signature verification + claims
   decoding (`parseAndDecodeClaims`) — is cached.
2. **Temporal (`exp`/`nbf`/`iat`) and audience validation run per-request,
   after the cache lookup** (`validateClaims`). A cached token therefore still
   starts failing with 401/`PGRST303` the moment its `exp` passes. The cache
   itself never invalidates on time (`alwaysValid` — "no invalidation for
   now").
3. **Errors are never cached** (`notCachingErrors`): a failed verification is
   recomputed on every request.
4. **Capacity** comes from `jwt-cache-max-entries` (default **1000**);
   `<= 0` disables caching entirely (`JwtNoCache` mode). When disabled, no
   cache observations are emitted at all.
5. **Eviction is SIEVE** (`PostgREST.Cache.Sieve`), not LRU: entries keep a
   *visited* bit set on hit; a hand walks from the oldest entry toward the
   newest, clearing visited bits on survivors and evicting the first
   unvisited entry. New entries insert at the head; survivors are not moved.
6. **Observations:** one lookup observation carrying a hit boolean
   (`JwtCacheLookup True|False` → `requests_total` always increments,
   `hits_total` only on hit) and one eviction observation (`JwtCacheEviction`
   → `evictions_total`).

`spec/auth.yaml` explicitly lists JwtCache behavior under `gaps:` — "treated
as a non-observable optimization", no frozen conformance case pins it — so the
frozen suite constrains this work only indirectly (it must stay green while
running through the cache).

## Goals

1. A per-instance JWT verification cache with PostgREST v14.12 semantics
   (points 1–6 above), on by default.
2. New config option `jwt_cache_max_entries` (default 1000, `<= 0` disables)
   with full CLI parity: `jwt-cache-max-entries` config-file key,
   `PGRST_JWT_CACHE_MAX_ENTRIES` env, and the `--dump-config` line (owner
   decision: keep the parity achieved in #49/#69 intact — no new deferral).
3. Telemetry events `[:bier, :jwt_cache, :lookup]` (with `hit: boolean`) and
   `[:bier, :jwt_cache, :eviction]`, each carrying `instance` metadata,
   consistent with the #26/#36 pool events. Emitted only when the cache is
   enabled, mirroring upstream.
4. A cache fault (table gone, owner process restarting) never fails a
   request — the request path falls back to direct verification.
5. `Bier.Telemetry`'s "Not yet emitted" moduledoc section is replaced by real
   documentation for the new family; #36 closes.

## Non-goals (explicitly out of scope)

- **30-second temporal-claim clock skew.** Upstream tolerates ±30s on
  `exp`/`nbf` and rejects future `iat`; Bier's `validate_temporal/1` does
  neither. No frozen case pins it. Folding it in here would be a silent
  behavior change inside a caching PR — filed separately as #74.
- **Conformance/spec edits.** `spec/**`, `test/conformance/**`, and
  `test/support/**` are frozen ground truth. Coverage lands as regular ExUnit
  tests in new files under `test/bier/`.
- **Prometheus `/metrics` rendering.** The events are the instrumentation
  points; a `/metrics` admin endpoint remains a separate issue (as noted in
  #36).
- **Runtime reconfiguration.** Upstream's `JwtCache.update` handles config
  reloads; Bier's config is fixed per instance boot, so there is nothing to
  reconfigure. `'reload config'` remains a no-op per the #29 design.

## Design

### 1. Config

- `Bier.schema/0` (`lib/bier.ex`): add `jwt_cache_max_entries`, type
  `:integer`, default `env(:jwt_cache_max_entries, 1000)`, documented as
  PostgREST `jwt-cache-max-entries` with `<= 0` meaning "disabled".
- `Bier.Config`: new field + typespec. No cross-validation needed (any integer
  is valid; non-positive just disables).
- `Bier.CLI.Config`: new entry in the key table — `key: "jwt-cache-max-entries"`,
  `env: "PGRST_JWT_CACHE_MAX_ENTRIES"`, `kind: :int`, default `1000`, no
  aliases — mapped through to `jwt_cache_max_entries`. The `--dump-config`
  line appears automatically: Bier's dump is sorted by key, and the frozen
  dump case (1705) asserts `dump_contains` substrings, not ordering, so no
  manual positioning exists or is needed.

### 2. Splitting `Bier.JWT` at the upstream seam

`verify/4` keeps its exact public contract but is recomposed from two halves:

- **Cacheable half** — new public function (the `parseAndDecodeClaims`
  equivalent): trim/parts split, header decode, signature verification
  (`verify_signature/3`, unchanged), payload decode. Returns
  `{:ok, claims, claims_json} | {:error, reason}`. `claims_json` (the
  canonically re-encoded payload) is deterministic from the claims, so it is
  computed once and cached alongside them.
- **Per-request half** — new public function grouping the existing
  `validate_temporal/1` + `validate_audience/2` (logic byte-for-byte
  unchanged) plus `RoleClaim.extract/2`. Runs on every request, hit or miss.

The pre-checks stay ahead of any cache involvement, exactly as today: `nil`
token → `{:ok, :anonymous}`, empty/whitespace token → `{:error, :empty}`,
missing secret → `{:error, :no_secret}`. None of these touch the cache.

### 3. `Bier.JwtCache` (new module)

A per-instance GenServer child of the `Bier` supervisor, started **only when
`jwt_secret` is set and `jwt_cache_max_entries > 0`** (same conditional-child
pattern as the `db_channel_enabled` gate for `Bier.SchemaCacheListener`).
Registered via `Bier.Registry.via(name, Bier.JwtCache)`; its ETS table handle
is published in `:persistent_term` under `{Bier, :jwt_cache, name}` (the
`Bier.SchemaCache` keying pattern) and erased on terminate.

**Storage.** One public ETS `:set` with `read_concurrency: true`. Rows are
`{token, claims, claims_json, visited?}`. The GenServer owns the table; request
processes read and flip the visited bit directly; all structural writes
(insert, evict) are serialized through the GenServer.

**Lookup path** (runs in the request process, lock-free on hits):

1. `:ets.lookup(tid, token)` —
   - **hit:** `:ets.update_element(tid, token, {4, true})` (SIEVE visited
     bit), emit `lookup` with `hit: true`, return the cached
     `{claims, claims_json}`.
   - **miss:** emit `lookup` with `hit: false`, run the cacheable half in the
     request process, and on success `GenServer.call` the owner to insert.
     Errors are returned to the caller and **never inserted**.

**Insert + SIEVE eviction** (inside the GenServer, serialized):

- Insertion order lives in GenServer state as a doubly-linked structure
  (token → `{prev, next}` map plus `head`/`tail`/`hand` pointers) — O(1)
  insert, unlink, and hand movement. Visited bits live only in ETS (readers
  set them without a GenServer round-trip).
- On insert: if the token is already present (two requests raced the same
  miss), do nothing. If at capacity, run the hand from its current position
  (or the tail on first eviction) toward the head: visited entry → clear the
  bit, advance; unvisited entry → `:ets.delete`, unlink, emit `eviction`,
  leave the hand at its predecessor. Then insert the new row at the head.
- One eviction event fires per evicted entry, mirroring `JwtCacheEviction`.

**Failure isolation.** All cache interaction from the request path is wrapped
so that a missing `persistent_term` entry, a dead table (`badarg`), or an
`:exit` from the owner call degrades to direct verification. A cache fault can
never fail or 500 a request.

### 4. `Bier.Auth.resolve/2` integration

For a present token with a configured secret, `Auth` composes:

```
cacheable half (via Bier.JwtCache when enabled, else direct)
→ per-request half (temporal + aud + role extraction)
→ build_context/5 (unchanged)
```

When the cache is disabled by config, `Auth` calls the two `Bier.JWT` halves
directly — equivalent to today's `verify/4` — and no cache events are emitted.
Everything else in `Auth` (GUCs, pre-request hook, error mapping) is
untouched.

### 5. Telemetry

Two new events in `Bier.Telemetry`, following the pool-event conventions:

| Event | Measurements | Metadata | PostgREST metric |
|---|---|---|---|
| `[:bier, :jwt_cache, :lookup]` | `%{count: 1}` | `%{hit: boolean(), instance: name}` | `pgrst_jwt_cache_requests_total` (all), `pgrst_jwt_cache_hits_total` (`hit: true`) |
| `[:bier, :jwt_cache, :eviction]` | `%{count: 1}` | `%{instance: name}` | `pgrst_jwt_cache_evictions_total` |

The `lookup` event fires from the request process (both outcomes); `eviction`
fires from the cache owner. The moduledoc's "Not yet emitted" section is
removed and replaced with documentation of the family, closing the loop that
section points at (#36).

### 6. Testing

New `test/bier/jwt_cache_test.exs` (precedent: `pool_monitor_test.exs` for the
pool half; `test/bier/` is not frozen):

- hit/miss round-trip: second lookup of the same token is a hit and skips
  re-verification;
- expired-on-hit: a token cached while valid fails with `:expired` once `exp`
  passes (per-request temporal validation);
- errors not cached: an invalid token misses on every lookup;
- capacity + SIEVE order: with max entries N, inserting N+1 evicts the oldest
  *unvisited* entry; a visited entry survives the first hand pass;
- telemetry: `lookup` hit/miss metadata and `eviction` fire with `instance`,
  asserted via `:telemetry_test.attach_event_handlers/2` as in
  `telemetry_test.exs`;
- disabled cache (`jwt_cache_max_entries: 0`): no `Bier.JwtCache` child, no
  events, verification still correct;
- cache-fault fallback: request path still verifies when the cache table is
  unavailable.

CLI coverage extends `test/bier/cli_test.exs` patterns: env/config-file
resolution and the dump line for `jwt-cache-max-entries`.

The frozen conformance suite (auth area) runs through the enabled-by-default
cache via the shared `Bier.ConformanceServer` — free integration coverage that
must stay green, including the `PGRST301`/`PGRST303` error cases (which also
exercise the errors-not-cached path in-band).
