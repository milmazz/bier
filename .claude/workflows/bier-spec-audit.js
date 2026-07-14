/**
 * bier-spec-audit — adversarial citation audit + fix for the bier spec/ tree
 * ===========================================================================
 *
 * A standalone run of Phase C (Cross-check) of docs/workflows/bier-spec.md,
 * for re-verifying the spec/ tree without re-researching it (e.g. after a
 * bier-spec run left areas un-cross-checked, or as a periodic drift audit).
 * For each area it runs:
 *
 *   1. AUDIT  — a fresh, read-only reviewer locates the area's cases (by the
 *      `feature:` field, NOT a computed band — on-disk ids don't all follow the
 *      formula), RE-FETCHES every cited source URL, and confirms the cited line
 *      actually supports the claim. Flags wrong/missing citations + missing
 *      major features. Verdict pass | revise.
 *   2. FIX    — only on "revise": a writer corrects wrong citations, DROPS any
 *      untraceable claim (logging a gap — never guesses), and adds cases for
 *      missing major features; then a fresh reviewer re-audits once.
 *
 * After the per-area pipeline it folds any fixture deltas the fixers wrote
 * into the PRIMARY spec/conformance/fixtures.sql (never regenerating it from
 * the historical fragments), machine-VERIFIES the tree with real commands, and
 * REFRESHES spec/COVERAGE.md + spec/conformance/INDEX.md from disk.
 *
 * Writes ONLY under spec/. Reuses the existing research on disk — auditors are
 * read-only; only the fix pass and the tail write.
 *
 * Robustness / determinism notes (2026-07 revision, adversarially reviewed):
 *   - Structured outputs via the runtime's `schema:` option (validated +
 *     retried at the tool-call layer) replace the old ```json-fence scraping.
 *   - Defaults to ALL areas on disk; restrict with args.areas (unknown keys are
 *     reported; a run matching zero areas aborts before any agent spawns).
 *     args.pinned selects the PostgREST version (default "v14.12").
 *   - Fixtures: fixtures.sql is PRIMARY; fixers write new objects to per-area
 *     *.delta.sql files; fixtures_local.sql and the live loader inputs
 *     rpc.sql/headers.sql are untouchable (spec/conformance/fixtures/README.md).
 *   - Every lost agent — per-area AND the tail Consolidate/Verify/Synthesize —
 *     becomes an explicit gap; a lost re-auditor never erases the original
 *     audit findings; a lost fixer is reported as fix_agent_lost.
 *   - The Verify phase grounds fixture load / case validation / stale-pin
 *     citations / referenced relations in real command output.
 */

export const meta = {
  name: "bier-spec-audit",
  description: "Adversarial citation audit of the bier spec/ tree: re-fetch every cited PostgREST source and verify it supports the claim, fix what's wrong, then fold fixture deltas, machine-verify, and refresh COVERAGE/INDEX",
  whenToUse: "Re-verify spec/ citations without re-researching: after a bier-spec run left areas un-cross-checked, or as a drift audit against the pinned version (args.pinned, args.areas).",
  phases: [
    { title: "Audit", detail: "read-only reviewer per area re-fetches every cited source and verifies it" },
    { title: "Fix", detail: "revise areas only: correct/drop bad citations, add missing cases, re-audit once" },
    { title: "Consolidate", detail: "fold spec/conformance/fixtures/*.delta.sql into the primary fixtures.sql" },
    { title: "Verify", detail: "machine checks: fixture load, case-schema validation, ids, stale pins, referenced relations" },
    { title: "Synthesize", detail: "refresh spec/COVERAGE.md + spec/conformance/INDEX.md from disk" },
  ],
};

// ── Configuration ──────────────────────────────────────────────────────────

const PINNED = (args && args.pinned) || "v14.12";
const RAW = `https://raw.githubusercontent.com/PostgREST/postgrest/${PINNED}`;
const DOCS = `https://postgrest.org/en/v${PINNED.replace(/^v/, "").split(".")[0]}/`;
const MAX_FIX_ROUNDS = 1; // audit → fix → re-audit (one fix round)

