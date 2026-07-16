/**
 * bier-conformance — bring lib/ (back) to green against the conformance suite
 * ===========================================================================
 *
 * 2026-07 rewrite (adversarially reviewed): the original script was a
 * greenfield build plan (add postgrex, create config/, replace the
 * introspection stub, ...) — all of which shipped long ago. Re-running that
 * against the implemented codebase would instruct agents to re-scaffold
 * working architecture. This version is a BASELINE → REPAIR workflow, which
 * also covers the original use-case:
 *
 *   1. Baseline   — load fixtures + run the full suite once; derive per-area
 *                   failure counts from real output.
 *   2. Foundation — ONLY if the suite cannot run at all (fixture load fails,
 *      repair       compile errors, harness crash): one agent repairs the
 *                   infra per docs/CONFORMANCE_IMPL.md, then re-baselines.
 *                   A baseline/repair AGENT THROW is a runtime-lifecycle
 *                   failure, not evidence the suite is broken — it routes to
 *                   an errored/blocked return, never to the repair agent.
 *   3. Slices     — one sequential agent per FAILING area, in canonical
 *                   order, extending the shared core (sequential => no merge
 *                   conflicts, deterministic order). Green areas are skipped.
 *                   Each iteration is try/caught so one thrown slice can't
 *                   destroy the others' accumulated work.
 *   4. Finalize   — full CI gate set + honest tally with raw evidence. Runs
 *                   even when no slices ran: the baseline never checks
 *                   format/credo/docs/warnings gates, so skipping Finalize on
 *                   a "green" baseline could report green over a broken gate.
 *
 * Harness-shaped failures (assertion keys the frozen harness can't evaluate,
 * missing JWT sign_with keys, PGRST106 on a novel schema label, relations
 * missing from the fixture DB) are CLASSIFIED and routed to the human gate as
 * "harness_gap:" blockers — slice agents must not contort lib/ to work around
 * them, and no agent here may edit test/** or spec/**.
 *
 * Determinism levers: structured schema-validated reports, an `evidence`
 * field that must carry the pasted test-summary line (numbers are grounded in
 * command output, not recall), canonical slice ordering, and skip-if-green
 * slice idempotency — re-running on a green tree does one baseline run plus
 * one gate-check Finalize and changes nothing.
 */

export const meta = {
  name: 'bier-conformance',
  description: 'Bring Bier lib/ to green against the PostgREST conformance suite: baseline the failures, repair the foundation only if the suite cannot run, then one sequential agent per failing area, then full CI gates',
  whenToUse: 'After the spec/ tree changed (bier-spec / bier-spec-audit re-sync + human harness gate) or whenever conformance failures need working down. Green areas are skipped.',
  phases: [
    { title: 'Baseline', detail: 'fixture load + full mix test; per-area failure counts from real output' },
    { title: 'Foundation repair', detail: 'only if the suite cannot run: fix infra/pipeline per docs/CONFORMANCE_IMPL.md' },
    { title: 'Feature slices', detail: 'one sequential agent per failing area, extending the shared core' },
    { title: 'Finalize', detail: 'full CI gate set, honest pass report with raw evidence' },
  ],
}

const DOC = 'docs/CONFORMANCE_IMPL.md'

const RULES = `
HARD RULES (read ${DOC} in full first — it encodes the architecture and the keystone DB trick; CLAUDE.md summarizes the current pipeline):
- Bier is ALREADY IMPLEMENTED and has passed this suite before. You are repairing/extending, not scaffolding: never re-create deps, config files, or modules that exist — read the current code and modify it. Do NOT rewrite working code from scratch.
- Write ONLY under lib/, mix.exs, config/. NEVER edit test/** or spec/** (frozen ground truth; spec/conformance/fixtures_local.sql is human-owned). If a test looks wrong, re-read its cited source: URL — do not change the test.
- HARNESS GAPS are not yours to solve: if a failure is caused by the frozen harness rather than lib/ — an "unknown key" raise from conformance_assertions, a case needing a JWT sign_with key the harness doesn't define, PGRST106 because a case uses a schema label the fixture loader never builds, or undefined_table because the fixture DB lacks a relation the case references — record it as a blocker prefixed "harness_gap:" with the case ids and STOP working on those cases. Do not contort lib/ (or smuggle DDL into the fixture loader) to paper over them.
- Serialize JSON via Bier.json_library(). Keep mix format clean and compile warning-free.
- 'mix test' is aliased to run 'mix bier.fixtures.load' first (drops+recreates the local bier_test DB, loads spec/conformance/fixtures.sql + fixtures_local.sql, mirrors area schemas). Both are idempotent; a reachable local Postgres is required.
- Report HONEST numbers copied from actual command output, and paste the final test-summary line (e.g. "532 tests, 3 failures, 57 excluded") verbatim into the "evidence" field. Do not claim green without running the command.
`

