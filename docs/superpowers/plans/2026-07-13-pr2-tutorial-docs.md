# PR 2 — Brewery tutorial & user-facing documentation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **BLOCKED ON PR 1** (`2026-07-13-pr1-auth-gate.md`) being merged: the Authentication tutorial relies on a naturally named `api` schema getting role-switching once `jwt_secret`/`db_anon_role` are configured. Do not start until PR 1 is on the base branch.

**Goal:** Ship a PostgREST-style documentation set — two tutorials and three reference guides — built on an original brewery-catalog example database, rendered as ex_doc extras.

**Architecture:** New Markdown files under `docs/tutorials/` and `docs/guides/`, wired into `mix.exs` `extras` + `groups_for_extras`. A single runnable SQL script (`docs/tutorials/brewery.sql`) backs both tutorials. Reference guides document the existing library surface (query grammar, config, observability) with brewery examples.

**Tech Stack:** ex_doc (`~> 0.40`), Markdown, PostgreSQL, curl. Mermaid is available in docs (configured in `mix.exs` `before_closing_head_tag`).

## Global Constraints

- ex_doc `main: "readme"` stays; docs build must pass `mix docs --warnings-as-errors` (a CI gate). Use `skip_undefined_reference_warnings_on` / `skip_code_autolink_to` in `mix.exs` if a new extra triggers autolink warnings, mirroring the existing pattern.
- **All examples use the brewery `api` schema** and must reflect *Bier's actual behavior* — verify request/response pairs against a booted instance, don't copy PostgREST output.
- Do not edit `spec/**` or `test/**`.
- Elixir `~> 1.18`; JSON via stdlib `JSON` (Bier default).
- End commit messages with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## File Structure

- `docs/tutorials/brewery.sql` — runnable schema+roles+seed (source of truth for both tutorials).
- `docs/tutorials/getting-started.md` — tut0 analog.
- `docs/tutorials/authentication.md` — tut1 analog.
- `docs/guides/api-reference.md` — request/response API surface.
- `docs/guides/configuration.md` — options + config surfaces + standalone.
- `docs/guides/observability.md` — telemetry/timing/health/errors.
- `mix.exs` — `extras` + `groups_for_extras`.
- `README.md` — add a short "Documentation" section.

Each doc is one task (a reviewer can accept/reject each page independently). Task 1 (SQL) is a dependency of Tasks 2-3 and is verified by actually booting Bier against it.

---

## Task 1: Brewery example database (runnable SQL)

**Files:** Create `docs/tutorials/brewery.sql`

- [ ] **Step 1: Write the SQL script**

