# Workflow: `bier-spec` — PostgREST spec-research fan-out

> Launch brief + design for the `/bier-spec` dynamic workflow
> (`.claude/workflows/bier-spec.js`). This document is the human-readable
> source of truth; the `.js` is a best-effort encoding of it for the
> dynamic-workflow runtime.

## 1. What this workflow does

It executes **Phase 1 of `docs/AGENT_PLAN.md`** (the *Spec Researcher*) as a
single background [dynamic workflow](https://code.claude.com/docs/en/workflows):
it fans out one subagent per PostgREST feature area, has a second wave of agents
**adversarially cross-check** each other's findings against cited PostgREST
source, then consolidates and synthesizes the result into a complete `spec/`
tree. The run returns **one report**; no per-turn transcript.

It is deliberately scoped to research only. It writes **only under `spec/`**
(the Researcher's writable globs in `AGENT_PLAN.md` §4.2). It does **not** touch
`lib/`, `test/`, or `mix.exs`. Generating the failing ExUnit suite from `spec/`
is Phase 2 (the Tester) and is out of scope here.

### Why this phase, and why a workflow

- A dynamic workflow is **one background run that returns one report**, fanning
  out up to 16 concurrent / 1,000 total subagents, whose signature quality move
  is *agents reviewing each other's work* before it's reported. Spec research is
  exactly that shape: ~16 independent feature areas, each researched in parallel,
  each verifiable against a citable source.
- Originally this was the bottleneck (no `spec/` existed and every later phase
  was blocked on it). Today `spec/` exists and the workflow's usual job is the
  **sync-mode re-run**: re-verifying and updating the tree against a newer
  pinned PostgREST version.

## 2. Pinned target

- **PostgREST `v14.12`** — the single version this run specs. (Override via
  `args.pinned` at launch.) Reaching parity with one pinned version is
  the priority; chasing upstream drift comes later (the Spec-Drift Auditor).
- Sources of truth, in priority order:
  1. PostgREST test tree — `test/spec/Feature/**` (Haskell) + `test/spec/fixtures/**` (SQL). **Ground truth.**
  2. PostgREST Haskell source — `src/**`.
  3. PostgREST docs site — behavior the tests imply but don't state.
- **Every** spec entry must carry a `source` URL **with a line anchor**.
  Untraceable claims are dropped and logged as gaps — the Tester refuses
  untraceable spec entries (`AGENT_PLAN.md` §12).

## 3. Phases

```
A. Partition      one research unit per feature area (table below) — in-script, no agent
B. Research       fan-out: 1 agent / area -> writes (or re-syncs) spec/<area>.yaml + cases + fixture fragment
C. Cross-check    fan-out: 1 fresh agent / area, adversarially re-auditing that SAME area's output (never its author)
   └─ revise loop  on "revise" verdict, re-dispatch research with the issues (<= 2 rounds; stops early if no actionable issues)
D. Consolidate    1 agent: fold per-area fixture deltas (fixtures/*.delta.sql)
                  into the PRIMARY spec/conformance/fixtures.sql — NEVER a
                  regeneration from the historical fragments (they lack objects
                  and seed-merge decisions only the merged file has); deltas are
                  emptied after folding
E. Verify         1 agent: MACHINE checks with real command output — fixture load
                  (mix bier.fixtures.load / psql), every case validated against
                  spec/case.schema.json, case-id uniqueness, zero `source:` URLs
                  citing a non-pinned version, every case-referenced relation
                  exists in the loaded DB, case count
F. Synthesize     1 agent: spec/README.md, spec/COVERAGE.md, conformance/INDEX.md
                  refreshed from disk (case.schema.json only drafted if absent;
                  an existing "Scope decisions" section is preserved)
G. Report         script returns coverage matrix + verified case count + the list of gaps needing a human decision
```

Agent budget: worst case 17 areas × 3 rounds × 2 agents (initial + 2 revisions,
researcher + reviewer re-dispatched per round) + 3 tail agents = **105 max**,
far under the 1,000 cap, with ≤16 running at once. Typical runs are far smaller
(most areas pass review in round 0).

**Sync mode.** When `spec/` already exists (the usual case now), research agents
do NOT regenerate: they diff the previous pin against the target
(`git diff <prev>..<pinned> -- test/spec/ src/`) to find what actually changed,
locate their area's cases by the `feature:` field, re-anchor every citation to
the pinned version, fix changed behavior, add cases for new features, and drop
no-longer-existing behavior as logged gaps. Behaviors the frozen
`case.schema.json` cannot express are never approximated with weaker
assertions — they're recorded as `needed_assertion:` gaps for the human harness
gate, and fixture objects needing loader exposure (rpc/headers area schemas,
new `schema:` labels) as `loader_exposure:` gaps.
New case ids come from the area's band (fixed by its position in the canonical
area table, stable under `args.areas` subsets) with a closed per-area overflow
range; existing ids are never renumbered.

**Fixture layering.** `spec/conformance/fixtures.sql` is the primary artifact;
researchers write new fixture objects only to their area's
`fixtures/<key>.delta.sql`; `fixtures_local.sql` (human-owned) and the live
loader inputs `fixtures/rpc.sql`/`headers.sql` are untouchable. Seed-data
ground truth for expected bodies is the CONSOLIDATED database as built by
`mix bier.fixtures.load`, never a historical fragment. Full contract:
`spec/conformance/fixtures/README.md`.

## 4. Feature-area taxonomy (the research units)

Derived from `AGENT_PLAN.md` §5.1. One agent owns one row and writes that row's
`spec/<key>.yaml`.

| #  | key                  | scope (non-exhaustive)                                                                                   |
|----|----------------------|---------------------------------------------------------------------------------------------------------|
| 1  | `url_grammar`        | path → schema/table/row, reserved query params, percent-encoding, the full request grammar              |
| 2  | `operators`          | `eq gt gte lt lte neq like ilike match imatch in is isdistinct fts plfts phfts wfts cs cd ov sl sr nxr nxl adj` + `not` |
| 3  | `select`             | columns, alias, `::cast`, JSON paths `->`/`->>`, embeds (o2m/m2o/m2m via junction), `!inner`/`!left`, hints, spread `...`, computed cols, aggregates |
| 4  | `filters`            | horizontal filters, `and`/`or`/`not`, grouping, quoting, JSON arrows, filtering on embedded resources    |
| 5  | `ordering`           | `asc`/`desc`, `nullsfirst`/`nullslast`, `embed.order=`, order on computed/aggregate columns               |
| 6  | `pagination`         | `limit`/`offset`, `Range` request header, `Content-Range` response, `Prefer: count=exact\|planned\|estimated` |
| 7  | `representations`    | `Prefer: return=minimal\|headers-only\|representation`, resolution + which status/body each yields         |
| 8  | `mutations`          | POST/PATCH/PUT/DELETE bodies, bulk, upsert (`resolution=merge\|ignore-duplicates`), `on_conflict`, `missing=default`, `columns=`, limited update/delete |
| 9  | `rpc`                | `/rpc/<fn>`, GET vs POST, scalar vs SETOF, single-row, `Prefer: params=single-object`, variadic, named/default args, `void` |
| 10 | `auth`               | JWT verify (HS256/RS256/ES256/EdDSA/JWKS), role switch, `db-pre-request`, GUCs (`request.jwt.claims`, `request.headers`, `request.cookies`, `request.method`, `request.path`), `aud`/`exp` |
| 11 | `errors`             | SQLSTATE → HTTP status map, error body `{code,message,details,hint}`, `RAISE`/`PTxxx` custom errors        |
| 12 | `headers`            | request + response headers, `Prefer` echo, `Content-Profile`/`Accept-Profile` schema switch, `Location`, `Content-Location` |
| 13 | `content_negotiation`| `application/json`, `text/csv`, `application/vnd.pgrst.object+json` (single), GeoJSON, OpenAPI, `application/octet-stream` (bytea), `application/vnd.pgrst.plan` (EXPLAIN) |
| 14 | `openapi`            | OpenAPI 3.0 generation rules, descriptions from `COMMENT`s, security schemes                              |
| 15 | `config`             | every PostgREST config key + semantics (`db-uri`, `db-schemas`, `db-anon-role`, `jwt-secret`, `jwt-aud`, `db-max-rows`, `server-port`, …) |
| 16 | `observability`      | log format, `log-level`, `Server-Timing`, metrics/traces surface                                          |
| 17 | `domain_representations` | `CREATE DOMAIN` + `CREATE CAST` conversions: read/write casts (json/text), filtering on the underlying value, defaults |

Restrict a run to a subset of areas with `args.areas` (e.g.
`{areas: ["select", "rpc"]}`); pick the PostgREST version with `args.pinned`
(default `v14.12` — it also derives the docs major-version URL).

## 5. Agent contracts

### B/C · Research agent (one per area)
- **Reads**: the area's PostgREST docs page(s); `test/spec/Feature/**` + fixtures
  + `src/**` for that area (via `git clone --depth 1 --branch v14.12` or raw
  `WebFetch` of `raw.githubusercontent.com/PostgREST/postgrest/v14.12/...`).
- **Writes** (only under `spec/`):
  - `spec/<key>.yaml` — the area's behavior model (see `AGENT_PLAN.md` §5.1 shapes).
  - `spec/conformance/cases/NNNN_<slug>.yaml` — ≥1 black-box case per public
    feature in the area, in the §5.1 case shape (request → expect, with `source`).
  - `spec/conformance/fixtures/<key>.delta.sql` — only if new/changed cases need
    fixture objects that don't exist yet (new objects only; folded into the
    primary `fixtures.sql` by phase D).
