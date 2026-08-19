# postgrest-conformance Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract bier's `spec/` tree into a standalone `postgrest-conformance` repo (data-only, language-agnostic suite with a materialized fixture chain), then migrate bier to consume it as a git submodule with zero conformance behavior change.

**Architecture:** Phase A builds the new repo at `~/Dev/elixir-lang/postgrest-conformance`: static content copies over, the dynamic parts of bier's fixture loader are ported to a standalone Elixir script that generates a checked-in `06_area_schemas.sql`, and a pg_dump equivalence gate proves the numbered chain reproduces the loader's database byte-for-byte. Phase B swaps bier's `spec/` for a submodule and reduces `bier.fixtures.load` to a dumb psql executor.

**Tech Stack:** git, psql/pg_dump (PostgreSQL 16 + PostGIS), Elixir (`Mix.install` script for the generator), Python 3 + `jsonschema`+`pyyaml` (validation tooling), GitHub Actions.

**Spec:** `docs/superpowers/plans/../specs/2026-08-18-postgrest-conformance-extraction-design.md` (same branch). Read it first; this plan argues from it.

## Global Constraints

- **Zero behavior change** in bier: exit gate is `mix precommit` green with the same 758 passing / 4 excluded conformance cases and `@divergences` untouched.
- **Case expectations are frozen**: no task may change any case's `request`/`expect`/`source` content. The only permitted case edit is the mechanical `preconditions:` retirement (Task 5).
- New repo lives at `/Users/milmazz/Dev/elixir-lang/postgrest-conformance`; bier work happens in the existing worktree `/Users/milmazz/Dev/elixir-lang/bier/.claude/worktrees/postgrest-conformance-spec` (bier Phase B commits go on branch `refactor/spec-submodule` created from `docs/postgrest-conformance-spec`).
- **Never touch the shared main checkout** (`~/Dev/elixir-lang/bier`) — another agent is working there. Verify `git branch --show-current` before every commit.
- **Shared Postgres**: the conformance harness hardcodes database `bier_test`. All scratch work uses `bier_conf_a` / `bier_conf_b` / `bier_conf_c` via `PGDATABASE`. Any task that must touch `bier_test` (Task 14 only) requires confirming with the user that no other session is mid-test.
- Databases are created with `TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C'` and loaded with `PGTZ=UTC` — both are load-bearing (case 1606 collation; timestamptz seeds).
- Outward-facing actions (creating the GitHub repo, pushing, opening a bier PR) require explicit user confirmation at the task where they occur.
- New-repo commit messages use conventional commits; end every commit with the `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` trailer.
- Derivation base: `milmazz/bier@6024c62`. Source paths below are relative to the bier worktree unless absolute.

---

## Phase A — build the `postgrest-conformance` repo

### Task 1: Scaffold repo and copy static content

**Files:**
- Create: `/Users/milmazz/Dev/elixir-lang/postgrest-conformance/` — `README.md`, `LICENSE`, `PIN`, `CHANGELOG.md`, `.gitignore`, `case.schema.json`, `cases/` (762 files), `spec/` (17 area yaml + `url_grammar.md`), `COVERAGE.md`, `INDEX.md`

**Interfaces:**
- Produces: repo root `$NEW=/Users/milmazz/Dev/elixir-lang/postgrest-conformance` used by every later task; `cases/*.yaml` at repo root (no `spec/conformance/` nesting); area docs under `spec/`.

- [ ] **Step 1: Init repo and copy content** (`$BIER` = the bier worktree path)

```bash
NEW=/Users/milmazz/Dev/elixir-lang/postgrest-conformance
BIER=/Users/milmazz/Dev/elixir-lang/bier/.claude/worktrees/postgrest-conformance-spec
git init "$NEW" && cd "$NEW"
mkdir -p cases spec fixtures tools
cp "$BIER"/spec/conformance/cases/*.yaml cases/
cp "$BIER"/spec/*.yaml "$BIER"/spec/url_grammar.md spec/
cp "$BIER"/spec/conformance/case.schema.json .
cp "$BIER"/spec/COVERAGE.md COVERAGE.md
cp "$BIER"/spec/conformance/INDEX.md INDEX.md
printf 'postgrest: v16.0\ncommit: %s\n' "$(grep -oE 'v16\.0[^ ]*' "$BIER"/spec/COVERAGE.md | head -1)" > PIN
```
Then write `PIN` properly by hand: two lines, `postgrest: v16.0` and the upstream commit for the v16.0 tag (`git ls-remote https://github.com/PostgREST/postgrest.git refs/tags/v16.0`).

- [ ] **Step 2: Write LICENSE, README, CHANGELOG, .gitignore**

