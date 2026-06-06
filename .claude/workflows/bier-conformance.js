export const meta = {
  name: 'bier-conformance',
  description: 'Implement Bier lib/ to pass the PostgREST conformance suite, foundation-first then sequential feature slices',
  phases: [
    { title: 'Foundation: DB & infra', detail: 'deps, config, fixture loader+mirror, Postgrex pool, introspection' },
    { title: 'Foundation: read pipeline', detail: 'routing, parser, query executor, render, errors; operators/ordering/select green' },
    { title: 'Feature slices', detail: 'one sequential agent per area, extending the shared core' },
    { title: 'Finalize', detail: 'full suite, CI gates, honest pass report' },
  ],
}

const DOC = 'docs/CONFORMANCE_IMPL.md'

const REPORT = {
  type: 'object',
  additionalProperties: false,
  required: ['summary', 'files_changed', 'area_pass', 'area_total', 'full_pass', 'full_fail', 'blockers'],
  properties: {
    summary: { type: 'string', description: 'what you implemented, 2-4 sentences' },
    files_changed: { type: 'array', items: { type: 'string' } },
    area_pass: { type: 'integer', description: 'tests passing in this slice (mix test --only area:<area>)' },
    area_total: { type: 'integer', description: 'non-pending tests in this slice' },
    full_pass: { type: 'integer', description: 'total passing in full mix test run' },
    full_fail: { type: 'integer', description: 'total failures in full mix test run' },
    regressions: { type: 'string', description: 'any previously-green areas you broke, or "none"' },
    blockers: { type: 'array', items: { type: 'string' }, description: 'unresolved issues for later agents' },
  },
}

const RULES = `
HARD RULES (read ${DOC} in full first — it encodes the architecture and the keystone DB trick):
- Write ONLY under lib/, mix.exs, config/. NEVER edit test/** or spec/** (frozen ground truth).
- If a test looks wrong, re-read its cited source: URL — do not change the test.
- Serialize JSON via Bier.json_library(). Keep mix format clean and compile warning-free.
- Postgres bier_test is loaded by the 'mix bier.fixtures.load' task (wired into the 'mix test' alias). It is idempotent.
- Report HONEST numbers from actual command output. Do not claim green without running the command.
`

phase('Foundation: DB & infra')
const f1 = await agent(
  `You are building the Bier DB foundation. ${RULES}

TASK (Foundation step 1 of 2 — infrastructure only; the next agent builds the request pipeline):
1. Add {:postgrex, "~> 0.20"} to mix.exs deps (runtime). Run mix deps.get.
2. Create config/config.exs, config/test.exs, config/runtime.exs per ${DOC} §2.4. DB settings must default from application env (ConformanceServer passes only name+router). db_schemas first element is the default schema "test"; list every exposed schema (test, operators, ordering, pagination, representations, mutations, rpc, headers, config, openapi, domain_representations, observability, v1, v2).
3. Extend Bier.Config and the @schema in lib/bier.ex to carry DB settings (hostname, port, database, username, password, pool_size, db_schemas, db_anon_role, etc.), pulling defaults from Application env.
4. Create the fixture loader mix task lib/mix/tasks/bier.fixtures.load.ex (mix bier.fixtures.load): drop+create bier_test, ensure roles, load spec/conformance/fixtures.sql (psql -v ON_ERROR_STOP=1), then MIRROR test into each area schema (operators, ordering, pagination, representations, mutations, headers, config, domain_representations) as auto-updatable views per ${DOC} §2.2. Idempotent. Wire it into a 'mix test' alias in mix.exs and ensure the task compiles (elixirc_paths/aliases).
5. Add a per-instance Postgrex pool as a child under the Bier supervisor (lib/bier.ex init/1), registered via Bier.Registry.via(name, Postgrex). Params from Bier.Config.
6. Create lib/bier/introspection.ex and call it from HttpServerStarter (replace the hardcoded db_structure stub): query pg_catalog for tables, columns (name,type,pk,notnull,default), primary keys, and foreign keys across db_schemas. Return a structure the router/controller can use.

VERIFY: mix bier.fixtures.load succeeds and prints the schemas it built; mix compile --warnings-as-errors clean; the instance boots and introspection returns real relations (write a tiny throwaway check or an iex one-liner, then remove it). Do NOT worry about conformance cases passing yet — that's the next agent. Run mix format.

Return the structured report (area_pass/area_total can be 0 here; set full_pass/full_fail from a 'mix test' run if it completes, else 0 and explain in blockers).`,
  { label: 'foundation:infra', phase: 'Foundation: DB & infra', schema: REPORT }
)
log(`Foundation infra: ${f1?.summary ?? 'no report'} | blockers: ${(f1?.blockers ?? []).join('; ') || 'none'}`)

