/**
 * bier-spec-audit — adversarial citation audit + fix for the bier spec/ tree
 * ===========================================================================
 *
 * A standalone run of Phase C (Cross-check) of docs/workflows/bier-spec.md,
 * for when the main bier-spec run produced spec/ but the adversarial review
 * did not complete for every area. For each area it:
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
 * After the per-area pipeline it RE-CONSOLIDATES spec/conformance/fixtures.sql
 * (to absorb fixer edits + any newly added area like domain_representations)
 * and REFRESHES spec/COVERAGE.md + spec/conformance/INDEX.md.
 *
 * Writes ONLY under spec/. Reuses the existing research on disk — auditors are
 * read-only; only the fix pass and the tail write.
 *
 * Runtime API: same as bier-spec.js — `export const meta` literal + top-level
 * body using agent()/pipeline()/parallel()/phase()/log(). agent() returns the
 * final message as a STRING; each agent ends with a fenced ```json block we
 * parse with parseJsonResult() (no schema: — these are heavy, long agents).
 */

export const meta = {
  name: "bier-spec-audit",
  description: "Adversarial citation audit of the bier spec/ tree: re-fetch every cited PostgREST source and verify it supports the claim, fix what's wrong, then re-consolidate fixtures and refresh COVERAGE/INDEX",
  whenToUse: "After a bier-spec run left areas un-cross-checked. Verifies cited lines actually support each claim; reuses on-disk research.",
  phases: [
    { title: "Audit", detail: "read-only reviewer per area re-fetches every cited source and verifies it" },
    { title: "Fix", detail: "revise areas only: correct/drop bad citations, add missing cases, re-audit once" },
    { title: "Consolidate", detail: "re-merge fixture fragments → spec/conformance/fixtures.sql" },
    { title: "Synthesize", detail: "refresh spec/COVERAGE.md + spec/conformance/INDEX.md" },
  ],
};

// ── Configuration ──────────────────────────────────────────────────────────

const PINNED = (args && args.pinned) || "v14.12";
const RAW = `https://raw.githubusercontent.com/PostgREST/postgrest/${PINNED}`;
const MAX_FIX_ROUNDS = 1; // audit → fix → re-audit (one fix round)

// Areas to audit: everything EXCEPT the two the main run already cross-checked
// (pagination, auth), PLUS the freshly-added domain_representations area.
const AUDIT_AREAS = [
  { key: "url_grammar", file: "url_grammar.md" },
  { key: "operators", file: "operators.yaml" },
  { key: "select", file: "select.yaml" },
  { key: "filters", file: "filters.yaml" },
  { key: "ordering", file: "ordering.yaml" },
  { key: "representations", file: "representations.yaml" },
  { key: "mutations", file: "mutations.yaml" },
  { key: "rpc", file: "rpc.yaml" },
  { key: "errors", file: "errors.yaml" },
  { key: "headers", file: "headers.yaml" },
  { key: "content_negotiation", file: "content_negotiation.yaml" },
  { key: "openapi", file: "openapi.yaml" },
  { key: "config", file: "config.yaml" },
  { key: "observability", file: "observability.yaml" },
  { key: "domain_representations", file: "domain_representations.yaml" },
];

// ── Result parsing (same robust JSON-block scrape as bier-spec.js) ───────────

function parseJsonResult(name, result) {
  const matches = [...String(result).matchAll(/```json\s*([\s\S]*?)```/g)];
  if (matches.length === 0) return { _unparsed: true, name, raw: String(result).slice(-2000) };
  try {
    return JSON.parse(matches[matches.length - 1][1]);
  } catch (e) {
    return { _unparsed: true, name, error: String(e), raw: matches[matches.length - 1][1] };
  }
}

// ── Prompt builders ─────────────────────────────────────────────────────────

