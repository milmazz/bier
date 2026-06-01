/**
 * bier-spec — PostgREST spec-research fan-out (Phase 1 of docs/AGENT_PLAN.md)
 * ===========================================================================
 *
 * A dynamic workflow (https://code.claude.com/docs/en/workflows) that researches
 * PostgREST's public behavior and lays down a complete `spec/` tree: one subagent
 * per feature area researches + drafts the spec, a fresh adversarial reviewer
 * cross-checks each area's findings against cited PostgREST source (re-dispatching
 * the researcher on a "revise" verdict, up to MAX_REVISIONS), then the fixtures
 * are consolidated and the result synthesized into COVERAGE.md.
 *
 * Design source of truth: docs/workflows/bier-spec.md (read it before editing).
 * Writes ONLY under spec/. Does not touch lib/, test/, or mix.exs.
 *
 * ── Runtime API ─────────────────────────────────────────────────────────────
 * This is encoded against the Claude Code dynamic-workflow runtime:
 *   - `export const meta` literal (below) declares name/description/phases.
 *   - the script body runs directly in an async context; there is no entry fn.
 *   - `agent(prompt, opts)` spawns a subagent and returns its final message as a
 *     STRING. We do NOT use the `schema:` option here: these agents do heavy,
 *     long tool work (web fetches, git clone, writing dozens of files) and
 *     reliably finish in prose rather than making the forced StructuredOutput
 *     tool call — which made `agent({schema})` throw at the tail of an otherwise
 *     successful run. Instead each agent ends with a fenced ```json block and we
 *     parse the last one (parseJsonResult), degrading gracefully if it's absent.
 *   - `parallel(thunks)` runs the per-area work concurrently (capped at
 *     min(16, cores-2) automatically) and barriers before consolidation, which
 *     genuinely needs every fixture fragment on disk first. Each area is wrapped
 *     in try/catch so one failure can't sink the barrier (and the consolidate /
 *     synthesize tail).
 *   - agents inherit all tools (Read/Write/Edit/WebFetch/WebSearch/Bash); the
 *     permissions the research agents need are pre-allowed by the operator per
 *     docs/workflows/bier-spec.md §8, not by this script.
 *   - Research is idempotent: an agent that finds its area's spec already on disk
 *     validates + tops up rather than regenerating, so a re-run after a partial
 *     failure is cheap.
 */

export const meta = {
  name: "bier-spec",
  description: "PostgREST v14 spec-research fan-out: one agent per feature area writes spec/, a fresh adversarial reviewer cross-checks cited sources, then consolidate fixtures and synthesize COVERAGE.md",
  whenToUse: "Phase 1 of docs/AGENT_PLAN.md — build the spec/ tree from PostgREST's public behavior. Run once before the Tester phase.",
  phases: [
    { title: "Research", detail: "1 agent / feature area → spec/<area>.yaml + conformance cases + fixture fragment" },
    { title: "Cross-check", detail: "fresh adversarial reviewer per area re-verifies every citation; revise loop ≤2 rounds" },
    { title: "Consolidate", detail: "merge fixture fragments → spec/conformance/fixtures.sql (loads on PG 14/15/16)" },
    { title: "Synthesize", detail: "spec/README.md, COVERAGE.md, case.schema.json, conformance/INDEX.md" },
  ],
};

// ── Configuration ──────────────────────────────────────────────────────────

const PINNED = (args && args.pinned) || "v14.12"; // single PostgREST version this run specs (override via args.pinned)
const REPO = "https://github.com/PostgREST/postgrest";
const RAW = `https://raw.githubusercontent.com/PostgREST/postgrest/${PINNED}`;
const MAX_REVISIONS = 2; // adversarial revise rounds per area before escalating to the gap list

// The research units. One agent owns one area and writes spec/<key>.yaml.
// `scope` is fed verbatim into the agent prompt — keep it concrete.
const AREAS = [
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
  { key: "openapi", file: "openapi.yaml", scope: "OpenAPI 3.0 document generation rules, descriptions sourced from COMMENTs, security schemes" },
  { key: "config", file: "config.yaml", scope: "every PostgREST config key + semantics: db-uri, db-schemas, db-anon-role, jwt-secret, jwt-aud, db-max-rows, server-port, and the rest" },
  { key: "observability", file: "observability.yaml", scope: "log format, log-level, Server-Timing header, metrics/traces surface" },
];

// ── Result parsing ───────────────────────────────────────────────────────────
// agent() returns the subagent's final message as a string. We ask each agent to
// end with a single fenced ```json block and parse the LAST one. If it's missing
// or malformed we return a flagged object rather than throwing, so one ragged
// agent can't sink the run — the work it wrote to disk still stands.