phase('Foundation: read pipeline')
const f2 = await agent(
  `You are building the Bier request pipeline on top of the DB foundation just landed by the previous agent. ${RULES}

Context from the infra agent: ${JSON.stringify(f1)}

TASK (Foundation step 2 of 2 — the read pipeline; target the FIRST green conformance cases):
Follow ${DOC} §4 and §1 (the frozen harness contract — Accept-Profile mapping is critical).
1. Routing: rework lib/bier/router_builder.ex to a catch-all that routes every request to Bier.Plugs.ActionController, which resolves {schema, relation} from the path + Accept-Profile/Content-Profile (default schema = first of db_schemas). Unknown relation => 404 PGRST205; unknown schema => 406 PGRST106. Keep the :match / Plug.Parsers / :dispatch pipeline.
2. Extend Bier.QueryParser for the reserved params select/order/limit/offset and column filters (col=op.value incl. not.). Reuse what exists.
3. Create lib/bier/query_executor.ex: build ONE parameterized SQL statement returning JSON via json_agg over a subquery (see ${DOC} §4.5), execute through the instance Postgrex pool, return rows + full_count.
4. Rewrite lib/bier/plugs/action_controller.ex to actually parse -> execute -> render: Content-Type application/json; charset=utf-8, body = json_agg text, Content-Range (e.g. 0-13/*), correct status. Empty result => [] with 200.
5. Extend lib/bier/plugs/fallback_controller.ex toward PostgREST's {code,message,details,hint} envelope and SQLSTATE/PGRST mapping skeleton (§4.7).

VERIFY (must show real numbers):
- mix test --only area:operators  (target: most/all 50 green)
- mix test --only area:ordering   (target: most of 23 green)
- mix test --only area:select and --only area:filters (the schema:test read cases — as many as the read pipeline supports; embedding/aggregates can remain for the select slice)
- then full mix test for regressions; mix format; mix compile --warnings-as-errors.

Return the structured report with REAL counts (area_pass/area_total for operators; full_pass/full_fail from the full run). List anything you deferred in blockers.`,
  { label: 'foundation:pipeline', phase: 'Foundation: read pipeline', schema: REPORT }
)
log(`Foundation pipeline: ${f2?.summary ?? 'no report'} | operators ${f2?.area_pass}/${f2?.area_total} | full ${f2?.full_pass} pass / ${f2?.full_fail} fail`)