function auditPrompt(area) {
  return `You are an adversarial Spec Reviewer for the Bier project, auditing the
on-disk spec/ output for the "${area.key}" PostgREST ${PINNED} area. You did NOT
write it; be skeptical — your job is to BREAK it, not bless it. You are
READ-ONLY: do not modify any file.

Repo: /Users/milmazz/Dev/elixir-lang/bier. Locate this area's material:
  - the behavior model: spec/${area.file}
  - its conformance cases: they are the spec/conformance/cases/*.yaml whose
    \`feature:\` field's leading segment is "${area.key}" (find them with e.g.
    grep -rl 'feature: ${area.key}' spec/conformance/cases/). Do NOT rely on id
    ranges — on-disk ids don't all follow a formula.

For EVERY entry in the model and EVERY case:
  1. RE-FETCH the cited \`source:\` URL (it is a ${RAW}/... raw link with a #Lnnn
     anchor) and read the cited line + surrounding context. Confirm it ACTUALLY
     supports the specific claim / expected status / header / body. Flag any
     citation that is missing, points to the wrong line, or contradicts the case.
  2. Check the PostgREST v14 docs page for this area for MAJOR public features
     that have NO case.
  3. Confirm each case validates against spec/case.schema.json.

Verdict "pass" ONLY if every citation genuinely supports its claim AND no major
feature is missing. Otherwise "revise" with specific, actionable issues (name the
case id and exactly what is wrong + the correct source if you found it).

End your final message with a single fenced json block (nothing after it):
\`\`\`json
{"area":"${area.key}","verdict":"pass","cases_checked":0,"issues":[{"case_id":"","problem":"","correct_source":""}],"bad_citations":[],"missing_features":[]}
\`\`\``;
}

function fixPrompt(area, issues) {
  return `You are the Spec Fixer for the Bier project, area "${area.key}"
(PostgREST ${PINNED}). An adversarial reviewer found problems. Fix every one,
writing ONLY under spec/ (never lib/, test/, mix.exs). Repo:
/Users/milmazz/Dev/elixir-lang/bier.

Reviewer issues:
- ${issues.map((x) => (typeof x === "string" ? x : `${x.case_id || "?"}: ${x.problem || ""}${x.correct_source ? ` (correct source: ${x.correct_source})` : ""}`)).join("\n- ")}

Rules:
  - Where a citation points to the wrong line but a real supporting line exists,
    correct the \`source:\` URL/anchor.
  - If a claim or case CANNOT be traced to a real ${PINNED} source line, DROP it
    (delete the case file / remove the entry) and record it under "dropped" with
    why. Do NOT guess or fabricate a citation.
  - For a missing major feature, ADD case(s) with real cited sources and any
    fixture rows they need in spec/conformance/fixtures/${area.key}.sql. Pick
    conformance ids that are currently unused (ls spec/conformance/cases/ first).
  - Every case must still validate against spec/case.schema.json and carry a
    raw.githubusercontent.com source URL with a #L anchor.

End your final message with a single fenced json block (nothing after it):
\`\`\`json
{"area":"${area.key}","fixed":[],"dropped":[],"added_cases":[],"remaining_gaps":[]}
\`\`\``;
}

const CONSOLIDATE_PROMPT = `You are the Fixture Consolidator for the Bier project.
Re-merge every spec/conformance/fixtures/*.sql fragment into a single, refreshed
spec/conformance/fixtures.sql that loads cleanly on Postgres 14, 15, and 16. The
fragments may have changed since the last consolidation (a fix pass edited some;
a new spec/conformance/fixtures/domain_representations.sql may have been added) —
regenerate from the current fragments, do not trust the old merged file:
- dedupe shared schemas/roles/tables/types, resolve naming collisions (rename +
  note), order DDL by dependency, keep a provenance header listing the fragments.
- if psql is available, verify it loads; otherwise do a careful static check.
Repo: /Users/milmazz/Dev/elixir-lang/bier. Write ONLY under spec/. End with a
fenced json block:
\`\`\`json
{"conflicts_resolved":[],"loads_clean":true,"verified_with":"psql|static-check","notes":[]}
\`\`\``;

function synthRefreshPrompt(auditSummary) {
  return `You are the Spec Synthesizer for the Bier project. The conformance cases
have changed (an audit fixed/dropped some, and a new domain_representations area
was added). REFRESH these to match what is on disk NOW — read the actual files,
do not trust stale counts. Repo: /Users/milmazz/Dev/elixir-lang/bier. Write ONLY
under spec/:
  - spec/COVERAGE.md          map every PostgREST v14 docs page -> covering case
                              ids; flag uncovered pages. ADD a "Scope decisions"
                              section recording: domain_representations is now
                              COVERED; connection_pool is OUT OF SCOPE (operational,
                              not observable over HTTP — point to the relevant
                              config keys instead); schema_cache and listener are
                              DEFERRED (testable only with a schema-reload-signal
                              harness, NOTIFY pgrst — note as future work).
  - spec/conformance/INDEX.md  refresh the area <-> case-ids <-> fixture-fragment
                              cross-reference and per-area counts (now 17 areas).
Also fold this audit summary into a short "Review status" note in COVERAGE.md
(which areas passed the adversarial citation audit):
${auditSummary}

End your final message with a single fenced json block:
\`\`\`json
{"total_cases":0,"covered_pages":0,"uncovered_pages":[],"areas_passed_audit":[],"open_gaps":[]}
\`\`\``;
}

