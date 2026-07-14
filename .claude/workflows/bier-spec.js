/**
 * bier-spec — PostgREST spec-research fan-out (Phase 1 of docs/AGENT_PLAN.md)
 * ===========================================================================
 *
 * A dynamic workflow that researches PostgREST's public behavior and lays down
 * — or, when spec/ already exists, RE-SYNCS — the `spec/` tree: one subagent
 * per feature area researches + drafts (or re-verifies against the pinned
 * version and tops up), a fresh adversarial reviewer cross-checks each area's
 * findings against cited PostgREST source (re-dispatching the researcher on a
 * "revise" verdict, up to MAX_REVISIONS), the fixture deltas are folded into
 * the primary fixtures.sql, a machine-check Verify pass validates the tree
 * with real commands, and the result is synthesized into COVERAGE.md.
 *
 * Design source of truth: docs/workflows/bier-spec.md (read it before editing).
 * Writes ONLY under spec/. Does not touch lib/, test/, or mix.exs.
 *
 * Robustness / determinism notes (2026-07 revision, adversarially reviewed):
 *   - Agent results use the runtime's `schema:` StructuredOutput option —
 *     validation happens at the tool-call layer and the model retries on
 *     mismatch. Schemas are deliberately SMALL (counts + gaps, not full entry
 *     dumps) so heavy research agents aren't asked to reproduce their on-disk
 *     work in the report.
 *   - agent() returns null when a subagent is skipped mid-run or dies on a
 *     terminal error; every null — including the tail Consolidate/Verify/
 *     Synthesize agents — becomes an explicit gap in the report.
 *   - Fixtures: spec/conformance/fixtures.sql is the PRIMARY artifact and is
 *     never regenerated from the historical fragments (they lack objects and
 *     seed-merge decisions the frozen expectations depend on). Researchers
 *     write new fixture objects to per-area *.delta.sql files (parallel-safe);
 *     the sequential Consolidator folds them in. fixtures_local.sql and the
 *     live loader inputs rpc.sql/headers.sql are human-owned and untouchable.
 *     See spec/conformance/fixtures/README.md.
 *   - The Verify phase turns "fixtures load" / "cases validate" / "citations
 *     point at the pinned version" / "referenced relations exist" into facts
 *     from real command output instead of agent self-reports.
 *   - Version-parametric: args.pinned (default "v14.12") drives every source
 *     URL including the docs major version; args.areas (e.g. ["select","rpc"])
 *     restricts the run to a subset (unknown keys are reported, and a run
 *     matching zero areas aborts before spawning any agent).
 *   - Case ids: agents locate an area's EXISTING cases by the `feature:` field
 *     (on-disk ids don't all follow the band formula); NEW ids come from the
 *     area's band computed from its position in ALL_AREAS (stable under
 *     args.areas subsets), with a closed per-area overflow range, so parallel
 *     areas can't collide.
 *   - Research is idempotent: an agent that finds its area's spec on disk
 *     syncs/tops up rather than regenerating, so a re-run after a partial
 *     failure is cheap.
 */

export const meta = {
  name: "bier-spec",
  description: "PostgREST spec-research fan-out: one agent per feature area writes or re-syncs spec/, a fresh adversarial reviewer cross-checks cited sources, then fold fixture deltas, machine-verify the tree, and synthesize COVERAGE.md",
  whenToUse: "Build the spec/ tree from PostgREST's public behavior, or re-sync an existing spec/ tree to a new pinned PostgREST version (pass args.pinned).",
  phases: [
    { title: "Research", detail: "1 agent / feature area → spec/<area>.yaml + conformance cases + fixture delta (sync mode when spec/ exists)" },
    { title: "Cross-check", detail: "fresh adversarial reviewer per area re-verifies every citation; revise loop ≤2 rounds" },
    { title: "Consolidate", detail: "fold spec/conformance/fixtures/*.delta.sql into the primary fixtures.sql" },
    { title: "Verify", detail: "machine checks: fixture load, case-schema validation, id uniqueness, stale-pin citations, referenced relations" },
    { title: "Synthesize", detail: "spec/README.md, COVERAGE.md, conformance/INDEX.md refreshed from disk" },
  ],
};

// ── Configuration ──────────────────────────────────────────────────────────

