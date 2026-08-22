# Design: extract the conformance suite into `postgrest-conformance`

**Date:** 2026-08-18
**Status:** approved design, pre-implementation
**Derived from:** discussion in-session; repo facts verified against `bier@main` (6024c62)

## Context and goals

Bier's `spec/` tree is a frozen, citation-backed record of PostgREST v16.0
behavior: 762 declarative HTTP request/response cases across 17 areas, a JSON
Schema for the case format, layered SQL fixtures, and area documentation. The
format is already language-agnostic — YAML cases assert HTTP status, headers,
and byte-exact bodies, with per-case provenance links to the exact PostgREST
test source line.

Goal: extract this into a standalone repository, **`postgrest-conformance`**,
so any PostgREST-compatible implementation (bier included) can consume it as a
conformance test suite. This follows the proven "declarative data + JSON
Schema + thin per-implementation harness" model of the
[JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite),
CommonMark's `spec.txt`, and the Web Platform Tests. No pre-existing open test
specification format fits (Gherkin cannot express byte-exact assertions; Hurl's
assertion language is too narrow; Postman assertions are JavaScript) — the
format itself, published and documented, is the deliverable.

Decisions already made:

- **Independent community project** under `github.com/milmazz`, not an upstream
  PostgREST artifact (upstream blessing is a later possibility, made easier by
  a working artifact).
- **Data-only v1**: no supported runner. Consumers write a thin harness.
- **Bier consumes via a git submodule** at `spec/`, pinned to tagged releases.
- **Clean history**: the new repo starts fresh with a
  `Derived from: milmazz/bier@<sha>` note; per-case provenance is already
  carried by each case's upstream `source:` citation.

## Non-goals (v1)

- A supported, product-quality runner (internal CI tooling is fine).
- Re-syncing to a PostgREST version newer than the current v16.0 pin.
- Changing any case expectation — extraction is behavior-preserving.
- Upstream (PostgREST org) adoption.

## Repo identity

- **Name:** `postgrest-conformance`, under `github.com/milmazz` (transferable
  to an org later).
- **License:** MIT, with an attribution note: cases are derived from
  PostgREST's own MIT-licensed test suite. The attribution doubles as the
  contribute-back story.
- **README** states the model explicitly: language-agnostic conformance suite
  in the JSON Schema Test Suite style; consumers implement a thin harness per
  `HARNESS.md`; the suite records only what PostgREST does — implementation
  divergences live in each consumer's own skip list.

## Layout

```
postgrest-conformance/
├── README.md            # model, derived-from note, implementer quick start
├── HARNESS.md           # the consumer contract (see below)
├── LICENSE              # MIT + PostgREST attribution
├── PIN                  # exact upstream version + commit (v16.0)
├── CHANGELOG.md
├── case.schema.json
├── cases/               # 762 case YAMLs (format unchanged)
├── spec/                # 17 area docs (auth.yaml … select.yaml) + url_grammar.md
├── fixtures/
│   ├── 01_roles.sql             # postgrest_test_* role creation (idempotent)
│   ├── 02_base.sql              # today's fixtures.sql (authoritative DDL+seeds)
│   ├── 03_supplement.sql        # today's fixtures_local.sql
│   ├── 04_postgis.sql           # PostGIS-dependent fixtures (conditional; see HARNESS.md)
│   ├── 05_corrections.sql       # seed corrections (complex_items), now explicit SQL
│   ├── 06_area_schemas.sql      # GENERATED: materialized area-schema build (see below)
│   ├── 07_analyze.sql           # ANALYZE
│   ├── provenance/              # delta write-channel + frozen 2026-06 fragments
│   └── README.md                # load order + ownership/layering rules
├── tools/                       # internal maintenance only, not a consumer API
│   ├── regen_area_schemas.*     # regenerates 06_area_schemas.sql from 01–05
│   └── validate.*               # schema-validate cases, lint ids/citations/INDEX
├── COVERAGE.md
├── INDEX.md
└── .github/workflows/validate.yml
```

The `<area>.delta.sql` write-channel files and the frozen 2026-06 provenance
fragments under bier's `spec/conformance/fixtures/` move as-is into a
`fixtures/provenance/` subdirectory with their existing README semantics
(deltas are the write channel for spec-research workflows; historical fragments
are non-authoritative). `rpc.sql`/`headers.sql` — currently live loader inputs —
become inputs to the generator tool only (see next section).

## Fixture build materialization (design amendment, verified against the loader)

`mix bier.fixtures.load` is not "load SQL files": it is an 11-step environment
builder (`lib/mix/tasks/bier.fixtures.load.ex`), and several steps generate DDL
dynamically:

1. Ensure `postgrest_test_*` roles; drop/recreate the database.
2. Load `fixtures.sql`, then `fixtures_local.sql`, then PostGIS fixtures.
3. **Seed corrections** (Elixir-embedded SQL): `test.complex_items."field-with_sep" = id`
   and `arr_data = ARRAY(generate_series(1, id))`.
4. **Dynamic area-schema mirroring** into 7 schemas (`operators`, `ordering`,
   `pagination`, `representations`, `mutations`, `config`,
   `domain_representations`): introspects `pg_catalog` for every `test`
   relation and creates auto-updatable views; generates thin wrapper functions
   for single-composite-argument computed-column functions and for
   SETOF-returning RPC functions, retyped against the area's relations.