// Structured report for every slice agent. `evidence` grounds the claimed
// numbers in pasted command output.
const REPORT = {
  type: 'object',
  additionalProperties: false,
  required: ['summary', 'files_changed', 'area_pass', 'area_total', 'full_pass', 'full_fail', 'regressions', 'evidence', 'blockers'],
  properties: {
    summary: { type: 'string', description: 'what you implemented, 2-4 sentences' },
    files_changed: { type: 'array', items: { type: 'string' } },
    area_pass: { type: 'integer', description: 'tests passing in this slice (mix test --only area:<area>, pending flunks subtracted)' },
    area_total: { type: 'integer', description: 'non-pending tests in this slice' },
    full_pass: { type: 'integer', description: 'total passing in the full mix test run' },
    full_fail: { type: 'integer', description: 'total failures in the full mix test run' },
    regressions: { type: 'string', description: 'any previously-green areas you broke, or "none"' },
    evidence: { type: 'string', description: 'the verbatim final summary line(s) of the mix test runs the numbers came from' },
    blockers: { type: 'array', items: { type: 'string' }, description: 'unresolved issues; prefix harness-caused ones with "harness_gap:"' },
  },
}

// Finalize has no slice — forcing it through REPORT would make it fabricate
// area_pass/area_total to satisfy the schema.
const FINALIZE_REPORT = {
  type: 'object',
  additionalProperties: false,
  required: ['summary', 'files_changed', 'full_pass', 'full_fail', 'excluded', 'gates_clean', 'regressions', 'evidence', 'blockers'],
  properties: {
    summary: { type: 'string', description: 'final tally + per-area failure breakdown + top open root causes' },
    files_changed: { type: 'array', items: { type: 'string' } },
    full_pass: { type: 'integer' },
    full_fail: { type: 'integer' },
    excluded: { type: 'integer' },
    gates_clean: { type: 'boolean', description: 'every CI gate (deps.unlock/format/hex.audit/compile/credo/docs) passed' },
    regressions: { type: 'string' },
    evidence: { type: 'string', description: 'verbatim final mix test summary line + which gates failed, if any' },
    blockers: { type: 'array', items: { type: 'string' }, description: 'unresolved issues; prefix harness-caused ones with "harness_gap:"' },
  },
}

// Baseline / re-baseline report: the facts the orchestration branches on.
const BASELINE = {
  type: 'object',
  additionalProperties: false,
  required: ['fixtures_load_ok', 'suite_runs', 'full_pass', 'full_fail', 'excluded', 'failing_areas', 'evidence', 'blockers'],
  properties: {
    fixtures_load_ok: { type: 'boolean', description: 'mix bier.fixtures.load succeeded' },
    suite_runs: { type: 'boolean', description: 'mix test executed to completion — failures are fine; compile errors / harness crashes are not' },
    full_pass: { type: 'integer' },
    full_fail: { type: 'integer' },
    excluded: { type: 'integer' },
    failing_areas: {
      type: 'array',
      description: 'one entry per conformance area with >=1 failure; empty when green',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['area', 'failures'],
        properties: { area: { type: 'string' }, failures: { type: 'integer' } },
      },
    },
    evidence: { type: 'string', description: 'verbatim final mix test summary line + how the per-area counts were derived' },
    blockers: { type: 'array', items: { type: 'string' }, description: 'what prevents the suite from running, if anything; prefix harness-caused failures with "harness_gap:"' },
  },
}

