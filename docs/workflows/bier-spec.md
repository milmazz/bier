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
- It's the current bottleneck: per the snapshot, **no `spec/` exists yet**, and
  every later phase (Tester, Developers, Phase 4 differential) is blocked on it.

## 2. Pinned target

- **PostgREST `v12.2.0`** — the single version this run specs. (Override via the
  `PINNED` constant / launch prompt.) Reaching parity with one pinned version is
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
B. Research       fan-out: 1 agent / area -> writes spec/<area>.yaml + cases + fixture fragment
C. Cross-check    fan-out: 1 agent / area, reviewing a DIFFERENT area's output (adversarial)
   └─ revise loop  on "revise" verdict, re-dispatch research with the issues (<= 2 rounds)
D. Consolidate    1 agent: merge fixture fragments -> spec/conformance/fixtures.sql (loads on PG 14/15/16)
E. Synthesize     1 agent: spec/README.md, spec/COVERAGE.md, spec/case.schema.json, conformance/INDEX.md
F. Report         script returns coverage matrix + case count + the list of gaps needing a human decision
```

Agent budget: 16 (research) + 16 (review) + up to 16×2 (revisions) + 1 + 1 ≈ **66
max**, far under the 1,000 cap, with ≤16 running at once.

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

## 5. Agent contracts

### B/C · Research agent (one per area)
- **Reads**: the area's PostgREST docs page(s); `test/spec/Feature/**` + fixtures
  + `src/**` for that area (via `git clone --depth 1 --branch v12.2.0` or raw
  `WebFetch` of `raw.githubusercontent.com/PostgREST/postgrest/v12.2.0/...`).
- **Writes** (only under `spec/`):
  - `spec/<key>.yaml` — the area's behavior model (see `AGENT_PLAN.md` §5.1 shapes).
  - `spec/conformance/cases/NNNN_<slug>.yaml` — ≥1 black-box case per public
    feature in the area, in the §5.1 case shape (request → expect, with `source`).
  - `spec/conformance/fixtures/<key>.sql` — the schema/data fragment its cases need.
- **Returns** (structured): `[{ entry_id, claim, source_url, source_line, case_ids }]`.
- **Hard rule**: no entry without a `source` URL + line. Untraceable → omit + log a gap.

### C · Review agent (one per area, never its own)
Reviews a **different** area's output (agent *i* reviews area *(i+1) mod n*).
- **Verifies** each citation actually supports the claim (re-fetches the source),
  flags contradictions, checks the area's docs ToC for **missing** major features,
  and lints every case against `spec/case.schema.json`.
- **Returns**: `{ verdict: "pass"|"revise", issues: [...], dropped_entries: [...], missing_features: [...] }`.
- On `"revise"`, the script re-dispatches the research agent with `issues`
  appended, then re-reviews — up to **2** rounds, after which residual issues
  are escalated into the final report as gaps.

### D · Consolidation agent (one)
Merges every `spec/conformance/fixtures/*.sql` into a single
`spec/conformance/fixtures.sql` that loads cleanly on Postgres 14/15/16: dedupe
shared schemas/tables, resolve naming collisions, order DDL by dependency.
Returns the conflict list it resolved.

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
    ├── fixtures/<key>.sql      # per-area fragments (kept for provenance)
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
3. **Launch** — either run the saved command:
   ```
   /bier-spec
   ```
   …or, to (re)generate the script from this brief, paste a prompt containing the
   keyword **workflow**:
   ```
   Run a workflow that executes docs/workflows/bier-spec.md: spec-research
   fan-out for PostgREST v12.2.0, one subagent per feature area writing spec/,
   a second adversarial wave cross-checking each area's cited sources, then
   consolidate fixtures and synthesize COVERAGE.md. Write only under spec/.
   ```
4. **Approve** the plan when prompted (*Yes, run it*). Watch with `/workflows`.
5. **Read the report**, triage its gap list, then hand `spec/` to Phase 2.

To re-save an improved run as the project command: `/workflows` → select the run
→ `s` → `.claude/workflows/`.

## 9. Caveats

- **Runtime API**: the workflow runtime's agent-spawn primitive isn't publicly
  documented. `bier-spec.js` isolates that coupling in a single `dispatch()`
  wrapper — if your runtime names it differently (`spawnAgent`, `agent.run`, …),
  adjust only that function. The runtime may also choose to regenerate the script
  from this brief; this `.md` is the authoritative design either way.
- **No mid-run input**: decisions the agents can't resolve from a cited source
  (genuine PostgREST ambiguities) surface in the final report's gap list rather
  than blocking the run.
- **Cost**: ~30–66 agents fanning out over web fetches is meaningfully more
  tokens than a single conversation. Check `/model` first.
