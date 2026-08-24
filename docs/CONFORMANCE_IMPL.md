# Bier conformance implementation guide (agent handoff)

This is the **shared context** for every implementation agent working to make the
conformance suite (`test/conformance/conformance_test.exs`) pass. Read it fully
before writing code. It encodes findings that are expensive to re-derive.

> **Authority split.** `spec/` is a git submodule of
> [`milmazz/postgrest-conformance`](https://github.com/milmazz/postgrest-conformance).
> That repo's `spec/HARNESS.md` is the **implementer-agnostic contract**:
> fixture build, server config keys, request execution, and assertion
> semantics — it is the authority for anything it covers, and this doc does
> not restate it. This doc covers only the **bier-specific** layer on top of
> that contract: the ExUnit harness under `test/support/`, the DB-wiring
> keystone this codebase uses to satisfy the contract, the request pipeline,
> and build order. When in doubt about what a case *means*, read
> `spec/HARNESS.md`; when in doubt about how *bier* implements it, read on.

> Goal (operational definition of done): every conformance case that passes
> against PostgREST v16.0 must pass against Bier, against the same Postgres
> fixture DB. PostgREST is the ground truth; cases cite the exact source line.

> **Pinned version: v16.0** (submodule tag `v16.0.0-suite.4`, which folded in
> the spread/aggregate cases 11100–11138 and added the `--ready` CLI cases
> 1745–1748). `spec/` was re-synced from v14.12 to
> v16.0 in one spec-only pass (532 → 762 cases, every `source:` re-pinned),
> which moved the target ahead of `lib/` by 100 failures. `lib/` has since
> caught up: the suite is green, all 17 areas at zero, and issues #93–#96 are
> closed.
> Re-syncing `spec/` itself now happens **upstream**, in the
> `postgrest-conformance` repo, via its own workflows — this repo only bumps
> the pinned submodule commit; implementation work never edits `spec/`
> directly.

---

## 0. Hard rules for agents

- **Writes allowed only under** `lib/`, `mix.exs`, and `config/`.
- **NEVER edit** anything under `test/**` or `spec/**`. The test harness and the
  conformance cases/fixtures are frozen ground truth. If a test seems wrong, it
  is almost certainly encoding real PostgREST behavior — re-read the cited
  `source:` URL, do not change the test.
- Serialize JSON through `Bier.json_library()` (never call `JSON`/`Jason`
  directly).
- CI gates (run before claiming done):
  `mix format --check-formatted`, `mix compile --warnings-as-errors`,
  `mix deps.unlock --check-unused`, then `mix test`.
- Verify a slice with: `mix test --only area:<area>` (tags are set per case, see
  §3). Don't break previously-green areas — run the full `mix test` before
  finishing.

---

## 1. The frozen test harness (the contract you implement against)

- `test/test_helper.exs` calls `Bier.ConformanceServer.start!()` then
  `ExUnit.start(exclude: [:pending])`.
- `Bier.ConformanceServer` (`test/support/conformance_server.ex`) boots **ONE
  shared `Bier` instance** for the whole suite:
  `Bier.start_link(name: :"...Instance", router: [port: <free>, scheme: :http])`.
  **It passes only `name` + `router`.** Therefore **all DB/PostgREST settings
  must come from `config/` (application env), not from start_link opts.**
- `Bier.HttpCase.perform/1` (`test/support/http_case.ex`) issues the request with
  `Req` and returns `%{status:, headers:, body:}` (header keys downcased, multi
  values joined with `", "`, body is the **raw string** — not decoded).
- **Accept-Profile mapping (critical):** `perform/1` derives the request schema
  from the case's `schema:` field:

  ```elixir
  if schema in [nil, "public", "test"], do: base,
  else: Map.put_new(base, "Accept-Profile", schema)
  ```

  So a case with `schema: operators` is sent with header
  `Accept-Profile: operators` (unless it already set one). `schema: test`/nil
  sends **no** profile header. See §2 for what this demands of the DB. This is
  bier's implementation of `spec/HARNESS.md` §3 (step 4) — that document is
  the authority on the rule itself; this is only proof bier's harness follows
  it.
- `Bier.ConformanceAssertions` implements the assertion semantics
  `spec/HARNESS.md` §4 specifies (`status`, `headers`, `headers_present`,
  `headers_absent`, `headers_match`, `headers_no_blank`,
  `headers_absent_in_value`, `body_exact`/`body_json`, `body_contains`,
  `body_raw`, `body_jsonpath`; unknown keys raise rather than skip silently).
  Read HARNESS.md §4 for what each key means — don't re-derive it from this
  module's source. The only case category bier's own harness can't assert is
  `status_text` (3 cases, HTTP reason phrase — `Req` doesn't expose it), tagged
  `:pending` and excluded; that's a bier-specific limitation, not part of the
  upstream contract (see §3 below).
- The conformance suite runs `async: true` → **the shared instance/DB is
  concurrently hit by many tests.** Read paths are fine. Mutating areas
  (`mutations`, `representations` writes) must not rely on global DB state that
  other tests mutate; prefer per-area schemas (§2) and design so concurrent
  mutation cases don't collide (PostgREST cases are mostly self-contained, e.g.
  they insert+return without asserting table-wide counts; verify per case).

---

## 2. Database wiring (the keystone)

### 2.1 Target DB & fixtures
- Local Postgres (running on `localhost:5432`, PostgreSQL 17) with the PostGIS
  extension available — `mix bier.fixtures.load` runs the `spec/` submodule's
  numbered fixture chain (`spec/fixtures/01_roles.sql` through
  `07_analyze.sql`, in order, via `psql`), which includes `04_postgis.sql`
  running `CREATE EXTENSION IF NOT EXISTS postgis` and creating `test.shops`
  for the frozen geo+json read cases (1616-1618), plus an isolated `geotest`
  schema (shops/shop_bles/plain tables, `get_shops`/`get_shop_geom` functions)
  used by `test/bier/geojson_test.exs` (reads, incl. the advanced/embed path)
  and `test/bier/geojson_http_test.exs` (mutations and RPC) to cover
  `application/geo+json` — deliberately excluded from the shared instance's
  `db_schemas` so the frozen suite never sees it. DB name: **`bier_test`**.
  Connecting user: the local superuser (`milmazz`); roles
  `postgrest_test_anonymous|default_role|author` already exist cluster-wide and
  are also (idempotently) created by the fixtures.
- `spec/fixtures/02_base.sql` is the **primary fixture artifact** (the
  submodule's successor to bier's old, in-repo `fixtures.sql`): it originated
  as the merge of the 17 per-area fragments into schema **`test`** (plus `v1`,
  `v2`, `observability`, `private`, `postgrest`, `jwt`, `"تست"`,
  `"SPECIAL ""@/\#~_-"`), choosing the **superset** object/seed when fragments
  disagreed, and has since gained objects the fragments never had. It is
  **never regenerated from the fragments** (they are historical provenance,
  kept in the submodule under `spec/fixtures/provenance/`) — it changes only
  incrementally, upstream, via a reviewed commit to the submodule. See
  `spec/fixtures/README.md` for the full layering, including
  `spec/fixtures/03_supplement.sql` (the successor to bier's old, human-edited
  `fixtures_local.sql`, now upstream-owned) which the chain loads right after
  `02_base.sql`. `test.items` ends up `bigserial` PK with rows **1..15** — the
  superset that satisfies operators/ordering/pagination/etc.

### 2.2 Why area schemas must exist, and the view-mirror trick
A case's `schema:` is a **fixture-set label, not a Postgres schema**
(`spec/INDEX.md`). But the frozen harness turns labels like `operators`,
`ordering`, `pagination`, `representations`, `mutations`, `rpc`, `headers`,
`config`, `openapi`, `domain_representations` into a real
`Accept-Profile: <label>` header. PostgREST returns **406 PGRST106** for an
`Accept-Profile` not in `db-schemas` (proven by cases 1010/1012/1560 →
`{"code":"PGRST106","message":"Invalid schema: unknown"}`). So for those cases
to return **200 with their data**, each label **must be a real exposed schema
containing that area's tables**.

**Keystone (verified):** because the consolidator already folded every area into
`test` as a superset, nobody text-munges fragments. Instead the fixture chain's
last generated step, `spec/fixtures/06_area_schemas.sql`, **mirrors `test` into
each area schema as auto-updatable views**:

```sql
CREATE SCHEMA operators;
-- for every table r in schema test:
CREATE VIEW operators.<r> AS SELECT * FROM test.<r>;
-- for every view v in schema test: the mirror inlines v's own
-- definition (its base tables/functions) instead of selecting from
-- test.<v>, so writes through the mirror resolve PKs/Location the
-- same way the original view does (suite.3, case 1824)
```

That file is **pre-generated and checked into the submodule**, not built at
load time — bier's loader only executes it as one more chain step, the same
as any other `spec/fixtures/0N_*.sql` file. It is regenerated **upstream**
(`elixir tools/regen_area_schemas.exs` in `postgrest-conformance`) whenever a
fixture change adds/removes an area-schema relation; bier never regenerates
or hand-edits it.

Verified: `operators.items WHERE id=5` ⇒ `[{"id":5}]` (case 1050);
`NOT (id=5)` ⇒ 14 rows 1..4,6..15 (case 1051); the views report
`is_insertable_into = YES`, so simple single-table writes (mutations,
representations) pass straight through to `test.*`.

**Mirror list** (areas whose label ≠ `test`/`public` and that are pure
table/data areas): `operators, ordering, pagination, representations, mutations,
headers, config, domain_representations`. (`headers`/`config` also need the
v1/v2/private/special schemas, already built by the consolidated load.)

**Function-heavy areas** (`rpc`, `openapi`, parts of `auth`/`config`) expose
**functions**, which plain views don't cover. `06_area_schemas.sql` carries
those too: alongside the view mirrors it has full `CREATE FUNCTION`/`CREATE
TABLE` statements for each area's function-backed objects (e.g.
`rpc.add_them`, `rpc.getallprojects`, `config.get_lines`), produced by the
same upstream `tools/regen_area_schemas.exs` pass (§2.2 above) and checked
into the submodule alongside the view mirrors. Bier's loader does not choose
a mirroring strategy or generate any of this DDL — it only executes the
file as one more `spec/fixtures/0N_*.sql` chain step (§2.3). A function-heavy
area that needs a new or changed object gets that change **upstream**, in
`postgrest-conformance`, like any other fixture edit.

