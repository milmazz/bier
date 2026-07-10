# Bier conformance implementation guide (agent handoff)

This is the **shared context** for every implementation agent working to make the
conformance suite (`test/conformance/conformance_test.exs`) pass. Read it fully
before writing code. It encodes findings that are expensive to re-derive.

> Goal (operational definition of done): every conformance case that passes
> against PostgREST v14.12 must pass against Bier, against the same Postgres
> fixture DB. PostgREST is the ground truth; cases cite the exact source line.

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
  sends **no** profile header. See §2 for what this demands of the DB.
- `Bier.ConformanceAssertions` supports these `expect` keys: `status`,
  `headers` (exact), `headers_present`, `headers_absent`, `headers_match`
  (regex), `headers_no_blank`, `headers_absent_in_value`, `body_exact` /
  `body_json` (deep JSON equality; empty/nil ⇒ body must be `""`),
  `body_contains` (substring list), `body_raw` (exact string). Unknown keys
  raise. `body_jsonpath`, `status_text`, JWT, and CLI cases are auto-tagged
  `:pending` and excluded — **do not target them** (see §3).
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
  extension available — `mix bier.fixtures.load` runs
  `CREATE EXTENSION IF NOT EXISTS postgis` and creates `test.shops` for the
  geo+json cases (1616-1618). DB name: **`bier_test`**. Connecting user: the
  local superuser (`milmazz`); roles
  `postgrest_test_anonymous|default_role|author` already exist cluster-wide and
  are also (idempotently) created by the fixtures.
- `spec/conformance/fixtures.sql` is the **consolidated** fixture: it merges all
  17 per-area fragments into schema **`test`** (plus `v1`, `v2`, `observability`,
  `private`, `postgrest`, `jwt`, `"تست"`, `"SPECIAL ""@/\#~_-"`), choosing the
  **superset** object/seed when fragments disagree. It loads cleanly into a fresh
  `bier_test` (`psql -v ON_ERROR_STOP=1 -f spec/conformance/fixtures.sql`).
  `test.items` ends up `bigserial` PK with rows **1..15** — the superset that
  satisfies operators/ordering/pagination/etc.

### 2.2 Why area schemas must exist, and the view-mirror trick
A case's `schema:` is a **fixture-set label, not a Postgres schema**
(`spec/conformance/INDEX.md`). But the frozen harness turns labels like
`operators`, `ordering`, `pagination`, `representations`, `mutations`, `rpc`,
`headers`, `config`, `openapi`, `domain_representations` into a real
`Accept-Profile: <label>` header. PostgREST returns **406 PGRST106** for an
`Accept-Profile` not in `db-schemas` (proven by cases 1010/1012/1560 →
`{"code":"PGRST106","message":"Invalid schema: unknown"}`). So for those cases
to return **200 with their data**, each label **must be a real exposed schema
containing that area's tables**.

**Keystone (verified):** because the consolidator already folded every area into
`test` as a superset, you do **not** text-munge fragments. Instead the fixture
loader **mirrors `test` into each area schema as auto-updatable views**:

```sql
CREATE SCHEMA operators;
-- for every relation r in schema test:
CREATE VIEW operators.<r> AS SELECT * FROM test.<r>;
```

Verified: `operators.items WHERE id=5` ⇒ `[{"id":5}]` (case 1050);
`NOT (id=5)` ⇒ 14 rows 1..4,6..15 (case 1051); the views report
`is_insertable_into = YES`, so simple single-table writes (mutations,
representations) pass straight through to `test.*`.

**Mirror list** (areas whose label ≠ `test`/`public` and that are pure
table/data areas): `operators, ordering, pagination, representations, mutations,
headers, config, domain_representations`. (`headers`/`config` also need the
v1/v2/private/special schemas, already built by the consolidated load.)

**Function-heavy areas** (`rpc`, `openapi`, parts of `auth`/`config`) expose
**functions**, which views don't cover. Options for the owning agent, in order of
preference:
1. Mirror `test`'s functions into the area schema with thin SQL wrappers
   generated from `pg_proc` (handle overloads/variadics/OUT params), **or**
2. Re-load that one fragment into the area schema by remapping its
   `test`→`<area>` schema references at load time (those fragments are
   `test.`-qualified, so a scoped rewrite of `\btest\b` in DDL contexts works;
   verify nothing in string literals breaks).
   Keep this confined to the area's own loader step.

### 2.3 How the loader runs
- A `Mix.Task` (`lib/mix/tasks/bier.fixtures.load.ex`, namespaced
  `mix bier.fixtures.load`) that: drops+creates `bier_test`, ensures roles, loads
  `spec/conformance/fixtures.sql`, then mirrors the area schemas. Idempotent
  (safe to re-run). Connection params from `config/test.exs`.