function parseJsonResult(name, result) {
  const matches = [...String(result).matchAll(/```json\s*([\s\S]*?)```/g)];
  if (matches.length === 0) {
    return { _unparsed: true, name, raw: String(result).slice(-2000) };
  }
  try {
    return JSON.parse(matches[matches.length - 1][1]);
  } catch (e) {
    return { _unparsed: true, name, error: String(e), raw: matches[matches.length - 1][1] };
  }
}

// ── Prompt builders ─────────────────────────────────────────────────────────

function researchPrompt(area, band, priorIssues) {
  const revising = priorIssues && priorIssues.length;
  return `You are the Spec Researcher for the Bier project, working ONLY on the
"${area.key}" feature area of PostgREST ${PINNED}. Read docs/AGENT_PLAN.md §5.1
for the exact deliverable shapes. You may WRITE ONLY under spec/. Never touch
lib/, test/, or mix.exs.

Area scope: ${area.scope}

IDEMPOTENCY: first check whether spec/${area.file} and this area's cases already
exist. If they do and look complete + correctly cited, do NOT regenerate them —
read them, fix only what's wrong or missing, and report what's there. Only do
full research from scratch if the files are absent.

Ground truth, in priority order:
  1. PostgREST tests:    ${RAW}/test/spec/Feature/...  (+ test/spec/fixtures/*.sql)
  2. PostgREST source:   ${RAW}/src/...
  3. PostgREST docs:     https://postgrest.org/en/v14/   (behavior tests imply)
Clone shallow if helpful: git clone --depth 1 --branch ${PINNED} ${REPO}

Produce, under spec/:
  - spec/${area.file}                       the behavior model for this area
  - spec/conformance/cases/NNNN_<slug>.yaml  >=1 black-box case per public feature,
       in the AGENT_PLAN.md §5.1 case shape (id, feature, request, schema,
       preconditions, expect{status,headers,body_*}, notes, source)
  - spec/conformance/fixtures/${area.key}.sql  the schema/data your cases need
Pick conformance-case id ranges that won't collide: use the band [${band} .. ${band + 49}].

HARD RULE: every entry and every case MUST carry a \`source\` URL with a line
anchor (e.g. .../AndOrSpec.hs#L117). If you cannot trace a behavior to a real
source line, OMIT it and record it under "gaps" — do not guess.
${revising ? `\nA reviewer found issues in your previous pass. Fix every one:\n- ${priorIssues.join("\n- ")}\n` : ""}
End your final message with a single fenced json block (and nothing after it):
\`\`\`json
{"area":"${area.key}","entries":[{"entry_id":"","claim":"","source_url":"","source_line":0,"case_ids":[]}],"files_written":[],"gaps":[]}
\`\`\``;
}

function reviewPrompt(area, band) {
  return `You are an adversarial Spec Reviewer for the Bier project. Audit the
spec/ output for the "${area.key}" PostgREST area produced by another agent — you
did NOT write it. Be skeptical; your job is to break it, not bless it.

For each entry in spec/${area.file} and each spec/conformance/cases/*.yaml in this
area's id band [${band} .. ${band + 49}]:
  1. Re-fetch the cited source (${RAW}/...) and confirm it actually supports the
     claim. Flag any claim whose citation is missing, wrong, or contradicts it.
  2. Check the PostgREST docs ToC for this area for MAJOR features with no case.
  3. Lint every case against spec/case.schema.json if present (else note its absence).

Verdict "pass" only if every entry is correctly cited and no major feature is
missing. Otherwise "revise" with specific, actionable issues.

End your final message with a single fenced json block (and nothing after it):
\`\`\`json
{"area":"${area.key}","verdict":"pass","issues":[],"dropped_entries":[],"missing_features":[]}
\`\`\``;
}

const CONSOLIDATE_PROMPT = `You are the Fixture Consolidator for the Bier project.
Merge every spec/conformance/fixtures/*.sql fragment into a single
spec/conformance/fixtures.sql that loads cleanly on Postgres 14, 15, and 16:
- dedupe shared schemas/roles/tables created by more than one fragment,
- resolve naming collisions (rename + note it),
- order DDL so dependencies (schemas, types, tables, FKs, functions) come first,
- if psql is available, verify it loads; otherwise do a careful static check.
Write ONLY under spec/. End your final message with a single fenced json block:
\`\`\`json
{"conflicts_resolved":[],"loads_clean":true,"notes":[]}
\`\`\``;

function synthesisPrompt(reviewSummary) {
  return `You are the Spec Synthesizer for the Bier project. The per-area spec/
files and conformance cases now exist. Produce, under spec/:
  - spec/README.md        overview + the pinned version (${PINNED})
  - spec/case.schema.json  a JSON-Schema the conformance cases validate against
                           (the Tester owns it afterward; draft a faithful one)
  - spec/COVERAGE.md       a table mapping every PostgREST v14 docs page -> the
                           conformance case IDs that cover it; flag uncovered pages
  - spec/conformance/INDEX.md  cross-reference of cases <-> feature areas

Reviewer summary to fold into COVERAGE.md gaps:
${reviewSummary}

Write ONLY under spec/. End your final message with a single fenced json block:
\`\`\`json
{"total_cases":0,"covered_pages":0,"uncovered_pages":[],"open_gaps":[]}
\`\`\``;
}