const PINNED = (args && args.pinned) || "v14.12"; // PostgREST version this run specs (override via args.pinned)
const REPO = "https://github.com/PostgREST/postgrest";
const RAW = `https://raw.githubusercontent.com/PostgREST/postgrest/${PINNED}`;
const DOCS = `https://postgrest.org/en/v${PINNED.replace(/^v/, "").split(".")[0]}/`;
const MAX_REVISIONS = 2; // adversarial revise rounds per area before escalating to the gap list

// The research units. One agent owns one area and writes spec/<key>.<ext>.
// `scope` is fed verbatim into the agent prompt — keep it concrete.
// ORDER MATTERS: an area's position here fixes its new-case id band forever;
// append new areas at the end, never reorder.
const ALL_AREAS = [
  { key: "url_grammar", file: "url_grammar.md", scope: "path -> schema/table/row resolution, reserved query params, percent-encoding, the full request grammar" },
  { key: "operators", file: "operators.yaml", scope: "eq gt gte lt lte neq like ilike match imatch in is isdistinct fts plfts phfts wfts cs cd ov sl sr nxr nxl adj, plus the `not` prefix; each with pg_op, type constraints, examples" },
  { key: "select", file: "select.yaml", scope: "columns, alias, ::cast, JSON paths ->/->>, embeds (one-to-many, many-to-one, many-to-many via junction), !inner/!left, disambiguation hints, spread ...embed, computed columns, aggregate functions" },
  { key: "filters", file: "filters.yaml", scope: "horizontal filters, logical and/or/not, grouping & precedence, value quoting, JSON arrow filters, filtering on embedded resources" },
  { key: "ordering", file: "ordering.yaml", scope: "asc/desc, nullsfirst/nullslast, embed.order=, ordering on computed and aggregate columns" },
  { key: "pagination", file: "pagination.yaml", scope: "limit/offset, Range request header, Content-Range response header, Prefer: count=exact|planned|estimated" },
  { key: "representations", file: "representations.yaml", scope: "Prefer: return=minimal|headers-only|representation; which status code and body each resolution yields" },
  { key: "mutations", file: "mutations.yaml", scope: "POST/PATCH/PUT/DELETE body shapes, bulk ops, upsert (resolution=merge-duplicates|ignore-duplicates), on_conflict, missing=default, columns= param, limited update/delete" },
  { key: "rpc", file: "rpc.yaml", scope: "/rpc/<fn>: GET vs POST, scalar vs SETOF, single-row, Prefer: params=single-object, variadic, named & default args, void returns, table-valued functions" },
  { key: "auth", file: "auth.yaml", scope: "JWT verify (HS256/RS256/ES256/EdDSA/JWKS), role switching, db-pre-request, GUCs (request.jwt.claims, request.headers, request.cookies, request.method, request.path), aud/exp validation" },
  { key: "errors", file: "errors.yaml", scope: "PG SQLSTATE -> HTTP status map, error body shape {code,message,details,hint}, RAISE/PTxxx custom errors" },
  { key: "headers", file: "headers.yaml", scope: "request + response headers, Prefer echo, Content-Profile/Accept-Profile schema switching, Location on insert, Content-Location" },
  { key: "content_negotiation", file: "content_negotiation.yaml", scope: "application/json, text/csv, application/vnd.pgrst.object+json (single object), GeoJSON, OpenAPI, application/octet-stream (bytea), application/vnd.pgrst.plan (EXPLAIN)" },
  { key: "openapi", file: "openapi.yaml", scope: "OpenAPI document generation rules, descriptions sourced from COMMENTs, security schemes" },
  { key: "config", file: "config.yaml", scope: "every PostgREST config key + semantics: db-uri, db-schemas, db-anon-role, jwt-secret, jwt-aud, db-max-rows, server-port, and the rest" },
  { key: "observability", file: "observability.yaml", scope: "log format, log-level, Server-Timing header, metrics/traces surface" },
  { key: "domain_representations", file: "domain_representations.yaml", scope: "CREATE DOMAIN + CREATE CAST 'domain representation' conversions: read casts (to json/text), write casts (from json/text), filtering on the underlying value, defaults, interaction with select/mutations" },
];
const REQUESTED_AREAS = args && Array.isArray(args.areas) && args.areas.length ? args.areas : null;
const UNKNOWN_AREA_KEYS = REQUESTED_AREAS
  ? REQUESTED_AREAS.filter((k) => !ALL_AREAS.some((a) => a.key === k))
  : [];
