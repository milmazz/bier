/**
 * bier-spec — PostgREST spec-research fan-out (Phase 1 of docs/AGENT_PLAN.md)
 * ===========================================================================
 *
 * A dynamic workflow (https://code.claude.com/docs/en/workflows) that researches
 * PostgREST's public behavior and lays down a complete `spec/` tree: one subagent
 * per feature area researches + drafts the spec, a second wave adversarially
 * cross-checks each area's findings against cited PostgREST source, then the
 * fixtures are consolidated and the result synthesized into COVERAGE.md.
 *
 * Design source of truth: docs/workflows/bier-spec.md (read it before editing).
 * Writes ONLY under spec/. Does not touch lib/, test/, or mix.exs.
 *
 * ── Assumed runtime API ────────────────────────────────────────────────────
 * The dynamic-workflow runtime injects an agent-spawning primitive. Its exact
 * name/signature isn't publicly documented, so this script assumes:
 *
 *     await runAgent({ name, prompt, model?, allowedTools? })
 *        -> { result: string }            // result is the agent's final message
 *
 * That call is the ONLY coupling to the runtime — it's wrapped in dispatch()
 * below. If your runtime exposes it as spawnAgent()/agent.run()/etc., change
 * just that wrapper. Agents do all filesystem + shell work (the workflow script
 * itself has no FS/shell access); this script only coordinates and holds the
 * intermediate results in variables.
 *
 * Entry point: default export async fn returning the final report. If your
 * runtime expects a different entry shape, keep `run()` and adapt the export.
 */

// ── Configuration ──────────────────────────────────────────────────────────

const PINNED = "v14.12"; // the single PostgREST version this run specs
const REPO = "https://github.com/PostgREST/postgrest";
const RAW = `https://raw.githubusercontent.com/PostgREST/postgrest/${PINNED}`;
const MAX_REVISIONS = 2; // adversarial revise rounds per area before escalating
const CONCURRENCY = 16; // runtime caps at 16; we mirror it for clarity

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

// ── Runtime coupling (the one place to reconcile with your runtime) ─────────

async function dispatch(name, prompt, opts = {}) {
  // eslint-disable-next-line no-undef
  const { result } = await runAgent({
    name,
    prompt,
    model: opts.model, // undefined => inherit the session model
    allowedTools: opts.allowedTools,
  });
  return result;
}

// Agents must reliably hand structured data back. We ask them to end their
// final message with a fenced ```json block and parse the last one.
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

