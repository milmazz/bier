# Brewery Tutorial & User-Facing Documentation — Design

**Date:** 2026-07-13
**Status:** Approved (pending spec review)
**Branch:** `worktree-tutorial-docs`

## Goal

Bier needs user-facing documentation before its first release. Today the ex_doc
`extras` are only `README.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, and
`docs/injection_safety.md` — there is no learning path and no task-oriented
reference. This work adds a PostgREST-style split of **Tutorials** (learn by
doing) and **Reference** guides, driven by an original example domain, plus one
enabling library change.

The tutorials follow the shape of PostgREST's `tut0`/`tut1` but use an original
domain — a **brewery catalog** (on-brand with the project name "Bier") — with
entirely different examples.

## Non-goals (YAGNI)

- No changes to the conformance `spec/` tree or to test assertions.
- No new observability features — the observability guide documents what already
  exists (telemetry events, Server-Timing, `/live` + `/ready`, pool monitor,
  trace header, error envelope).
- No asymmetric-JWT / JWKS tutorial content beyond what the code supports today.
- No RLS-based tutorial; Bier's access control is GRANTs + role switching. RLS is
  mentioned only as an optional extension.
- No interactive/hosted playground; docs are static Markdown rendered by ex_doc.

## Part A — Enabling library change: generalize the auth gate

### Problem

`Bier.Auth.applicable?/1` (`lib/bier/auth.ex:46`) hardcodes `schema == "auth"`.
Role switching, JWT role resolution, and the `request.*` GUCs therefore activate
**only** for a schema literally named `auth`. For every other schema, requests
run as the connecting Postgres role with no auth context, so `db_anon_role` and
`jwt_secret` are effectively inert. This is a deliberate conformance compromise
(documented in the `auth.ex` moduledoc): the shared fixture DB grants
`postgrest_test_anonymous` almost no table privileges
(`spec/conformance/fixtures.sql:1618-1625`), so switching roles across the
non-auth areas would fail with `42501 permission denied`.

This blocks an honest Authentication tutorial: it cannot expose a naturally
named `api` schema the way PostgREST's tut1 does.

### Change

Introduce a configurable set of auth-gated schemas and gate activation on auth
actually being configured:

- **New config option `db_auth_schemas`**
  - Type: `list(string) | nil`
  - Default: `nil`
  - Env var: `PGRST_DB_AUTH_SCHEMAS` (added to the CLI/standalone spec)
  - Semantics: the exposed schemas for which Bier applies the auth context.
    `nil` means "all exposed `db_schemas`".
  - Added to `Bier.schema/0` (`lib/bier.ex`) sourced from application env like
    its siblings, validated by `Bier.Config`.

- **`Bier.Auth.applicable?/2`** replaces `applicable?/1`:

  ```elixir
  def applicable?(schema, config) do
    auth_configured?(config) and schema in auth_schemas(config)
  end

  defp auth_configured?(config), do: config.jwt_secret != nil or config.db_anon_role != nil
  defp auth_schemas(config), do: config.db_auth_schemas || config.db_schemas
  ```

  The `auth_configured?` guard is what makes `nil` (= all schemas) safe: a host
  app that exposes schemas with no auth configured keeps running as the
  connecting role instead of getting blanket `401`s.

- **Call site:** `lib/bier/plugs/action_controller.ex:80` updated to pass
  `config`.

- **Conformance pin (the one approved test-support edit):** add
  `db_auth_schemas: ["auth"]` to `Bier.ConformanceServer` base_opts
  (`test/support/conformance_server.ex`). The shared instance configures
  `jwt_secret` + `db_anon_role` globally, so pinning the set to `["auth"]`
  reproduces `applicable? == (schema == "auth")` exactly and keeps the suite
  green. This records the shared-DB compromise where it belongs (in the test
  harness) instead of as a magic library default.

### Why this is conformance-safe

With the pin, the conformance instance evaluates
`auth_configured?` = true and `auth_schemas` = `["auth"]`, so
`applicable?(schema, config) == (schema in ["auth"])` — byte-for-byte the current
behavior. Per-case variant instances inherit the pin via `Keyword.merge`.

### Verification gate (hard checkpoint)

`mix test` (full conformance suite) MUST be green after Part A before any Part B
docs work begins. If any case regresses, stop and investigate — do not proceed
to docs. Also add a focused unit test for `applicable?/2` covering: auth
configured + schema in set → true; auth configured + schema not in set → false;
auth not configured → false; `nil` default → all `db_schemas`.

### Tracking

File/link a GitHub issue noting `db_auth_schemas` is a stepping stone toward
matching PostgREST's universal role-switching, and reference it from the auth
tutorial's limitation note.

## Part B — The brewery example database

A single SQL setup script (shown inline in the Getting Started tutorial and
reused by the Authentication tutorial) creates schema `api` plus PostgREST-style
roles.

### Roles

- `authenticator` — LOGIN, minimal privileges; the role Bier connects as. Can
  `SET ROLE` to `web_anon` / `brewery_member`.
- `web_anon` — NOLOGIN; read-only catalog access; the `db_anon_role`.
- `brewery_member` — NOLOGIN; `web_anon` grants + INSERT on `check_ins`; the role
  named in authenticated JWTs.

### Tables (schema `api`)

```
styles(id, name, description)
breweries(id, name, city, country, founded_year, latitude, longitude)
beers(id, brewery_id -> breweries, style_id -> styles, name, abv, ibu, description)
taprooms(id, brewery_id -> breweries, name, address, city)
check_ins(id, beer_id -> beers, drinker, rating (1..5 CHECK), comment, created_at default now())
```

FKs give resource-embedding demos (`beers` ↔ `breweries`/`styles`,
`breweries` → `taprooms`, `beers` → `check_ins`).

### Stored functions (RPC)

- `api.search_beers(term text)` → `SETOF api.beers` (STABLE) — GET `/rpc/search_beers?term=IPA`.
- `api.top_rated_beers(min_rating int default 4)` → table of `(beer_id, name, avg_rating, check_in_count)` (STABLE) — GET `/rpc/top_rated_beers`.

### Grants

- `web_anon`: USAGE on `api`; SELECT on `styles`, `breweries`, `beers`,
  `taprooms`, `check_ins`; EXECUTE on both functions.
- `brewery_member`: inherits the above + INSERT on `check_ins` (+ USAGE on its
  id sequence).

Seed data: a handful of breweries, styles, beers, taprooms, and a few check-ins,
chosen so filter/order/pagination/embedding examples return interesting rows.

## Part C — Documentation set (ex_doc extras)

### New files

| File | Group | Role |
|------|-------|------|
| `docs/tutorials/getting-started.md` | Tutorials | tut0 analog: DB + anon role + boot Bier + first reads |
| `docs/tutorials/authentication.md` | Tutorials | tut1 analog ("the golden tap"): roles, JWT, member-only check-ins |
| `docs/guides/api-reference.md` | Reference | full request/response API surface |
| `docs/guides/configuration.md` | Reference | option table + config surfaces + standalone/Docker/CLI |
| `docs/guides/observability.md` | Reference | telemetry, Server-Timing, health, pool, trace, errors |

### `mix.exs` wiring

```elixir
extras: [
  "README.md",
  "docs/tutorials/getting-started.md",
  "docs/tutorials/authentication.md",
  "docs/guides/api-reference.md",
  "docs/guides/configuration.md",
  "docs/guides/observability.md",
  "docs/injection_safety.md",
  "CHANGELOG.md",
  "CONTRIBUTING.md"
],
groups_for_extras: [
  Tutorials: [~r"docs/tutorials/"],
  Reference: [~r"docs/guides/", ~r"docs/injection_safety"]
],
```

`main: "readme"` stays. README gets a short "Documentation" section linking the
new pages.

### Page outlines

**getting-started.md** (tut0 analog)
1. What you'll build; prerequisites (PostgreSQL, Elixir 1.18+).
2. Create the brewery DB: run the SQL setup script (schema `api`, tables, seed,
   `authenticator` + `web_anon`, grants).
3. Boot Bier — two paths:
   - **Quick path:** standalone via Docker (`docker run` with `PGRST_DB_URI`,
     `PGRST_DB_SCHEMAS=api`, `PGRST_DB_ANON_ROLE=web_anon`) or release binary.
   - **Elixir path:** a child spec `{Bier, name:, router:, database:, db_schemas:
     ["api"], db_anon_role: "web_anon", ...}` in a supervision tree / IEx.
4. First requests (curl): list beers; filter (`?abv=gte.6`); select columns +
   rename; order; paginate (`limit`/`offset`, Range header, `Prefer: count=exact`
   + Content-Range); embed (`?select=name,breweries(name,city)`); one RPC GET.
5. Where to go next → API reference, Authentication tutorial.

**authentication.md** (tut1 analog — "the golden tap")
1. Recap; goal: anonymous drinkers read the catalog, only authenticated members
   post check-ins.
2. Add roles: `brewery_member`; grant INSERT on `check_ins`; show anon INSERT
   failing with `401`.
3. Configure Bier auth: set `jwt_secret`; expose `api`. Explain that with auth
   configured, role-switching now applies to the exposed `api` schema
   (the Part A change), and a short note on the current design + tracking issue.
4. Mint a JWT with `{"role": "brewery_member"}` (show HS256 signing;
   jwt.io / a one-off Elixir/JOSE snippet), pass `Authorization: Bearer`.
5. Authenticated POST `check_ins` succeeds; anon still `401`. Explain the GUCs
   available to SQL (`request.jwt.claims`, `current_setting`) and `db_pre_request`
   as an extension.
6. Notes: token expiry, `jwt_role_claim_key`, audience; pointer to configuration
   guide.

**api-reference.md** (mirrors PostgREST references/api.html, Bier examples)
- Reading rows; vertical filtering (`select`, rename, cast, JSON paths, computed
  columns, aggregates + `db-aggregates`).
- Horizontal filtering: full operator table (`eq/gt/gte/lt/lte/neq`, `like`,
  `ilike`, `match`, `in`, `is`, `isdistinct`, fts family, range/array ops),
  negation (`not.`), quantifiers (`any`/`all`), logical trees (`and`/`or`),
  JSON arrow filters, filters on embedded resources.
- Ordering (asc/desc, nulls, multi-column, embedded, JSON path).
- Pagination (limit/offset, Range headers, `Prefer: count`, Content-Range,
  status codes 200/206/416).
- Resource embedding (M2O/O2M/M2M, alias, `!inner`/`!left`, disambiguation,
  spread, embedded filters/order).
- Mutations (POST/PATCH/PUT/DELETE, `Prefer: return=…`, `resolution=…`,
  `missing=default`, `?columns=`, `?on_conflict=`, Location header).
- RPC (`/rpc/<fn>` GET vs POST, args, variadic, return shapes, shaping).
- Content negotiation (Accept types incl. `text/csv`, `application/geo+json`,
  `vnd.pgrst.object/array`, `nulls=stripped`, plan; 406 behavior).
- Error responses (envelope `{code, message, details, hint}`, PGRST codes).

All examples use the brewery schema.

**configuration.md**
- Three config surfaces: `Bier.start_link/1` keyword opts; application env
  (`config :bier, key: value`); `PGRST_*` env vars (standalone) with precedence
  flags > env > file > default.
- Full option table (name, type, default, `PGRST_*` var) generated from
  `Bier.schema/0` + the CLI spec — including the new `db_auth_schemas`.
- `PGRST_DB_URI` parsing (URI + conninfo; `sslmode`).
- Standalone boot: release (`MIX_ENV=prod mix release`, `BIER_STANDALONE=1`),
  Docker, the `bier` CLI (`--dump-config`, `--example`, config file), inspecting
  configuration.
- Cross-field validators (jwt-secret ≥ 32 bytes, `admin-server-port` ≠
  `server-port`, socket mode, etc.).
- Schema-cache reload (`db_channel`, NOTIFY, `Bier.reload_schema_cache/1`).

**observability.md**
- Telemetry events: `[:bier, :request, :start|:stop]`,
  `[:bier, :schema_cache, :load, …]`, `[:bier, :pool, :status]`,
  `[:bier, :pool, :checkout_timeout]` — measurements + metadata keys + an
  `attach` example.
- Server-Timing (`server_timing_enabled`, phases jwt/parse/plan/transaction/
  response, header format, OPTIONS subset).
- Health/readiness: `admin_server_port`, `GET /live`, `GET /ready`,
  `Bier.Health.ready?/1` semantics.
- Pool monitor (`DBConnection.get_connection_metrics`, sampling cadence).
- Trace header (`server_trace_header` echo).
- Error logging (PGRST001/PGRST002, level, structured metadata) and the error
  envelope shape with PGRST codes.

## Sequencing

1. **Part A** lib change (config option, `applicable?/2`, call site, conformance
   pin, unit test).
2. **`mix test` green gate.** Stop if red.
3. **Part B** SQL setup script (validated by actually loading it into a scratch
   DB and running the tutorial's example requests against a booted `api`
   instance).
4. **Part C** write the five docs; wire `mix.exs`; add README "Documentation"
   section.
5. **`mix docs --warnings-as-errors` green gate** + `mix format` + `mix credo
   --strict` (the relevant `mix precommit` gates).
6. Optional: verify a couple of tutorial requests end-to-end against a locally
   booted brewery instance so the printed curl/response pairs are real.

## Risks

- **Conformance regression from Part A.** Mitigated by the `["auth"]` pin
  reproducing exact current behavior; caught by the `mix test` gate. Edge case:
  a case that nulls *both* `jwt_secret` and `db_anon_role` while targeting the
  auth schema would flip `auth_configured?` to false; the gate will surface it
  and we adjust (believed not to exist).
- **Example drift.** Tutorial request/response pairs must match real Bier output;
  mitigated by running the examples against a booted brewery instance (step 6).
- **Doc build warnings** (autolink/undefined refs) failing the `--warnings-as-
  errors` gate; mitigated by building locally and using `skip_*` config as the
  existing docs do.
```