### 2.3 How the loader runs
- A `Mix.Task` (`lib/mix/tasks/bier.fixtures.load.ex`, namespaced
  `mix bier.fixtures.load`) that: runs `spec/fixtures/01_roles.sql` against the
  `postgres` maintenance DB, drops+recreates `bier_test` (pinned to
  `TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C'`, per
  `spec/HARNESS.md` §1), then runs every remaining `spec/fixtures/0N_*.sql`
  file, in sorted order, against it via `psql`. It is a pure **chain
  executor** now — all the dynamic DDL generation (the postgis extension
  setup, the area-schema mirror loop) that used to live in this task moved
  upstream as static, checked-in fixture files (§2.1–2.2). Idempotent (safe to
  re-run). Connection params come from the standard `PG*` environment
  variables (`PGHOST`/`PGPORT`/`PGDATABASE`/`PGUSER`/`PGPASSWORD`), not
  `config/test.exs` — the task deliberately doesn't depend on a shipped
  `config/` (the conformance server's own settings live in
  `Bier.ConformanceServer.base_opts/0`, per `spec/HARNESS.md` §2.1).
- Wired into a `mix test` **alias** in `mix.exs`:
  `aliases: [test: ["bier.fixtures.load", "test"]]` (with
  `preferred_cli_env`/`elixirc_paths` so the task compiles in `:test`).
