# Brewery Tutorial & User-Facing Documentation — Design

**Date:** 2026-07-13
**Status:** Approved (pending spec review)
**Branch/worktree:** `.claude/worktrees/tutorial-docs`

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

## Delivery: two PRs

This work ships as **two separate pull requests**, in order:

1. **PR 1 — Auth gate (library + conformance harness).** Make Bier's per-request
   auth context faithful to PostgREST: role-switching/GUCs/`db-pre-request`
   activate whenever auth is configured, for all exposed schemas. Self-contained;
   its acceptance gate is a fully green conformance suite. **No documentation
   changes.** (Part A below.)

2. **PR 2 — Tutorial + documentation.** The brewery example database and the five
   ex_doc pages. **Depends on PR 1 being merged** (the Authentication tutorial
   relies on PR 1's behavior — a naturally named `api` schema getting
   role-switching without a special option). (Parts B + C below.)

## Non-goals (YAGNI)

- No changes to the conformance `spec/` tree (cases, assertions, or
  `fixtures.sql`). PR 1 edits only `test/support/` (the harness) and `lib/`.
- **No new configuration option** for auth gating (an earlier draft proposed
  `db_auth_schemas`; rejected in favor of staying faithful to PostgREST, which
  has no such option).
- No new observability features — the observability guide documents what already
  exists.
- No asymmetric-JWT / JWKS tutorial content beyond what the code supports today.
- No RLS-based tutorial; Bier's access control is GRANTs + role switching. RLS is
  mentioned only as an optional extension.
- No interactive/hosted playground; docs are static Markdown rendered by ex_doc.

---

## PR 1 — Part A: make the auth gate faithful to PostgREST

### Problem

`Bier.Auth.applicable?/1` (`lib/bier/auth.ex:46`) hardcodes `schema == "auth"`.
Role switching, JWT role resolution, the `request.*` GUCs, **and** the
`db-pre-request` hook (`run_pre_request` runs inside `with_context`,
`auth.ex:130,167`) therefore activate **only** for a schema literally named
`auth`. For every other schema, requests run as the connecting Postgres role with
no auth context, so `db_anon_role`, `jwt_secret`, and `db-pre-request` are
effectively inert.

PostgREST has no such gate: when the `authenticator` connects and auth is
configured, every request switches role (JWT `role` claim, else `db-anon-role`)
and runs `db-pre-request`. Bier's gate is a compromise for the shared conformance
fixture DB, where the connection is a superuser and
`fixtures.sql:1618-1625` grants `postgrest_test_anonymous` almost no privileges —
so switching roles across the non-auth areas would fail with `42501`.

This blocks an honest Authentication tutorial: it cannot expose a naturally named
`api` schema the way PostgREST's tut1 does.

### Library change

Make activation depend on whether auth is configured, not on the schema name:

```elixir
# lib/bier/auth.ex
def applicable?(config), do: auth_configured?(config)

defp auth_configured?(config),
  do: config.jwt_secret != nil or config.db_anon_role != nil
```

- Signature changes from `applicable?(schema)` to `applicable?(config)`.
- Call site `lib/bier/plugs/action_controller.ex:80` updated to pass `config`
  (it already has both `schema` and `config` in scope).
- No new config option. This mirrors PostgREST: auth configured ⇒ role-switching
  for all exposed schemas; auth not configured ⇒ run as the connecting role.
- Add a focused unit test for `applicable?/1`: jwt_secret set → true;
  db_anon_role set → true; both nil → false.

### Why the conformance suite needs a harness change

The shared conformance instance (`test/support/conformance_server.ex` base_opts)
sets `jwt_secret` + `db_anon_role` + `db_pre_request` **globally**, and its
`db_schemas` lists every area. Under the new rule, `auth_configured? == true`
would switch roles for **all** areas → `42501` (the fixtures don't grant the
roles, and `fixtures.sql` is frozen). So the harness must stop configuring auth
on the instance that serves the non-auth areas.

Empirically the auth need partitions cleanly (verified against `spec/`):

- Every JWT/claims-dependent case carries `schema: auth` (45 cases). The
  `test.reveal_big_jwt`/`get_current_user` functions are only ever exercised
  through `schema: auth` cases (e.g. case 1486).
- 3 `openapi` cases (1675/1676/1677) filter the OpenAPI doc by role.
- The root path `/` (40 cases, across `openapi`/`observability`/`test`) resolves
  the anon role to filter the doc — but **root never switches the DB role** (it
  calls `Bier.Auth.resolve` then `build_openapi_document(config, role)`; no
  `with_context`, no `SET ROLE`), so an auth-configured instance serves root
  cases without touching grants.
