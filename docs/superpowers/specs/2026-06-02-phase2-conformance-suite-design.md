# Phase 2 — Conformance Test Suite (the Tester) — Design

> Status: approved (design). Implementation plan to follow via writing-plans.
> Scope: `docs/AGENT_PLAN.md` Phase 2 / §5.2 (the Tester), conformance suite only.

## 1. Goal

Convert the `spec/` tree (532 black-box conformance cases, produced and audited
in Phase 1) into a complete, **initially ~100%-failing** ExUnit suite under
`test/`, using a *generator* that emits one test per YAML case. As Phase 3
Developers implement `lib/` slices, cases flip from red to green; Phase 4 runs
the same suite against PostgREST as the acceptance gate.

This phase delivers the **conformance suite only** — the spec-driven red suite
plus its support harness and test-only deps. Property tests and the
`query_parser.ex` migration are explicitly out of scope (separate sessions /
Phase 3 dev slices).

## 2. Key decisions (settled during brainstorming)

1. **Not a workflow.** Phase 1 fanned out because its 16 feature areas were
   independent research. Phase 2 is one coherent, interdependent harness
   (loader + server + assertions + generator sharing types/conventions);
   parallel agents would only collide on the same `test/support/` files. Built
   directly here, TDD-style. (Workflows return for Phase 3's 17 parallel slices.)
2. **Defer Postgres.** Bier cannot query a DB yet — its config schema
   (`lib/bier.ex`) has only `name` + `router`; introspection is stubbed and the
   controllers return canned responses. So every case goes red *without* a DB.
   We do **not** stand up Postgres/`postgres_case`/fixtures now; the harness is
   designed so they slot in when the `executor` slice (Phase 3, slice 7) needs
   them.
3. **HTTP now, CLI pending.** The runner dispatches on `request.kind`. HTTP
   cases (including auth — JWT is pre-minted in the case header) run and go red.
   CLI cases (`config` dump, some `observability` flags: `request.kind: cli`,
   `flag: …`, asserting `exit_code`/`dump_contains`/`stderr_contains`) have no
   execution target (no Bier CLI exists), so they are tagged `@tag :cli` +
   `@tag :pending` and excluded by default — a documented record, not hidden.
4. **One shared Bier instance**, not per-test. `RouterBuilder` names the
   generated router module after the instance and rebuilds it every boot, so
   per-test instances would cause module-name churn and a big slowdown — and buy
   no isolation, since the cases are stateless reads against canned responses.

## 3. Architecture

```
spec/conformance/cases/*.yaml
        │  (compile time, yaml_elixir)
        ▼
ConformanceCase.load_all/0  ──►  [%ConformanceCase{…}]   (test/support/conformance_case.ex)
        │
        ▼  generator (for c <- load_all(), do: test …)
test/conformance/conformance_test.exs
        │  request/1 (req)                 assert_expect/2
        ▼                                          ▲
  HTTP ──► shared Bier instance ──► response ──────┘
           (canned/404 → mismatch → red)
```

### Components (all test-only; within the Tester's `test/**` globs)

| File | Responsibility |
| ---- | -------------- |
| `test/support/conformance_case.ex` | `load_all/0` reads `spec/conformance/cases/*.yaml` at compile time → `%ConformanceCase{id, feature, area, kind, request, schema, preconditions, expect, source}`. `area` = leading segment of `feature:`; `kind` = `:http`\|`:cli` (from `request.kind`, default `:http`). |
| `test/support/conformance_server.ex` | Starts ONE Bier instance (unique name, `router: [port: 0]` → actual port read back from Bandit), exposes `base_url/0`. Booted in `test_helper.exs`, stopped at exit. |
| `test/support/http_case.ex` | `ExUnit.CaseTemplate` exposing `base_url` + `request/1`: builds the HTTP call (method, path, headers, body) from a case, deriving `Accept-Profile` from `schema:` so cases are future-correct when Bier supports schema routing. |
| `test/support/conformance_assertions.ex` | `assert_expect(resp, expect)` interpreting the assertion vocabulary `case.schema.json` settled on (see §4). Unknown assertion key → **raises** (never silently passes). |
| `test/conformance/conformance_test.exs` | The generator: `@moduletag :conformance`, `async: true`, one tagged test per case. |
| `test/test_helper.exs` | Boots the shared server; `ExUnit.start(exclude: [:cli])`. |
| `mix.exs` | Test-only deps: `yaml_elixir`, `req`, `excoveralls` + coverage aliases. |

## 4. Assertion vocabulary

Interpreted by `conformance_assertions.ex`, matching the keys the Phase-1 audit
settled `spec/case.schema.json` on (NOT the plan's illustrative `body_jsonpath`,
which the real cases do not use):

- `status` — integer equality.
- `headers` — subset match: each given header present with the given value.
- `headers_present` / `headers_absent` — presence/absence only.
- `body_exact` — JSON deep-equality (decode via `Bier.json_library/0`).
- `body_json` — parse response as JSON, compare to the given structure.
- `body_contains` — substring/subset containment.
- `body_raw` — exact byte comparison (covers the custom-media SOH-byte case 1636).
- `body_exact: null` / `body_exact: ""` — asserts an empty response body.
- `headers_match` — per-header regex match (`Regex.match?`).
- `headers_no_blank` — asserts no response header has a blank value.
- `headers_absent_in_value` — the named header's value must not contain the given substrings.
- CLI-only keys (`exit_code`, `dump_contains`, `stderr_contains`, …) — not
  interpreted; their cases are pending-tagged and excluded (see §9).

> Correction to the original draft: the real cases **do** use `body_jsonpath`
> (39 cases) — they are not absent. Evaluating it needs a JSONPath evaluator,
> which is deferred (see §9), so those cases are tagged `:pending` and excluded
> rather than handled here.

## 5. Tagging strategy

- `@moduletag :conformance` on the generated module.
- Per test: `@tag area: <area atom>` (e.g. `:operators`, `:rpc`) so Phase-3
  Developers run their slice's cases: `mix test --only area:operators`.
- Harness-unevaluable cases: `@tag :pending` + `@tag pending_reason: <reason>`,
  excluded by default via `ExUnit.start(exclude: [:pending])`. `pending_reason`
  is one of `:cli`, `:jwt`, `:jsonpath`, `:status_text` (see §9).

## 6. Behavior: why it's red and runs clean

Bier boots without a DB, `req` always receives *a* response, and the assertion
fails on the canned-vs-expected mismatch — so `mix test` runs to completion with
no crashes "outside the assertion itself" (§5.2 exit criterion). Actual first-run
outcome: **475 tests, 450 failures, 80 excluded (pending), 0 invalid** — every
runnable HTTP case fails on a real `assert_expect` mismatch (no `RuntimeError`,
no `FunctionClauseError`).

## 7. Error handling

- **Loader:** a YAML that fails to parse fails the compile, naming the file.
  (All 532 are schema-valid as of Phase 1, so this is a safety net.)
- **Unknown `expect` key:** `assert_expect` raises a clear "unsupported
  assertion" error — prevents a case from passing by ignoring an assertion.
- **Shared server boot failure:** `test_helper.exs` raises; the suite does not
  run (surfaces infra breakage loudly rather than masking it).

## 8. Exit-criteria mapping (§5.2)

| §5.2 criterion | This design |
| -------------- | ----------- |
| `mix test` runs to completion (no compile errors / crashes) | ✓ — shared instance boots; no DB; assertions fail cleanly |
| Failure count ≈ total conformance case count | ✓ for HTTP (~500). CLI (~30) tracked as **excluded/pending**, the documented exception (same spirit as the `schema_cache`/`listener` deferral in `COVERAGE.md`) |
| `mix coveralls` ≥ 90% of test infrastructure | ✓ — every case exercises the loader/runner/assertions; `excoveralls` added |
| `@tag :pending` count → 0 before Phase 2 closes | 80 cases stay `:pending` until their harness capability lands (CLI, JWT signing, JSONPath, status-text) — the tracked exceptions, in the same spirit as the `schema_cache`/`listener` deferral in `COVERAGE.md` |

## 9. Pending / out of scope (deferred, by decision)

**Pending cases (tagged `:pending`, excluded; 80 total).** The final holistic
review found the original draft under-specified the assertion vocabulary. These
cases are spec'd but the current HTTP harness cannot yet evaluate them; each is
tagged `@tag :pending` + `@tag pending_reason:`. To be implemented in a follow-up:

- `:cli` (26) — `request.kind: cli` (config dump, observability flags); no Bier CLI exists.
- `:jsonpath` (39) — `expect.body_jsonpath`; needs a JSONPath evaluator
  (a `test/support/jsonpath.ex` subset). **Correction:** the real cases *do*
  use `body_jsonpath` — the original draft's claim that they don't was wrong.
- `:jwt` (12) — `request.jwt` (sign + send a Bearer token); needs a test-only
  JWT signer. (Auth cases with a pre-minted token in the header run normally.)
- `:status_text` (3) — `expect.status_text` asserts the HTTP reason phrase,
  which `req`/Finch does not expose.

**Out of scope for Phase 2 (unchanged):**

- `test/support/postgres_case.ex`, fixture loading, per-test transaction
  rollback — added when the `executor` slice queries Postgres.
- Property tests (`test/property/**`).
- Migrating `query_parser.ex` into `lib/bier/query/` and expanding parser unit
  tests — touches `lib/` (Developer-owned) and overlaps Phase 0 / Phase 3.

## 10. Branch / role note

Work proceeds on `fix/bier-spec-workflow-runtime-api` (per request), not a
`test/`-prefixed branch. The §4.3 role-guard is not built yet. All writes are
`test/**` plus test-only `mix.exs` deps — within the Tester's ownership in the
§4.2 matrix.