const AREAS = REQUESTED_AREAS ? ALL_AREAS.filter((a) => REQUESTED_AREAS.includes(a.key)) : ALL_AREAS;

// New-case id allocation: the band is derived from the area's position in
// ALL_AREAS (NOT the filtered run list), so a subset run can never squat
// another area's band. Overflow is a CLOSED per-area range for the same reason.
function idBands(areaKey) {
  const idx = ALL_AREAS.findIndex((a) => a.key === areaKey);
  const band = 1000 + idx * 50;
  const overflow = 10000 + idx * 200;
  return { band, bandEnd: band + 49, overflow, overflowEnd: overflow + 199 };
}

// ── Structured-output schemas ────────────────────────────────────────────────
// Kept small on purpose: the real deliverable is what the agents write under
// spec/; the report only needs enough to steer the revise loop and the tail.

const RESEARCH_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["area", "files_written", "cases_touched", "gaps"],
  properties: {
    area: { type: "string" },
    files_written: { type: "array", items: { type: "string" }, description: "spec/ paths created or edited this pass (empty if everything was already correct)" },
    cases_touched: { type: "array", items: { type: "string" }, description: "conformance case ids added, updated, or verified-unchanged this pass" },
    gaps: { type: "array", items: { type: "string" }, description: "untraceable behaviors omitted/dropped, plus `needed_assertion:` and `loader_exposure:` items (see prompt)" },
  },
};

const REVIEW_SCHEMA = {
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
  required: ["total_cases", "covered_pages", "uncovered_pages", "open_gaps"],
  properties: {
    total_cases: { type: "integer" },
    covered_pages: { type: "integer" },
    uncovered_pages: { type: "array", items: { type: "string" } },
    open_gaps: { type: "array", items: { type: "string" } },
  },
};

// ── Prompt builders ─────────────────────────────────────────────────────────