`LICENSE`: MIT, copyright `2026 Milton Mazzarri`, followed by a `## Attribution` section: "Conformance cases are derived from the test suite of PostgREST (https://github.com/PostgREST/postgrest), © PostgREST contributors, MIT License." `.gitignore`: `*.dump`, `scratch/`. `CHANGELOG.md`: one `## v16.0.0-suite.1 (unreleased)` entry. `README.md` sections (write full prose, ~80 lines): What this is (language-agnostic PostgREST conformance suite, JSON Schema Test Suite model); `Derived from: milmazz/bier@6024c62`; Repository layout table; Quick start for implementers (3 numbered steps: build the DB from `fixtures/01…07` with `psql -v ON_ERROR_STOP=1` under `PGTZ=UTC` into a `LC_COLLATE 'C'` database, configure your server per `HARNESS.md`, run each `cases/*.yaml` and assert per `HARNESS.md`); Versioning (`v16.0.0-suite.N`, `PIN` file); Divergences (consumers keep their own skip list; the suite records only what PostgREST does); License/attribution pointer.

- [ ] **Step 3: Verify counts and commit**

```bash
[ "$(ls cases | wc -l)" -eq 762 ] && [ "$(ls spec/*.yaml | wc -l)" -eq 17 ] && echo OK
git add -A && git commit -m "feat: scaffold suite from milmazz/bier@6024c62"
```

### Task 2: Static fixture chain (01–05, 07) and fixture docs

**Files:**
- Create: `fixtures/01_roles.sql`, `fixtures/02_base.sql`, `fixtures/03_supplement.sql`, `fixtures/04_postgis.sql`, `fixtures/05_corrections.sql`, `fixtures/07_analyze.sql`, `fixtures/inputs/rpc.sql`, `fixtures/inputs/headers.sql`, `fixtures/provenance/*`, `fixtures/README.md`

**Interfaces:**
- Consumes: bier loader source `lib/mix/tasks/bier.fixtures.load.ex` (roles L72–79; postgis SQL L146–189; corrections SQL L207–212).
- Produces: chain files 01–05 and 07 loadable in order; `fixtures/inputs/` holds the generator's live inputs (Task 3); load order contract: 01 against `postgres` DB, 02–07 against the target DB.

- [ ] **Step 1: Create the SQL files**

`01_roles.sql` — one idempotent DO block per role, exactly as the loader builds at L74–76, for `postgrest_test_anonymous`, `postgrest_test_default_role`, `postgrest_test_author`:

```sql
DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'postgrest_test_anonymous') THEN CREATE ROLE postgrest_test_anonymous; END IF; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'postgrest_test_default_role') THEN CREATE ROLE postgrest_test_default_role; END IF; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'postgrest_test_author') THEN CREATE ROLE postgrest_test_author; END IF; END $$;
```

`02_base.sql` = byte-copy of `$BIER/spec/conformance/fixtures.sql`. `03_supplement.sql` = byte-copy of `fixtures_local.sql`. `04_postgis.sql` = the exact heredoc SQL from loader L146–189 (CREATE EXTENSION postgis through the geotest grants), verbatim. `05_corrections.sql` = the exact SQL from L207–212 (the two `UPDATE test.complex_items` statements), verbatim, preceded by the loader's comment block L194–205 rewritten as SQL comments. `07_analyze.sql` = `ANALYZE;` plus a comment: planner-estimate cases (`count=planned`/`estimated`) assume analyzed tables.

- [ ] **Step 2: Copy provenance and generator inputs; write fixtures/README.md**

```bash
mkdir -p fixtures/provenance
cp "$BIER"/spec/conformance/fixtures/rpc.sql "$BIER"/spec/conformance/fixtures/headers.sql fixtures/inputs/
cp "$BIER"/spec/conformance/fixtures/*.sql fixtures/provenance/   # then remove rpc.sql/headers.sql duplicates from provenance/
rm fixtures/provenance/rpc.sql fixtures/provenance/headers.sql
```
`fixtures/README.md`: adapt `$BIER/spec/conformance/fixtures/README.md` — keep the ownership table (owners become "PR review"), replace the `mix bier.fixtures.load` framing with the numbered-chain contract: run 01 against the `postgres` maintenance DB, create the target DB with `TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C'`, then run 02→07 in order with `psql -v ON_ERROR_STOP=1 -q` and `PGTZ=UTC`. Document `inputs/` (live generator inputs, human-owned, invariants 3–4 from the old README apply verbatim) and `provenance/` (frozen, non-authoritative, includes the `<area>.delta.sql` write channel). State PostGIS is required for `04` and which cases need it (1616–1618 + geotest areas).

- [ ] **Step 3: Verify the static chain loads; commit**