- Shells out to `psql` (present at `/opt/homebrew/opt/libpq/bin/psql` on the
  reference dev machine, or on `PATH` in CI) for every file in the chain, with
  `-v ON_ERROR_STOP=1 -q` and `PGTZ=UTC` (per `spec/HARNESS.md` §1) so
  failures are loud and timestamp literals resolve consistently.

### 2.4 Config plumbing
- Extend `Bier.Config` + the `@schema` in `lib/bier.ex` with DB settings, with
  **defaults sourced from application env** so the frozen ConformanceServer
  (which passes none) still gets them. Suggested keys (PostgREST parity names):
  `db: [hostname, port, database, username, password, pool_size]`,
  `db_schemas` (ordered list; **first is the default** schema, i.e. `"test"`),
  `db_anon_role` (`"postgrest_test_anonymous"`), `db_extra_search_path`,
  `db_max_rows`, `jwt_secret`, `server_cors_allowed_origins`, ...
- `config/config.exs` holds shared defaults; `config/test.exs` points at
  `bier_test`; `config/runtime.exs` can read `DATABASE_URL`/`PGRST_*` env for the
  `config` area cases. Keep `db_schemas` listing **every** exposed schema:
  `["test","operators","ordering","pagination","representations","mutations","rpc","headers","config","openapi","domain_representations","observability","v1","v2", ...]`.