- **Returns** (structured): `[{ entry_id, claim, source_url, source_line, case_ids }]`.
- **Hard rule**: no entry without a `source` URL + line. Untraceable → omit + log a gap.

### C · Review agent (one per area, never its author)
A **fresh, stateless** agent re-audits the **same** area it reviews — it did not
write that area's spec. Because every subagent is independent, a same-area review
by a different agent already gives the adversarial property; reviewing an
unrelated area would not let the reviewer verify *these* citations.
- **Verifies** each citation actually supports the claim (re-fetches the source),
  flags contradictions, checks the area's docs ToC for **missing** major features,
  and lints every case against `spec/case.schema.json`.
- **Returns**: `{ verdict: "pass"|"revise", issues: [...], dropped_entries: [...], missing_features: [...] }`.
- On `"revise"`, the script re-dispatches the research agent with `issues`
  appended, then re-reviews — up to **2** rounds, after which residual issues
  are escalated into the final report as gaps.

### D · Consolidation agent (one)
Folds every `spec/conformance/fixtures/*.delta.sql` into the **primary**
`spec/conformance/fixtures.sql` (dependency-correct position, dedup against
what's already there, rename real collisions), then empties each folded delta
and verifies the load (`mix bier.fixtures.load`, falling back to psql / static
check). It must NEVER regenerate `fixtures.sql` from the historical fragments
and never touch `fixtures_local.sql` or the live loader inputs
`rpc.sql`/`headers.sql`. Returns the folded-delta and conflict lists.

### E · Synthesis agent (one)
Emits `spec/README.md` (version pin + overview), `spec/COVERAGE.md` (every
PostgREST docs page → covering case IDs), a draft `spec/case.schema.json`
(JSON-Schema the cases validate against — the Tester owns it thereafter), and
`spec/conformance/INDEX.md`. Returns coverage totals.

## 6. Output layout (what a successful run leaves on disk)

```
spec/
├── README.md  url_grammar.md  operators.yaml  select.yaml  filters.yaml
├── ordering.yaml  pagination.yaml  representations.yaml  mutations.yaml
├── rpc.yaml  auth.yaml  errors.yaml  headers.yaml  content_negotiation.yaml
├── openapi.yaml  config.yaml  observability.yaml
├── COVERAGE.md  case.schema.json
└── conformance/
    ├── fixtures.sql            # consolidated, loads on PG 14/15/16
    ├── fixtures_local.sql      # human-owned supplement (never workflow-written)
    ├── fixtures/README.md      # fixture layering + ownership contract
    ├── fixtures/<key>.sql      # historical fragments (provenance only) + the
    │                           # live loader inputs rpc.sql/headers.sql
    ├── fixtures/<key>.delta.sql # transient write channel, emptied after folding
    ├── cases/NNNN_*.yaml       # black-box request→response records
    └── INDEX.md
```

## 7. Exit criteria (Phase 1 done — `AGENT_PLAN.md` §5.1)

- `spec/conformance/fixtures.sql` loads cleanly into Postgres 14/15/16.
- ≥1 conformance case per public feature in PostgREST's docs ToC.
- Every case YAML validates against `spec/case.schema.json`.
- `spec/COVERAGE.md` maps every PostgREST docs page → its case IDs.
- Every spec entry cites a source URL + line; the report's gap list is the
  agenda for the human (workflows can't ask mid-run).

## 8. How to run it

This phase requires an **interactive** Claude Code session — a Claude Code on the
web / headless session can't launch the workflow runtime.

1. **Enable dynamic workflows** (Pro only): `/config` → toggle *Dynamic
   workflows* on. (On Max/Team/Enterprise/API it's on by default.) Needs Claude
   Code ≥ v2.1.154.
2. **Pre-allow the tools the agents need** so the run doesn't pause on prompts —
   add to your allowlist: `WebFetch`, `WebSearch`, and the Bash commands the
   research agents use, e.g. `Bash(git clone:*)`, `Bash(psql:*)`.
3. **Launch.** `bier-spec.js` lives in `.claude/workflows/`, which is *not* a
   slash-command directory — there is no `/bier-spec` command (that only exists
   if you separately save one). Launch it one of these ways, easiest first:
   - **Ask Claude, with the keyword _workflow_ in your message** — e.g.
     "run the bier-spec workflow." Claude drives the runtime for you. If the
     workflow resolves by name it runs as `Workflow({name: "bier-spec"})`;
     otherwise Claude runs it by path:
     `Workflow({scriptPath: ".claude/workflows/bier-spec.js"})`. To override the
     pinned version, pass args: `Workflow({scriptPath: "…", args: {pinned: "v15.0"}})`.
   - **(Re)generate from this brief** instead of using the committed script —
     paste a prompt containing the keyword **workflow**:
     ```
     Run a workflow that executes docs/workflows/bier-spec.md: spec-research
     fan-out for PostgREST v14.12, one subagent per feature area writing spec/,
     a fresh adversarial reviewer re-auditing each area's cited sources, then
     consolidate fixtures and synthesize COVERAGE.md. Write only under spec/.
     ```
4. **Approve** the plan when prompted (*Yes, run it*). It runs in the background;
   watch with `/workflows`.
5. **Read the report**, triage its `gaps_for_human_review` list, then hand
   `spec/` to Phase 2.

To save an improved run as a reusable `/bier-spec` slash command, copy/move the
script into `.claude/commands/`; `/workflows` → select the run → `s` lets you
re-save the script back into `.claude/workflows/`.

## 9. Caveats

- **Structured outputs** (2026-07 revision): agents report via the runtime's
  `schema:` StructuredOutput option — validated and retried at the tool-call
  layer — instead of the old "end with a ```json fence" convention. Schemas are
  kept small (paths/ids/gaps, not full entry dumps); the spec/ files on disk are
  the real deliverable. `agent()` returns `null` for a skipped or
  terminally-errored subagent; the script records every null as an explicit gap.
- **Determinism**: full determinism is impossible (live web research + LLM
  judgment). The run is made *reproducible in structure* instead: pinned-version
  URLs, canonical area ordering, idempotent sync-mode research, machine-verified
  acceptance facts (phase E), and no silent data loss in the report.
- **No mid-run input**: decisions the agents can't resolve from a cited source
  (genuine PostgREST ambiguities) surface in the final report's gap list rather
  than blocking the run.
- **Cost**: ~30–66 agents fanning out over web fetches is meaningfully more
  tokens than a single conversation. Check `/model` first.