// Every area in the spec/ tree. Restrict a run with args.areas (e.g.
// {areas: ["select", "rpc"]}) instead of editing this list.
const ALL_AREAS = [
  { key: "url_grammar", file: "url_grammar.md" },
  { key: "operators", file: "operators.yaml" },
  { key: "select", file: "select.yaml" },
  { key: "filters", file: "filters.yaml" },
  { key: "ordering", file: "ordering.yaml" },
  { key: "pagination", file: "pagination.yaml" },
  { key: "representations", file: "representations.yaml" },
  { key: "mutations", file: "mutations.yaml" },
  { key: "rpc", file: "rpc.yaml" },
  { key: "auth", file: "auth.yaml" },
  { key: "errors", file: "errors.yaml" },
  { key: "headers", file: "headers.yaml" },
  { key: "content_negotiation", file: "content_negotiation.yaml" },
  { key: "openapi", file: "openapi.yaml" },
  { key: "config", file: "config.yaml" },
  { key: "observability", file: "observability.yaml" },
  { key: "domain_representations", file: "domain_representations.yaml" },
];
const REQUESTED_AREAS = args && Array.isArray(args.areas) && args.areas.length ? args.areas : null;
const UNKNOWN_AREA_KEYS = REQUESTED_AREAS
  ? REQUESTED_AREAS.filter((k) => !ALL_AREAS.some((a) => a.key === k))
  : [];
const AUDIT_AREAS = REQUESTED_AREAS ? ALL_AREAS.filter((a) => REQUESTED_AREAS.includes(a.key)) : ALL_AREAS;

// ── Structured-output schemas ────────────────────────────────────────────────

const AUDIT_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["area", "verdict", "cases_checked", "issues", "missing_features"],
  properties: {
    area: { type: "string" },
    verdict: { type: "string", enum: ["pass", "revise"] },
    cases_checked: { type: "integer" },
    issues: { type: "array", items: { type: "string" }, description: 'actionable problems, each "<case id or entry>: <what is wrong> (correct source: <url>)"; empty when verdict is pass' },
    missing_features: { type: "array", items: { type: "string" } },
  },
};

const FIX_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["area", "fixed", "dropped", "added_cases", "remaining_gaps"],
  properties: {
    area: { type: "string" },
    fixed: { type: "array", items: { type: "string" } },
    dropped: { type: "array", items: { type: "string" }, description: "untraceable claims/cases removed, with why" },
    added_cases: { type: "array", items: { type: "string" } },
    remaining_gaps: { type: "array", items: { type: "string" }, description: "unresolved items, incl. `needed_assertion:` / `loader_exposure:` prefixed ones" },
  },
};

const CONSOLIDATE_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["deltas_folded", "conflicts_resolved", "loads_clean", "verified_with", "notes"],
  properties: {
    deltas_folded: { type: "array", items: { type: "string" }, description: "delta files folded into fixtures.sql and emptied; [] when none existed" },
    conflicts_resolved: { type: "array", items: { type: "string" } },
    loads_clean: { type: "boolean" },
    verified_with: { type: "string", enum: ["mix bier.fixtures.load", "psql", "static-check"] },
    notes: { type: "array", items: { type: "string" } },
  },
};

const VERIFY_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["fixtures_load_ok", "cases_schema_valid", "invalid_cases", "duplicate_ids", "stale_pin_citations", "missing_relations", "case_count", "evidence"],
  properties: {
    fixtures_load_ok: { type: "boolean" },
    cases_schema_valid: { type: "boolean" },
    invalid_cases: { type: "array", items: { type: "string" } },
    duplicate_ids: { type: "array", items: { type: "string" } },
    stale_pin_citations: { type: "array", items: { type: "string" }, description: "files/case ids whose source: URL references any PostgREST version other than the pinned one" },
    missing_relations: { type: "array", items: { type: "string" }, description: "relations/functions referenced by case request paths that do not exist in the loaded DB" },
    case_count: { type: "integer" },
    evidence: { type: "string", description: "the exact command tails these facts came from" },
  },
};