function researchPrompt(area, priorIssues) {
  const { band, bandEnd, overflow, overflowEnd } = idBands(area.key);
  const revising = priorIssues && priorIssues.length;
  return `You are the Spec Researcher for the Bier project, working ONLY on the
"${area.key}" feature area of PostgREST ${PINNED}. Read docs/AGENT_PLAN.md §5.1
for the exact deliverable shapes. Work from the repository root (the current
directory).

AUTHORIZATION: CLAUDE.md declares spec/ frozen — that freeze governs
conformance-IMPLEMENTATION work. This run is the operator-approved spec
re-sync; you MAY write under spec/ within the rules below. You may still never
touch lib/, test/, or mix.exs.

Area scope: ${area.scope}

SYNC MODE (the usual case): spec/${area.file} and this area's cases probably
already exist, researched against an OLDER PostgREST version — spec/README.md
records the previous pin. Do NOT regenerate from scratch, and do NOT re-derive
everything by hand; work the DIFF:
  - clone both pins shallow (git clone --depth 1 --branch <tag> ${REPO}) and run
    git diff <previous-pin>..${PINNED} -- test/spec/ src/ to find what actually
    changed; docs changes: ${DOCS};
  - locate this area's existing cases by their \`feature:\` field, e.g.
    grep -rl 'feature: ${area.key}' spec/conformance/cases/ — NEVER assume id
    ranges; on-disk ids don't all follow a formula;
  - update every \`source:\` citation to a ${PINNED} anchor: for files the diff
    shows unchanged, re-anchor (line numbers may still shift — confirm the
    anchored line's content matches the claim); for changed files, re-verify
    the behavior itself;
  - fix behavior that changed between pins, add cases for features new in
    ${PINNED}, and drop entries/cases whose behavior no longer exists (record
    each drop under "gaps" with why);
  - leave files you verified as correct untouched.
Only do full from-scratch research if this area's files are absent.

Ground truth, in priority order:
  1. PostgREST tests:    ${RAW}/test/spec/Feature/...  (+ test/spec/fixtures/*.sql)
  2. PostgREST source:   ${RAW}/src/...
  3. PostgREST docs:     ${DOCS}   (behavior the tests imply)

Deliverables, under spec/:
  - spec/${area.file}                        the behavior model for this area
  - spec/conformance/cases/NNNN_<slug>.yaml  >=1 black-box case per public feature,
       in the AGENT_PLAN.md §5.1 case shape (id, feature, request, schema,
       preconditions, expect{status,headers,body_*}, notes, source)
  - spec/conformance/fixtures/${area.key}.delta.sql  ONLY if your new/changed
       cases need fixture objects that don't exist yet (see FIXTURE RULES)
For NEW cases only: allocate unused ids from [${band} .. ${bandEnd}]; if that
band is exhausted, use ONLY [${overflow} .. ${overflowEnd}] (this area's closed
overflow range — never stray outside it). Never renumber existing cases.

FIXTURE RULES (spec/conformance/fixtures/README.md is authoritative):
  - Seed-data ground truth is the CONSOLIDATED database as built by
    'mix bier.fixtures.load' (e.g. test.items has rows 1..15 — a superset of
    what any historical fragment seeds). Derive and verify every expected body
    against a freshly loaded bier_test, NEVER against a fragment file.
  - NEVER edit spec/conformance/fixtures.sql, fixtures_local.sql, or any
    existing fixtures/*.sql (rpc.sql and headers.sql are LIVE loader inputs
    with fragile invariants). New fixture objects go ONLY in
    spec/conformance/fixtures/${area.key}.delta.sql — new objects only, never
    DDL that duplicates what fixtures.sql already has. The consolidator folds
    deltas in after the fan-out.
  - A case's \`schema:\` field is a fixture-set LABEL the frozen harness sends
    as an Accept-Profile header — NOT a file to load. Use only labels that
    already exist on disk in other cases (test, operators, ordering, ..., rpc,
    headers, auth). If a new behavior would need a NEW label or needs an object
    exposed under the rpc/headers area schemas (which are built from the live
    loader inputs, not mirrored), do NOT invent it — record a gap prefixed
    "loader_exposure:" describing what the loader would need to expose.

HARD RULES:
  - Every entry and every case MUST carry a \`source\` URL with a line anchor
    (e.g. .../AndOrSpec.hs#L117) pointing at ${PINNED}. If you cannot trace a
    behavior to a real source line, OMIT it and record it under "gaps" — do not
    guess.
  - If a behavior cannot be expressed with the existing keys in
    spec/case.schema.json, do NOT approximate it with a weaker assertion (e.g.
    body_contains where an exact match is needed); record a gap prefixed
    "needed_assertion:" describing the assertion style required. The harness
    owner extends the schema between runs.
${revising ? `\nA reviewer found issues in your previous pass. Fix every one:\n- ${priorIssues.join("\n- ")}\n` : ""}
When done, return the structured report (small: paths written, case ids touched,
gaps). The spec/ files on disk are the real deliverable.`;
}