// ── Per-area unit: audit → (fix → re-audit) ──────────────────────────────────

async function auditArea(area) {
  let review = {};
  let fix = null;
  try {
    const a = await agent(auditPrompt(area), { label: `audit:${area.key}`, phase: "Audit" });
    review = parseJsonResult(`audit:${area.key}`, a);

    if (review.verdict === "revise" && (review.issues || []).length) {
      for (let round = 0; round < MAX_FIX_ROUNDS; round++) {
        const f = await agent(fixPrompt(area, review.issues), { label: `fix:${area.key}`, phase: "Fix" });
        fix = parseJsonResult(`fix:${area.key}`, f);
        const re = await agent(auditPrompt(area), { label: `reaudit:${area.key}`, phase: "Fix" });
        review = parseJsonResult(`reaudit:${area.key}`, re);
        if (review.verdict === "pass" || review._unparsed) break;
      }
    }
  } catch (e) {
    return { area: area.key, review, fix, error: String(e) };
  }
  return { area: area.key, review, fix };
}

// ── Orchestration ────────────────────────────────────────────────────────────

log(`Auditing citations for ${AUDIT_AREAS.length} areas of PostgREST ${PINNED} (re-fetching every cited source)...`);

// Pipeline: each area's fix pass kicks off the moment its audit returns "revise",
// rather than waiting for the slowest auditor.
const results = (
  await pipeline(
    AUDIT_AREAS,
    (area) => auditArea(area),
  )
).filter(Boolean);

const gaps = [];
for (const r of results) {
  if (r.error) gaps.push({ area: r.area, kind: "area_errored", detail: r.error });
  if (r.review._unparsed) gaps.push({ area: r.area, kind: "audit_result_unparsed", detail: r.review.raw?.slice(0, 300) });
  for (const m of r.review.missing_features || []) gaps.push({ area: r.area, kind: "missing_feature", detail: m });
  for (const d of (r.fix && r.fix.dropped) || []) gaps.push({ area: r.area, kind: "dropped_untraceable", detail: d });
  for (const g of (r.fix && r.fix.remaining_gaps) || []) gaps.push({ area: r.area, kind: "unresolved_after_fix", detail: g });
  if (r.review.verdict === "revise") gaps.push({ area: r.area, kind: "still_revise_after_fix", detail: r.review.issues });
}

// Tail: re-consolidate fixtures, then refresh COVERAGE/INDEX. Sequential — the
// synthesis reads the post-fix on-disk state.
log("Re-consolidating fixtures and refreshing coverage...");
const consolidate = parseJsonResult(
  "consolidate",
  await agent(CONSOLIDATE_PROMPT, { label: "reconsolidate-fixtures", phase: "Consolidate" }),
);

const auditSummary = results
  .map((r) => `- ${r.area}: ${r.review.verdict || "?"}${(r.review.bad_citations || []).length ? ` (${(r.review.bad_citations || []).length} bad citations)` : ""}`)
  .join("\n");
const synthesis = parseJsonResult(
  "synthesize",
  await agent(synthRefreshPrompt(auditSummary), { label: "refresh-coverage", phase: "Synthesize" }),
);

const passed = results.filter((r) => r.review.verdict === "pass").length;
return {
  workflow: "bier-spec-audit",
  pinned_postgrest: PINNED,
  areas_audited: AUDIT_AREAS.length,
  areas_passing_audit: passed,
  bad_citations_found: results.reduce((n, r) => n + ((r.review.bad_citations || []).length), 0),
  total_conformance_cases: synthesis.total_cases ?? null,
  docs_pages_covered: synthesis.covered_pages ?? null,
  docs_pages_uncovered: synthesis.uncovered_pages ?? [],
  fixtures_load_clean: consolidate.loads_clean ?? null,
  gaps_for_human_review: gaps.concat((synthesis.open_gaps || []).map((g) => ({ kind: "synthesis_gap", detail: g }))),
  next: "Phase 2 (Tester): generate the failing ExUnit suite from spec/.",
};