```bash
psql -d postgres -v ON_ERROR_STOP=1 -q -f fixtures/01_roles.sql
psql -d postgres -c 'DROP DATABASE IF EXISTS bier_conf_b' \
  -c "CREATE DATABASE bier_conf_b TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C'"
for f in fixtures/02_base.sql fixtures/03_supplement.sql fixtures/04_postgis.sql fixtures/05_corrections.sql fixtures/07_analyze.sql; do
  PGTZ=UTC psql -d bier_conf_b -v ON_ERROR_STOP=1 -q -f "$f" || break
done
```
Expected: no errors. Commit: `feat: static fixture chain (roles, base, supplement, postgis, corrections)`.

### Task 3: Generator script and `06_area_schemas.sql`

**Files:**
- Create: `tools/regen_area_schemas.exs`, `fixtures/06_area_schemas.sql` (generated)

**Interfaces:**
- Consumes: `fixtures/01…05,07`, `fixtures/inputs/{rpc,headers}.sql`; bier loader source functions (verbatim ports).
- Produces: `tools/regen_area_schemas.exs` — run as `elixir tools/regen_area_schemas.exs` from the repo root; rebuilds a scratch DB from the chain, runs the dynamic build, writes `fixtures/06_area_schemas.sql` via pg_dump. Deterministic: same inputs + same PG version ⇒ identical output (CI freshness relies on this).

- [ ] **Step 1: Write `tools/regen_area_schemas.exs`**

Structure (write exactly this skeleton; the bodies marked *verbatim* are mechanical copies from `$BIER/lib/mix/tasks/bier.fixtures.load.ex` with only the listed substitutions):

```elixir
Mix.install([{:postgrex, "~> 0.19"}])

defmodule Regen do
  @scratch_db "postgrest_conf_regen"
  @mirror_schemas ~w(operators ordering pagination representations mutations config domain_representations)

  def run do
    cfg = db_config()
    psql = psql_bin()
    before = list_schemas(cfg)
    build_chain(psql, cfg)
    mirror_area_schemas(cfg)          # verbatim port
    load_rpc_schema(psql, cfg)        # verbatim port; fragment path "fixtures/inputs/rpc.sql"
    load_headers_schema(psql, cfg)    # verbatim port; fragment path "fixtures/inputs/headers.sql"
    load_auth_schema(psql, cfg)       # verbatim port
    dump_new_schemas(cfg, before)
  end
  # ... helpers below
end

Regen.run()
```

Port rules — copy these functions from the loader **verbatim**, then apply only these edits: `Mix.raise(msg)` → `raise(msg)`; `Path.expand("spec/conformance/fixtures/rpc.sql", File.cwd!())` → `"fixtures/inputs/rpc.sql"` (same for headers.sql); `cfg[:database]` resolves to `@scratch_db` (override in `db_config/0`). Functions to port with their bier line ranges: `mirror_area_schemas/1` (L384–464), `isolate_representations/1` (L476–557), `isolate_mutations/1` (L558–600), `query_computed_member_fns/1` (L601–627), `query_setof_relation_fns/1` (L628–667), `mirror_setof_fn_ddl/2` (L668–686), `load_rpc_schema/2` (L232–255), `load_headers_schema/2` (L276–312), `load_auth_schema/2` (L329–382), `db_config/0` (L687–695, with `database:` forced to `@scratch_db`), `base_args/2`, `psql_env/2`, `run_psql!/4`, `psql_bin/0` (L697–728).

New helpers (write fully):

```elixir
defp build_chain(psql, cfg) do
  run_psql!(psql, cfg, "postgres", File.read!("fixtures/01_roles.sql"))
  run_psql!(psql, cfg, "postgres", ~s(DROP DATABASE IF EXISTS "#{@scratch_db}";))
  run_psql!(psql, cfg, "postgres",
    ~s(CREATE DATABASE "#{@scratch_db}" TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C';))
  for f <- ~w(02_base.sql 03_supplement.sql 04_postgis.sql 05_corrections.sql) do
    {out, status} = System.cmd(psql,
      base_args(cfg, @scratch_db) ++ ["-v", "ON_ERROR_STOP=1", "-q", "-f", "fixtures/#{f}"],
      env: psql_env(cfg), stderr_to_stdout: true)
    if status != 0, do: raise("psql failed on #{f} (exit #{status}):\n#{out}")
  end
end

defp list_schemas(cfg) do
  # connect with Postgrex to @scratch_db's server but database "postgres"?  No —
  # BEFORE list must come from the freshly built chain DB *before* dynamic steps.
  # Simplest correct order: call this right after build_chain/2 instead of before it.
  {:ok, conn} = Postgrex.start_link(hostname: cfg[:hostname], port: cfg[:port],
    database: @scratch_db, username: cfg[:username], password: cfg[:password])
  %{rows: rows} = Postgrex.query!(conn,
    "SELECT nspname FROM pg_namespace WHERE nspname NOT LIKE 'pg_%' AND nspname <> 'information_schema'", [])
  GenServer.stop(conn)
  Enum.map(rows, fn [n] -> n end) |> MapSet.new()
end

defp dump_new_schemas(cfg, before) do
  after_ = list_schemas(cfg)
  new = MapSet.difference(after_, before) |> Enum.sort()
  args = Enum.flat_map(new, &["-n", &1]) ++ ["--no-owner", "-d", @scratch_db,
    "-h", to_string(cfg[:hostname]), "-p", to_string(cfg[:port])] ++
    (if cfg[:username], do: ["-U", to_string(cfg[:username])], else: [])
  {dump, 0} = System.cmd("pg_dump", args, env: psql_env(cfg))
  header = "-- GENERATED by tools/regen_area_schemas.exs — do not edit.\n" <>
           "-- Regenerate: elixir tools/regen_area_schemas.exs (from repo root)\n" <>
           "-- Schemas: #{Enum.join(new, ", ")}\n"
  clean = dump |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, "-- Dumped"))
    |> Enum.join("\n")
  File.write!("fixtures/06_area_schemas.sql", header <> clean)
  IO.puts("Wrote fixtures/06_area_schemas.sql (#{length(new)} schemas)")
end
```