const SYNTH_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["total_cases", "covered_pages", "uncovered_pages", "areas_passed_audit", "open_gaps"],
  properties: {
    total_cases: { type: "integer" },
    covered_pages: { type: "integer" },
    uncovered_pages: { type: "array", items: { type: "string" } },
    areas_passed_audit: { type: "array", items: { type: "string" } },
    open_gaps: { type: "array", items: { type: "string" } },
  },
};

// ── Prompt builders ─────────────────────────────────────────────────────────

function auditPrompt(area) {
  return `You are an adversarial Spec Reviewer for the Bier project, auditing the
on-disk spec/ output for the "${area.key}" area of PostgREST ${PINNED}. You did
NOT write it; be skeptical — your job is to BREAK it, not bless it. You are
READ-ONLY: do not modify any file. Work from the repository root (the current
directory).

Locate this area's material:
  - the behavior model: spec/${area.file}
  - its conformance cases: they are the spec/conformance/cases/*.yaml whose
    \`feature:\` field's leading segment is "${area.key}" (find them with e.g.
    grep -rl 'feature: ${area.key}' spec/conformance/cases/). Do NOT rely on id
    ranges — on-disk ids don't all follow a formula.

For EVERY entry in the model and EVERY case:
  1. RE-FETCH the cited \`source:\` URL and read the cited line + surrounding
     context. It must be a ${RAW}/... raw link with a #Lnnn anchor — flag any
     citation that is missing, points at a DIFFERENT PostgREST version, points
     to the wrong line, or contradicts the claim / expected status / header /
     body.
  2. Check the PostgREST docs (${DOCS}) page for this area for MAJOR public
     features that have NO case.
  3. Confirm each case validates against spec/case.schema.json, and flag any
     case whose expected body contradicts the CONSOLIDATED seed data (the
     loaded bier_test / spec/conformance/fixtures.sql — e.g. test.items is rows
     1..15), which is the seed ground truth — not the historical fragment files.

Verdict "pass" ONLY if every citation genuinely supports its claim at ${PINNED}
AND no major feature is missing. Otherwise "revise", with each issue formatted
"<case id or entry>: <what is wrong> (correct source: <url>)" so a fixer can act
on it without re-deriving your work.`;
}

function fixPrompt(area, issues) {
  return `You are the Spec Fixer for the Bier project, area "${area.key}"
(PostgREST ${PINNED}). An adversarial reviewer found problems. Fix every one.
Work from the repository root (the current directory).

AUTHORIZATION: CLAUDE.md declares spec/ frozen — that freeze governs
conformance-IMPLEMENTATION work. This run is the operator-approved spec audit;
you MAY write under spec/ within the rules below. You may still never touch
lib/, test/, or mix.exs.

Reviewer issues:
- ${issues.join("\n- ")}

Rules:
  - Where a citation points to the wrong line or version but a real supporting
    ${PINNED} line exists, correct the \`source:\` URL/anchor.
  - If a claim or case CANNOT be traced to a real ${PINNED} source line, DROP it
    (delete the case file / remove the entry) and record it under "dropped" with
    why. Do NOT guess or fabricate a citation.
  - For a missing major feature, ADD case(s) with real cited sources. Pick
    conformance ids that are currently unused (ls spec/conformance/cases/ first).
  - FIXTURE RULES (spec/conformance/fixtures/README.md is authoritative):
    seed-data ground truth is the CONSOLIDATED database built by
    'mix bier.fixtures.load' (e.g. test.items has rows 1..15) — verify expected
    bodies against it, never against a historical fragment. NEVER edit
    spec/conformance/fixtures.sql, fixtures_local.sql, or any existing
    fixtures/*.sql (rpc.sql/headers.sql are LIVE loader inputs). New fixture
    objects go ONLY in spec/conformance/fixtures/${area.key}.delta.sql (new
    objects only). If an object would need exposure under the rpc/headers area
    schemas or a NEW \`schema:\` label, record it under remaining_gaps prefixed
    "loader_exposure:" instead of improvising.
  - A case's \`schema:\` field is a fixture-set LABEL sent as an Accept-Profile
    header, not a file; use only labels that already exist in other cases.
  - Every case must still validate against spec/case.schema.json and carry a
    raw.githubusercontent.com ${PINNED} source URL with a #L anchor. If a
    behavior cannot be expressed with the existing case.schema.json keys, do
    NOT approximate it with a weaker assertion — record it under remaining_gaps
    prefixed "needed_assertion:".`;
}