```sql
-- docs/tutorials/brewery.sql
-- The Bier tutorial database: a brewery catalog.
-- Load with:  psql -d bier_tutorial -f docs/tutorials/brewery.sql

-- ---------------------------------------------------------------------------
-- Roles (PostgREST-style): `authenticator` connects and can switch into the
-- anonymous or member role. Change the password before using anywhere real.
-- ---------------------------------------------------------------------------
create role authenticator noinherit login password 'mysecretpassword';
create role web_anon nologin;
create role brewery_member nologin;
grant web_anon to authenticator;
grant brewery_member to authenticator;

create schema api;
grant usage on schema api to web_anon, brewery_member;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table api.styles (
  id          serial primary key,
  name        text not null unique,
  description text
);

create table api.breweries (
  id           serial primary key,
  name         text not null,
  city         text,
  country      text,
  founded_year int,
  latitude     numeric(9,6),
  longitude    numeric(9,6)
);

create table api.beers (
  id          serial primary key,
  brewery_id  int not null references api.breweries(id),
  style_id    int references api.styles(id),
  name        text not null,
  abv         numeric(4,2),
  ibu         int,
  description text
);

create table api.taprooms (
  id         serial primary key,
  brewery_id int not null references api.breweries(id),
  name       text not null,
  address    text,
  city       text
);

create table api.check_ins (
  id         serial primary key,
  beer_id    int not null references api.beers(id),
  drinker    text not null,
  rating     int not null check (rating between 1 and 5),
  comment    text,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Functions (RPC)
-- ---------------------------------------------------------------------------
create function api.search_beers(term text) returns setof api.beers
  language sql stable as $$
    select * from api.beers
    where name ilike '%' || term || '%'
       or coalesce(description, '') ilike '%' || term || '%';
  $$;

create function api.top_rated_beers(min_rating int default 4)
  returns table(beer_id int, name text, avg_rating numeric, check_in_count bigint)
  language sql stable as $$
    select b.id, b.name, round(avg(c.rating), 2), count(c.id)
    from api.beers b
    join api.check_ins c on c.beer_id = b.id
    group by b.id, b.name
    having avg(c.rating) >= min_rating
    order by avg(c.rating) desc;
  $$;

-- ---------------------------------------------------------------------------
-- Grants: web_anon reads the catalog; brewery_member also posts check-ins.
-- ---------------------------------------------------------------------------
grant select on api.styles, api.breweries, api.beers, api.taprooms, api.check_ins to web_anon;
grant execute on function api.search_beers(text), api.top_rated_beers(int) to web_anon;

grant select on api.styles, api.breweries, api.beers, api.taprooms, api.check_ins to brewery_member;
grant insert on api.check_ins to brewery_member;
grant usage on sequence api.check_ins_id_seq to brewery_member;
grant execute on function api.search_beers(text), api.top_rated_beers(int) to brewery_member;

-- ---------------------------------------------------------------------------
-- Seed data
-- ---------------------------------------------------------------------------
insert into api.styles (name, description) values
  ('IPA', 'India Pale Ale — hop-forward and bitter'),
  ('Stout', 'Dark, roasted, full-bodied'),
  ('Pilsner', 'Crisp pale lager'),
  ('Saison', 'Fruity, spicy farmhouse ale'),
  ('Hazy IPA', 'Juicy, cloudy New England IPA');

insert into api.breweries (name, city, country, founded_year, latitude, longitude) values
  ('Reunion Brewing', 'Portland', 'USA', 2016, 45.512230, -122.658722),
  ('Kernel Brewery', 'London', 'UK', 2009, 51.494400, -0.070300),
  ('Cloudwater', 'Manchester', 'UK', 2014, 53.474800, -2.238300),
  ('Tanque Verde', 'Tucson', 'USA', 2019, 32.221700, -110.926500);

insert into api.beers (brewery_id, style_id, name, abv, ibu, description) values
  (1, 1, 'Trail Crest IPA', 6.80, 65, 'Piney West Coast IPA'),
  (1, 5, 'Fog Line', 6.20, 40, 'Hazy and juicy'),
  (2, 3, 'Table Pils', 4.80, 30, 'Delicate and dry'),
  (2, 2, 'Export Stout', 7.50, 55, 'Rich roasted stout'),
  (3, 5, 'DIPA v12', 8.50, 70, 'Big hazy double IPA'),
  (4, 4, 'Desert Saison', 5.90, 25, 'Peppery farmhouse ale');

insert into api.taprooms (brewery_id, name, address, city) values
  (1, 'Reunion Taproom', '123 SE Ash St', 'Portland'),
  (3, 'Cloudwater Barrel Store', 'Unit 7-8 Sheffield St', 'Manchester');

insert into api.check_ins (beer_id, drinker, rating, comment) values
  (1, 'sam',  5, 'Loved the pine'),
  (1, 'alex', 4, 'Solid IPA'),
  (4, 'sam',  5, 'Best stout in town'),
  (5, 'jo',   4, 'Juicy'),
  (2, 'alex', 3, 'Fine');
```

- [ ] **Step 2: Load it into a scratch database**

Run:
```bash
createdb bier_tutorial 2>/dev/null; psql -d bier_tutorial -f docs/tutorials/brewery.sql
```
Expected: no errors; `CREATE ROLE`/`CREATE TABLE`/`INSERT` notices. (Roles are cluster-global — if they already exist, drop them or ignore the "already exists" error; note this in the tutorial.)

- [ ] **Step 3: Boot Bier against it and smoke-test**

Run (IEx one-liner):
```bash
iex -S mix run -e 'Bier.start_link(name: BreweryDemo, router: [port: 4050, scheme: :http], database: "bier_tutorial", username: "authenticator", password: "mysecretpassword", db_schemas: ["api"], db_anon_role: "web_anon")' &
sleep 2
curl -s "http://localhost:4050/beers?select=name,abv&order=abv.desc&limit=3"
curl -s "http://localhost:4050/rpc/top_rated_beers"
```
Expected: JSON array of beers ordered by abv; RPC returns aggregated rows. Capture the real output — the tutorials must quote these actual responses.

- [ ] **Step 4: Commit**