---

## 3. Case → area → tag map (how to target a slice)

`test/conformance/conformance_test.exs` generates one test per case and sets
`@tag area: :<area>` (first `/` segment of `feature:`). **`:status_text` is the
only harness-gap pending reason** (`Req` does not expose the HTTP reason phrase,
#42) — 3 cases, excluded; don't target them. The other pending reason,
`:deliberate_divergence`, is a decision rather than a gap (1771 → #122, 11125 →
#138); it is declared in `@divergences`/`@divergence_pins` in
`test/conformance/conformance_test.exs`, and README §"Deliberate divergences
from PostgREST" carries the rationale. `:jwt`, `:jsonpath` and `:cli` are no
longer pending: JWT and JSONPath cases run in the normal suite and CLI cases run
directly via `Bier.CliCase`.

Counts and bands below are the **805**-case v16.0 tree, derived from disk;
`spec/INDEX.md` is the authoritative cross-reference (`spec/HARNESS.md` §7
carries the same table, implementer-agnostic) and a case's `feature:` prefix
— not its id neighbourhood — decides its area. The table below adds one
column HARNESS.md's doesn't: the sub-feature notes an implementation agent
actually needs; treat `spec/HARNESS.md`/`spec/INDEX.md` as authoritative for
the id bands/counts themselves if the two ever drift after a pin bump.

> **Four areas use 5-digit overflow bands** (`operators` 10200+, `mutations`
> 11400+, `auth` 11800+, `content_negotiation` 12400+) because their 50-wide
> primary bands filled. These sort *lexically* into unrelated areas' ranges, so
> `ls spec/cases/` is misleading — always `ls | sort -n`.

| Area | Id band | Count | Profile/schema | Notes |
|------|---------|------:|----------------|-------|
| url_grammar | 1000–1035 | 36 | test/multi/unicode + explicit v1/v2 | path & method resolution, %-encoding, `+`→space, reserved params (`limit`/`offset` forbidden on PUT), OPTIONS `Allow` matrix, Accept/Content-Profile (incl. 406 PGRST106), unicode schema `"تست"` |
| operators | 1050–1099, 10200–10236 | 87 | `operators` | eq/neq/lt../in (incl. empty set)/is/like/ilike/match/fts (incl. auto `to_tsvector()` coercion)/cs/cd/ov/sl/sr/adj/isdistinct/not/quantifier |
| select | 1100–1149, 11100–11138 | 89 | `test` | columns, alias, `::cast`, json-path, computed cols, **embedding** (incl. the v16 alias/legacy-target-name rules and `table!fk` hints), spread, aggregates |
| filters | 1150–1199 | 50 | `test` | horizontal, logical `and/or/not`, json, quoting, embed filters (incl. `!inner`, null filtering, or-across-embeds) |
| ordering | 1200–1232 | 33 | `ordering` | dir, nulls first/last, json_path, computed, multi-col, related/embed |
| pagination | 1250–1288 | 39 | `pagination` | limit/offset, **Range header**, **Content-Range**, count modes (`Prefer: count=`), `db-max-rows` |
| representations | 1300–1327, 1330–1333 | 32 | `representations` (+`rpc` for 1326) | `Prefer: return=representation/minimal`, singular (`Accept: ...vnd.pgrst.object`), stripped nulls, `Preference-Applied` |
| mutations | 1350–1399, 11400–11415 (no 11406) | 65 | `mutations` | POST/PATCH/PUT/DELETE, upsert (`Prefer: resolution=`), columns param, missing-default, safe-update/delete, max-affected, form-urlencoded bodies |
| rpc | 1400–1443 | 44 | `rpc` (functions) + `test` | GET/POST `/rpc/<fn>`, scalar/setof/composite/void, args, overloaded, variadic, single unnamed json param |
| auth | 1450–1499, 11800–11818 | 69 | `auth` | JWT verification, audience, `jwt-role-claim-key` (v16: RFC 9535 JSON Path, #93), anonymous role, role via GUC, pre-request |
| errors | 1500–1526 | 27 | `test` | SQLSTATE→HTTP map, PGRST codes, `RAISE`, error headers, envelope key order, verbosity |
| headers | 1550–1584 | 35 | `headers` (+v1/v2/private/special) | Prefer (incl. v16 `timezone`, #94), Accept/Content-Profile, Location, Content-Location, `Vary`, GUC response headers |
| content_negotiation | 1600–1649, 12400–12401 | 52 | `test` | JSON/CSV/GeoJSON/octet-stream/text, `Accept` negotiation & precedence, singular, nulls-stripped, custom media handlers, errors |
| openapi | 1650–1688 | 39 | `openapi` (functions) + `openapi_no_comment` | root spec, defaults, comments, table/types/rpc/security, modes |
| config | 1700–1748 | 49 | `config` | sources/aliases/validation/coercion/precedence, `db-max-rows`, `db-tx-end`, app-settings, CORS, `--dump-config` and `--ready` (via `Bier.CliCase`) |
| observability | 1750–1771 | 22 | `observability` | `Server-Timing`, trace header passthrough, log level, `Server:` header |
| domain_representations | 1800–1836 | 37 | `domain_representations` (+`test` for 1822) | domain cast read/write/filter/default representations, `?columns=` on views |

---

## 4. Request pipeline (target architecture)

PostgREST resolves the target relation **at request time** from the path +
Accept-Profile, then builds **one SQL statement** returning JSON. Mirror that:

1. **Per-instance Postgrex pool** under the `Bier` supervisor, registered via
   `Bier.Registry.via(name, Postgrex)`. Add it to the children in
   `Bier.init/1` (params from `Bier.Config`). `HttpServerStarter` uses it for
   introspection at boot.
2. **Introspection** (`lib/bier/introspection.ex`, replaces the stub in
   `http_server_starter.ex`): query `pg_catalog`/`information_schema` for tables,
   columns (name, type, pk, nullability, default), primary keys, and **foreign
   keys** (needed for embedding), across all `db_schemas`. Cache in instance
   state (and/or `:persistent_term`). The schema cache is read on every request.
3. **Routing** (`lib/bier/router_builder.ex`): the current per-table
   `get/post/delete` generation can't express Accept-Profile resolution or
   `/rpc/*`. Move to a **catch-all** that sends every request to
   `ActionController`, which resolves `{schema, relation}` from the path +
   `Accept-Profile`/`Content-Profile` (default schema = first of `db_schemas`).
   Keep the `:match`/`Plug.Parsers`/`:dispatch` plug pipeline. Unknown relation
   ⇒ 404 PGRST205; unknown schema ⇒ 406 PGRST106.
4. **Parse** the query string with `Bier.QueryParser` (extend it). PostgREST
   reserved params: `select`, `order`, `limit`, `offset`, `on_conflict`,
   `columns`, `and`, `or`, `not`; everything else is a column filter
   (`col=op.value`, with `not.`, ranges, quantifiers). NB: the harness decodes
   `+`→space per URL rules — handle in the path/query layer.

   > The two parser modules — `lib/bier/query_parser.ex` and
   > `lib/bier/query_parser/nimble.ex` — are **generated** (dependency-free,
   > no runtime `nimble_parsec`) from `*.ex.exs` templates via `mix gen.parsers`.
   > `nimble_parsec` is a `:dev`-only dep used solely to run that task. Edit the
   > `.ex.exs` templates, re-run `mix gen.parsers`, and commit both the template
   > and the regenerated `.ex` (the `.ex` is the source `mix compile` reads).
5. **Build SQL** (`lib/bier/query_executor.ex`). PostgREST's shape, reproduce it:

   ```sql
   SELECT coalesce(json_agg(_postgrest_t), '[]')::text AS body,
          count(*) OVER() AS full_count   -- for Content-Range/count
   FROM ( SELECT <select-list> FROM <schema>.<relation>
          WHERE <filters> ORDER BY <order> LIMIT <l> OFFSET <o> ) _postgrest_t;
   ```

   - Use **parameterized** queries (`$1`,…) — never interpolate user values.
   - Singular (`Accept: application/vnd.pgrst.object+json`) ⇒ `json_agg`→single
     object, 406 if not exactly one row (PGRST116).
   - Set role per request (`SET LOCAL role` to `db_anon_role` or JWT role) inside
     a transaction; commit/rollback per `db-tx-end`. Foundation may run as the
     connecting user (no role switch) and add role-switching with auth.
6. **Render**: `Content-Type: application/json; charset=utf-8`, `Content-Range`
   (e.g. `0-13/*` or `0-13/15`), status (200/201/204/206), Location for inserts,
   etc. Body is compared as **raw JSON text** but via deep-equality after decode
   (key order doesn't matter; **whitespace doesn't matter**) — except `body_raw`
   cases (CSV etc.) which compare the exact string.
7. **Errors** (`lib/bier/plugs/fallback_controller.ex`): emit PostgREST's
   envelope `{"code","message","details","hint"}` and map SQLSTATE→HTTP
   (`23503`→409 PGRST.., `42501`→403, `42P01`→404 PGRST205, `22P02`→400, …) and
   PGRST codes (PGRST100/102/103/106/116/200/202/204/300…). The `errors` area
   cases pin exact codes/messages — follow them precisely.

---

## 5. Suggested build order (dependencies)

1. **Foundation** (must come first; everything depends on it): deps
   (`postgrex`), config plumbing (§2.4), fixture chain loader (§2.3, which
   pulls in the pre-generated area-schema mirror from §2.2), Postgrex pool,
   introspection, catch-all routing, read pipeline
   (select/filters/order/limit/offset → SQL → JSON), Content-Type, basic
   Content-Range, error envelope skeleton. **Target green:** `operators` (87),
   `ordering` (33), and the `test`-schema read parts of `select`/`filters`.
2. **Read-shaped slices** (extend parser/executor): `pagination`
   (Range/Content-Range/count), `select` embedding+aggregates+casts, `filters`
   logical/json, `ordering` edge cases, `content_negotiation`
   (CSV/GeoJSON/singular/nulls).
3. **Write slices**: `mutations`, `representations` (Prefer return=, upsert,
   columns, safe-update).
4. **Function/meta slices**: `rpc` (its area-schema functions ship pre-built
   in `06_area_schemas.sql`, §2.2), `openapi`, `errors`, `headers`,
   `observability`, `domain_representations`, `config` (non-CLI subset),
   `url_grammar` profile/406 edge cases.
5. **auth**: only the small non-`:pending` subset is reachable now.

Each slice: read its cases, run `mix test --only area:<area>`, implement to
green, then run the **full** `mix test` to catch regressions, then `mix format`.

---

## 6. Gotchas discovered
- `mise` pins Elixir 1.20 / OTP 29; `JSON` stdlib is the default encoder.
- The shell here is `fish`; `psql` lives at `/opt/homebrew/opt/libpq/bin/psql`.
- Fixtures `GRANT` privileges to `postgrest_test_*` roles **on `test.*`**; if you
  add role-switching, mirror grants to area schemas or the anon role will get
  `42501`. Foundation connecting as superuser sidesteps this.
- `headers`/`url_grammar` use exotic schema names (`"تست"`, `"SPECIAL ..."`) —
  identifier quoting matters.
- Body comparison is JSON-deep-equal (whitespace/key-order agnostic) except
  `body_raw`. Don't fight whitespace for JSON cases.
- Don't target `:pending` cases (only `status_text`, 3 cases — see §3) — they
  `flunk` by design and are excluded.