const CONSOLIDATE_PROMPT = `You are the Fixture Consolidator for the Bier project.
spec/conformance/fixtures.sql is the PRIMARY fixture artifact. NEVER regenerate
it from the historical fixtures/*.sql fragments — it embeds merge decisions
(superset seeds, renames, later additions) that exist only in it and that the
frozen case expectations depend on (spec/conformance/fixtures/README.md is
authoritative). Work from the repository root; write ONLY under spec/.

Your job: fold every spec/conformance/fixtures/*.delta.sql into fixtures.sql.
- Integrate each delta's objects at the dependency-correct position, deduping
  against what fixtures.sql already has; resolve real collisions by renaming
  (note each one).
- After folding a delta and verifying the load, EMPTY that delta file down to a
  one-line comment recording the fold (do not delete the file).
- NEVER touch fixtures_local.sql (human-owned), rpc.sql/headers.sql (live
  loader inputs), or any other historical fragment.
- Verify the result loads, preferring in this order: 'mix bier.fixtures.load'
  (its normal behavior is to drop+recreate the local bier_test database), else
  psql into a throwaway database, else a careful static check. Report which.
If there are NO delta files, just run the load verification on the current
fixtures.sql and report deltas_folded: [].`;

const VERIFY_PROMPT = `You are the Spec Verifier for the Bier project — a
machine-check pass, not a judgment call. Work from the repository root. Do NOT
modify any file in the repository; throwaway scripts go OUTSIDE the repo (e.g.
your scratchpad or /tmp). Run these checks and report FACTS from real command
output — if a check cannot run, report its flag as false (or its list as
["check-not-run: <why>"]) and say why in "evidence":
  1. Fixture load: run 'mix bier.fixtures.load' (dropping+recreating the local
     bier_test database is its normal, intended behavior). If mix or Postgres is
     unavailable, fall back to loading spec/conformance/fixtures.sql plus
     spec/conformance/fixtures_local.sql with psql into a throwaway database.
  2. Case schema: validate EVERY spec/conformance/cases/*.yaml against
     spec/case.schema.json (e.g. python3 with pyyaml+jsonschema, or
     check-jsonschema). List every invalid case id.
  3. Id uniqueness: confirm every case id is unique across the tree; list dupes.
  4. Stale pins: grep every \`source:\` URL in spec/*.yaml, spec/*.md and
     spec/conformance/cases/*.yaml — list every file/case whose URL references
     a PostgREST version tag other than ${PINNED}.
  5. Referenced relations: extract the relation each case's request path
     targets (the first path segment; /rpc/<fn> targets function <fn>) and
     confirm it exists in the loaded database under the case's \`schema:\`
     label (or \`test\` when the label is null/public/test). List the missing
     ones as "<case id>: <schema>.<relation>".
  6. Count the case files.
Put the exact command tails you relied on in "evidence".`;

function synthRefreshPrompt(auditSummary, verify) {
  return `You are the Spec Synthesizer for the Bier project. The conformance
cases may have changed (an audit fixed, dropped, or added some). REFRESH these
to match what is on disk NOW — read the actual files, do not trust stale counts.
Work from the repository root; write ONLY under spec/:
  - spec/COVERAGE.md          map every PostgREST docs page (${DOCS}) -> covering
                              case ids; flag uncovered pages. PRESERVE the
                              existing "Scope decisions" section verbatim unless
                              it contradicts what is now on disk (then update it
                              and say so in your report's open_gaps).
  - spec/conformance/INDEX.md refresh the area <-> case-ids <-> fixture
                              cross-reference and per-area counts from the
                              actual files on disk.
Also fold this audit summary into a short "Review status" note in COVERAGE.md
(which areas passed the adversarial citation audit, and when):
${auditSummary}

Machine-verification facts (record failures honestly in COVERAGE.md):
${JSON.stringify(verify)}`;
}