// ── Per-area unit: research → adversarial review → bounded revise loop ───────

async function specifyArea(area, i) {
  const band = 1000 + i * 50;
  let issues = [];
  let research = {};
  let review = {};

  try {
    for (let round = 0; round <= MAX_REVISIONS; round++) {
      const suffix = round ? `:r${round}` : "";

      const r = await agent(researchPrompt(area, band, issues), {
        label: `research:${area.key}${suffix}`,
        phase: "Research",
      });
      research = parseJsonResult(`research:${area.key}`, r);

      // Adversarial: a fresh agent (never the author) re-verifies this area's citations.
      const rv = await agent(reviewPrompt(area, band), {
        label: `review:${area.key}${suffix}`,
        phase: "Cross-check",
      });
      review = parseJsonResult(`review:${area.key}`, rv);

      // _unparsed review → can't trust the verdict; stop revising and let the
      // synthesis/gap pass surface it rather than looping pointlessly.
      if (review.verdict === "pass" || review._unparsed) break;
      issues = review.issues || [];
    }
  } catch (e) {
    // One area erroring must not sink the barrier (or the consolidate/synthesize
    // tail). Files this area already wrote to spec/ still stand.
    return { area: area.key, band, research, review, error: String(e) };
  }

  return { area: area.key, band, research, review };
}

// ── Orchestration ───────────────────────────────────────────────────────────

log(`Specifying PostgREST ${PINNED} across ${AREAS.length} feature areas (≤2 revise rounds each)...`);

// Phase Research + Cross-check: every area in parallel. Barrier here is correct —
// consolidation needs every fixture fragment written before it can merge them.
const areaResults = (
  await parallel(AREAS.map((area, i) => () => specifyArea(area, i)))
).filter(Boolean);

// Collect everything a human needs to decide — workflows can't ask mid-run.
const gaps = [];
for (const a of areaResults) {
  for (const g of a.research.gaps || []) gaps.push({ area: a.area, kind: "research_gap", detail: g });
  for (const m of a.review.missing_features || []) gaps.push({ area: a.area, kind: "missing_feature", detail: m });
  if (a.review.verdict !== "pass" && (a.review.issues || []).length) {
    gaps.push({ area: a.area, kind: "unresolved_after_revisions", issues: a.review.issues });
  }
  if (a.error) gaps.push({ area: a.area, kind: "area_errored", detail: a.error });
  if (a.research._unparsed) gaps.push({ area: a.area, kind: "research_result_unparsed", detail: a.research.raw?.slice(0, 300) });
  if (a.review._unparsed) gaps.push({ area: a.area, kind: "review_result_unparsed", detail: a.review.raw?.slice(0, 300) });
}

// Phase Consolidate: merge the fixture fragments into one loadable file.
log("Consolidating fixture fragments → spec/conformance/fixtures.sql");
const consolidate = parseJsonResult(
  "consolidate",
  await agent(CONSOLIDATE_PROMPT, { label: "consolidate-fixtures", phase: "Consolidate" })
);

// Phase Synthesize: README / COVERAGE / case.schema.json / INDEX.
const reviewSummary = areaResults
  .map((a) => `- ${a.area}: ${a.review.verdict || "?"}` + ((a.review.missing_features || []).length ? ` (missing: ${a.review.missing_features.join(", ")})` : ""))
  .join("\n");
const synthesis = parseJsonResult(
  "synthesize",
  await agent(synthesisPrompt(reviewSummary), { label: "synthesize-spec", phase: "Synthesize" })
);

// The single report this run returns.
const passed = areaResults.filter((a) => a.review.verdict === "pass").length;
return {
  workflow: "bier-spec",
  pinned_postgrest: PINNED,
  areas_total: AREAS.length,
  areas_passing_review: passed,
  total_conformance_cases: synthesis.total_cases ?? null,
  docs_pages_covered: synthesis.covered_pages ?? null,
  docs_pages_uncovered: synthesis.uncovered_pages ?? [],
  fixtures_load_clean: consolidate.loads_clean ?? null,
  fixture_conflicts_resolved: consolidate.conflicts_resolved ?? [],
  gaps_for_human_review: gaps.concat((synthesis.open_gaps || []).map((g) => ({ kind: "synthesis_gap", detail: g }))),
  next: "Phase 2 (Tester): generate the failing ExUnit suite from spec/.",
};