const BASELINE_TASK = `
TASK — establish the real current state; change NOTHING under lib/ (this pass is read-only apart from the test database):
1. Run 'mix bier.fixtures.load'. Report whether it succeeds.
2. Run the full 'mix test' ONCE and capture the output.
3. Derive per-area failure counts: every conformance test is tagged with its area
   (test/conformance/conformance_test.exs generates one test per spec/ case, each
   @tag area: :<area>). Map each failing test back to its area from the failure
   output / the case files under spec/conformance/cases — do NOT re-run the suite
   once per area (each 'mix test' invocation reloads the fixture DB; it's slow).
4. Classify obviously harness-shaped failures ("unknown key" assertion raises,
   missing sign_with JWT keys, PGRST106 on a schema label the loader doesn't
   build, undefined_table for a relation missing from the fixture DB) into
   blockers prefixed "harness_gap:" with their case ids — still count them in
   failing_areas, the orchestrator and the human gate need both views.
5. If the suite cannot run (fixture load fails, compile error, harness crash),
   set suite_runs=false and describe exactly what broke in blockers, with the
   error output in evidence.
Report honest numbers; paste the final test-summary line verbatim into evidence.`

// Canonical slice order + per-area focus notes. Determinism: failing areas are
// always worked in THIS order. Areas without an entry here still get a slice
// (with a generic focus) — the list is guidance, not a filter.
const SLICE_FOCUS = {
  url_grammar: 'path/method/percent-encoding edge cases, reserved params/characters, Accept/Content-Profile incl. 406 PGRST106, unicode schema names, multi-schema v1/v2',
  operators: 'the full comparison/pattern/fts/range/array operator set incl. the not. prefix and quoting',
  select: 'embedding via FK resolution, ::casts, json-path, computed columns, spread, aggregates (db-aggregates)',
  filters: 'logical and/or/not trees, json filters, quoting, embedded-resource filters',
  ordering: 'nulls first/last, json_path, computed columns, multi-column, related/embedded ordering, error cases',
  pagination: 'limit/offset, Range request header, Content-Range with exact/estimated/planned count (Prefer: count=), db-max-rows',
  content_negotiation: 'Accept negotiation & precedence; CSV (text/csv), GeoJSON, octet-stream, text; singular vnd.pgrst.object; nulls-stripped; custom media handlers; errors',
  representations: 'Prefer: return=representation|minimal, singular object responses, stripped nulls, Location header',
  mutations: 'POST/PATCH/PUT/DELETE, upsert (Prefer: resolution=merge|ignore-duplicates + on_conflict), columns param, missing-default, safe-update/safe-delete (require filter), Prefer: handling=, max-affected. Mind async shared-DB isolation (§1).',
  errors: 'SQLSTATE->HTTP mapping, exact PGRST codes/messages, RAISE handling, error response headers',
  rpc: 'GET/POST /rpc/<fn>, scalar/setof/composite/void returns, named args, overloaded fns, single unnamed json param, count/shape. Functions live in schema rpc — mirrored per §2.2.',
  auth: 'JWT verification, role switching, GUCs (request.jwt.claims, request.headers, ...), aud/exp validation, anonymous role',
  headers: 'Prefer, Accept/Content-Profile routing, Location, Content-Location, GUC-set response headers; exotic schema names',
  observability: 'Server-Timing header, trace-header passthrough, log-level behavior',
  domain_representations: 'CREATE DOMAIN cast-based read/write/filter/default representations',
  openapi: 'root OpenAPI doc generation: defaults, comments, table/types/rpc/security, modes (functions live in schema openapi)',
  config: 'non-CLI subset: sources/aliases/validation/coercion/precedence, db-max-rows, db-tx-end, app-settings, server CORS',
}
const SLICE_ORDER = Object.keys(SLICE_FOCUS)