// Bounded-concurrency map (the runtime also caps at 16; this keeps batches tidy).
async function mapLimit(items, limit, fn) {
  const out = new Array(items.length);
  let next = 0;
  async function worker() {
    while (next < items.length) {
      const i = next++;
      out[i] = await fn(items[i], i);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return out;
}

const RESEARCH_TOOLS = ["Read", "Write", "Edit", "WebFetch", "WebSearch", "Bash"];
const REVIEW_TOOLS = ["Read", "WebFetch", "WebSearch", "Bash"];

// ── Prompt builders ─────────────────────────────────────────────────────────

function researchPrompt(area, priorIssues) {
  const revising = priorIssues && priorIssues.length;
  return `You are the Spec Researcher for the Bier project, working ONLY on the
"${area.key}" feature area of PostgREST ${PINNED}. Read docs/AGENT_PLAN.md §5.1
for the exact deliverable shapes. You may WRITE ONLY under spec/. Never touch
lib/, test/, or mix.exs.

Area scope: ${area.scope}

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
Pick conformance-case id ranges that won't collide: use the band
  [${1000 + AREAS.findIndex((a) => a.key === area.key) * 50} .. ${1000 + AREAS.findIndex((a) => a.key === area.key) * 50 + 49}].

HARD RULE: every entry and every case MUST carry a \`source\` URL with a line
anchor (e.g. .../AndOrSpec.hs#L117). If you cannot trace a behavior to a real
source line, OMIT it and record it under "gaps" — do not guess.
${revising ? `\nA reviewer found issues in your previous pass. Fix every one:\n- ${priorIssues.join("\n- ")}\n` : ""}
End your final message with a single fenced json block:
\`\`\`json
{"area":"${area.key}","entries":[{"entry_id":"","claim":"","source_url":"","source_line":0,"case_ids":[]}],"files_written":[],"gaps":[]}
\`\`\``;
}

function reviewPrompt(area) {
  return `You are an adversarial Spec Reviewer for the Bier project. Audit the
spec/ output for the "${area.key}" PostgREST area produced by another agent — you
did NOT write it. Be skeptical; your job is to break it, not bless it.

For each entry in spec/${area.file} and each spec/conformance/cases/*.yaml in this
area's id band:
  1. Re-fetch the cited source (${RAW}/...) and confirm it actually supports the
     claim. Flag any claim whose citation is missing, wrong, or contradicts it.
  2. Check the PostgREST docs ToC for this area for MAJOR features with no case.
  3. Lint every case against spec/case.schema.json if present (else note its absence).

Verdict "pass" only if every entry is correctly cited and no major feature is
missing. Otherwise "revise" with specific, actionable issues.

End with a single fenced json block:
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
Write ONLY under spec/. End with a fenced json block:
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

Write ONLY under spec/. End with a fenced json block:
\`\`\`json
{"total_cases":0,"covered_pages":0,"uncovered_pages":[],"open_gaps":[]}
\`\`\``;
}

// ── Orchestration ───────────────────────────────────────────────────────────

async function run() {
  const gaps = []; // everything a human needs to decide (workflows can't ask mid-run)

  // Phase B + C: research each area, then have a DIFFERENT agent review it,
  // re-dispatching the researcher on "revise" up to MAX_REVISIONS times.
  const areaResults = await mapLimit(AREAS, CONCURRENCY, async (area, i) => {
    let issues = [];
    let research;
    let review;

    for (let round = 0; round <= MAX_REVISIONS; round++) {
      const r = await dispatch(
        `research:${area.key}${round ? `:r${round}` : ""}`,
        researchPrompt(area, issues),
        { allowedTools: RESEARCH_TOOLS }
      );
      research = parseJsonResult(`research:${area.key}`, r);

      // Adversarial: area i is reviewed against the rubric, by a fresh agent.
      const rv = await dispatch(
        `review:${area.key}${round ? `:r${round}` : ""}`,
        reviewPrompt(area),
        { allowedTools: REVIEW_TOOLS }
      );
      review = parseJsonResult(`review:${area.key}`, rv);

      if (review.verdict === "pass" || review._unparsed) break;
      issues = review.issues || [];
      if (round === MAX_REVISIONS && issues.length) {
        gaps.push({ area: area.key, kind: "unresolved_after_revisions", issues });
      }
    }

    for (const g of research.gaps || []) gaps.push({ area: area.key, kind: "research_gap", detail: g });
    for (const m of review.missing_features || []) gaps.push({ area: area.key, kind: "missing_feature", detail: m });

    return { area: area.key, research, review };
  });

  // Phase D: consolidate the fixture fragments into one loadable file.
  const consolidate = parseJsonResult(
    "consolidate",
    await dispatch("consolidate-fixtures", CONSOLIDATE_PROMPT, { allowedTools: RESEARCH_TOOLS })
  );

  // Phase E: synthesize README / COVERAGE / case.schema.json / INDEX.
  const reviewSummary = areaResults
    .map((a) => `- ${a.area}: ${a.review.verdict || "?"}` + ((a.review.missing_features || []).length ? ` (missing: ${a.review.missing_features.join(", ")})` : ""))
    .join("\n");
  const synthesis = parseJsonResult(
    "synthesize",
    await dispatch("synthesize-spec", synthesisPrompt(reviewSummary), { allowedTools: RESEARCH_TOOLS })
  );

  // Phase F: the single report this run returns.
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
}

export default run;