Adjust `run/0` to the corrected order: `build_chain` → `before = list_schemas` → dynamic steps → `dump_new_schemas`. Expected new schemas: the 7 mirrors + `rpc`, `headers`, `headers_private`, `auth` (11 total; the script computes rather than assumes).

- [ ] **Step 2: Run the generator**

```bash
cd /Users/milmazz/Dev/elixir-lang/postgrest-conformance && elixir tools/regen_area_schemas.exs
```
Expected: `Wrote fixtures/06_area_schemas.sql (11 schemas)`.

- [ ] **Step 3: Verify the full chain loads standalone**

Rebuild `bier_conf_b` from scratch running 01→07 **including 06** (same commands as Task 2 Step 3, adding `06_area_schemas.sql` before `07_analyze.sql`). Expected: no errors. Determinism check: run the generator a second time; `git diff --stat fixtures/06_area_schemas.sql` must be empty.

- [ ] **Step 4: Commit**

`feat: port dynamic fixture build as generator; materialize 06_area_schemas.sql`

### Task 4: Equivalence gate — chain DB ≡ bier-loader DB

**Files:**
- Create: `tools/verify_equivalence.sh`

**Interfaces:**
- Consumes: bier worktree (`mix bier.fixtures.load` honors `PGDATABASE`, see loader `db_config/0` L687); the full chain 01–07.
- Produces: an empty-diff proof required before Phase B may delete bier's loader logic.

- [ ] **Step 1: Write `tools/verify_equivalence.sh`**

```bash
#!/usr/bin/env bash
# Proves fixtures/01..07 reproduce bier's loader-built database byte-for-byte.
# Usage: BIER=/path/to/bier/checkout tools/verify_equivalence.sh
set -euo pipefail
BIER="${BIER:?set BIER to a bier checkout}"
A=bier_conf_a B=bier_conf_b
( cd "$BIER" && PGDATABASE=$A mix bier.fixtures.load )
psql -d postgres -v ON_ERROR_STOP=1 -q -f fixtures/01_roles.sql
psql -d postgres -q -c "DROP DATABASE IF EXISTS $B" \
  -c "CREATE DATABASE $B TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C'"
for f in fixtures/0[2-7]_*.sql; do PGTZ=UTC psql -d "$B" -v ON_ERROR_STOP=1 -q -f "$f"; done
mkdir -p scratch
for db in $A $B; do
  pg_dump --no-owner -d "$db" | grep -v '^-- Dumped' > "scratch/$db.dump"
done
diff -u scratch/$A.dump scratch/$B.dump && echo "EQUIVALENT"
```

- [ ] **Step 2: Run it**

```bash
chmod +x tools/verify_equivalence.sh
BIER=/Users/milmazz/Dev/elixir-lang/bier/.claude/worktrees/postgrest-conformance-spec tools/verify_equivalence.sh
```
Expected: `EQUIVALENT`. If the diff is non-empty, fix the chain/generator (NOT the loader) until empty — every hunk is a fidelity bug in Tasks 2–3. Common suspects: missing grants, `setval` sequence states in the isolated tables, geotest objects landing in the wrong file.

- [ ] **Step 3: Clean up scratch DBs and commit**

```bash
psql -d postgres -q -c 'DROP DATABASE IF EXISTS bier_conf_a' -c 'DROP DATABASE IF EXISTS bier_conf_b' \
  -c 'DROP DATABASE IF EXISTS postgrest_conf_regen'
git add tools/verify_equivalence.sh && git commit -m "test: pg_dump equivalence gate vs bier loader"
```

### Task 5: Retire `preconditions:` from the case format

**Files:**
- Modify: `cases/*.yaml` (all 762), `case.schema.json`; check `INDEX.md`, `README.md`, `spec/*.yaml` for mentions