// ── Per-area unit: audit → (fix → re-audit) ──────────────────────────────────

async function auditArea(area) {
  let review = null;
  let fix = null;
  let fixAttempted = false;
  let fixLost = false;
  try {
    review = await agent(auditPrompt(area), { label: `audit:${area.key}`, phase: "Audit", schema: AUDIT_SCHEMA });

    if (review && review.verdict === "revise" && (review.issues || []).length) {
      for (let round = 0; round < MAX_FIX_ROUNDS; round++) {
        fixAttempted = true;
        fix = await agent(fixPrompt(area, review.issues), { label: `fix:${area.key}`, phase: "Fix", schema: FIX_SCHEMA });
        if (!fix) fixLost = true;
        const re = await agent(auditPrompt(area), { label: `reaudit:${area.key}`, phase: "Fix", schema: AUDIT_SCHEMA });
        // A lost re-auditor must not overwrite the original findings.
        if (re) review = re;
        if (!re || review.verdict === "pass" || !(review.issues || []).length) break;
      }
    }
  } catch (e) {
    return { area: area.key, review, fix, fixAttempted, fixLost, error: String(e) };
  }
  return { area: area.key, review, fix, fixAttempted, fixLost };
}

// ── Orchestration ────────────────────────────────────────────────────────────

if (UNKNOWN_AREA_KEYS.length) {
  log(`args.areas contains unknown keys (ignored): ${UNKNOWN_AREA_KEYS.join(", ")}`);
}
if (AUDIT_AREAS.length === 0) {
  // Abort BEFORE any agent runs — otherwise the tail would still rewrite
  // fixtures/COVERAGE/INDEX for a run that audited nothing.
  return {
    workflow: "bier-spec-audit",
    error: "args.areas matched no known areas — nothing to do",
    unknown_area_keys: UNKNOWN_AREA_KEYS,
    known_area_keys: ALL_AREAS.map((a) => a.key),
  };
}

log(`Auditing citations for ${AUDIT_AREAS.length} areas of PostgREST ${PINNED} (re-fetching every cited source)...`);

// Pipeline: each area's fix pass kicks off the moment its audit returns "revise",
// rather than waiting for the slowest auditor.
const slots = await pipeline(AUDIT_AREAS, (area) => auditArea(area));

// pipeline() preserves input order, so slot i corresponds to AUDIT_AREAS[i]; a
// null slot (skipped / terminally-errored agent) is recorded, never dropped.
const gaps = [];
const results = [];
slots.forEach((slot, i) => {
  if (!slot) {
    log(`area ${AUDIT_AREAS[i].key}: agent slot returned null (skipped or terminal error)`);
    gaps.push({ area: AUDIT_AREAS[i].key, kind: "area_agent_lost", detail: "pipeline slot returned null (agent skipped mid-run or died after retries)" });
    return;
  }
  results.push(slot);
  const review = slot.review || {};
  if (slot.error) gaps.push({ area: slot.area, kind: "area_errored", detail: slot.error });
  if (!slot.review) gaps.push({ area: slot.area, kind: "audit_report_missing", detail: "audit agent returned no structured report; area is unverified" });
  if (slot.fixLost) gaps.push({ area: slot.area, kind: "fix_agent_lost", detail: "fix agent returned no structured report; the re-audit ran against a possibly-unfixed tree" });
  for (const m of review.missing_features || []) gaps.push({ area: slot.area, kind: "missing_feature", detail: m });
  for (const d of (slot.fix && slot.fix.dropped) || []) gaps.push({ area: slot.area, kind: "dropped_untraceable", detail: d });
  for (const g of (slot.fix && slot.fix.remaining_gaps) || []) gaps.push({ area: slot.area, kind: "unresolved_after_fix", detail: g });
  if (review.verdict === "revise") {
    gaps.push({
      area: slot.area,
      kind: slot.fixAttempted ? "still_revise_after_fix" : "revise_without_actionable_issues",
      issues: review.issues || [],
    });
  }
});