5. **Isolation rewrites**: in `representations` and `mutations`, replaces the
   mutable relations' views with independent real tables (copied data, own
   PK/FK/sequences) so destructive writes cannot corrupt the shared `test`
   tables read concurrently by other areas.
6. **Text-remapping loaders**: `rpc.sql` is re-loaded with `\btest\b → rpc`
   remapping; `headers.sql` is split on a marker line and remapped to build the
   multi-schema `v1`/`v2`/`SPECIAL` routing environment; an `auth` schema
   builder runs its own DDL.
7. `ANALYZE`.

A consumer cannot be asked to reimplement steps 3–6, and shipping the Elixir
loader contradicts language-agnosticism. **Resolution: materialize.** The
dynamic output of steps 3–6 is deterministic given the static inputs, so it is
flattened into checked-in generated SQL (`06_area_schemas.sql`, plus
`05_corrections.sql` for step 3) by an internal generator in `tools/`. The
generator may be written in any convenient language (it is maintenance tooling,
like the JSON Schema Test Suite's `bin/` scripts); CI regenerates and fails on
diff, so the checked-in SQL can never drift from its inputs. The consumer
story becomes: **run `fixtures/01…07` in order with
`psql -v ON_ERROR_STOP=1`** — nothing else.

PostGIS remains an optional layer: `HARNESS.md` documents which cases require
it and how a consumer skips them when the extension is unavailable (mirroring
bier's current conditional behavior).

## `preconditions:` resolution

43 of 762 cases carry non-empty `preconditions:`; bier's harness parses and
**never executes** them. No parsed-but-ignored field ships in v1. During
extraction each non-empty occurrence is audited: if its intent is already
satisfied by the fixture chain (the known pattern — e.g. representations'
mutable relations being loader-built real tables), the field is emptied; if a
case genuinely depends on unexecuted setup, the setup moves into the fixture
chain or a per-case documented mechanism. If the audit empties all 43, the
field is removed from `case.schema.json` entirely.

## HARNESS.md — the consumer contract

The document that makes the repo usable by a stranger; a formalization of what
bier's `docs/CONFORMANCE_IMPL.md` + `test/support/` harness encode today:

- **Server configuration** the suite assumes: exposed schemas and the default
  schema, JWT secret value and HS256 signing of the tokens cases use, prefer
  defaults, no response compression and always-present `Content-Length`.
- **Database build**: the numbered fixture load order, required roles,
  PostGIS-optional layer, target PostgreSQL versions.
- **Assertion semantics**: what `body_exact` means byte-for-byte (including
  PostgREST's `json_agg` `, \n ` separators and jsonb embed key ordering),
  header equality vs. absence rules, status assertions.
- **Case format**: field-by-field walk of `case.schema.json`, area tags, the
  `source:` citation convention.
- **Divergence convention**: consumers keep their own skip/divergence list;
  the suite never records implementation divergences.

## Versioning

Tags: **`v16.0.0-suite.N`** — PostgREST pin + suite revision. Pin bumps come
from re-sync passes; correction-only releases bump `suite.N`. The `PIN` file
records the exact upstream version and commit. The `bier-spec` /
`bier-spec-audit` workflows (`.claude/workflows/`) move to this repo, since
they edit spec content; their human-gated authorization rules move with them.

## CI (`validate.yml`)

- **v1:** schema-validate every case against `case.schema.json`; lint unique
  ids, well-formed `source:` citations, INDEX/COVERAGE consistency; load the
  full fixture chain into real PostgreSQL to prove the SQL is valid; verify
  `06_area_schemas.sql` is freshly regenerable (no drift).
- **Phase 2 (credibility centerpiece, not a v1 blocker):** an internal job
  boots real PostgREST v16.0 in Docker and executes every case against it via
  a small throwaway runner, so the README can claim every case is
  machine-verified against PostgREST itself. Internal tooling only; the
  data-only promise to consumers stands.

## Bier migration

1. Create and populate `postgrest-conformance` from bier's current `spec/`,
   restructured per the layout above, with the materialized fixture chain;
   tag `v16.0.0-suite.1`.
2. In bier: delete `spec/`, add the submodule at `spec/` (test-generator path
   churn stays minimal); reduce `bier.fixtures.load` to a dumb executor of the
   numbered SQL files (dynamic build logic and embedded SQL deleted — it moved
   upstream as generated SQL); add `submodules: true` to CI checkout; update
   CLAUDE.md's freeze language ("`spec/` is a pinned submodule; changes happen
   in postgrest-conformance"); relocate the `bier-spec`/`bier-spec-audit`
   workflows.
3. **Exit criterion:** full `mix precommit` green against the submodule pin
   with zero behavior change — same 758 passing cases, same 4 exclusions,
   `@divergences` and its compile-time guard untouched.

## Risks and mitigations

- **Materialized SQL diverges from what bier's loader produced** → the
  migration's exit criterion is a byte-identical conformance outcome; the
  generator is validated by diffing a `pg_dump` of the old loader's database
  against the new chain's before bier's loader logic is deleted.
- **Submodule ergonomics annoy contributors** → fallback documented: a fetch
  task that vendors a release tarball into a gitignored `spec/`. Decision
  deferred until friction is real.
- **`fixtures_local.sql` naming confusion** ("local" no longer means anything
  in a shared repo) → renamed to `03_supplement.sql`; its human-owned,
  reviewed-commits-only rule becomes normal PR review in the new repo.