**Interfaces:**
- Produces: no case file and no schema mention of `preconditions`; prior non-empty values preserved under `notes` as `Assumes: …`.

Background (audited 2026-08-18): 43 cases carry non-empty `preconditions` — state-reset SQL (`DELETE`/`INSERT` on `test.items`, `test.tiobe_pls`; `ANALYZE test.child_entities`) and prose requirements (`Requires db-plan-enabled = true`, postgis, pg-safeupdate). Bier parses and never executes them; the suite is green, so each is already satisfied by the fixture chain (07 covers ANALYZE) or by the documented server config (HARNESS.md, Task 6). They are documentation, so they fold into `notes`.

- [ ] **Step 1: Write and run the migration script** (throwaway, run from repo root)

```python
# tools/scratch_retire_preconditions.py  (delete after running)
import glob, re, yaml
for path in sorted(glob.glob("cases/*.yaml")):
    doc = yaml.safe_load(open(path))
    pre = doc.pop("preconditions", None)
    text = open(path).read()
    if pre:  # fold into notes, then strip the block
        assume = " Assumes: " + " ".join(str(p).strip() for p in pre)
        doc["notes"] = (doc.get("notes") or "").rstrip() + assume
        text = re.sub(r"(?ms)^preconditions:.*?(?=^[a-z_]+:)", "", text)
        text = re.sub(r"(?ms)^(notes: .*?)$", lambda m: yaml.dump({"notes": doc["notes"]},
                      default_flow_style=False, allow_unicode=True, width=10**6).rstrip(), text, count=1)
    else:
        text = re.sub(r"(?m)^preconditions: \[\]\n", "", text)
    open(path, "w").write(text)
```
CAUTION: the regex edit preserves untouched formatting of every other key (a full yaml round-trip would reformat frozen content — do not do that). After running, spot-check case 1021 (unicode INSERT precondition) and 1272 (ANALYZE) by eye, and diff a no-preconditions case (1000) to confirm only the one line vanished.

- [ ] **Step 2: Update `case.schema.json`** — remove the `preconditions` property (and from `required` if listed). Grep `INDEX.md README.md spec/ fixtures/README.md` for `precondition` and update prose (the old harness note "preconditions are not executed" becomes: state assumptions live in `notes` and are satisfied by the fixture chain / HARNESS.md config).

- [ ] **Step 3: Verify and commit**

```bash
grep -rl "preconditions" cases/ case.schema.json && echo FAIL || echo OK
python3 -c "
import glob,json,yaml,jsonschema
s=json.load(open('case.schema.json'))
[jsonschema.validate(yaml.safe_load(open(f)),s) for f in glob.glob('cases/*.yaml')]
print('762 valid')"
rm tools/scratch_retire_preconditions.py
git add -A && git commit -m "refactor!: retire preconditions field; fold content into notes"
```

### Task 6: HARNESS.md — the consumer contract

**Files:**
- Create: `HARNESS.md`
- Source: `$BIER/test/support/conformance_server.ex` (all of it), `$BIER/test/support/conformance_assertions.ex`, `$BIER/test/support/http_case.ex`, `$BIER/docs/CONFORMANCE_IMPL.md`

**Interfaces:**
- Produces: the complete implementer contract; README links to it.

- [ ] **Step 1: Write HARNESS.md** with these sections, sourcing exact values from the files above (do not paraphrase config values — copy them):
  1. **Database build**: numbered chain contract (as fixtures/README.md), PostgreSQL/PostGIS requirement, collation/PGTZ pins and why (case 1606; timestamptz seeds).
  2. **Server configuration**: the shared instance's full option set from `ConformanceServer.base_opts/0` (db_schemas list, `database: bier_test` becomes "your test DB", pool size, prefer defaults, `db_profile_default`), auth options from `auth_opts` (`jwt_secret: "reallyreallyreallyreallyverysafe"`, anon role, pre-request), and the **per-case variant instances** table (at minimum 1654 → `db_schemas: ["openapi_no_comment"]`, 1764 → no jwt_secret, the asymmetric-JWK case per L112–145 — enumerate every `variant_extra_opts` clause and the header-derived config mapping at L143).
  3. **Request execution**: how a case's `request` maps to HTTP (method, path used raw, headers as given), JWT guidance: tokens are HS256-signed with the secret above; document how case tokens embed claims (read 2–3 auth cases and describe concretely).
  4. **Assertion semantics**: `status`; header rules (equality, which headers must be absent when unlisted — copy the actual rules from `conformance_assertions.ex`, including Content-Length presence); body modes (`body_exact` byte profile: PostgREST `json_agg` `,\n ` separators, jsonb embed internal ordering; any other body assertion keys the schema defines — enumerate from `case.schema.json`).
  5. **Response compression**: never compress; always emit `Content-Length` (PostgREST behavior; bier boots Bandit with `compress: false`).
  6. **Divergence convention**: consumers keep a skip list with reasons; the suite never records implementation divergences; bier's `@divergences` cited as the reference pattern.
  7. **Areas**: the 17 `area` tag values and their case-id ranges (derive from INDEX.md).