- No non-auth relation/RPC case sends an `Authorization` header or reads
  `request.jwt.claims` without `missing_ok` (`test.authors_only`'s `owner`
  default uses `current_setting(..., true)` → NULL when unset, same as today).

### Conformance harness change (test/support only)

Split the single shared instance into two, differing only in auth config:

- **`bulk` instance** — base_opts **without** `jwt_secret`, `db_anon_role`,
  `db_pre_request`. `auth_configured? == false` → runs as superuser →
  byte-identical to today for the non-auth areas.
- **`auth` instance** — bulk opts **plus** those three auth settings.

Route in `Bier.ConformanceServer.url_for/1` by a predicate on the case:

```
schema in ["auth", "openapi"] or request.path == "/"  → auth instance
otherwise                                              → bulk instance
```

Existing per-case variants (1467–1473 jwt-aud, 1764 no-secret, etc.) rebase onto
the `auth` instance's opts. Keep all non-auth shared settings (server-timing,
trace header, CORS, `db_max_rows_by_schema`, `db_plan_enabled`,
`db_tx_end: :rollback`, `db_safe_update_tables`, profiles/aliases) on **both**
instances so behavior is unchanged.

### Verification gate (hard checkpoint)

`mix test` (full conformance suite) MUST be green before PR 1 is opened. Expect
one or two routing stragglers on the first run — most likely an `openapi` case
that reads a *relation* under the now-active role switch and hits `42501`. Fix by
refining the routing predicate (or routing that specific case id), never by
editing `spec/`. Also run `mix format`, `mix credo --strict`, and
`mix docs --warnings-as-errors` (the moduledoc for `Bier.Auth` must be updated to
describe the new behavior).

### Tracking

Reference the GitHub issue for PostgREST-faithful auth in the PR description; note
that the connect-as-`authenticator` + role GRANTs model (vs. superuser) remains
future work, out of scope here.

---

## PR 2 — Part B: the brewery example database

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

## PR 2 — Part C: documentation set (ex_doc extras)

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
3. Configure Bier auth: set `jwt_secret`; expose `api`. With auth configured,
   role-switching applies to the exposed `api` schema (PR 1's behavior) — same
   model as PostgREST, no special option.
4. Mint a JWT with `{"role": "brewery_member"}` (HS256 signing; jwt.io / a
   one-off Elixir/JOSE snippet), pass `Authorization: Bearer`.
5. Authenticated POST `check_ins` succeeds; anon still `401`. Explain the GUCs
   available to SQL (`request.jwt.claims`, `current_setting`) and show
   `db_pre_request` as the PostgREST-style extension point (a `check_token`-style
   guard function).
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
- Full option table (name, type, default, `PGRST_*` var) from `Bier.schema/0` +
  the CLI spec.
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

---

## Sequencing

**PR 1 (auth gate):**
1. Library: `applicable?(config)` + call-site update + `Bier.Auth` moduledoc.
2. Harness: split into `bulk` / `auth` instances + `url_for` routing predicate;
   rebase variants.
3. Unit test for `applicable?/1`.
4. **`mix test` green gate** (iterate routing for stragglers). Then `mix format`,
   `mix credo --strict`, `mix docs --warnings-as-errors`.
5. Open PR 1. Merge before starting PR 2.

**PR 2 (tutorial + docs):**
6. SQL setup script; validate by loading it into a scratch DB and booting an
   `api` instance.
7. Write the five docs; wire `mix.exs`; add README "Documentation" section.
8. **`mix docs --warnings-as-errors` green gate** + `mix format`.
9. Optional: run a couple of tutorial requests end-to-end against a booted
   brewery instance so printed curl/response pairs are real.
10. Open PR 2.

## Risks

- **Conformance regression from PR 1's harness split.** The `bulk` instance
  reproduces today's superuser behavior exactly; the `auth` instance reproduces
  today's `schema=="auth"` behavior for the routed cases. Residual risk is
  routing completeness — caught by the `mix test` gate; fix via the predicate,
  never `spec/`.
- **An `openapi`/root case that reads a relation under role-switch** could hit
  `42501` on the `auth` instance. Mitigation: identify during the green-gate run
  and route or adjust.
- **Example drift.** Tutorial request/response pairs must match real Bier output;
  mitigated by running the examples against a booted brewery instance.
- **Doc build warnings** failing `--warnings-as-errors`; mitigated by building
  locally and using the existing `skip_*` docs config.
```