```bash
git add docs/tutorials/brewery.sql
git commit -m "docs(tutorial): brewery example database (schema, roles, seed)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Getting Started tutorial (tut0 analog)

**Files:** Create `docs/tutorials/getting-started.md`

**Interfaces / facts to use (verified against the library):**
- Boot as a child spec: `{Bier, name:, router: [port:, scheme: :http], database:, username:, password:, db_schemas: ["api"], db_anon_role: "web_anon"}`.
- Standalone/Docker env: `PGRST_DB_URI`, `PGRST_DB_SCHEMAS=api`, `PGRST_DB_ANON_ROLE=web_anon`, `PGRST_SERVER_PORT` (Docker default 3000, `BIER_STANDALONE=1` baked in). Release: `MIX_ENV=prod mix release`, `BIER_STANDALONE=1 ... _build/prod/rel/bier/bin/bier start`.
- Query syntax: filter `?abv=gte.6`, select+rename `?select=beer:name,abv`, order `?order=abv.desc`, paginate `?limit=3&offset=3` and `Range`/`Prefer: count=exact` → `Content-Range`, embed `?select=name,breweries(name,city)`, RPC `GET /rpc/search_beers?term=IPA`.

- [ ] **Step 1: Write the page** with these sections (use real curl output from Task 1 Step 3, and the brewery schema throughout):
  1. Intro — what you'll build (a read-only brewery API) + prerequisites (PostgreSQL running, Elixir 1.18+).
  2. Create the database — `createdb bier_tutorial` + `psql -f docs/tutorials/brewery.sql`; brief note on the three roles.
  3. Run Bier — **Quick path** (Docker/release with the `PGRST_*` env vars above) and **Elixir path** (the child-spec snippet, in a supervision tree and/or `iex -S mix`). Show the boot log / readiness.
  4. Your first requests — list beers; filter (`?abv=gte.6`); select + rename columns; order; paginate (both `limit/offset` and `Range` + `Prefer: count=exact`, showing `Content-Range`); embed breweries; call `GET /rpc/search_beers?term=IPA`. Each with the real curl command and response.
  5. Recap + next steps — link `[API reference](../guides/api-reference.md)` and `[Authentication](authentication.md)`.

- [ ] **Step 2: Verify build** — Run `mix docs --warnings-as-errors 2>&1 | tail -20`. Expected: no warnings referencing this file. (Full `extras` wiring lands in Task 7; for now confirm Markdown is well-formed by building after Task 7, or build ad hoc.)

- [ ] **Step 3: Commit** — `git add docs/tutorials/getting-started.md && git commit -m "docs(tutorial): getting started ..."`.

---

## Task 3: Authentication tutorial (tut1 analog — "the golden tap")

**Files:** Create `docs/tutorials/authentication.md`

**Facts to use (verified):**
- With `jwt_secret` (or `db_anon_role`) configured, role-switching applies to the exposed `api` schema (PR 1 behavior) — no special option.
- Client sends `Authorization: Bearer <jwt>`; role comes from the `role` claim (`jwt_role_claim_key` default `.role`); HS256 secret ≥ 32 bytes.
- Anonymous → `web_anon` (the `db_anon_role`). No token + no anon role → 401 (PGRST302).
- SQL sees `current_setting('request.jwt.claims', true)::json`.
- `db_pre_request` runs a guard function per request inside the auth transaction (the PostgREST `check_token` pattern); a `raise insufficient_privilege` aborts with 401/403.

- [ ] **Step 1: Write the page** with sections:
  1. Recap + goal — anon reads the catalog; only members post check-ins.
  2. Grant the split — `web_anon` has no INSERT on `api.check_ins`; `brewery_member` does (already in `brewery.sql`). Show anon `POST /check_ins` → `401`.
  3. Configure the secret — boot Bier with `jwt_secret: "<32+ byte secret>"` (or `PGRST_JWT_SECRET`) plus `db_anon_role: "web_anon"` and `db_schemas: ["api"]`. One sentence: role-switching now applies to `api` (same as PostgREST).
  4. Mint a token — payload `{"role": "brewery_member"}`, HS256 with the secret. Show a copy-pasteable Elixir/JOSE snippet **and** mention jwt.io.
  5. Authenticated request — `POST /check_ins` with `Authorization: Bearer …` → `201`; anon still `401`. Show reading claims from SQL via a computed column or RPC (`current_setting('request.jwt.claims', true)`).
  6. Optional guard — a `db_pre_request` function (e.g. `api.check_token()` that blocks a banned drinker with `raise insufficient_privilege`), wired via `db_pre_request: "api.check_token"` / `PGRST_DB_PRE_REQUEST`. This is the PostgREST `check_token` pattern.
  7. Notes — token `exp`, `jwt_role_claim_key`, `jwt_aud`; link `[Configuration](../guides/configuration.md)`.

- [ ] **Step 2: Verify** the token/POST flow end-to-end against a booted `api` instance (build after PR 1 is merged); quote the real 201/401 responses.

- [ ] **Step 3: Commit** — `docs(tutorial): authentication ...`.

---

## Task 4: API reference guide

**Files:** Create `docs/guides/api-reference.md`

**Authoritative sources to mine (do not invent syntax):** `spec/*.yaml` (filters, select, ordering, pagination, mutations, rpc, content_negotiation), `lib/bier/query_executor.ex` (operator→SQL table, ~lines 812-940), `lib/bier/preferences.ex` (recognized Prefer keys), `lib/bier/plugs/fallback_controller.ex` (PGRST codes). Use brewery examples everywhere.

- [ ] **Step 1: Write the page** covering, each with syntax + a brewery example:
  - Reading & vertical filtering: `select`, alias `beer:name`, cast `abv::text`, JSON paths, computed columns, aggregates (`select=count()`, `abv.avg()`; note `db-aggregates-enabled`).
  - Horizontal filtering: operator table — `eq neq gt gte lt lte like ilike match imatch in is isdistinct fts plfts phfts wfts cs cd ov sl sr nxr nxl adj`; negation `not.`; quantifiers `(any)`/`(all)`; logical `and`/`or` trees + nesting; JSON arrow `->`/`->>` filters; filters on embedded resources.
  - Ordering: `asc`/`desc`, `nullsfirst`/`nullslast`, multi-column, embedded, JSON path, to-one related column.
  - Pagination: `limit`/`offset`, `Range`/`Range-Unit`, `Prefer: count=none|exact|planned|estimated`, `Content-Range`, statuses 200/206/416 (PGRST103).
  - Resource embedding: M2O/O2M/M2M, alias, `!inner`/`!left`, disambiguation (`!fk`, FK column), spread `...brewery(name)`, embedded filters/order; errors PGRST200/201/108.
  - Mutations: POST/PATCH/PUT/DELETE; `Prefer: return=representation|headers-only|minimal`, `resolution=merge-duplicates|ignore-duplicates`, `missing=default`, `handling=strict`+`max-affected`; `?columns=`, `?on_conflict=`; `Location` (headers-only); statuses.
  - RPC: `/rpc/<fn>` GET (query args) vs POST (JSON body args); variadic; return shapes (scalar/array/object/void→204); shaping with `select`/filters/`limit`/`count`/`Accept: text/csv`.
  - Content negotiation: `application/json` (default), `text/csv`, `application/geo+json`, `application/vnd.pgrst.object+json` (+`;nulls=stripped`), plan; 406 (PGRST107) behavior.
  - Errors: envelope `{code, message, details, hint}` + `Proxy-Status` header; table of common PGRST codes.

- [ ] **Step 2: Verify build** (after Task 7 wiring) — `mix docs --warnings-as-errors`.

- [ ] **Step 3: Commit** — `docs(guide): API reference`.

---

## Task 5: Configuration reference guide

**Files:** Create `docs/guides/configuration.md`

**Sources:** `lib/bier.ex` `schema/0` (option names/types/defaults), `lib/bier/cli/config.ex` (`PGRST_*` names + `PGRST_DB_URI` parsing + precedence), `lib/bier/config.ex` (cross-field validators), `README.md` (standalone/Docker/release).

- [ ] **Step 1: Write the page** covering:
  - Three config surfaces: `Bier.start_link/1` keyword opts; app env (`config :bier, key: value`); `PGRST_*` env vars (precedence flags > env > file > default).
  - Full option table: name, type, default, `PGRST_*` var — generated from `schema/0` + the CLI spec. Include every option (connection, pool, server, `db_schemas`, `db_anon_role`, `jwt_*`, `server_timing_enabled`, `server_trace_header`, `admin_server_port`, `openapi_*`, `app_settings`, etc.).
  - `PGRST_DB_URI` (URI + libpq conninfo; `sslmode`).
  - Standalone boot: release (`MIX_ENV=prod mix release`, `BIER_STANDALONE=1`), Docker, the `bier` CLI (`--dump-config`, `-e/--example`, config file, `-v`, `-h`).
  - Validators (jwt-secret ≥ 32 bytes; `admin-server-port` ≠ `server-port`; socket mode 600-777; proxy-uri absolute; base64 secret; role-claim-key parse).
  - Schema-cache reload: `db_channel` + `NOTIFY <channel>, 'reload schema'`, `db_channel_enabled`, `Bier.reload_schema_cache/1`.

- [ ] **Step 2: Verify** the option table against `./bier --dump-config` / `--example` output (build the escript: `mix escript.build`).

- [ ] **Step 3: Commit** — `docs(guide): configuration reference`.

---

## Task 6: Observability reference guide

**Files:** Create `docs/guides/observability.md`

**Sources/facts (verified):**
- Telemetry events: `[:bier, :request, :start]` (meas `system_time`,`monotonic_time`; meta `instance`,`method`,`route`); `[:bier, :request, :stop]` (meas `duration`,`monotonic_time`; meta `instance`,`method`,`route`,`status`,`schema`,`relation`); `[:bier, :schema_cache, :load, :start|:stop|:exception]` (span; `relation_count` on stop); `[:bier, :pool, :status]` (meas `max`,`available`,`waiting`; meta `instance`); `[:bier, :pool, :checkout_timeout]` (meas `count`; meta `instance`).
- Server-Timing: `server_timing_enabled` (default false); phases `jwt, parse, plan, transaction, response`; header `jwt;dur=0.512, parse;dur=0.037, ...` (3 decimals); OPTIONS reports only `jwt, parse, response`.
- Health: `admin_server_port` (default nil; must differ from server port); `GET /live` → 200; `GET /ready` → 200/503 (`Bier.Health.ready?/1` = schema cache loaded AND `SELECT 1` ok); pool monitor samples `DBConnection.get_connection_metrics/1` every 5000 ms.
- Trace header: `server_trace_header` echoes the named request header onto the response.
- Errors: `Bier.ErrorLogger` logs PGRST001 (DB client error) / PGRST002 (schema cache) at `:error` with metadata `bier_instance`, `bier_error_code`; envelope `{code, message, details, hint}` + `Proxy-Status: PostgREST; error=<code>`.

- [ ] **Step 1: Write the page** with sections: Telemetry events (table + `:telemetry.attach/4` example), Server-Timing, Health/readiness (admin server), Pool monitoring, Trace header, Error logging & envelope.

- [ ] **Step 2: Verify build** (after Task 7) — `mix docs --warnings-as-errors`.

- [ ] **Step 3: Commit** — `docs(guide): observability reference`.

---

## Task 7: Wire ex_doc extras + README section + build gate

**Files:** Modify `mix.exs` (`docs/0`), `README.md`

- [ ] **Step 1: Update `mix.exs` `docs/0`** `extras` and add `groups_for_extras`:

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

(Keep `main: "readme"`, `source_ref`, `skip_*`, `before_closing_head_tag`. `brewery.sql` is NOT an extra — it's referenced by path from the tutorials.)

- [ ] **Step 2: Add a "Documentation" section to `README.md`** (after "Usage" or near the top) linking the two tutorials and three guides.

- [ ] **Step 3: Build gate** — Run `mix docs --warnings-as-errors`. Expected: builds clean, with `Tutorials` and `Reference` groups in the sidebar containing the five pages. Fix any autolink/undefined-reference warnings via `skip_*` config.

- [ ] **Step 4: Format + commit** — `mix format`, then:
```bash
git add mix.exs README.md
git commit -m "docs: wire tutorials and reference guides into ex_doc extras

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage:** brewery DB (Task 1) ✓; getting-started (Task 2) ✓; authentication (Task 3) ✓; api-reference (Task 4) ✓; configuration (Task 5) ✓; observability (Task 6) ✓; `mix.exs` wiring + README + groups_for_extras (Task 7) ✓.
- **Placeholders:** SQL is complete/runnable; doc tasks give concrete section lists + verified facts + authoritative source files. Prose is written by the implementer against those (not pre-duplicated here).
- **Consistency:** `api` schema, `web_anon`/`brewery_member`/`authenticator` roles, and the five file paths are identical across Tasks 1-7 and the `mix.exs` wiring.
- **Dependency note:** Tasks 2-3 verification requires PR 1 merged (role-switching on `api`); Tasks 4-6 do not.