function slicePrompt(area, failures, baselineEvidence) {
  return `You own the "${area}" conformance slice for Bier. ${RULES}

The baseline run found ${failures} failing test(s) in this area. Baseline evidence:
${baselineEvidence}

Read ${DOC} (esp. the row for "${area}" in §3 and the relevant parts of §4) and
this slice's cases: the spec/conformance/cases/*.yaml whose feature: starts with
"${area}" (grep -rl 'feature: ${area}' spec/conformance/cases/).
Focus areas: ${SLICE_FOCUS[area] || 'see the failing cases under spec/conformance/cases'}.

Build on the existing foundation + earlier slices already in lib/. Extend the
parser/executor/controller/renderer/introspection as needed; add to working
code, never rewrite it.

VERIFY with real output:
  mix test --only area:${area}
KNOWN QUIRK: '--only' RE-INCLUDES the :pending-tagged tests this suite normally
excludes, and those flunk unconditionally — their generated names contain
"(pending:". Subtract them from your failure count, exclude them from
area_pass/area_total (which count non-pending tests only), and NEVER attempt to
fix them.
Iterate until every non-pending, non-harness_gap case passes. Then run the FULL
'mix test' to check you didn't regress earlier areas (if you did, fix it). Then
mix format and mix compile --warnings-as-errors.

Return the structured report with REAL counts for area ${area} and the full
suite, and the verbatim summary lines in evidence.`
}

// ── Phase 1: Baseline ────────────────────────────────────────────────────────

phase('Baseline')
let base = null
try {
  base = await agent(
    `You are baselining the Bier conformance suite. ${RULES}
${BASELINE_TASK}`,
    { label: 'baseline', phase: 'Baseline', schema: BASELINE }
  )
} catch (e) {
  // A throw here is a runtime-lifecycle failure, not evidence the suite is
  // broken — return a structured report instead of dying, and do NOT send a
  // repair agent after a healthy suite.
  return { workflow: 'bier-conformance', outcome: 'errored', detail: `baseline agent threw: ${String(e)}` }
}
log(base
  ? `Baseline: ${base.full_pass} pass / ${base.full_fail} fail / ${base.excluded} excluded | failing areas: ${base.failing_areas.map((f) => `${f.area}(${f.failures})`).join(', ') || 'none'}`
  : 'Baseline agent returned no report')

// ── Phase 2: Foundation repair — only when the suite cannot run ─────────────

if (!base || !base.fixtures_load_ok || !base.suite_runs) {
  phase('Foundation repair')
  log('Suite cannot run — dispatching foundation repair')
  let repaired = null
  try {
    repaired = await agent(
      `The Bier conformance suite cannot currently run. ${RULES}

Baseline findings: ${JSON.stringify(base)}

TASK: repair whatever prevents 'mix bier.fixtures.load' and 'mix test' from
executing to completion — compile errors, fixture-loader failures against the
current spec/conformance/fixtures.sql (e.g. new schemas/roles the mirror logic
must cover), boot/introspection crashes. Consult ${DOC} for the architecture.
Fix lib//mix.exs/config/ only. Test FAILURES are fine at this stage — the later
slice agents work those down; your job ends when the full suite runs to
completion. If what blocks the run is harness-shaped (frozen test/** or spec/**
would have to change), record it as a "harness_gap:" blocker and stop — that
routes to the human gate.

When it runs, re-baseline exactly as follows and return the baseline-shaped report:
${BASELINE_TASK}`,
      { label: 'foundation:repair', phase: 'Foundation repair', schema: BASELINE }
    )
  } catch (e) {
    log(`Foundation repair threw: ${String(e)}`)
  }
  if (repaired) base = repaired
  if (!base || !base.suite_runs || !base.fixtures_load_ok) {
    // Nothing downstream can act without a runnable suite — report and stop.
    return {
      workflow: 'bier-conformance',
      outcome: 'blocked',
      detail: 'suite still cannot run after foundation repair',
      baseline: base ?? null,
      blockers: (base && base.blockers) || ['baseline and repair agents returned no report'],
    }
  }
  log(`Post-repair baseline: ${base.full_pass} pass / ${base.full_fail} fail | failing areas: ${base.failing_areas.map((f) => `${f.area}(${f.failures})`).join(', ') || 'none'}`)
}