- [ ] **Step 2: Self-check** — for each of the 7 sections, confirm a stranger could act on it without reading bier source; fix gaps. Commit: `docs: HARNESS.md consumer contract`.

### Task 7: Validation tooling

**Files:**
- Create: `tools/validate.py`

**Interfaces:**
- Produces: `python3 tools/validate.py` exits 0 on a healthy tree; CI (Task 8) and future PRs run it.

- [ ] **Step 1: Write `tools/validate.py`** (stdlib + `pyyaml` + `jsonschema`):

```python
#!/usr/bin/env python3
"""Validate the suite tree: schema, ids, citations, index consistency."""
import glob, json, re, sys
import yaml, jsonschema

errors = []
schema = json.load(open("case.schema.json"))
seen = {}
for path in sorted(glob.glob("cases/*.yaml")):
    doc = yaml.safe_load(open(path))
    try:
        jsonschema.validate(doc, schema)
    except jsonschema.ValidationError as e:
        errors.append(f"{path}: schema: {e.message}"); continue
    cid = doc["id"]
    if cid in seen: errors.append(f"{path}: duplicate id {cid} (also {seen[cid]})")
    seen[cid] = path
    stem = re.match(r"(\d+)_", path.split("/")[-1])
    if not stem or int(stem.group(1)) != cid:
        errors.append(f"{path}: filename prefix != id {cid}")
    src = doc.get("source", "")
    if not re.match(r"^https://raw\.githubusercontent\.com/PostgREST/postgrest/v[\d.]+/", src):
        errors.append(f"{path}: malformed source citation: {src!r}")
indexed = set(int(m) for m in re.findall(r"\b(1\d{3})\b", open("INDEX.md").read()))
missing = set(seen) - indexed
if missing: errors.append(f"INDEX.md missing ids: {sorted(missing)[:10]}...({len(missing)})")
print(f"{len(seen)} cases checked")
if errors:
    print("\n".join(errors)); sys.exit(1)
print("OK")
```
Adjust the INDEX consistency check to INDEX.md's real structure after reading it (if INDEX lists ranges instead of ids, check area counts instead — keep the check honest, delete it only if INDEX has no machine-checkable claims).