// Sequential slices: each builds on the shared working tree (no concurrency => no merge conflicts).
const SLICES = [
  { area: 'select', focus: 'embedding via FK resolution, ::casts, json-path, computed columns, spread, aggregates (db-aggregates)' },
  { area: 'filters', focus: 'logical and/or/not trees, json filters, quoting, embedded-resource filters' },
  { area: 'ordering', focus: 'nulls first/last, json_path, computed columns, multi-column, related/embedded ordering, error cases' },
  { area: 'pagination', focus: 'limit/offset, Range request header, Content-Range with exact/estimated/planned count (Prefer: count=), db-max-rows' },
  { area: 'content_negotiation', focus: 'Accept negotiation & precedence; CSV (text/csv), GeoJSON, octet-stream, text; singular vnd.pgrst.object; nulls-stripped; custom media handlers; errors' },
  { area: 'representations', focus: 'Prefer: return=representation|minimal, singular object responses, stripped nulls, Location header' },
  { area: 'mutations', focus: 'POST/PATCH/PUT/DELETE, upsert (Prefer: resolution=merge|ignore-duplicates + on_conflict), columns param, missing-default, safe-update/safe-delete (require filter), Prefer: handling=, max-affected. Mind async shared-DB isolation (§1).' },
  { area: 'errors', focus: 'SQLSTATE->HTTP mapping, exact PGRST codes/messages, RAISE handling, error response headers' },
  { area: 'rpc', focus: 'GET/POST /rpc/<fn>, scalar/setof/composite/void returns, named args, overloaded fns, single unnamed json param, count/shape. Functions need to live in schema rpc — mirror test functions per ${DOC} §2.2.' },
  { area: 'headers', focus: 'Prefer, Accept/Content-Profile routing, Location, Content-Location, GUC-set response headers; exotic schema names v1/v2/private/SPECIAL' },
  { area: 'observability', focus: 'Server-Timing header, trace-header passthrough, log-level behavior' },
  { area: 'domain_representations', focus: 'CREATE DOMAIN cast-based read/write/filter/default representations' },
  { area: 'openapi', focus: 'root OpenAPI doc generation: defaults, comments, table/types/rpc/security, modes (functions live in schema openapi)' },
  { area: 'config', focus: 'non-CLI subset: sources/aliases/validation/coercion/precedence, db-max-rows, db-tx-end, app-settings, server CORS (CLI/dump-config cases are :pending)' },
  { area: 'url_grammar', focus: 'remaining path/method/percent-encoding edge cases, reserved params/characters, Accept/Content-Profile incl. 406 PGRST106, unicode schema تست, multi-schema v1/v2' },
]

phase('Feature slices')
const sliceReports = []
for (let i = 0; i < SLICES.length; i++) {
  const s = SLICES[i]
  const r = await agent(
    `You own the "${s.area}" conformance slice for Bier. ${RULES}

Read ${DOC} (esp. the row for "${s.area}" in §3 and the relevant parts of §4) and read this slice's cases:
  spec/conformance/cases/  (the files for area "${s.area}"; their feature: starts with "${s.area}/").
Focus areas: ${s.focus}.

Build on the existing foundation + earlier slices already in lib/. Extend the parser/executor/controller/renderer/introspection as needed. Do NOT rewrite working code from scratch; add to it. If "${s.area}" needs its data/functions in a real schema named "${s.area}", ensure the fixture loader (mix bier.fixtures.load) provides it (extend the loader's mirror logic in lib/, per §2.2) — but never edit spec/**.

VERIFY with real output:
  mix test --only area:${s.area}
Iterate until as many non-pending cases as possible pass. Then run the FULL 'mix test' to check you didn't regress earlier areas (if you did, fix it). Then mix format and mix compile --warnings-as-errors.

Return the structured report with REAL counts for area ${s.area} and the full suite.`,
    { label: `slice:${s.area}`, phase: 'Feature slices', schema: REPORT }
  )
  sliceReports.push({ area: s.area, ...(r || {}) })
  log(`slice ${s.area}: ${r?.area_pass}/${r?.area_total} | full ${r?.full_pass} pass / ${r?.full_fail} fail | regress: ${r?.regressions ?? '?'}`)
}

phase('Finalize')
const fin = await agent(
  `Finalize the Bier conformance implementation. ${RULES}

Slice reports so far: ${JSON.stringify(sliceReports)}

TASK:
1. Run the full CI gate set and capture real output:
   mix deps.unlock --check-unused ; mix format --check-formatted ; mix compile --warnings-as-errors ; mix docs --warnings-as-errors ; mix test
2. Fix any cross-cutting regressions or gate failures you can (lib/ only). Do not touch test/** or spec/**.
3. Produce an HONEST final tally: total conformance cases, passing, failing, and excluded(:pending). Break down failures by area and give the top recurring root causes still open.

Return the structured report; put the per-area failure breakdown and root causes in 'summary' and 'blockers'. full_pass/full_fail must come from the actual final 'mix test' output.`,
  { label: 'finalize', phase: 'Finalize', schema: REPORT }
)
log(`FINAL: ${fin?.full_pass} pass / ${fin?.full_fail} fail`)

return { foundation: [f1, f2], slices: sliceReports, finalize: fin }