// ── Phase 3: Feature slices — failing areas only, canonical order ───────────

const failureByArea = new Map(
  (base.failing_areas || []).filter((f) => f.failures > 0).map((f) => [f.area, f.failures])
)
// Canonical order first, then any area the baseline reported that we don't
// have a canonical position for (new areas after a spec re-sync), in report order.
const todo = SLICE_ORDER.filter((a) => failureByArea.has(a)).concat(
  [...failureByArea.keys()].filter((a) => !SLICE_ORDER.includes(a))
)

const sliceReports = []
if (todo.length === 0) {
  log('No failing areas — skipping feature slices')
} else {
  phase('Feature slices')
  log(`Working ${todo.length} failing area(s) sequentially: ${todo.join(', ')}`)
  for (const area of todo) {
    // Sequential on purpose: slices share one working tree (no merge
    // conflicts) and later slices build on earlier fixes. Each iteration is
    // caught so one thrown slice can't destroy the remaining slices' turn.
    let r = null
    try {
      r = await agent(slicePrompt(area, failureByArea.get(area), base.evidence), {
        label: `slice:${area}`,
        phase: 'Feature slices',
        schema: REPORT,
      })
    } catch (e) {
      log(`slice ${area}: agent threw: ${String(e)}`)
      r = { summary: `slice agent threw: ${String(e)}`, blockers: ['slice agent lost (threw)'] }
    }
    sliceReports.push({ area, ...(r || { summary: 'agent returned no report', blockers: ['slice agent lost'] }) })
    log(r && r.evidence
      ? `slice ${area}: ${r.area_pass}/${r.area_total} | full ${r.full_pass} pass / ${r.full_fail} fail | regress: ${r.regressions}`
      : `slice ${area}: no usable report`)
  }
}

// ── Phase 4: Finalize — always runs (the baseline never checks the CI gates) ─

phase('Finalize')
const finalizeContext = todo.length
  ? `Baseline: ${JSON.stringify({ full_pass: base.full_pass, full_fail: base.full_fail, failing_areas: base.failing_areas })}
Slice reports so far: ${JSON.stringify(sliceReports)}
`
  : `The baseline was green (${base.full_pass} pass / ${base.full_fail} fail) and no slices ran — this is a gate check.
`
let fin = null
try {
  fin = await agent(
    `Finalize the Bier conformance implementation. ${RULES}

${finalizeContext}
TASK:
1. Run the full CI gate set and capture real output:
   mix deps.unlock --check-unused ; mix format --check-formatted ; mix hex.audit ; mix compile --warnings-as-errors ; mix credo --strict ; mix docs --warnings-as-errors ; mix test
   (this mirrors the 'mix precommit' alias — run the gates individually so each reports separately)
2. Fix any cross-cutting regressions or gate failures you can (lib//mix.exs/config/ only). Do not touch test/** or spec/**.
3. Produce an HONEST final tally: total conformance cases, passing, failing, and excluded (:pending). Break down remaining failures by area and give the top recurring root causes still open (harness-shaped ones prefixed "harness_gap:").

Return the structured report; full_pass/full_fail/excluded must come from the
actual final 'mix test' output, with the verbatim summary line in evidence.`,
    { label: 'finalize', phase: 'Finalize', schema: FINALIZE_REPORT }
  )
} catch (e) {
  log(`Finalize agent threw: ${String(e)}`)
}
log(fin ? `FINAL: ${fin.full_pass} pass / ${fin.full_fail} fail | gates clean: ${fin.gates_clean} | ${fin.evidence}` : 'Finalize agent returned no report')

const harnessGaps = []
  .concat((base && base.blockers) || [], ...sliceReports.map((s) => s.blockers || []), (fin && fin.blockers) || [])
  .filter((b) => typeof b === 'string' && b.startsWith('harness_gap:'))

return {
  workflow: 'bier-conformance',
  outcome: fin && fin.full_fail === 0 && fin.gates_clean ? 'green' : 'failures_remain',
  harness_gaps_for_human_gate: harnessGaps,
  baseline: base,
  slices: sliceReports,
  finalize: fin ?? null,
}