- Wire it into a `mix test` **alias** in `mix.exs`:
  `aliases: [test: ["bier.fixtures.load", "test"]]` (and add
  `preferred_cli_env`/`elixirc_paths` so the task compiles in `:test`).
- It may shell out to `psql` (present at `/opt/homebrew/opt/libpq/bin/psql`) for
  the bulk `\i fixtures.sql`, and use Postgrex for the mirror loop — pick one and
  keep it simple. `ON_ERROR_STOP=1` so failures are loud.

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
`@tag area: :<area>` (first `/` segment of `feature:`). Pending tags
(`:cli`, `:jwt` via `request.jwt`, `:jsonpath` via `expect.body_jsonpath`,
`:status_text`) are excluded — **don't count or target them.**

| Area | Id band | Count | Profile/schema | Notes |
|------|---------|------:|----------------|-------|
| url_grammar | 1000–1027 | 28 | test/multi/unicode + explicit v1/v2 | path & method resolution, %-encoding, `+`→space, reserved params, Accept/Content-Profile (incl. 406 PGRST106), unicode schema `"تست"` |
| operators | 1050–1099 | 50 | `operators` | eq/neq/lt../in/is/like/ilike/match/fts/cs/cd/ov/sl/sr/adj/isdistinct/not/quantifier |
| select | 1100–1137 | 38 | `test` | columns, alias, `::cast`, json-path, computed cols, **embedding** (FK resolution), spread, aggregates |
| filters | 1150–1187 | 38 | `test` | horizontal, logical `and/or/not`, json, quoting, embed filters |
| ordering | 1200–1222 | 23 | `ordering` | dir, nulls first/last, json_path, computed, multi-col, related/embed |
| pagination | 1250–1277 | 28 | `pagination` | limit/offset, **Range header**, **Content-Range**, count modes (`Prefer: count=`), `db-max-rows` |
| representations | 1300–1332 | 33 | `representations` | `Prefer: return=representation/minimal`, singular (`Accept: ...vnd.pgrst.object`), stripped nulls |
| mutations | 1350–1395 | 46 | `mutations` | POST/PATCH/PUT/DELETE, upsert (`Prefer: resolution=`), columns param, missing-default, safe-update/delete, max-affected |
| rpc | 1400–1439 | 40 | `rpc` (functions) | GET/POST `/rpc/<fn>`, scalar/setof/composite/void, args, overloaded, single unnamed json param |
| auth | 1450–1494 | 45 | `auth` | **mostly `:pending` (jwt)**. Non-jwt: anonymous, role via GUC, pre-request — small subset evaluable |
| errors | 1500–1516 | 17 | `test` | SQLSTATE→HTTP map, PGRST codes, `RAISE`, error headers |
| headers | 1550–1574 | 25 | `headers` (+v1/v2/private/special) | Prefer, Accept/Content-Profile, Location, Content-Location, GUC response headers |
| content_negotiation | 1600–1638 | 39 | `test` | JSON/CSV/GeoJSON/octet-stream/text, `Accept` negotiation & precedence, singular, nulls-stripped, custom media handlers, errors |
| openapi | 1650–1682 | 33 | `openapi` (functions) | root spec, defaults, comments, table/types/rpc/security, modes |
| config | 1700–1730 | 31 | `config` | sources/aliases/validation/coercion/precedence, `db-max-rows`, `db-tx-end`, app-settings, CORS. Several are `:cli` (pending) |
| observability | 1750–1767 | 18 | `observability` | `Server-Timing`, trace header passthrough, log level |
| domain_representations | 1800–1814 | 15 | `domain_representations` | domain cast read/write/filter/default representations |

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
   (`postgrex`), config plumbing (§2.4), fixture loader + mirror (§2.2–2.3),
   Postgrex pool, introspection, catch-all routing, read pipeline
   (select/filters/order/limit/offset → SQL → JSON), Content-Type, basic
   Content-Range, error envelope skeleton. **Target green:** `operators` (50),
   `ordering` (23), and the `test`-schema read parts of `select`/`filters`.
2. **Read-shaped slices** (extend parser/executor): `pagination`
   (Range/Content-Range/count), `select` embedding+aggregates+casts, `filters`
   logical/json, `ordering` edge cases, `content_negotiation`
   (CSV/GeoJSON/singular/nulls).
3. **Write slices**: `mutations`, `representations` (Prefer return=, upsert,
   columns, safe-update).
4. **Function/meta slices**: `rpc` (function mirroring §2.2), `openapi`,
   `errors`, `headers`, `observability`, `domain_representations`, `config`
   (non-CLI subset), `url_grammar` profile/406 edge cases.
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
- Don't target `:pending` cases (jwt/jsonpath/status_text/cli) — they `flunk` by
  design and are excluded.