function reviewPrompt(area) {
  return `You are an adversarial Spec Reviewer for the Bier project. Audit the
on-disk spec/ output for the "${area.key}" area of PostgREST ${PINNED}, produced
by another agent — you did NOT write it. Be skeptical; your job is to break it,
not bless it. You are READ-ONLY: do not modify any file. Work from the
repository root (the current directory).

Locate this area's material:
  - the behavior model: spec/${area.file}
  - its conformance cases: the spec/conformance/cases/*.yaml whose \`feature:\`
    field's leading segment is "${area.key}" (find them with e.g.
    grep -rl 'feature: ${area.key}' spec/conformance/cases/). Do NOT rely on id
    ranges — on-disk ids don't all follow a formula.

For EVERY entry in the model and EVERY case:
  1. RE-FETCH the cited \`source:\` URL and read the cited line + surrounding
     context. It must be a ${RAW}/... link with a #Lnnn anchor — flag citations
     that are missing, point at a DIFFERENT PostgREST version, point to the
     wrong line, or contradict the claim/status/header/body.
  2. Check the PostgREST docs (${DOCS}) page for this area for MAJOR public
     features that have NO case.
  3. Validate each case against spec/case.schema.json (note if it is absent),
     and flag any case whose expected body contradicts the CONSOLIDATED seed
     data (the loaded bier_test / spec/conformance/fixtures.sql — e.g.
     test.items is rows 1..15), which is the seed ground truth — not the
     historical fragment files.

Verdict "pass" ONLY if every citation genuinely supports its claim at ${PINNED}
AND no major feature is missing. Otherwise "revise", with each issue formatted
"<case id or entry>: <what is wrong> (correct source: <url>)" so the researcher
can act on it without re-deriving your work.`;
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

function synthesisPrompt(reviewSummary, verify) {
  return `You are the Spec Synthesizer for the Bier project. The per-area spec/
files and conformance cases now exist on disk. Work from the repository root;
write ONLY under spec/. REFRESH these to match what is on disk NOW — read the
actual files, never trust stale counts:
  - spec/README.md        overview + the pinned version (${PINNED})
  - spec/COVERAGE.md      a table mapping every PostgREST docs page (${DOCS})
                          -> the conformance case IDs that cover it; flag
                          uncovered pages. PRESERVE any existing "Scope
                          decisions" section verbatim unless it contradicts
                          what is now on disk (then update it and say so).
  - spec/conformance/INDEX.md  cross-reference of cases <-> feature areas with
                          per-area counts
  - spec/case.schema.json ONLY if it does not exist yet (draft a faithful
                          JSON-Schema); if it exists, leave it alone — the
                          Tester owns it.

Adversarial-review summary to fold into COVERAGE.md gaps:
${reviewSummary}

Machine-verification facts (record failures honestly in COVERAGE.md):
${JSON.stringify(verify)}`;
}

// ── Per-area unit: research → adversarial review → bounded revise loop ───────

async function specifyArea(area) {
  let issues = [];
  let research = null;
  let review = null;

  try {
    for (let round = 0; round <= MAX_REVISIONS; round++) {
      const suffix = round ? `:r${round}` : "";

      // A lost researcher/reviewer (null) must not erase the previous round's
      // report — keep the last real one and stop the loop.
      const r = await agent(researchPrompt(area, issues), {
        label: `research:${area.key}${suffix}`,
        phase: "Research",
        schema: RESEARCH_SCHEMA,
      });
      if (r) research = r;

      // Adversarial: a fresh agent (never the author) re-verifies this area's citations.
      const rv = await agent(reviewPrompt(area), {
        label: `review:${area.key}${suffix}`,
        phase: "Cross-check",
        schema: REVIEW_SCHEMA,
      });
      if (rv) review = rv;
      if (!rv || review.verdict === "pass") break;
      issues = review.issues || [];
      // "revise" with zero actionable issues gives the researcher nothing to
      // fix — looping would just burn tokens. Surface it as a gap instead.
      if (!issues.length) break;
    }
  } catch (e) {
    // One area erroring must not sink the barrier (or the consolidate/verify/
    // synthesize tail). Files this area already wrote to spec/ still stand.
    return { area: area.key, research, review, error: String(e) };
  }

  return { area: area.key, research, review };
}

// ── Orchestration ───────────────────────────────────────────────────────────

if (UNKNOWN_AREA_KEYS.length) {
  log(`args.areas contains unknown keys (ignored): ${UNKNOWN_AREA_KEYS.join(", ")}`);
}
if (AREAS.length === 0) {
  // Abort BEFORE any agent runs — otherwise the tail would still rewrite
  // fixtures/COVERAGE/INDEX for a run that researched nothing.
  return {
    workflow: "bier-spec",
    error: "args.areas matched no known areas — nothing to do",
    unknown_area_keys: UNKNOWN_AREA_KEYS,
    known_area_keys: ALL_AREAS.map((a) => a.key),
  };
}

log(`Specifying PostgREST ${PINNED} across ${AREAS.length} feature areas (≤${MAX_REVISIONS} revise rounds each)...`);

// Phase Research + Cross-check: every area in parallel. Barrier here is correct —
// the consolidator needs every fixture delta written before it can fold them.
const areaSlots = await parallel(AREAS.map((area) => () => specifyArea(area)));

// Collect everything a human needs to decide — workflows can't ask mid-run.
// parallel() preserves input order, so slot i corresponds to AREAS[i]; a null
// slot (skipped / terminally-errored agent) is recorded, never silently dropped.
const gaps = [];
const areaResults = [];
areaSlots.forEach((slot, i) => {
  if (!slot) {
    log(`area ${AREAS[i].key}: agent slot returned null (skipped or terminal error)`);
    gaps.push({ area: AREAS[i].key, kind: "area_agent_lost", detail: "parallel slot returned null (agent skipped mid-run or died after retries)" });
    return;
  }
  areaResults.push(slot);
  const research = slot.research || {};
  const review = slot.review || {};
  for (const g of research.gaps || []) gaps.push({ area: slot.area, kind: "research_gap", detail: g });
  for (const m of review.missing_features || []) gaps.push({ area: slot.area, kind: "missing_feature", detail: m });
  if (!slot.research) gaps.push({ area: slot.area, kind: "research_report_missing", detail: "research agent returned no structured report; check its on-disk output" });
  if (!slot.review) gaps.push({ area: slot.area, kind: "review_report_missing", detail: "review agent returned no structured report; area is unverified" });
  if (review.verdict === "revise") {
    gaps.push({
      area: slot.area,
      kind: (review.issues || []).length ? "unresolved_after_revisions" : "revise_without_issues",
      issues: review.issues || [],
    });
  }
  if (slot.error) gaps.push({ area: slot.area, kind: "area_errored", detail: slot.error });
});

// Phase Consolidate: fold the fixture deltas into the primary fixtures.sql.
log("Folding fixture deltas → spec/conformance/fixtures.sql");
const consolidateResult = await agent(CONSOLIDATE_PROMPT, { label: "consolidate-fixtures", phase: "Consolidate", schema: CONSOLIDATE_SCHEMA });
if (!consolidateResult) gaps.push({ kind: "consolidate_agent_lost", detail: "consolidator returned no report — delta files may be unfolded; inspect spec/conformance/fixtures/*.delta.sql" });
else if (consolidateResult.loads_clean === false) gaps.push({ kind: "fixtures_reported_unclean", detail: (consolidateResult.notes || []).join("; ") || "consolidator reported loads_clean=false" });
const consolidate = consolidateResult || {};

// Phase Verify: machine checks with real command output — not self-reports.
log("Verifying spec/ tree: fixture load, case schema, ids, stale pins, referenced relations");
const verifyResult = await agent(VERIFY_PROMPT, { label: "verify-spec-tree", phase: "Verify", schema: VERIFY_SCHEMA });
if (!verifyResult) gaps.push({ kind: "verify_agent_lost", detail: "verify agent returned no report — the tree is UNVERIFIED; do not proceed on green assumptions" });
const verify = verifyResult || {};
if (verify.fixtures_load_ok === false) gaps.push({ kind: "fixtures_do_not_load", detail: verify.evidence || "see verify agent output" });
if (verify.cases_schema_valid === false) gaps.push({ kind: "cases_fail_schema", detail: (verify.invalid_cases || []).join(", ") });
if ((verify.duplicate_ids || []).length) gaps.push({ kind: "duplicate_case_ids", detail: verify.duplicate_ids.join(", ") });
if ((verify.stale_pin_citations || []).length) gaps.push({ kind: "stale_pin_citations", detail: verify.stale_pin_citations.join(", ") });
if ((verify.missing_relations || []).length) gaps.push({ kind: "cases_reference_missing_relations", detail: verify.missing_relations.join(", ") });

// Phase Synthesize: README / COVERAGE / INDEX refreshed from disk.
const reviewSummary = areaResults
  .map((a) => `- ${a.area}: ${(a.review && a.review.verdict) || "unreviewed"}` + (((a.review && a.review.missing_features) || []).length ? ` (missing: ${a.review.missing_features.join(", ")})` : ""))
  .join("\n");
const synthesisResult = await agent(synthesisPrompt(reviewSummary, verify), { label: "synthesize-spec", phase: "Synthesize", schema: SYNTH_SCHEMA });
if (!synthesisResult) gaps.push({ kind: "synthesize_agent_lost", detail: "synthesis agent returned no report — README/COVERAGE/INDEX may be stale" });
const synthesis = synthesisResult || {};

// The single report this run returns.
const passed = areaResults.filter((a) => a.review && a.review.verdict === "pass").length;
return {
  workflow: "bier-spec",
  pinned_postgrest: PINNED,
  areas_total: AREAS.length,
  areas_passing_review: passed,
  unknown_area_keys: UNKNOWN_AREA_KEYS,
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
  next: "Human gate: review the spec diff and the needed_assertion:/loader_exposure: gaps, sync the test harness, then run bier-conformance.",
};