- [ ] **Step 2: Run** — `python3 tools/validate.py` → `762 cases checked / OK`. Fix any findings (citation-format errors mean adjusting the *check* only if the format is legitimately different; never edit a case's source URL). Commit: `feat: tree validation tool`.

### Task 8: CI workflow

**Files:**
- Create: `.github/workflows/validate.yml`

- [ ] **Step 1: Write the workflow** — three jobs, all on `push`/`pull_request`:

```yaml
name: validate
on: [push, pull_request]
jobs:
  tree:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.12" }
      - run: pip install pyyaml jsonschema
      - run: python3 tools/validate.py
  fixtures:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgis/postgis:16-3.4
        env: { POSTGRES_PASSWORD: postgres }
        ports: ["5432:5432"]
        options: >-
          --health-cmd pg_isready --health-interval 5s --health-timeout 5s --health-retries 10
    env: { PGHOST: localhost, PGUSER: postgres, PGPASSWORD: postgres, PGTZ: UTC }
    steps:
      - uses: actions/checkout@v4
      - name: Load chain
        run: |
          psql -d postgres -v ON_ERROR_STOP=1 -q -f fixtures/01_roles.sql
          psql -d postgres -q -c "CREATE DATABASE conf TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C'"
          for f in fixtures/0[2-7]_*.sql; do psql -d conf -v ON_ERROR_STOP=1 -q -f "$f"; done
  freshness:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgis/postgis:16-3.4
        env: { POSTGRES_PASSWORD: postgres }
        ports: ["5432:5432"]
        options: >-
          --health-cmd pg_isready --health-interval 5s --health-timeout 5s --health-retries 10
    env: { PGHOST: localhost, PGUSER: postgres, PGPASSWORD: postgres }
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with: { elixir-version: "1.18", otp-version: "27" }
      - run: sudo apt-get update && sudo apt-get install -y postgresql-client-16
      - run: elixir tools/regen_area_schemas.exs
      - run: git diff --exit-code fixtures/06_area_schemas.sql
```
Note in a YAML comment why freshness pins the postgres image: `06` is pg_dump output, stable only per PG major version.

- [ ] **Step 2: Lint locally** (`python3 -c "import yaml; yaml.safe_load(open('.github/workflows/validate.yml'))"`) and commit: `ci: tree validation, fixture load, generator freshness`. CI proper runs after Task 10's push — Task 10 verifies all three jobs green.

### Task 9: Migrate the spec-maintenance workflows

**Files:**
- Create: `.claude/workflows/` in the new repo — copies of `$BIER/.claude/workflows/` bier-spec and bier-spec-audit scripts (check exact filenames with `ls`), plus any skill files they reference under `$BIER/.claude/`
- Create: `CONTRIBUTING.md`

- [ ] **Step 1: Copy the workflow files**, then sweep path references: `spec/conformance/cases` → `cases`, `spec/conformance/fixtures` → `fixtures/provenance` (deltas) or `fixtures/inputs`, `spec/` area docs stay `spec/`, `spec/conformance/case.schema.json` → `case.schema.json`. Do NOT rewrite their research/authorization prompts — only paths. Names may stay `bier-spec*` for continuity; add a header comment noting they now maintain this repo.
- [ ] **Step 2: Write `CONTRIBUTING.md`**: cases record PostgREST behavior only (cite `source`); expectation changes only via the re-sync workflows against a new `PIN`; fixture edits go through `provenance/<area>.delta.sql` folding or reviewed edits to `inputs/`/`03_supplement.sql`; regenerate `06` after any fixture change; run `tools/validate.py` before PRs.
- [ ] **Step 3: Commit**: `docs: contribution rules; migrate spec re-sync workflows`.

### Task 10: Publish and tag  ⚠️ outward-facing

- [ ] **Step 1: CONFIRM with the user** (do not proceed without an explicit yes in this session): creating public repo `milmazz/postgrest-conformance` and pushing.
- [ ] **Step 2: Create, push, tag**

```bash
cd /Users/milmazz/Dev/elixir-lang/postgrest-conformance
gh repo create milmazz/postgrest-conformance --public --source . --description "Language-agnostic PostgREST conformance suite" --push
git tag v16.0.0-suite.1 && git push origin v16.0.0-suite.1
```
- [ ] **Step 3: Verify CI** — `gh run watch` until all three jobs pass; fix and re-push if not (a red freshness job on first run likely means a PG-version mismatch between local generation and CI — regenerate `06` with a local PG16 matching the CI image, or pin the image to the local major version).

---

## Phase B — migrate bier (worktree, branch `refactor/spec-submodule`)

### Task 11: Swap `spec/` for the submodule

**Files:**
- Delete: `spec/` (entire tree)
- Create: `.gitmodules`, submodule at `spec/`
- Modify: `test/support/conformance_case.ex:38` (`@cases_dir`) — plus every hit of a repo-wide grep for `spec/conformance` and `spec/` path literals (known: `lib/mix/tasks/bier.fixtures.load.ex` L45/L122/L233/L277 — rewritten wholesale in Task 12; `docs/CONFORMANCE_IMPL.md` — Task 13). Harness-file edits here are pre-approved by this plan (operator-approved spec + plan); keep them mechanical (paths only).

**Interfaces:**
- Produces: submodule layout `spec/cases/*.yaml`, `spec/fixtures/0N_*.sql`, `spec/case.schema.json`, `spec/HARNESS.md`, pinned at tag `v16.0.0-suite.1`.

- [ ] **Step 1: Branch** — in the worktree: verify `git branch --show-current` = `docs/postgrest-conformance-spec`, then `git checkout -b refactor/spec-submodule`.
- [ ] **Step 2: Swap**

```bash
git rm -r spec && rm -rf spec
git submodule add https://github.com/milmazz/postgrest-conformance.git spec
cd spec && git checkout v16.0.0-suite.1 && cd ..
git add .gitmodules spec
```
- [ ] **Step 3: Repoint paths** — `conformance_case.ex:38`: `@cases_dir Path.expand("../../spec/cases", __DIR__)`. Then `grep -rn "spec/conformance" lib test docs .github mix.exs` and fix every remaining hit except the two files owned by Tasks 12–13. If `ConformanceCase` parses `preconditions`, delete that field handling (the format retired it).
- [ ] **Step 4: Verify compile** — `mix compile --warnings-as-errors` clean. Commit: `refactor: consume spec/ as postgrest-conformance submodule`.

### Task 12: Reduce `bier.fixtures.load` to a chain executor

**Files:**
- Rewrite: `lib/mix/tasks/bier.fixtures.load.ex`

**Interfaces:**
- Produces: same task name and env contract (`PG*` vars, `PGTZ=UTC`, DB recreate with pinned collation); body = run `spec/fixtures/01…07` in order. All dynamic-build code deleted (it lives upstream as generated SQL).

- [ ] **Step 1: Rewrite the task** — keep module name and `run/1` shape; new full body:

```elixir
defmodule Mix.Tasks.Bier.Fixtures.Load do
  @shortdoc "Drops/creates the test DB and loads the postgrest-conformance fixture chain"
  @moduledoc """
  Loads the conformance fixture database from the `spec/` submodule's numbered
  chain (see spec/fixtures/README.md). Idempotent. Connection parameters come
  from the standard `PG*` environment variables.
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    cfg = db_config()
    psql = psql_bin()
    files = Path.wildcard("spec/fixtures/0*_*.sql") |> Enum.sort()

    if files == [] do
      Mix.raise("spec/fixtures/ is empty — run: git submodule update --init")
    end

    [roles | rest] = files
    Mix.shell().info("Loading conformance chain into #{cfg[:database]}")
    run_psql!(psql, cfg, "postgres", ["-f", roles])
    run_psql!(psql, cfg, "postgres", ["-c", ~s(DROP DATABASE IF EXISTS "#{cfg[:database]}";)])
    run_psql!(psql, cfg, "postgres", ["-c",
      ~s(CREATE DATABASE "#{cfg[:database]}" TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C';)])
    Enum.each(rest, &run_psql!(psql, cfg, cfg[:database], ["-f", &1]))
    Mix.shell().info("Done.")
  end
  # keep db_config/0, psql_bin/0 verbatim from the old file; base_args/2 and
  # psql_env/1 verbatim; run_psql!/4 becomes:
  defp run_psql!(psql, cfg, database, extra) do
    args = base_args(cfg, database) ++ ["-v", "ON_ERROR_STOP=1", "-q"] ++ extra
    {out, status} = System.cmd(psql, args, env: psql_env(cfg), stderr_to_stdout: true)
    if status != 0, do: Mix.raise("psql failed (exit #{status}): #{inspect(extra)}\n#{out}")
    out
  end
end
```
(The `01_roles.sql` file sorts first by construction; the guard `[roles | rest]` relies on the chain's `0N_` numbering.)

- [ ] **Step 2: Verify against a scratch DB** — `PGDATABASE=bier_conf_c mix bier.fixtures.load` succeeds; then `psql -d bier_conf_c -c "\dn"` shows the 11 dynamic schemas + test/private/v1/v2/etc; then `psql -d postgres -c 'DROP DATABASE bier_conf_c'`.
- [ ] **Step 3: Commit** — `refactor: fixtures loader executes the submodule chain`.

### Task 13: Docs, CI, and workflow cleanup in bier

**Files:**
- Modify: `CLAUDE.md`, `docs/CONFORMANCE_IMPL.md`, `.github/workflows/elixir.yml`
- Delete: `.claude/workflows/` bier-spec + bier-spec-audit files (migrated in Task 9); remove their entries from CLAUDE.md and any skill listings that reference them

- [ ] **Step 1: `elixir.yml`** — every `actions/checkout` step gains `with: { submodules: true }`.
- [ ] **Step 2: `CLAUDE.md`** — rewrite the "Test layout" freeze paragraphs: `spec/` is a pinned submodule of `github.com/milmazz/postgrest-conformance` (never edited in bier; bumps are explicit reviewed commits); the two old spec-edit exceptions now read "spec changes happen upstream via that repo's workflows"; `fixtures_local.sql` reference becomes `03_supplement.sql` upstream. `docs/CONFORMANCE_IMPL.md`: update paths and defer format/assertion authority to `spec/HARNESS.md`.
- [ ] **Step 3: Verify docs build** — `mix docs --warnings-as-errors` (catches broken doc links). Commit: `docs,ci: point conformance ground truth at the submodule`.

### Task 14: Zero-behavior-change gate  ⚠️ shared DB

- [ ] **Step 1: CONFIRM with the user** that no other session is running tests against the shared `bier_test` database (the harness hardcodes it; `mix test` drops/recreates it).
- [ ] **Step 2: Run the full gate** — `mix precommit` in the worktree. Expected: every step green; conformance summary 758 passing, 4 excluded, `@divergences` guard compiling. Any conformance failure here is an extraction-fidelity bug: trace it to the chain (Task 2–4) or path repointing (Task 11), fix upstream (new repo → retag `v16.0.0-suite.2` → bump submodule) — never by editing case content.
- [ ] **Step 3: Wrap up** — use superpowers:finishing-a-development-branch: present the bier branch (`refactor/spec-submodule`) for PR to `main` (confirm with user before pushing/opening the PR).

---

## Self-review notes

- Spec coverage: repo identity → T1; layout/fixture materialization → T2–T3; equivalence risk mitigation → T4; preconditions → T5; HARNESS.md → T6; CI v1 → T7–T8; workflow migration + contribution rules → T9; versioning/publish → T10; bier migration + loader reduction + CLAUDE.md/CI → T11–T13; exit criterion → T14. CI phase-2 (PostgREST oracle) is explicitly deferred by the spec — no task, by design.
- The generator stays Elixir deliberately (verbatim port of proven code beats a blind rewrite); the spec permits any language for `tools/`.