// Tail: fold fixture deltas, machine-verify, then refresh COVERAGE/INDEX.
// Sequential — each step reads the on-disk state the previous one produced.
log("Folding fixture deltas → spec/conformance/fixtures.sql");
const consolidateResult = await agent(CONSOLIDATE_PROMPT, { label: "consolidate-fixtures", phase: "Consolidate", schema: CONSOLIDATE_SCHEMA });
if (!consolidateResult) gaps.push({ kind: "consolidate_agent_lost", detail: "consolidator returned no report — delta files may be unfolded; inspect spec/conformance/fixtures/*.delta.sql" });
else if (consolidateResult.loads_clean === false) gaps.push({ kind: "fixtures_reported_unclean", detail: (consolidateResult.notes || []).join("; ") || "consolidator reported loads_clean=false" });
const consolidate = consolidateResult || {};

log("Verifying spec/ tree: fixture load, case schema, ids, stale pins, referenced relations");
const verifyResult = await agent(VERIFY_PROMPT, { label: "verify-spec-tree", phase: "Verify", schema: VERIFY_SCHEMA });
if (!verifyResult) gaps.push({ kind: "verify_agent_lost", detail: "verify agent returned no report — the tree is UNVERIFIED; do not proceed on green assumptions" });
const verify = verifyResult || {};
if (verify.fixtures_load_ok === false) gaps.push({ kind: "fixtures_do_not_load", detail: verify.evidence || "see verify agent output" });
if (verify.cases_schema_valid === false) gaps.push({ kind: "cases_fail_schema", detail: (verify.invalid_cases || []).join(", ") });
if ((verify.duplicate_ids || []).length) gaps.push({ kind: "duplicate_case_ids", detail: verify.duplicate_ids.join(", ") });
if ((verify.stale_pin_citations || []).length) gaps.push({ kind: "stale_pin_citations", detail: verify.stale_pin_citations.join(", ") });
if ((verify.missing_relations || []).length) gaps.push({ kind: "cases_reference_missing_relations", detail: verify.missing_relations.join(", ") });

const auditSummary = results
  .map((r) => {
    const review = r.review || {};
    const issueCount = (review.issues || []).length;
    return `- ${r.area}: ${review.verdict || "unaudited"}${issueCount ? ` (${issueCount} open issues)` : ""}${r.fixAttempted ? " [fix pass ran]" : ""}`;
  })
  .join("\n");
const synthesisResult = await agent(synthRefreshPrompt(auditSummary, verify), { label: "refresh-coverage", phase: "Synthesize", schema: SYNTH_SCHEMA });
if (!synthesisResult) gaps.push({ kind: "synthesize_agent_lost", detail: "synthesis agent returned no report — COVERAGE/INDEX may be stale" });
const synthesis = synthesisResult || {};

const passed = results.filter((r) => r.review && r.review.verdict === "pass").length;
return {
  workflow: "bier-spec-audit",
  pinned_postgrest: PINNED,
  areas_audited: AUDIT_AREAS.length,
  areas_passing_audit: passed,
  unknown_area_keys: UNKNOWN_AREA_KEYS,
  open_issues_after_audit: results.reduce((n, r) => n + (((r.review || {}).verdict === "revise" ? (r.review.issues || []).length : 0)), 0),
  total_conformance_cases: synthesis.total_cases ?? null,
  docs_pages_covered: synthesis.covered_pages ?? null,
  docs_pages_uncovered: synthesis.uncovered_pages ?? [],
  fixtures_load_ok: verify.fixtures_load_ok ?? null,
  cases_schema_valid: verify.cases_schema_valid ?? null,
  stale_pin_citations: verify.stale_pin_citations ?? null,
  missing_relations: verify.missing_relations ?? null,
  verified_case_count: verify.case_count ?? null,
  verify_evidence: verify.evidence ?? null,
  fixture_deltas_folded: consolidate.deltas_folded ?? [],
  fixture_conflicts_resolved: consolidate.conflicts_resolved ?? [],
  gaps_for_human_review: gaps.concat((synthesis.open_gaps || []).map((g) => ({ kind: "synthesis_gap", detail: g }))),
  next: "Human gate: review the audit diff and needed_assertion:/loader_exposure: gaps, sync the test harness if needed, then run bier-conformance.",
};
