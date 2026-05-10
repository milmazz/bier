# Bier Agent Factory Plan

A multi-agent strategy for delivering a 100% behavior-compatible Elixir
re-implementation of [PostgREST](https://postgrest.org). The factory is
organized as **one Researcher → one Tester → many Developers** with
strict file-ownership boundaries enforced by both convention and tooling.

> Deliver this document to a fresh Claude Code session. It is the single
> source of truth for the agent topology, deliverables, and gates.

---

## 1. Mission

Produce `:bier`, an Elixir library that is **drop-in equivalent** to PostgREST
on the wire: same URL grammar, same query semantics, same headers, same
status codes, same response bodies, same error envelopes, same OpenAPI output,
same auth contract (JWT + GUCs), and the same RPC surface.

"Compatible" is defined operationally: **every conformance test that passes
against PostgREST must pass against Bier**, against an identical Postgres
fixture database. PostgREST's own [`test/`](https://github.com/PostgREST/postgrest/tree/main/test)
tree (Haskell + SQL fixtures) is the ground truth.

Non-goals (explicit, to avoid scope creep):

- New features beyond PostgREST.
- Adapters for non-Postgres databases (until v2).
- Replacing Ecto with hand-rolled SQL generation if Ecto fits.

---

## 2. Current state (snapshot for the orchestrator)

- **Branch `main`**: scaffold only — `Bier.Application`, `Bier.Registry`,
  `Bier.Config`, `Bier.HttpServerStarter`, `Bier.RouterBuilder`,
  `Bier.Plugs.ActionController`, `Bier.Plugs.FallbackController`. Static stubs.
- **Branch `add_query_parser`**: a partial NimbleParsec parser at
  `lib/bier/query_parser.ex` covering `select` (with alias + cast),
  horizontal filters (`eq/gte/gt/lte/lt/neq/in/is/like/ilike` + `not`),
  `order`, `limit`, and insert body normalization. Tests at
  `test/bier/query_parser_test.exs`.
- **Deps**: `bandit ~> 1.0`, `plug ~> 1.19`, `nimble_parsec ~> 1.4`,
  `nimble_options ~> 1.0`. **Missing**: `postgrex`, `ecto_sql`, `jose` (JWT),
  `joken` or `jose` for JWT verify, `stream_data`/`propcheck` (property tests),
  `bypass`/`req` for HTTP-level tests, `excoveralls`.
- **No Postgres test infra yet** (no `docker-compose`, no migrations,
  no fixture loader).

The factory must absorb the existing parser (don't throw it away) but extend
it under the new spec-driven test harness.

---

## 3. Roles

Each role is a specialized subagent with its own system prompt, tool
allowlist, and writable file globs. The **boundaries are the contract** —
violating them is a CI failure, not just a convention.

### 3.1 Orchestrator (the human-driven session)

- Spawns and sequences the other agents.
- Owns `docs/STATUS.md` (the work board) and merges PRs.
- Never edits `lib/`, `test/`, or `spec/` directly.

### 3.2 Spec Researcher (1 agent, sequential)

**Goal**: produce a machine-readable, exhaustive specification of PostgREST's
public behavior.

- **Reads**: PostgREST docs site, PostgREST source (Haskell), PostgREST
  test fixtures, OpenAPI samples, GitHub issues tagged `behavior`.
- **Writes**: only under `spec/` (see §5).
- **Tools**: `WebFetch`, `WebSearch`, `Read`, `Write`, `Bash` (read-only:
  `git clone`, `grep`, `jq`).
- **Forbidden**: editing `lib/`, `test/`, `mix.exs`.

Deliverable shape: §5.1.

### 3.3 Tester (1 agent, sequential — but resumable)

**Goal**: convert `spec/` into a complete, initially-100%-failing ExUnit
suite. Owns the suite for the project's life.

- **Reads**: `spec/`, `lib/` (read-only, to discover module names).
- **Writes**: only under `test/` and `test/support/`. May add test deps to
  `mix.exs` (`only: :test`).
- **Tools**: `Read`, `Write`, `Edit`, `Bash` (`mix test`, `mix format`).
- **Forbidden**: editing `lib/` (other than registering supervised test
  helpers via `test/support`). Cannot weaken a test to make it pass — only
  the Researcher producing a corrected spec can authorize a test change,
  and the Tester re-derives the test from the new spec.

Deliverable shape: §5.2.

### 3.4 Developers (N agents, parallel — one per feature slice)

**Goal**: make their assigned slice of `test/` pass without touching tests.

- **Reads**: everything.
- **Writes**: only under `lib/`, plus runtime deps in `mix.exs`.
- **Tools**: full toolset except they cannot edit files matching
  `test/**` or `spec/**`.
- **Coordination**: each Developer works on its own branch
  (`feat/<slice-name>`), opens a PR when its slice is green, and waits
  for the Reviewer + Orchestrator merge.

Slice partitioning: §6.

### 3.5 Reviewer (1 agent, on-demand)

**Goal**: gate PRs from Developers. Confirms (a) the targeted slice's
tests now pass, (b) no other tests regressed, (c) no test files were
modified, (d) no spec files were modified.

- Runs `mix test`, `mix format --check-formatted`, `mix credo --strict`,
  `mix dialyzer`.
- Posts pass/fail with delta vs. main.

### 3.6 Spec-Drift Auditor (on-demand)

**Goal**: detect when upstream PostgREST changes behavior (new release,
docs change). Re-runs the Researcher's diffing pass and files an issue
if new behavior appears.

**Invocation**: manual only — the Orchestrator triggers it (e.g. when a
new PostgREST release lands, or before cutting a Bier release). It is
**not** scheduled. Reaching parity with the pinned PostgREST version is
the priority; chasing upstream drift before parity exists wastes
Researcher and Tester cycles. Once Phase 4 is green for the pinned
version, the Auditor becomes the mechanism for re-pinning to a newer
PostgREST.

---

## 4. File ownership matrix (enforce in CODEOWNERS + pre-commit)

### 4.1 Forge-neutral identity (Option 0 — default)

Roles in this document are **abstract**, not GitHub-account-bound. The
plan deliberately does not require one GitHub account per persona —
that path leads to either fake accounts (a ToS problem on a personal
namespace) or to maintaining N machine accounts with N email aliases
and N PATs (a real cost that buys only a nicer activity feed).

Instead, role is encoded in **three forge-neutral signals**, any one
of which is sufficient and which are checked in order of priority:

1. **PR label** — `role:researcher`, `role:tester`, `role:developer`,
   `role:reviewer`, `role:orchestrator`, `role:auditor`. Highest
   priority: an explicit label always wins.
2. **Branch prefix** — `research/<topic>`, `test/<area>`,
   `dev/<slice>/<topic>`, `review/<pr-number>`, `chore/<topic>` (for
   the Orchestrator), `audit/<topic>` (for the Spec-Drift Auditor).
   Used when no label is set.
3. **Commit trailer** — `X-Bier-Role: <role>` on every commit, written
   by the agent's wrapper. At least one commit on the branch must
   carry the trailer for audit; if labels and prefix are missing, the
   trailer is the fallback.

A single human GitHub account (or a single machine account, if you
prefer) drives every role. The role-guard CI determines which globs
the diff is allowed to touch by reading those signals — not by
reading `pr.user.login`.

Why this is the default:

- **Forge-neutral by construction.** Labels, branch prefixes, and
  commit trailers are universal Git/SCM primitives. The plan ports
  to Forgejo, Gitea, GitLab CE, or any future forge without edits.
- **No ToS friction.** Zero fake accounts; the plan is compatible with
  GitHub's personal-account terms.
- **Auditable.** Every commit's trailer plus the PR label gives a
  durable record of which persona authored what — without depending
  on any forge's UI or any per-role identity.
- **Cheap.** No PAT rotation, no email alias management, no extra
  branch-protection rules per identity.

Trade-off: GitHub's per-user activity feeds, contribution graphs, and
review-author filters all attribute everything to the single driving
account. That's a dashboard nicety, not a correctness property; the
role-guard CI and the trailer history reconstruct the same view on
demand.

If you later want isolated per-persona activity streams (e.g. a public
demo of the factory), upgrade to GitHub machine accounts (ToS-compliant
for automated use) or to a self-hosted Forgejo instance with
first-class bot accounts. The plan does not change — only the wrapper
that pushes commits picks up new credentials.

### 4.2 Ownership matrix

| Path                         | Researcher | Tester | Developer | Orchestrator |
| ---------------------------- | :--------: | :----: | :-------: | :----------: |
| `spec/**`                    |     RW     |   R    |     R     |      R       |
| `test/**` (except `support`) |     —      |   RW   |     R     |      R       |
| `test/support/**`            |     —      |   RW   |     R     |      R       |
| `lib/**`                     |     —      |   R    |    RW     |      R       |
| `mix.exs` runtime deps       |     —      |   —    |    RW     |      RW      |
| `mix.exs` test-only deps     |     —      |   RW   |     —     |      RW      |
| `CHANGELOG.md`               |     RW     |   RW   |    RW     |      RW      |
| `docs/STATUS.md`             |     —      |   —    |     —     |      RW      |
| `docs/AGENT_PLAN.md`         |     —      |   —    |     —     |      RW      |
| Postgres fixtures (`priv/`)  |     —      |   RW   |     R     |      R       |

`CHANGELOG.md` is the one file every role may write — but only to add
an entry corresponding to their own PR. Format: [Keep a Changelog
1.1.0](https://keepachangelog.com/en/1.1.0/), versioned with
[SemVer](https://semver.org). Sections: `Added`, `Changed`,
`Deprecated`, `Removed`, `Fixed`, `Security`, plus a Bier-specific
`Spec` section for changes that originate in `spec/` (Researcher) and
`Tests` for test-suite-only changes (Tester). Every PR must touch
`CHANGELOG.md` under `## [Unreleased]` — CI rejects PRs that don't
(see §8).

### 4.3 Enforcement

The matrix is enforced by a **role-guard** that fails closed: if the
role can't be determined, or if the diff escapes the role's globs,
CI rejects the PR.

1. **Role resolution** (`scripts/role-guard.sh`, runs in CI and as a
   pre-commit hook): apply the priority order from §4.1 (label →
   branch prefix → commit trailer). If none match, exit non-zero.
2. **Glob check**: compute `git diff --name-only origin/main...HEAD`
   and assert every changed path matches the resolved role's writable
   globs. `CHANGELOG.md` is permitted for every role (see §4.2).
3. **Trailer audit**: at least one commit on the branch must carry
   `X-Bier-Role:` matching the resolved role. The hook adds it
   automatically on commit if missing.
4. **Pre-commit hook** at `.githooks/pre-commit` runs the same check
   locally for fast feedback. Installed via `git config core.hooksPath
   .githooks`.
5. **CODEOWNERS** still exists, but only for **human review routing**
   (e.g. directing notifications to you for `spec/` changes). It is
   no longer the enforcement mechanism — labels, prefixes, and
   trailers are.

---

## 5. Deliverables

### 5.1 Researcher — `spec/`

Everything the Tester needs to write tests without re-reading PostgREST docs.

```
spec/
├── README.md                  # overview, version pinned (e.g. PostgREST v12.2.x)
├── url_grammar.md             # full grammar of paths, query params, headers
├── operators.yaml             # eq, gte, like, fts, cs, cd, ov, sl, …
│                              # each with: pg_op, type_constraints, examples
├── select.yaml                # select syntax: cols, alias, cast, json paths,
│                              # embedded resources (one-to-many, many-to-one,
│                              # many-to-many via junction, !inner, !left, etc.)
├── filters.yaml               # horizontal filters, logical ops (and/or/not),
│                              # quoting, JSON arrows, grouped filters
├── ordering.yaml              # asc/desc, nullsfirst/nullslast, embed.order
├── pagination.yaml            # limit/offset, Range header, Content-Range,
│                              # Prefer: count=…
├── representations.yaml       # Prefer: return=minimal|headers-only|representation
├── mutations.yaml             # POST/PATCH/PUT/DELETE: body shape, upsert,
│                              # on_conflict, missing=default, bulk
├── rpc.yaml                   # /rpc/<fn>: GET vs POST, scalar vs setof,
│                              # single-row, prefer params=single-object
├── auth.yaml                  # JWT verify (HS256, RS256, ES256, JWKS),
│                              # role switching, pre-request, GUCs
│                              # (request.jwt.claims, request.headers, …)
├── errors.yaml                # PG SQLSTATE → HTTP status map, error body
│                              # shape ({code, message, details, hint})
├── headers.yaml               # request + response headers, Prefer values,
│                              # Content-Profile, Accept-Profile, schemas
├── content_negotiation.yaml   # JSON, CSV, GeoJSON, OpenAPI, single-object,
│                              # binary (bytea via pgrest)
├── openapi.yaml               # OpenAPI 3.0 doc generation rules
├── config.yaml                # every PostgREST config key + semantics
├── observability.yaml         # logs, traces, metrics format
└── conformance/
    ├── fixtures.sql           # Postgres schema/data PostgREST tests use
    ├── cases/                 # one YAML per scenario (request → response)
    │   ├── 0001_select_simple.yaml
    │   ├── 0002_select_embed_one_to_many.yaml
    │   └── …
    └── INDEX.md               # cross-reference cases ↔ feature areas
```

Each `conformance/cases/*.yaml` is a black-box record:

```yaml
id: 0042
feature: filters/logical/or
request:
  method: GET
  path: /people?or=(age.gte.14,age.lte.18)
  headers: { Accept: application/json }
schema: tests           # which spec/conformance/fixtures.sql schema to run on
preconditions: []       # optional SQL to run before
expect:
  status: 200
  headers:
    Content-Type: application/json; charset=utf-8
  body_jsonpath:
    - { path: "$[*].age", all_match: { in_range: [14, 18] } }
  body_exact: null      # or a literal JSON document
notes: "Mirrors PostgREST test/spec/Feature/Query/AndOrSpec.hs:117"
source: https://github.com/PostgREST/postgrest/blob/v12.2.0/test/spec/Feature/Query/AndOrSpec.hs#L117
```

The Researcher's exit criteria:

- A fixture SQL file that loads cleanly into Postgres 14/15/16.
- ≥ 1 conformance case per public feature in PostgREST's docs ToC.
- Every YAML lints against `spec/case.schema.json` (published by Tester).
- A `spec/COVERAGE.md` enumerating every PostgREST docs page and the
  conformance case IDs that cover it.

### 5.2 Tester — `test/`

```
test/
├── test_helper.exs
├── support/
│   ├── postgres_case.ex        # ExUnit.CaseTemplate that starts/seeds DB
│   ├── http_case.ex            # spins Bandit on random port, returns base_url
│   ├── conformance_runner.ex   # reads spec/conformance/cases/*.yaml, runs them
│   ├── jsonpath.ex             # tiny JSONPath subset for body_jsonpath
│   └── fixtures/               # compiled SQL loader
├── bier/
│   ├── query_parser_test.exs   # unit (existing + extended)
│   ├── filter_parser_test.exs
│   ├── select_parser_test.exs
│   ├── embed_parser_test.exs
│   ├── router_builder_test.exs
│   ├── auth_test.exs
│   └── …
├── conformance/
│   └── conformance_test.exs    # generates one ExUnit test per spec case
└── property/
    ├── url_roundtrip_test.exs  # generators that assert parser ↔ printer
    └── operator_semantics_test.exs
```

Tester rules:

- `mix test` initially fails on **every** conformance case (skip 0,
  exclude 0). Use `@tag :pending` only as a record of "spec exists,
  test scaffold not yet written" — and `pending` count must reach 0
  before Phase 2 closes.
- Tests must be **deterministic** and **parallelizable** (`async: true`
  wherever the fixture allows; per-test transaction rollback for
  Postgres state).
- The conformance runner is a generator (`for case <- load_cases(),
  do: test "#{case.id}", do: …`) so adding a YAML auto-creates a test.
- The Tester publishes `spec/case.schema.json` and a CI job that
  validates every YAML on every push.

Exit criteria for Phase 2:

- `mix test` runs to completion (no compile errors, no runtime crashes
  outside the assertion itself).
- Failure count ≈ total conformance case count (since `lib/` is still
  stubs).
- `mix coveralls` reports test code coverage of the test infrastructure
  itself ≥ 90% (i.e. the runner is exercised).

### 5.3 Developers — `lib/`

Per-slice exit criteria:

- All tests tagged with the slice's `@moduletag :slice_<name>` pass.
- No test outside the slice regresses.
- `mix format`, `mix credo --strict`, `mix dialyzer` clean.
- New runtime deps justified in PR description.
- PR body links to the spec sections implemented.
- `CHANGELOG.md` updated under `## [Unreleased]` with one entry per
  user-visible change in the PR (see §4 for format).

---

## 6. Slice partition (the parallel work plan)

Slices are chosen so two Developers rarely touch the same file. Each
slice has a single owning module tree under `lib/bier/`.

| #  | Slice                  | Owns (writable)                                     | Depends on          |
| -- | ---------------------- | --------------------------------------------------- | ------------------- |
| 1  | `db_introspection`     | `lib/bier/introspection/**`                         | —                   |
| 2  | `query_parser_select`  | `lib/bier/query/select.ex`                          | —                   |
| 3  | `query_parser_filters` | `lib/bier/query/filters.ex`, `operators.ex`        | —                   |
| 4  | `query_parser_order`   | `lib/bier/query/order.ex`                           | —                   |
| 5  | `query_parser_embed`   | `lib/bier/query/embed.ex`                           | 1, 2                |
| 6  | `sql_builder`          | `lib/bier/sql/**`                                   | 2, 3, 4, 5          |
| 7  | `executor`             | `lib/bier/executor.ex`, Postgrex pool              | 6                   |
| 8  | `router`               | `lib/bier/router_builder.ex`, `lib/bier/plugs/**`  | 1                   |
| 9  | `mutations`            | `lib/bier/mutations/**`                             | 6, 7, 8             |
| 10 | `rpc`                  | `lib/bier/rpc/**`                                   | 1, 7, 8             |
| 11 | `auth_jwt`             | `lib/bier/auth/**`                                  | 8                   |
| 12 | `content_negotiation`  | `lib/bier/content/**`                               | 8                   |
| 13 | `pagination_headers`   | `lib/bier/pagination.ex`                            | 6, 7, 8             |
| 14 | `errors`               | `lib/bier/errors.ex`, `lib/bier/plugs/fallback…`   | 8                   |
| 15 | `openapi`              | `lib/bier/openapi/**`                               | 1                   |
| 16 | `config`               | `lib/bier/config.ex`                                | —                   |
| 17 | `observability`        | `lib/bier/telemetry.ex`                             | 8                   |

Independent slices runnable in parallel from day one: 1, 2, 3, 4, 16.
Then 5, then 6, then 7/8, then the rest.

The Orchestrator maintains a Kanban in `docs/STATUS.md`:

```
| slice | agent | branch | tests passing | blocked on | PR |
```

---

## 7. Coordination protocol

### 7.1 Spec gaps (Developer → Tester → Researcher)

A Developer finds a test that is **wrong** (contradicts PostgREST):

1. Developer opens an issue using the template `.github/ISSUE_TEMPLATE/spec-gap.md`.
   Required fields: failing test ID, observed PostgREST behavior, source URL,
   minimal reproduction.
2. Developer **does not** edit the test. They mark their PR `Draft` and
   move on to another slice.
3. Researcher verifies the discrepancy against PostgREST source/docs.
   If real, updates `spec/`. If not, closes the issue with the canonical
   reference.
4. Tester regenerates affected tests from the updated spec.
5. Developer rebases and continues.

### 7.2 Test infrastructure changes

The Tester may refactor `test/support/**` freely as long as the
generated test count and IDs are preserved.

### 7.3 Merging

- One slice = one PR.
- Reviewer agent runs the gate.
- Orchestrator merges to `main` (squash). No agent self-merges.

### 7.4 Conflict resolution

Two Developers needing the same file is a partition bug — the
Orchestrator re-slices and closes one PR.

---

## 8. Quality gates (CI, runs on every PR)

1. `mix format --check-formatted`
2. `mix compile --warnings-as-errors`
3. `mix credo --strict`
4. `mix dialyzer`
5. `mix test --cover` (must not regress previously-passing tests)
6. `mix test --only conformance` against Postgres 14, 15, 16 in matrix
7. **Role guard**: diff vs. base must lie within the PR author's
   allowed globs (§4)
8. **Spec lint**: every `spec/conformance/cases/*.yaml` validates
9. **Coverage gate**: line coverage ≥ 85% on touched modules
10. **Property tests**: `mix test --only property` (longer timeout)
11. **Changelog gate**: PR diff must add at least one line under
    `## [Unreleased]` in `CHANGELOG.md`. Exempt only via the label
    `changelog:skip` (chore, internal-doc-only, CI-only). The
    Reviewer agent rejects unjustified skips.

Postgres in CI: `services.postgres` matrix in GitHub Actions, with
`spec/conformance/fixtures.sql` loaded on boot.

---

## 9. Phasing & milestones

| Phase | Duration target | Exit gate                                                        |
| ----- | --------------- | ---------------------------------------------------------------- |
| 0     | 1 session       | This plan committed; CODEOWNERS + role guard CI in place         |
| 1     | 3–5 sessions    | `spec/` complete per §5.1 exit criteria                          |
| 2     | 2–3 sessions    | `test/` complete per §5.2 exit criteria; `mix test` ≈ 100% red   |
| 3     | N sessions      | All slices green; `mix test` 100% green                          |
| 4     | 1–2 sessions    | Side-by-side conformance: identical fixture DB, run same suite   |
|       |                 | against PostgREST and Bier; diff must be empty                   |
| 5     | on-demand       | v1.0 release; Spec-Drift Auditor available for re-pinning to     |
|       |                 | newer PostgREST versions when triggered                          |

Phase 4 is the **real** acceptance gate: the same
`spec/conformance/cases/*.yaml` runner pointed at PostgREST must produce
the same pass/fail vector as when pointed at Bier. This catches both
under-specified tests (PostgREST fails too — fix the spec) and Bier bugs
(PostgREST passes, Bier fails — Developer ticket).

---

## 10. Tooling & infra to add in Phase 0

Concrete checklist for the first session that picks up this plan:

- [ ] Add deps: `postgrex`, `ecto_sql`, `jose`, `joken`, `stream_data`,
      `excoveralls`, `credo`, `dialyxir`, `yaml_elixir`, `jason`.
- [ ] `docker-compose.yml` with Postgres 14/15/16 services on
      different ports.
- [ ] `priv/repo/conformance_fixtures.sql` placeholder.
- [ ] `.github/workflows/ci.yml` implementing §8 gates.
- [ ] `.github/workflows/spec-drift.yml` (manual `workflow_dispatch`
      only, runs Auditor when triggered by the Orchestrator — see §3.6).
- [ ] `scripts/role-guard.sh` implementing §4.3 (role resolution + glob
      check + trailer audit). Wired into `.github/workflows/ci.yml` and
      installable as a pre-commit hook via `core.hooksPath`.
- [ ] PR labels created in the repo: `role:researcher`, `role:tester`,
      `role:developer`, `role:reviewer`, `role:orchestrator`,
      `role:auditor`, plus `changelog:skip` (§8 #11).
- [ ] `.github/CODEOWNERS` per §4 (review routing only, not
      enforcement).
- [ ] `.githooks/pre-commit` invoking `scripts/role-guard.sh` plus
      `mix do format, compile`. Installed in CI bootstrap docs.
- [ ] `.github/ISSUE_TEMPLATE/spec-gap.md`.
- [ ] `docs/STATUS.md` Kanban skeleton.
- [ ] `CHANGELOG.md` initialized in Keep a Changelog format with an
      empty `## [Unreleased]` block and Bier-specific `Spec` / `Tests`
      sections documented in the file header.
- [ ] CI changelog gate (§8 #11) implemented.
- [ ] `.claude/agents/researcher.md`, `tester.md`, `developer.md`,
      `reviewer.md`, `auditor.md` (subagent definitions with the
      role's system prompt and tool allowlist).
- [ ] Move `lib/bier/query_parser.ex` into the new layout under
      `lib/bier/query/` and re-route its tests; this is a
      **migration**, not a rewrite — the existing parser becomes the
      seed for slices 2–4.

---

## 11. Subagent system-prompt skeletons

Each `.claude/agents/<role>.md` should include:

```
---
name: <role>
description: <when to invoke>
tools: <allowlist>
---

You are the <Role> agent for the Bier project. Read docs/AGENT_PLAN.md
in full before acting. Your single source of truth for behavior is
spec/ (you may not derive behavior from PostgREST docs directly —
ask the Researcher).

Writable globs (hard limit): <list>
Forbidden: editing any path outside your writable globs. If you
believe you need to, stop and open a coordination issue.

Identity (per §4.1, forge-neutral):
- Branch prefix: <prefix>/  (e.g. research/, test/, dev/<slice>/)
- Every commit MUST include the trailer: `X-Bier-Role: <role>`
- When opening a PR, apply the label `role:<role>`
- The role-guard CI (§4.3) will reject the PR if any of the above
  is missing or if the diff escapes your globs.

When you finish a unit of work:
1. Run the relevant gates (`mix test`, `mix format --check-formatted`,
   `scripts/role-guard.sh`).
2. Update docs/STATUS.md with your slice's row.
3. Open or update your PR with the `role:<role>` label. Do not merge.
```

---

## 12. Risks & mitigations

| Risk                                                             | Mitigation                                                                  |
| ---------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Spec is incomplete → Tester writes wrong tests                   | Phase 4 side-by-side run against PostgREST itself catches this              |
| Developers race on shared files (e.g. `router_builder.ex`)       | Slice partition + role guard; Orchestrator re-slices on conflict            |
| Tester silently weakens a test to make a Dev happy               | Forbidden by role; test diffs require Tester signature; CI flags coverage drop |
| Postgres version drift between Bier CI and PostgREST CI          | Match PostgREST's CI matrix exactly                                         |
| Library-level deps drift from PostgREST behavior (Postgrex bugs) | Pin Postgrex; add regression tests for every Postgrex-induced fix           |
| Endless spec scope (every PostgREST option)                      | Cut by version: target one PostgREST minor version per milestone           |
| Agents hallucinate PostgREST behavior                            | Researcher MUST cite a source URL + line for every spec entry; Tester refuses untraceable spec entries |
| Long-running parallel branches rot                               | Daily rebase by Orchestrator; slices kept small (≤ 1 week of work)         |

---

## 13. Definition of Done (project)

- All `spec/conformance/cases/` pass against Bier on Postgres 14/15/16.
- Phase 4 differential test against PostgREST (pinned version) is empty.
- `mix hex.publish --dry-run` succeeds.
- `CHANGELOG.md` `[Unreleased]` block has been promoted to a versioned
  release entry (with date), and every merged PR since the previous
  release has a corresponding entry.
- README rewritten with usage; `docs/AGENT_PLAN.md` archived under
  `docs/history/` with a postmortem.

---

## 14. First instruction to give the next session

> Read `docs/AGENT_PLAN.md` end-to-end. Then execute Phase 0 §10 as a
> single PR titled "Phase 0: factory bootstrap". Do not start the
> Researcher until Phase 0 is merged.
