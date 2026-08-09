# Coverage

Maps every page of the PostgREST **v16** documentation
([postgrest.org/en/v16](https://postgrest.org/en/v16/)) to the conformance case
ids that cover it. The docs-page list follows the v16 site's **References**
section and its **API** sub-pages, re-enumerated from the live site this pass
(16 API sub-pages; 12 top-level References entries, of which `api` is the parent
counted through its sub-pages).

A docs page with no covering case (and not explicitly scoped out below) is
flagged **GAP**.

Pinned target: **PostgREST v16.0**. Total cases: **643** across 17 areas
(counted on disk this pass, not carried over). The page set was re-fetched from
the live v16 site this pass — `references.html` lists 12 entries (11 pages plus
the `api` parent: Authentication, API, CLI, Transactions, Connection Pool, Schema
Cache, Errors, Configuration, Observability, Admin Server, HTTP Server, Listener)
and `references/api.html` lists 16 sub-pages, matching the tables below entry for
entry.

State of the tree when this file was written: **HEAD `4705810`**
("spec(filters): re-sync to PostgREST v16.0 (area 5/17)") with an **uncommitted
ordering re-sync in the working tree** — `spec/ordering.yaml`, this file and
`conformance/INDEX.md` modified, cases **1227–1232** untracked. Every count here
describes that on-disk state, including the uncommitted files. The previous
revision of this file was written at `2a65333` + an uncommitted filters re-sync,
with **637** cases; the whole delta is the ordering area (27 → 33 cases).

The re-sync is **5 of 17 areas committed** (auth, headers, config, select,
filters) with ordering in the working tree — treat every "not re-audited" note
below as describing that mid-flight state, not a finished pass.

## References → API sub-pages

| Docs page (`references/api/...`) | Covering case ids | Notes |
|----------------------------------|-------------------|-------|
| `tables_views` (Tables and Views) | 1000–1029 (url_grammar), 1050–1099 (operators), 1100–1149 (select, incl. the new composite/array JSON-operator cases 1143–1146), 1150–1199 (filters), 1200–1232 (ordering), 1300–1333 (representations), 1350–1397 (mutations) | Read/write of tables & views: path resolution, horizontal/logical filters, operators, vertical filtering (select), JSON/composite/array column access, ordering, insert/update/delete/upsert. **Partial** — three behaviors the page and its upstream spec assert have no case: the `IN`/`NOT IN` empty set, an empty filter *value*, and the implicit AND of two plain filters (the page's very first rule). See **Known gaps → filters**. |
| `functions` (Functions as RPC) | 1400–1440 (rpc), 1005–1007 (url_grammar /rpc paths), 1023 (rpc profile), 1231–1232 (ordering of an RPC result), 1271 (count envelope on an ordered RPC), 1489–1490 (auth rpc), 1570 (rpc status GUC) | GET/POST RPC, scalar/setof/composite/void returns, args, variadic, volatility, overloaded functions, single unnamed JSON parameter, reserved-word function name (1440), and the page's "filters, order and limits inline into a function" rule (`functions.rst` L283/L290) via 1231–1232. |
| `schemas` (Schemas) | 1008–1012, 1022–1024 (url_grammar profile), 1557–1560, 1574 (headers profile), 1730 (`db-schema` singular alias), 1733–1734 (`db-schemas` rejects `pg_catalog` / `information_schema`) | Accept-Profile / Content-Profile, multi-schema routing, unacceptable schema, restricted system schemas (new in v16). |
| `computed_fields` (Computed Fields) | 1128 (select computed-column), 1208 (ordering computed), 1806 (domain rep. via view + computed column) | Computed (virtual) columns in select and order. |
| `domain_representations` (Domain Representations) | 1800–1820 (domain_representations) | **COVERED**: CREATE DOMAIN cast representations — read (format cast shapes output, incl. implicit `select=*` and through-embed), write (parser cast applied to bodies, `columns=` param), filter (domain-typed predicates, `in`/`not.in`, across relations), default (no cast → base type), error paths (1819–1820). |
| `pagination_count` (Pagination and Count) | 1250–1277 (pagination), 1431 (rpc Range header), 1700–1701 (db-max-rows) | limit/offset, Range header, exact/planned/estimated count, db-max-rows. |
| `resource_embedding` (Resource Embedding) | 1112–1127, 1133–1142 (select embed/spread/one-to-one/computed rels/aliases/`!fk` hints), 1181–1199 (filters embed, incl. the nine new 1191–1199), 1211–1224, 1227–1229 (ordering embed/related, incl. computed-relationship related orders 1227–1228 and the nulls-order-alongside-limits regression 1229), 1276 (nested limit), 1028 (legacy embed target name), 1736 (`url-use-legacy-target-names` dump) | Many-to-one/one-to-many/many-to-many, one-to-one (pk-as-fk, unique FK), computed relationships, nested, inner/left, disambiguation (incl. the `table!fk` hint, 1142), spread, and the v16 target-name→alias migration (1028, 1138–1141, 1188–1190, 1224). The filters re-sync added third-level embed filters (1191), two-level and direct-only inner joins (1192–1193), the many-to-one / many-to-many / nested `is.null` + `not.is.null` antijoin matrix (1194, 1196–1199) and `or=` across two embeds (1195). **Partial** — Foreign Key Joins on Views / Chains of Views, Spread To-Many, and FK Joins on Partitioned Tables have no case (**Known gaps → select**), and the page's *Order in spread to-many* section — a named section with its own example, `films.order=year` — has no case in any band (**Known gaps → ordering**). |
| `resource_representation` (Resource Representation) | 1300–1333 (representations), 1230 (order applied to a PATCH's returned representation), 1550–1556 (Prefer), 1610–1615, 1629 (singular), 1630–1635 (nulls-stripped) | Prefer: return=representation/minimal/headers-only, singular object, vnd.pgrst.object, stripped nulls. |
| `media_type_handlers` (Media Type Handlers) | 1600–1646 (content_negotiation, incl. 1636–1638/1642/1644/1646 custom-media-handler), 1426 (rpc csv) | JSON/CSV/GeoJSON/octet-stream/text, Accept negotiation and precedence (1639–1641, 1645), custom media handlers (anyelement, override-builtin, any-handler, vendored-not-overridable, table aggregate, default-select requirement), plan output. |
| `aggregate_functions` (Aggregate Functions) | 1129–1133, 1147–1149 (select aggregate), 1644 (aggregate through a custom media handler) | count/sum/group-by/alias+cast, cast of the aggregated column and of the result (1147–1148), group-by across an embed (1149), agg in embed. **Partial** — *Aggregates in To-One Spreads* and the PGRST127 to-many-spread rejection have no case; see **Known gaps → select**. |
| `openapi` (OpenAPI) | 1650–1682 (openapi), 1619–1621, 1645 (content_negotiation openapi) | Root spec, comments→summary/description, type mapping, modes, security, `db-root-spec`. |
| `preferences` (Prefer Header) | 1550–1556, 1577–1581, 1584 (headers prefer), 1302–1304, 1313–1314, 1322, 1324, 1332–1333 (return=minimal / headers-only), 1390–1392 (max-affected), 1551–1552 (handling), 1553–1554, 1577–1581, 1584 (timezone) | Prefer: return, handling=strict/lenient, timezone (incl. ± offsets, leap seconds, invalid under default/lenient/strict, and the single- vs two-token `Preference-Applied` echo in 1553/1584), max-affected, missing-defaults via `columns`. **Partial** — every `handling` and `max-affected` case is table-flavored; the RPC flavor of both preferences (incl. PGRST128) has no case. See **Known gaps → headers**. |
| `vary_header` (Vary Header) | 1575 (default `Vary: Accept, Prefer, Range` on a read), 1576 (`response.headers` GUC override replaces it verbatim), 1582 (the default is appended by `toWaiResponse` for every non-error response, witnessed on OPTIONS), 1583 (error responses carry no `Vary` — they bypass `toWaiResponse`) | **NEW page in v16** — covered. 1582/1583 match the modelled entries `headers.vary.non_read_responses` / `headers.vary.absent_on_errors`. The one remaining leg — a *CORS preflight* answered by the wai-cors middleware, which never reaches `toWaiResponse` — is a gap; see **Known gaps → headers**. |
| `cors` (CORS) | 1702 (allowed-origin echo), 1703 (empty config allows all), 1704 (non-matching origin → no header), 1742 (default/empty origin list answers a preflight permissively), 1743 (the fixed `Access-Control-Expose-Headers` list on a plain `Origin` request) | 1742/1743 are **HTTP** cases inside the config band. **Partial** — none of the preflight cases asserts `Vary`-absence, the third leg of the v16 `Vary` rule (**Known gaps → headers**), and 1742 does not yet run under the config it declares (**Known gaps → config**). |
| `options` (OPTIONS method) | 1019 (url_grammar OPTIONS Allow), 1757, 1768–1769 (observability OPTIONS server-timing on table / rpc / root), 1742 (OPTIONS preflight) | OPTIONS Allow header; OPTIONS Server-Timing subset; CORS preflight. Partial — no dedicated `Allow`-body assertions beyond 1019. |
| `url_grammar` (URL Grammar) | 1000–1029 (url_grammar) | Path/method resolution, reserved query params (incl. the legacy embed target name, 1028), %-encoding, `+`→space, double-quoting reserved characters in filter values and in quoted identifiers (1025–1027, 1029). |

## References → top-level pages

| Docs page (`references/...`) | Covering case ids | Notes |
|------------------------------|-------------------|-------|
| `auth` (Authentication) | 1450–1499 + 11800–11818 (auth) | JWT validation/claims, HS256 (incl. binary/base64 secret) and RS256 (JWK and JWKS), roles, role-claim-key JSON Path, anonymous, audience, pre-request, GUC claims, login-token minting, clock-skew errors. Partial — see **Known gaps**. |
| `cli` (CLI) | 1705–1741 + 1744 (all 38 `request.kind: cli` cases) | `--dump-config`, `--example`, validation, env/file/db precedence, coercion, unknown-key tolerance (1739), aliases. Driven in-process by `Bier.CliCase`. Note 1742/1743 sit inside the band but are HTTP, so the CLI set is not contiguous. |
| `transactions` (Transactions) | 1387–1392 (safe-update/delete, max-affected), 1713, 1722 (db-tx-end validation + enum mapping), 1759 (transaction timing) | Tx-scoped GUCs, safe-update/safe-delete (rollback on missing WHERE), db-tx-end. Partial — no explicit characteristics/isolation-level case. |
| `connection_pool` (Connection Pool) | — (OUT OF SCOPE) | Pool sizing/acquisition behavior is operational and not observable as deterministic black-box HTTP. See **Scope decisions**. |
| `schema_cache` (Schema Cache) | — (DEFERRED) | Schema-cache reload (`NOTIFY pgrst, 'reload schema'` / SIGUSR1) needs a reload-signal harness. See **Scope decisions**. |
| `errors` (Errors) | 1500–1518 (errors), 1432–1434 (rpc errors), 1002, 1024, 1185 (not-found / invalid path), 1455–1464 + 11809–11814 (auth JWT errors), 1506, 1515–1516, 1518 (Proxy-Status envelope) | SQLSTATE→HTTP mapping, PGRST error codes, RAISE PGRST full control, 4xx/5xx envelopes, `Proxy-Status`, client-error-verbosity=minimal. Partial — **PGRST127** and **PGRST128** appear nowhere in the tree (see **Known gaps → select / headers**). |
| `configuration` (Configuration) | 1700–1744 (config) | Sources (env/file/db-role-settings, incl. `db-config = false` disabling the in-db source, 1744), aliases, validation, coercion (incl. `coerceBool` from numeric/text strings, 1740–1741), unknown-key tolerance (1739), precedence, app-settings, CORS keys (1702–1704, 1742–1743), plus the v16 keys `client-error-verbosity` (1731–1732), `server-reuseport` (1735), `url-use-legacy-target-names` (1736), `admin-server-unix-socket` (1737–1738). **Partial** — the page's *In-Database Configuration* section documents `db-pre-config` as the recommended mechanism and its *App Settings* section documents `current_setting('app.settings.*')`; neither has a case. See **Known gaps → config**. |
| `observability` (Observability) | 1750–1769 (observability), 1497 (JWT-cache Server-Timing), 1625–1628, 1643 (execution plan), 1506/1515/1516/1518/1002 (Proxy-Status) | Server-Timing, Trace header, log-level→status logging, execution plan, Proxy-Status. Partial — see **Known gaps** (Metrics, SQL query logs, Server version header). |
| `admin_server` (Admin Server) | 1717 (admin-port = server-port fatal), 1737 (`admin-server-unix-socket` dump), 1738 (admin socket-mode validation) | Config-surface validation via the CLI harness; `/live` and `/ready` covered by ExUnit (`test/bier/admin_server_test.exs`). Partial — `/metrics` and `/schema_cache` have no case. |
| `http_server` (HTTP Server) | — (OUT OF SCOPE, new page in v16) | The page documents exactly one behavior: Warp's graceful shutdown on `SIGTERM`. See **Scope decisions**. |
| `listener` (Listener) | — (DEFERRED) | LISTEN/NOTIFY channel (`db-channel`) reload trigger needs the same reload-signal harness. See **Scope decisions**. |

## Scope decisions

This section formalizes which uncovered docs pages are intentional vs. true
gaps. Bullets carried over from the previous (v14.12) pass are preserved; the
three that the current tree contradicts are marked **UPDATED (v16.0)** with the
old claim and what replaced it.

- **`domain_representations` — COVERED. UPDATED (v16.0):** the previous entry
  said "the new area 1800–1814 (15 cases)". On disk the area is now
  **1800–1820, 21 cases** (fixture `fixtures/domain_representations.sql`),
  adding implicit-`select=*` formatting (1815), through-embed with `select=*`
  (1816), `not.in` and cross-relation text-parser filters (1817–1818), and two
  unknown-column error paths (1819–1820). It exercises domain cast
  representations end to end (read/write/filter/default) and is not a gap.

- **`connection_pool` — OUT OF SCOPE.** Pool behavior (sizing, acquisition
  timeout, lifetime/idletime recycling, automatic recovery) is an operational
  runtime concern with no deterministic, observable HTTP contract: it surfaces
  only under concurrency/exhaustion timing, which a black-box conformance case
  cannot assert reliably. Instead of an HTTP case, the relevant configuration
  keys are validated for parsing/aliasing in the config area:
  `db-pool`, `db-pool-acquisition-timeout`, `db-pool-max-lifetime`,
  `db-pool-max-idletime` (alias `db-pool-timeout`), `db-pool-automatic-recovery`.
  **UPDATED (v16.0):** the previous entry added that "the config case that would
  exercise their parsing/aliasing (1707) is itself deferred as `:unmodeled_key`,
  so no running case covers them today." That is no longer true — 1707
  (`config/aliases`) is a live CLI case, and `case.schema.json` has no
  `pending`/`pending_reason` field at all (see the `cli` bullet).

- **`schema_cache` — DEFERRED (future work).** Schema-cache reload and
  stale-cache behavior are only testable with a schema-reload-signal harness
  (`NOTIFY pgrst, 'reload schema'` or SIGUSR1) that mutates the live schema mid
  run and asserts the API re-introspects. No such harness exists yet; cases are
  deferred until one is built. (v16 additionally documents an admin
  `/schema_cache` endpoint — same deferral, no case.)

- **`listener` — DEFERRED (future work).** The LISTEN/NOTIFY channel
  (`db-channel`, `db-channel-enabled`) is the transport for the same
  reload-signal harness. Deferred together with `schema_cache`.

- **`http_server` — OUT OF SCOPE (new page in v16).** The whole page documents
  Warp's graceful shutdown on `SIGTERM`: stop accepting new requests, let
  in-flight requests finish, close idle `Keep-Alive` connections, and mark
  shutdown responses non-reusable (`Connection: close` on HTTP/1.x). Asserting
  any of that requires signalling the server process mid-flight and observing
  connection reuse — outside the request/response shape `case.schema.json`
  expresses, and non-deterministic as a black-box case. No case authored; not
  counted as a gap in the summary below, but recorded here so the page is not
  silently dropped.

- **`cli` (config CLI cases) — COVERED. UPDATED (v16.0):** the previous entry
  described the band as 1705–1730 with 15 passing cases and a per-case
  `pending_reason` taxonomy (`:cli_parity`, `:unmodeled_key`, `:db_config`).
  Neither half survives contact with the tree: the CLI set is now
  **1705–1741 plus 1744 (38 cases)**, and **no spec case carries `pending` or
  `pending_reason`** — those are not properties of `case.schema.json`; they were
  harness-side tags. The harness's only remaining deferral is `:status_text`
  (`test/conformance/conformance_test.exs`), which excludes the **3** cases that
  assert `expect.status_text` (**1508, 1510, 1511**) because `Req` does not
  expose the HTTP reason phrase. The `:db_config` deferrals were retired when the
  in-database config source landed. `Bier.CLI` provides the standalone,
  drop-in PostgREST-compatible CLI (`PGRST_*` env, kebab config file,
  `--dump-config`); standalone packaging (`mix release` + Dockerfile) is tracked
  in #45.

  > **CORRECTIONS THIS PASS (both were wrong on disk).** This bullet previously
  > read "the CLI band is now **1705–1738 (34 cases)**" and "excludes the **6**
  > cases that assert `expect.status_text` (1508–1511, 1513–1514)".
  > (1) The CLI set grew to 38 and is **no longer contiguous**: 1739–1741 and
  > 1744 are CLI, but **1742/1743 are HTTP** CORS cases sitting inside the config
  > band. (2) Only **3** cases carry an `expect.status_text` key. 1509, 1513 and
  > 1514 merely *mention* `status_text` — in `notes:` (1509) or inside the
  > expected `hint:` string "DETAIL must be a JSON object with obligatory keys:
  > 'status', 'headers' and optional key: 'status_text'." (1513/1514) — so they
  > are not excluded and do run. This matches `CLAUDE.md`, which already said 3.

*(Scope decisions re-verified against the tree this pass: every bullet above
still matches disk — 1800–1820 is 21 cases, 1707 is a live CLI case, the CLI set
is 1705–1741 + 1744 = 38, and exactly 3 cases carry `expect.status_text`. Nothing
in this section was rewritten.)*

*(Re-verified once more at the 637-case state: all four facts still hold, and
the filters re-sync — the only change since — touched no scoped-out page. The
bullets above are carried forward **verbatim**; nothing on disk contradicts
them.)*

*(Re-verified a third time at the **643**-case state, fact by fact against disk:
`domain_representations` is 1800–1820 = **21** cases; **1707** is a live
`kind: cli` / `--dump-config` case and `case.schema.json` contains no `pending`
key at all (`grep -c pending` → 0); the CLI set is **1705–1741 + 1744 = 38**;
exactly **3** cases carry `expect.status_text` (1508, 1510, 1511). The ordering
re-sync — the only change since — added six cases to a covered page and touched
no scoped-out page. Nothing in this section was rewritten; only this
verification note was appended.)*

## Coverage summary

- Docs pages enumerated: **27** — 16 API sub-pages + 11 top-level reference
  pages (the `references/api` parent page is counted once, through its
  sub-pages; `url_grammar` is counted once). Re-enumerated from
  postgrest.org/en/v16 this pass; the page set is unchanged.
- Pages with at least one covering case: **23**.
- Pages explicitly scoped: **4** — `connection_pool` (out of scope),
  `http_server` (out of scope, new in v16), `schema_cache` (deferred),
  `listener` (deferred).
- Pages flagged **GAP** (no covering case and not scoped out): **0**.

Two pages are new in v16 relative to the previous pass: `api/vary_header`
(covered, 1575–1576 and 1582–1583) and `http_server` (scoped out — see above).

**Twelve** pages are marked **Partial** in the notes above (`options`,
`transactions`, `admin_server`, `observability`, `auth`, `preferences`, `cors`,
`configuration`, `resource_embedding`, `aggregate_functions`, `errors`, and —
from the filters audit — **`tables_views`**): they have covering cases but not
the full breadth of the docs page. These are soft gaps, itemized next.
`vary_header` stays **covered** but carries one itemized gap (the preflight leg).
The count is unchanged by the ordering pass: its two findings both land on
`resource_embedding`, which was already Partial.

`tables_views` remains the notable one: it is the single densest page in the tree
(seven areas, **285** cases feed it after the ordering pass), and it still misses
the page's opening rule on combining filters — that two plain filters on one
request are ANDed. Density is not coverage. `resource_embedding` makes the same
point from the other direction: the ordering audit found a **named docs section**
with its own worked example (*Order in spread to-many*) and zero assertions
anywhere in `spec/`, sitting next to 60+ cases that cover the rest of the page.

## Known gaps

Soft gaps — documented public behavior with no conformance case. **None is a
citation defect.** They fall into two kinds, and the distinction matters when
prioritizing:

- **Uncitable** — the ground truth to cite does not exist upstream at v16.0, or
  cannot be expressed in the current `case.schema.json` shape (multi-request
  sequences, signals, timing). Most of the *auth* and *observability* entries.
  These stay open until the harness or upstream changes.
- **Citable but uncovered** — upstream *does* assert the behavior at v16.0 with
  a fetchable it-block or golden file, and the case shape can express it; nobody
  wrote the case. **All five *select* entries, all three *filters* entries, all
  three *headers* entries, both *config* entries and both *ordering* entries are
  of this kind**, so they are the actionable ones. Each is labelled below.

A third axis cuts across both kinds and is what actually decides effort:
**what does closing it cost?** Of the fifteen citable-but-uncovered entries:

- **eight are case-only** — select's spread-to-many and terminal-`->`; filters'
  `in.()` (its core assertion; only the eight-column-type sweep needs a fixture)
  and the implicit AND; headers' RPC `handling` and the preflight `Vary`
  assertion; **ordering's order-in-spread-to-many and its aliased-relation
  PGRST118** (both mintable on relations the loaded DB already has);
- **four need fixture objects the consolidated DB does not have** — select's FK
  joins on views/chains and on partitioned tables, headers' RPC `max-affected`
  routines, filters' `empty_string` row;
- **two are blocked on the frozen harness honouring a case's `config:` block** —
  config's `app.settings.*` and select's aggregates-in-to-one-spreads;
- **one, config's `db-pre-config`, needs a pre-config function reachable at
  startup**, which is a fixture *and* harness decision.

The eight case-only entries are the whole of the low-cost work available, and the
two ordering entries are the cheapest of them: both reuse the
`ordering.projects` → `ordering.tasks` graph that case 1229 already drives.

### select (adversarial review verdict: **revise** — findings are *citable but uncovered*)

Five missing-coverage findings, **0 citation defects**. Ordered by priority.
Cases **1142–1149** were authored after the review; they close none of findings
1–4 and only partially touch finding 5 (noted inline).

- **Foreign Key Joins on Views / Chains of Views — no case anywhere in
  `spec/conformance/cases`, and no gap entry either.**
  [`resource_embedding.html#foreign-key-joins-on-views`](https://postgrest.org/en/v16/references/api/resource_embedding.html#foreign-key-joins-on-views)
  documents that PostgREST detects a view's source-table FKs and can embed
  through a view, including through *chains* of views. Upstream covers it
  densely — **20 `it`-blocks** in
  [`QuerySpec.hs#L883`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/QuerySpec.hs#L883)
  through `#L1020`. Nothing in the tree asserts it and nothing records it as a
  gap. **Highest-priority select gap**: it is a whole documented embedding
  mechanism, not a corner. Closing it needs the upstream view fixtures
  (`projects_view`-style chains), so it is a fixture decision, not a case-only
  edit.

- **Spread To-Many relationships — modeled, gap recorded, but the gap's
  justification does not hold.**
  [`resource_embedding.html#spread-to-many-relationships`](https://postgrest.org/en/v16/references/api/resource_embedding.html#spread-to-many-relationships)
  documents spreading a one-to-many so that each child column becomes a JSON
  *array* on the parent. `spec/select.yaml` carries entry
  `select.spread_one_to_many_arrays` with the gap "it needs the
  factories/processes fixture, which bier_test does not have"
  ([`SpreadQueriesSpec.hs#L93`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/SpreadQueriesSpec.hs#L93)).
  That justification is **weak**: this area already reproduces upstream *shapes*
  on local relations where the upstream fixture is missing — cases **1124** and
  **1140** do exactly that, by their own `notes:` — and
  `/projects?select=name,...tasks(name)` exercises the same behavior on
  relations `bier_test` already has. **Actionable with no fixture work**; the
  gap text should be rewritten or the case written.

- **Aggregates in To-One Spreads — an entire upstream context with no case and
  no entry; the paired PGRST127 rejection is absent from the whole tree.**
  [`aggregate_functions.html#aggregates-in-to-one-spreads`](https://postgrest.org/en/v16/references/api/aggregate_functions.html#aggregates-in-to-one-spreads)
  is backed upstream by
  [`AggregateFunctionsSpec.hs#L143`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/AggregateFunctionsSpec.hs#L143)
  through `#L295`, including nested spreads and the `count()`-without-field
  variants. Neither `spec/select.yaml` nor any case mentions it. Its negative
  counterpart — aggregates in a **to-many** spread are rejected with
  **PGRST127** ([`AggregateFunctionsSpec.hs#L298`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/AggregateFunctionsSpec.hs#L298))
  — is likewise absent: re-checked this pass, `grep -rl PGRST127 spec/` matches
  **only this file and `conformance/INDEX.md`**, i.e. the two documents that
  record the gap. No case asserts the code and no area model mentions it. Note
  any new case here inherits the harness constraint below (aggregates need
  `db-aggregates-enabled: true`).

- **Foreign Key Joins on Partitioned Tables — not cased, not recorded.**
  [`resource_embedding.html#foreign-key-joins-on-partitioned-tables`](https://postgrest.org/en/v16/references/api/resource_embedding.html#foreign-key-joins-on-partitioned-tables),
  upstream
  [`QuerySpec.hs#L789`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/QuerySpec.hs#L789).
  Lower priority than the three above — a narrower mechanism — but it belongs in
  `select.yaml`'s `gaps:` at minimum. Needs partitioned-table fixtures.

- **Terminal `->` on a json/jsonb column (returning a JSON value, not text) —
  claimed by an entry whose cases all end in `->>`.** Entry
  `select.json_arrow_text_key` (`spec/select.yaml:104`) claims both halves of the
  rule ("`->` navigates into a json/jsonb subfield keeping json type; `->>`
  extracts the field as text"), but its only cases — **1107–1110** — every one
  terminates in `->>` (`settings->foo->>bar`, `…->>int::integer`,
  `myBar:settings->foo->>bar`, `data->>0::int`). Upstream asserts the `->`
  terminal form separately at
  [`JsonOperatorSpec.hs#L142`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/JsonOperatorSpec.hs#L142)
  ("works when finishing with an index"). **Partially addressed since the
  review, but the gap stands**: new case **1143** (`/fav_numbers?select=num->i`)
  covers the *composite*-column variant and **1145**
  (`/arrays?select=a:numbers->0,…`) the *array*-column variant — both of which
  PostgREST routes through `to_jsonb(col)` before applying the path. Neither is a
  json/jsonb column terminating in `->`, which is the one the entry's claim
  names. Cheapest of the five to close: `test.json_arr` and
  `test.complex_items.settings` already exist.

### filters (adversarial review verdict: **revise** — findings are *citable but uncovered*)

Three missing-coverage findings, **0 citation defects**. The filters re-sync
that produced cases 1191–1199 closed a different set of gaps (embed
null-filtering, third-level filters, or-across-embeds) and did **not** touch
these three; all three remain open on disk. Each upstream anchor below was
re-fetched and read this pass, so the line numbers are verified, not carried
over.

- **`IN` / `NOT IN` with an empty set — an entire upstream `describe` block with
  no entry, no case, and until now no gap.** Upstream
  [`QuerySpec.hs#L1359`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/QuerySpec.hs#L1359)
  opens `describe "IN and NOT IN empty set"` and asserts **eleven** it-blocks
  against `items_with_different_col_types`:
  - `?<col>=in.()` → `[]` for eight column types (int, text, bool, bytea, char,
    date, real, time), L1361–L1384;
  - `?int_data=not.in.()&select=int_data` → **all** rows (the table seeds one:
    `[{"int_data": 1}]`), L1386;
  - `?int_data=in.(    )` → `[]`, spaces ignored, L1390;
  - `?int_data=in.( ,3,4)` → **400** with SQLSTATE `22P02`, `"invalid input
    syntax for type integer: \"\""` — an empty *element* is not an empty *set*,
    L1394.

  This is the behavior that motivates the very `SqlFragment` branch the
  operators model already cites: `spec/operators.yaml:213` documents
  `"value is a parenthesised list … Empty value => = ANY('{}')"` and
  `:221–222` pin the `[""] -> "= ANY('{}')"` line
  ([`SqlFragment.hs#L409`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/src/library/PostgREST/Query/SqlFragment.hs#L409)).
  So the rule is *modelled in prose in the wrong area and asserted nowhere*:
  **no case in the whole tree issues an `in.()` request** (re-run this pass:
  `grep -rn 'in\.()' spec/` matches 12 lines, 7 of which are this file's own gap
  text; outside it, exactly five — a parser comment at `operators.yaml:70` and
  the `notes:` of cases 1025, 1026, 1027 and 1053, every one of which uses a
  *non-empty* list).
  **Actionable, mostly case-only.** The empty-set semantics are type-independent
  — one branch on the parsed value, before any type is involved — so the
  primary assertion reproduces on relations `bier_test` already has
  (`/items?id=in.()` → `[]`, `?id=not.in.()` → all rows, `in.(    )` → `[]`,
  `in.( ,3,4)` → 400/22P02). Only the eight-column-type sweep needs the upstream
  `items_with_different_col_types` fixture, which is **not** in `fixtures.sql`
  (verified: `grep -c` → 0, and the relation is absent from the loaded DB).
  Decide the owning band first: the *value grammar* is filters, but the `in`
  operator's SQL rendering is claimed by operators, and the filters primary
  band 1150–1199 is now full (overflow range `[10600..10799]`).

- **Empty filter *value* (`=eq.` with nothing after the dot) — no entry, no
  case, no gap, in filters or any other area.** Upstream
  [`QuerySpec.hs#L1670`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/QuerySpec.hs#L1670)
  is `context "searching for an empty string"` / `it "works with an empty eq
  filter"`: `GET /empty_string?string=eq.&select=id,string` → **200**,
  `[{"id":1,"string":""}]`. It pins that a trailing-empty value is a legitimate
  empty string rather than a parse error or a NULL — the exact place a
  hand-written parser goes wrong.
  **Needs a fixture, and this is verified, not assumed.** `empty_string` is in
  neither `fixtures.sql` nor `fixtures_local.sql` (`grep -c` → 0 in both), and a
  sweep of *every* `text`/`varchar` column of every table in schema `test` on
  the freshly loaded `bier_test` found **no** row anywhere holding `''`. There
  is nothing to reproduce the shape on: closing this needs a seeded empty-string
  row (a `filters.delta.sql` — which would be the area's first; `filters.yaml`
  currently states it adds no fixture objects at all).

- **Implicit AND of two plain horizontal filters — the Horizontal Filtering
  page's opening rule on *combining* filters, with no filters entry and no
  filters case.**
  [`tables_views.rst#L46-L50`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/docs/references/api/tables_views.rst)
  (verified by fetching the file: L46 is "You can evaluate multiple conditions
  on columns by adding more query string parameters … 18 or older **and** are
  students", L50 the `curl "…/people?age=gte.18&student=is.true"`) — two
  independent filters, ANDed, immediately after the single-filter example.
  `spec/filters.yaml` models only the *mixed* form:
  `filters.logic.combined_with_traditional` ("a logic param and a traditional
  horizontal filter … are ANDed", case 1160) — a logic tree plus one filter,
  not two plain filters.
  **Lowest severity of the three, and deliberately labelled so.** The shape is
  exercised incidentally in three other areas — 1423
  (`/rpc/getallprojects?id=gt.1&id=lt.5`), 1612 (`/items?id=gt.0&id=lt.0`) and
  1802 (`/datarep_todos?…&id=gt.2&id=lt.5`) — so a regression would not pass
  silently. Two caveats keep it a real gap rather than a bookkeeping one: those
  are rpc / content-negotiation / domain-representation assertions that merely
  *happen* to use two filters, and all three AND **two conditions on the same
  column** (a range), where the docs' rule is about **two different columns**.
  The area that owns filter composition records no gap for either.
  **Case-only if closed** (two filters on `test.items`); the honest alternative
  is an entry in `filters.yaml` that names the three cross-area cases as the
  claim's evidence, the way this area already re-homes `ilike`/`cd`/`is`
  case-insensitivity onto operators cases.

### ordering (adversarial review verdict: **revise** — findings are *citable but uncovered*)

Two missing-coverage findings, **0 citation defects**. Both were raised against
the tree *after* the six new cases 1227–1232 landed, so neither is closed by
them. Both are **case-only** and both reproduce on relations the loaded
`bier_test` already has — the two cheapest open entries in this file. Unlike
filters, the ordering primary band is **not full**: 1200–1232 is in use, so
**1233+** is available without an overflow-range decision.

- **Order in spread to-many — a *named section* of the v16 docs with zero
  assertions anywhere in `spec/`.**
  [`resource_embedding.rst` § *Order in spread to-many*](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/docs/references/api/resource_embedding.rst)
  documents that the values inside the correlated arrays produced by a spread
  to-many are *unspecified* in order unless you say otherwise, and gives the
  worked example
  `directors?select=first_name,...films(film_titles:title,film_years:year)&first_name=like.Quentin*&films.order=year`
  — plus a nested twin further down that adds `films.roles.order=character`
  alongside `films.order=year`. Upstream exercises the same surface at
  [`SpreadQueriesSpec.hs#L163`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/SpreadQueriesSpec.hs#L163)
  (`#L185`, `#L196`) and
  [`AggregateFunctionsSpec.hs#L157`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/AggregateFunctionsSpec.hs#L157)
  (`#L168`). **No case in the 1200–1232 band touches it**; the tree records it
  only as the `order.spread_embed` gap in `spec/ordering.yaml:505`.

  **The gap's justification does not hold, and that is the finding.** The gap
  argues that every relation the behavior needs (`factories`, `processes`,
  `process_categories`, `supervisors`, `budget_categories`, …) is absent from the
  consolidated fixture DB, so standing them up would mint a large shared fixture
  surface outside the area's ownership. The *relations* are indeed absent —
  verified — but the *behavior* is not tied to them: an order inside a spread
  to-many reproduces directly on `ordering.projects` → `ordering.tasks`
  (`/projects?select=name,...tasks(task_names:name)&tasks.order=name`), the exact
  graph case **1229** already drives, and both relations exist in the loaded DB
  (checked this pass). Reproducing an upstream *shape* on local relations when
  the upstream fixture is missing is a pattern this tree already sanctions — the
  select area does it in cases **1124** and **1140**, by their own `notes:`.
  **Actionable with no fixture work**: either write the case in the 1233+ band or
  rewrite the gap text to stop resting on a fixture argument that the local graph
  defeats.

  > **Anchor caveat, recorded rather than smoothed over.** Two independent reads
  > of `resource_embedding.rst` placed the section differently — the adversarial
  > reviewer at **L1215–L1227** with the nested twin at **L1280–L1281**, this
  > pass's re-fetch at roughly **L1280–L1310**. Both agree on the section title
  > and on the example text quoted above, which is what the claim rests on.
  > Re-confirm the exact `#L` anchor against the raw file when the case is
  > authored; do not copy either range on trust.

- **Related-order PGRST118 names the *alias*, not the relation — asserted
  upstream, stated in a `notes:` field, pinned by no case.** Upstream
  [`RelatedQueriesSpec.hs`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/RelatedQueriesSpec.hs#L118)
  runs the not-to-one related order twice: once unaliased
  (`/clients?select=*,projects(*)&order=projects(id)`, the `#L107` it-block that
  case **1216** transcribes) and once **aliased**
  (`/clients?select=*,pros:projects(*)&order=pros(id)`), where the 400 envelope
  reads `"details": "'clients' and 'pros' do not form a many-to-one or
  one-to-one relationship"` and `"message": "A related order on 'pros' is not
  possible"` — i.e. the error names `pros`, the alias, not `projects`. That is
  `fromMaybe relName relAlias`
  ([`Plan.hs#L883`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/src/library/PostgREST/Plan.hs#L883)).
  The rule is written down in case **1228**'s `notes:` ("The details/message name
  the relation as addressed in the query string, i.e. `fromMaybe relName
  relAlias`") but **no case exercises the alias path**, and the model entry
  `order.related_not_to_one_error` (`spec/ordering.yaml:410`) claims only the
  generic form with `cases: [1216]`.
  **Minor but genuinely uncovered, and case-only**: `ordering.clients` and
  `ordering.projects` both exist in the loaded DB, so one case in the 1233+ band
  closes it with no fixture work. Same anchor caveat as above — the reviewer
  cites `#L118–L127`, this pass's re-fetch placed the aliased it-block at roughly
  `#L113–L120`; both agree it is the block immediately following `#L107`.

### config (adversarial review verdict: **revise** — findings are *citable but uncovered*)

Two missing-coverage findings, **0 citation defects**.

- **`db-pre-config` / In-Database Configuration via a pre-config function — no
  case, and the v16 docs make this the *recommended* mechanism.**
  [`references/configuration.html#in-database-configuration`](https://postgrest.org/en/v16/references/configuration.html#in-database-configuration)
  explicitly demotes the `ALTER ROLE … SET pgrst.*` path to "backwards
  compatibility … no longer recommended as it requires SUPERUSER", yet the
  tree's only in-db-config cases — **1724**, **1725**, **1744** — exercise
  exactly that deprecated path. The recommended path is **dump-observable**, so
  this fits the existing CLI case shape: `PGRST_DB_CONFIG=true` +
  `PGRST_DB_PRE_CONFIG=<fn>` with a function calling
  `set_config('pgrst.db_max_rows','500',true)` must make `--dump-config` emit
  `db-max-rows = 500`. Upstream golden:
  [`test/io/configs/expected/no-defaults-with-db-other-authenticator.config`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/io/configs/expected/no-defaults-with-db-other-authenticator.config),
  driven from
  [`test/io/test_cli.py#L165`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/io/test_cli.py#L165).
  `spec/config.yaml` does record a `db-pre-config` gap, but it understates the
  situation — it says "a runtime HTTP assertion was not located in v16.0
  test/spec", which is true and beside the point: the behavior is assertable
  today through the **CLI** shape. **Actionable**: needs a `preconditions_sql`
  channel (or a fixture-side pre-config function) plus one CLI case; the case
  shape itself is already sufficient.

- **`app.settings.*` reaching SQL as a GUC — no case anywhere in `spec/`, and
  until now no gap entry either.** Case **1729**
  (`config/app-settings/from-env`) pins only the `--dump-config` surface: that
  `PGRST_APP_SETTINGS_<NAME>` normalizes to `app-settings.<name>`. But the
  entire documented purpose of the parameter
  ([`references/configuration.html#app-settings`](https://postgrest.org/en/v16/references/configuration.html#app-settings))
  is that the value is readable from PostgreSQL functions via
  `current_setting('app.settings.<name>')`. Upstream asserts exactly that over
  HTTP: the it-block *"app settings available"* POSTs `/rpc/get_guc_value` with
  `{"name":"app.settings.app_host"}` and expects `"localhost"`
  ([`RpcSpec.hs#L914`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/RpcSpec.hs#L914)),
  with `configAppSettings = [("app.settings.app_host","localhost"),
  ("app.settings.external_api_secret","0123456789abcdef")]` in `baseCfg`.
  **Actionable and cheap**: `test.get_guc_value(name text)` already exists in
  `fixtures.sql:982` and already backs the auth-area GUC cases (1478–1485), so
  this needs only a case file — plus a harness that honours the case's `config:`
  block (see the next bullet).

- **Harness constraint that blocks already-written cases (not a spec gap, but it
  belongs here).** Case **1742**
  (`config/server-cors-allowed-origins/default-preflight`) is correct as written
  and declares the `server-cors-allowed-origins: ""` that upstream's `baseCfg`
  carries, but the frozen harness honours a `config:` block only for
  `kind: cli` cases and for the fixed `@variant_case_ids` list in
  `test/support/conformance_server.ex` (18 ids — 1467–1473, 1491, 1493, 1654,
  1677, 1678, 1680, 1682, **1703**, 1758, 1763, 1764 — which contains 1703 but
  **not 1742**). Every other HTTP case runs against a shared instance whose
  `server_cors_allowed_origins` is `"http://example.com, http://example2.com"`,
  so 1742 will echo the Origin instead of returning the permissive `*` and will
  **fail for the wrong reason**. Closing it is a harness decision (per-`config`
  instance booting, or a `@variant_case_ids` entry for 1742) behind the human
  harness gate, not a spec edit. **114** of the 643 cases carry a `config:` key
  (110 non-empty); 1742 is the one where the block is load-bearing and
  unhonoured for a *config*-area assertion, and the select area contributes ten
  more (see the next bullet).

- **Same constraint, select area — ten cases.** `spec/select.yaml`'s
  `harness_exposure` gap lists **1129–1133, 1139, 1140, 1147, 1148, 1149**;
  re-verified on disk this pass, those are exactly the ten select cases carrying
  a `config:` block and none is in `@variant_case_ids`. Eight need
  `db-aggregates-enabled: true` (PostgREST's default is `False`,
  [`Config.hs#L276`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/src/library/PostgREST/Config.hs#L276);
  upstream runs the spec under `baseCfg { configDbAggregates = True }`) and two
  need `url-use-legacy-target-names: false`. Until the harness owner wires them,
  all ten run with default config.

### auth (adversarial review verdict: **revise** — all findings informational)

- **`kid` verification.** Docs *JWT Signature Verification → Asymmetric Keys →
  kid verification*: a JWT whose `kid` matches no key in a JWKS is rejected 401;
  a JWT without `kid` falls back to trying each key. No case. The reviewer
  independently confirmed the gap's justification: `kid` appears nowhere in
  `test/io/*` or `test/spec/Feature/Auth/*` at v16.0, and the new
  `AsymmetricJwtSpec` JWKSet context uses a **single-key** set — so no black-box
  ground truth exists to cite. Informational, not a defect.
- **`jwt-role-claim-key` `search()` filter.** The *JWT Role Extraction* docs name
  `search()` as the only JSON Path function available, and `CHANGELOG.md#L91`
  makes it the replacement for the removed `^==` / `==^` / `*==` operators. No
  case. Verified: no `search(` occurrence in `test/io/fixtures/fixtures.yaml` at
  v16.0, so "no fixture exercises it end-to-end" is accurate.
- **Multi-request behaviors** — blocked on `case.schema.json` expressiveness, and
  correctly disclosed as gaps rather than approximated:
  (a) `JwtCacheSpec.hs#L20`/`#L35` assert *cross-request* properties (the second
  JWT parse duration ≤ the first); case 1497 pins only the single-shot 200, and
  the `jwt;dur=` metric itself is pinned by observability case 1750.
  (b) `AuthSpec.hs#L138` "recovers after 401 error with logged in user" is a
  three-request ordered sequence.
- **Deliberately not carried over (available strengthenings, not defects):** the
  upstream `Content-Length` matchers on `AuthSpec.hs#L24`/`#L37`/`#L102` (96 /
  97 / 100) for cases 1450/1451/1455, and the `Proxy-Status` header on the
  PGRST301 response (`ErrorSpec.hs#L51`) for 1457. Both are disclosed in
  `auth.yaml`'s `gaps:`, and the `Proxy-Status` envelope behavior is already
  pinned by the errors area (1002, 1506, 1515–1516, 1518).
- Further auth gaps recorded in `spec/auth.yaml` (`gaps:`): ES256 and EdDSA
  verification (library-supported, no upstream test at v16.0), JWKS multi-key
  rotation, and relative-time claim values (the 30 s clock-skew *boundary* is
  modeled but unconstrained, because `request.jwt.payload` is a static object —
  upstream never asserts the inside-the-window side either).

### headers (adversarial review verdict: **revise** — findings are *citable but uncovered*)

Three missing-coverage findings, **0 citation defects**. Unlike the auth
entries above, none of these is blocked on upstream ground truth or on case
expressiveness — upstream asserts all three at v16.0 and the case shape can
express them, so all three are actionable.

- **`Prefer: max-affected` on RPC — no case anywhere in `spec/`, and it was not
  even recorded as a gap.** Upstream has a whole `context "test Prefer:
  max-affected with rpc"` block —
  [`MaxAffectedSpec.hs#L85`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/Preferences/MaxAffectedSpec.hs#L85)
  through `#L128`, five `it`-blocks: `POST /rpc/delete_items_returns_setof` and
  `/rpc/delete_items_returns_table` with `handling=strict, max-affected=10`
  against 15 rows → **400 PGRST124** (`"details": "The query affects 15 rows"`);
  the same two routines with `max-affected=20` → **200** and the 15-row body;
  and `POST /rpc/delete_items_returns_void` with `handling=strict,
  max-affected=20` → **400 PGRST128**, `"Function must return SETOF or TABLE
  when max-affected preference is used with handling=strict"`. Documented at
  [`preferences.rst#L273-L303`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/docs/references/api/preferences.rst)
  (the RPC paragraph plus the closing `.. note::` that names PGRST128). Bier's
  only `max-affected` cases are table-flavored (1390–1392 mutations, 1555–1556
  headers), and **`PGRST128` is asserted by no case and modelled by no area
  file** (re-checked this pass: `grep -rl PGRST128 spec/` matches only this file
  and `conformance/INDEX.md`, the two documents recording the gap) — so the
  error code itself is entirely uncovered. `spec/rpc.yaml` explicitly delegates this
  coverage to the headers area ("Both preferences are modeled by the
  headers/mutations areas … so they stay out of this area to avoid duplicate
  ownership"), which means neither area owns it in practice. **Actionable**:
  authoring these needs `rpc`-fixture routines equivalent to
  `delete_items_returns_setof` / `_returns_table` / `_returns_void`, which do
  not exist in `fixtures.sql` — a fixture delta, not just a case file.

- **`Prefer: handling=strict|lenient` on RPC — claimed but not pinned.** The
  model entry `headers.prefer.handling.strict.error` claims the behavior
  generally, and `spec/rpc.yaml` delegates the RPC flavor here, but cases 1551
  and 1552 are both `GET /items` — table-flavored only. Upstream asserts the RPC
  flavor separately:
  [`HandlingSpec.hs#L35`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/Preferences/HandlingSpec.hs#L35)
  ("throws error with rpc", `POST /rpc/overloaded_unnamed_param` with
  `handling=strict, anything` → 400 PGRST122) and `#L62` ("does not throw error
  with rpc", the same route with `handling=lenient, anything` → 200, body
  `1`). Unlike the max-affected gap, this one is cheap to close:
  `rpc.overloaded_unnamed_param` already exists in the fixtures (it backs the
  `rpc/single-unnamed-param` and `rpc/overloaded` cases).

- **CORS preflight responses carry no `Vary` — the negative counterpart of
  `headers.vary.default` / `headers.vary.non_read_responses`, unmodelled and
  unrecorded.** Cases 1575/1582 pin that the default `Vary: Accept, Prefer,
  Range` is appended by `App.hs`' `toWaiResponse`, and 1583 pins its absence on
  errors, but a *preflight* is a third path: with an `Origin` present,
  `corsPolicy` returns a policy
  ([`Cors.hs#L27`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/src/library/PostgREST/Cors.hs#L27))
  and the wai-cors middleware answers the OPTIONS itself, so the response never
  reaches `toWaiResponse`; `corsVaryOrigin = False` (`Cors.hs#L39`) means it
  does not even gain a `Vary: Origin`. The preflight cases **already exist**
  (1702/1703, and 1742, all in the config band) and would only need
  `headers_absent: [Vary]` added — but they are frozen ground truth, and the id
  band is `config`'s, so the fix is an authoring decision (extend the existing
  preflight cases vs. add a headers-band case) rather than a mechanical edit.
  Note case 1582 deliberately sends **no** `Origin` precisely so its OPTIONS is
  *not* treated as a preflight, which is why the two rules do not collide.

### observability

- **Metrics** (`/metrics`, plus the schema-cache / connection-pool / JWT-cache /
  GHC runtime metric families) — no case; the admin `/metrics` endpoint is not
  implemented.
- **SQL query logs** (`log-query`) — documented in v16, implemented in Bier
  (`log-query` CLI config key), but no conformance case pins it.
- **Server version header** — no case asserts the `Server: postgrest/<version>`
  response header.

### admin_server

- `/metrics` and `/schema_cache` endpoints have no case (`/live` and `/ready`
  are covered by ExUnit, not by the conformance suite).

### options / transactions

- `options`: no dedicated assertions on the `Allow` header contents beyond 1019.
- `transactions`: no explicit transaction-characteristics / isolation-level case.

## Validation status

Machine-verified on **2026-08-08** at commit **`4705810`**
("spec(filters): re-sync to PostgREST v16.0 (area 5/17)"), against a tree
**dirty mid-re-sync**: 3 modified (`spec/ordering.yaml`, `spec/COVERAGE.md`,
`spec/conformance/INDEX.md`) plus 6 untracked new ordering cases
(**1227–1232**). The checks cover the on-disk state *including* those. No
repository file was modified by the verification — its scripts live in a
scratchpad outside the repo. **All six checks ran for real and every one
passed**; the substantive findings are recorded under *Open verification
finding* below.

- **Fixture load: OK.** `mix bier.fixtures.load` exited **0**, reporting the
  mirrored area schemas: `operators, ordering, pagination, representations,
  mutations, config, domain_representations`. The loader wires the human-owned
  supplement (`lib/mix/tasks/bier.fixtures.load.ex:105` expands
  `spec/conformance/fixtures_local.sql`). Post-load sanity on the loaded DB:
  **616** relations with `relkind in ('r','v','m','f','p')` excluding
  `pg_catalog`/`information_schema`/`pg_toast` (**827** counting *all*
  namespaces — the two figures use different filters and are not comparable),
  **1025** non-catalog functions, `select count(*) from test.items` → **15**.
  Schemas present: `SPECIAL "@/\#~_-`, `auth`, `config`,
  `domain_representations`, `geotest`, `headers`, `headers_private`, `jwt`,
  `mutations`, `observability`, `openapi_no_comment`, `operators`, `ordering`,
  `pagination`, `postgrest`, `private`, `public`, `representations`, `rpc`,
  `test`, `v1`, `v2`, `تست` — 23 schemas, byte-identical to the previous pass's
  list (the ordering re-sync added no fixture delta, so no new namespace).
  *(An earlier pass recorded 618 relations under the same catalog-excluding
  filter and the one before that 616. Nothing in the fixture tree changed
  between those passes, so the difference is a reload artifact, not a fixture
  edit. No case depends on the count; recorded rather than chased. This pass's
  run reported the schema list only.)*
- **Case count: 643** — `ls -1 spec/conformance/cases/*.yaml | wc -l` and the
  validator agree (643 files, 643 parsed), and `ls -1
  spec/conformance/cases/ | wc -l` is also **643**: **0** non-`.yaml` entries in
  the directory.
- All **643** cases parse as YAML. **0** parse errors, **0** non-mapping roots.
- All **643** cases validate against `case.schema.json` (`jsonschema` 4.26.0,
  Draft 2020-12, Python 3.14, PyYAML 6.0.3) — **0** invalid cases. The validator
  was proved **live rather than vacuous** by a negative control on a mutated copy
  of a pristine case: dropping `feature` → *"'feature' is a required property"*;
  `status: 999` → *"999 is greater than the maximum of 599"*; an extra key →
  *"Additional properties are not allowed ('bogus' was unexpected)"*.

  > **FAILURE OF THE NEGATIVE CONTROL, recorded honestly: the schema does not
  > enforce the pin.** The fourth control — rewriting a `source:` URL onto a
  > *different* PostgREST tag — produced **0 errors, NOT CAUGHT**. The schema's
  > pattern is
  > `^https://raw\.githubusercontent\.com/PostgREST/postgrest/.+#L[0-9]+$`, whose
  > `.+` matches any tag. So a clean schema run proves every case carries a
  > raw-host citation with a line anchor — it proves **nothing** about the
  > version. The URL sweep below is the *only* check that enforces `v16.0`;
  > do not substitute the schema run for it. (`case.schema.json` is the Tester's
  > file and was deliberately not edited here; tightening the pattern to the
  > pinned tag would be a Tester-side change.)
- **643** files, **643** distinct ids — **no duplicate ids**
  (`grep -h '^id:' … | sort -u | wc -l` → 643 for 643 files), and every `NNNN_`
  filename prefix equals the in-file `id:` (**0** mismatches).
- **Source pins: clean, single tag.** A regex sweep of every PostgREST
  `github`/`raw.githubusercontent` URL across `spec/*.yaml`, `spec/*.md` and
  `spec/conformance/cases/*.yaml` (in `source:` fields and in `notes:` prose
  alike) found **1738** references and **exactly one tag: `v16.0`**. Zero stale
  pins in scope. All **643** `source:` lines carry the tag (cases contribute
  **647** URLs — four cases cite an extra URL in `notes:`). Per group:
  `spec/*.yaml` + `spec/*.md` **1091** (1018 raw + 73 `blob/`),
  `spec/conformance/cases/*.yaml` **647**. Doc links resolve to
  `postgrest.org/en/v16`. This is the **only** check that enforces the pin — see
  the schema-validation caveat above.

  > **Use a prefix-aware pattern.** A naive `grep -vE 'postgrest/v16\.0/'`
  > reports false stale hits — **73** of them at this state: those are
  > `github.com/PostgREST/postgrest/blob/v16.0/…` lines where `blob/` sits
  > between the repo and the tag. All 73 are v16.0. Match
  > `postgrest/(raw/|blob/|tree/)?<tag>`.

  > **103 bare `v14.12` occurrences are prose, not citations.** Re-counted on
  > disk this pass across the 19 files of `spec/*.yaml` + `spec/*.md`: this file
  > (12), `url_grammar.md` (11), `auth.yaml` (10), `config.yaml` (8),
  > `errors.yaml` (7), `filters.yaml`/`observability.yaml`/`ordering.yaml`/`pagination.yaml`
  > (6 each), `content_negotiation.yaml`/`headers.yaml` (5 each), `select.yaml`
  > (4), `README.md`/`openapi.yaml`/`rpc.yaml` (3–4), `mutations.yaml` (2),
  > `domain_representations.yaml`/`operators.yaml`/`representations.yaml`
  > (1 each) — plus **23** case files. Sampled contexts are deliberate
  > v14.12→v16.0 change notes ("v16 dropped the named `testUnicodeCfg` helper
  > that v14.12 kept in `SpecHelper.hs`"; "the block is byte-identical to
  > v14.12, only the `src/library/` path and line numbers move"; "v16.0 moved to
  > RFC 9535 JSONPath, so a leading-dot expression — the v14.12 grammar — is now
  > itself invalid"). Verified mechanically, not sampled: **zero** files in
  > `spec/*.yaml`, `spec/*.md` or `spec/conformance/cases/*.yaml` contain a
  > `v14.12` *URL*. **Not** counted as stale pins.
- **Stale pins outside the checked globs — 51 `v14.12` URLs, unchanged.**
  Re-counted this pass with the prefix-aware pattern: **eight** files, **51**
  URLs, all in `--` provenance comments under `spec/conformance/fixtures/`:
  `ordering.sql` **27**, `observability.sql` **7**, `errors.sql` **5**,
  `auth.sql` **4**, `mutations.sql` **3**, `config.sql` **2**, `filters.sql`
  **2**, `rpc.sql` **1**. (A looser `grep -c v14.12` over the same directory
  returns **78** *lines* across **17** files — most are prose mentions, not
  URLs; the 51 is the URL count.) Per `conformance/fixtures/README.md` these
  files are historical provenance and explicitly **not authoritative** (the live
  artifact is `fixtures.sql`), and `.sql` is outside the pin check's declared
  globs — so this is **not** an in-scope failure. It is nonetheless real
  leftover pin drift the v16.0 re-sync has not touched.
- **Citation composition (not a check — an honesty note).** Grouping all **643**
  `source:` lines by directory: **460** cite `test/spec/Feature/Query`, 44
  `test/spec/Feature/Auth`, 34 `test/spec/Feature/OpenApi`, 15
  `test/spec/Feature/Query/Preferences`, 10 `test/spec/Feature`, 45 the
  `test/io` tree (fixtures/configs/golden files) — and **35** cite
  implementation code under `src/library/PostgREST/…` rather than an upstream
  assertion (26 directly under `src/library/PostgREST`, 6 under `.../ApiRequest`,
  2 under `.../Response`, 1 under `.../Config`). Those 35 expected bodies are
  *derived from reading the implementation*, not transcribed from an it-block,
  which is a weaker form of ground truth even though it is not a citation defect.
  The filters re-sync moved one case out of that set (**1189**: `source:` was
  `Plan.hs#L855`, now `QuerySpec.hs#L1187`, the assertion that actually spells
  out the expected `299` Warning; the implementation line stays in `notes:` as
  the rationale). The ordering re-sync added six cases and **all six cite
  upstream `it`-blocks**, so the 35 is unchanged and its share fell from
  35/637 to 35/643.
- **Id bands.** Fifteen areas each occupy one contiguous band; two areas are
  non-contiguous and must stay that way: **representations** (1300–1314,
  1320–1324, 1330–1333 — the gaps are deliberate sub-feature spacing) and
  **auth** (1450–1499 **+ 11800–11818** — the overflow band, the only 5-digit
  ids in the tree). Separately, the *config band* 1700–1744 is contiguous but
  **mixes shapes**: 1742/1743 are HTTP cases embedded in an otherwise CLI run
  of ids (see `conformance/INDEX.md` → *Case file shapes*). The **filters**
  primary band 1150–1199 is **fully allocated**; `spec/filters.yaml` declares
  `[10600..10799]` as the area's closed overflow range for future cases. New this
  pass: **ordering** grew to 1200–1232 and is still **contiguous with room** —
  1233+ is free inside its own band, which is why both ordering gaps below are
  costed as case-only with no band decision attached.
- **Referenced relations: 11 flagged, 0 genuine defects — every flag is a
  deliberate negative.** The check resolved the first path segment of each HTTP
  case (percent-decoded; `/rpc/<fn>` → function `<fn>`; bare `/` skipped; the 38
  `kind: cli` cases have no path) against `pg_class`/`pg_proc` on the loaded DB,
  following the frozen harness's schema resolution: `test`/`public`/`null` →
  `test`, an explicit `Accept-Profile`/`Content-Profile` on the case wins
  (`http_case.ex` uses `Map.put_new`, so the case header beats the label — this
  is what resolves 1574 to `SPECIAL "@/\#~_-`.names), plus the harness label
  aliases (`unicode` → `تست`, `multi` → `v1` via `db_profile_default`,
  `openapi_no_schema_comment` → `openapi_no_comment` for case 1654).
  **562 relations checked, 551 resolve, 11 do not — and all 11 assert 404**, i.e.
  the absence *is* the assertion. `UNRESOLVED_SCHEMA_CANDIDATES` was empty.

  | Expected | Cases |
  |----------|-------|
  | 404 | 1001 (`test.first`), 1002 (`test.invalid`), 1024 (`v1.another_table` — exists only in `v2`), 1360/1368/1373 (`mutations.garlic`/`.fake`/`.foozle`), 1432 (`rpc/fake`), 1515/1516/1517 (`test.non_existent_table`/`.invalid`/`.itemsx`), 1765 (`observability.unknown`) |

  > **Why 11 and not the 16 the previous pass reported — a classification
  > change, not a repair.** The earlier run additionally flagged five cases whose
  > expectation is **406**: **1010**/**1560**/**1583** (`Accept-Profile:
  > unknown`), **1012** (`Content-Profile: unknown`) and **1652**
  > (`Accept-Profile: openapi`, a label that names no schema). All five still
  > exist and still expect 406 — re-read out of the case files this pass. This
  > pass's script classifies a request whose *schema* cannot be resolved as a
  > schema-level skip rather than a missing *relation*, so it never reaches the
  > relation lookup. The union of both runs is the same 16 cases and no
  > conclusion changes; only the bucket does. (Prior passes reported 30 by
  > running the check literally, without the label aliases at all. Do not read
  > 30 → 16 → 11 as three repairs; it is one set of cases counted three ways.)

  Two spot-checks confirm intent rather than accident: **1024** asserts the body
  message `Could not find the table 'v1.another_table' in the schema cache`
  while the DB really does hold `v2.another_table` and `v1.parents`; **1652**
  asserts 406 for the media type, so the relation is never resolved at all.

  **Zero** case whose expected status is 2xx/3xx targets a missing relation — the
  one conclusion that matters, and it is identical under all three
  classifications.

  All six new ordering cases resolve: **1227**/**1228** target
  `test.videogames`/`test.designers` (with the `computed_designers` /
  `computed_videogames` functions, which exist **only** in `test` — hence those
  two cases' `schema: test` label), **1229** targets `ordering.clients`, **1230**
  `mutations.no_pk`, and **1231**/**1232** the function `ordering.getitemrange`.

### Open verification finding (carry into the conformance run)

**Case 1652 (`openapi.entities`) may pass for the wrong reason — and the whole
`openapi` label family is inert.** Still open at this pass. The empirical data
point below (1652 **passes**, `mix test --only area:openapi` → 32/33) is
**carried over from the previous pass, not re-run here** — this pass ran the six
static checks only, no `mix test`. Passing does not distinguish the two possible
reasons, so re-running it proves nothing new anyway; strengthening the case is
what would.

None of the three `openapi`-area fixture-set labels names a schema that exists in
the loaded DB. All 33 openapi cases carry one of `openapi` (31),
`openapi_no_schema_comment` (1654) or `openapi_variadic` (1672);
`test/support/http_case.ex` turns each into an `Accept-Profile: <label>` request
header, yet `mix bier.fixtures.load` creates none of them — re-confirmed against
the freshly loaded DB this pass: the schema list on the load includes
`openapi_no_comment` but no `openapi`, no `multi` and no `unicode`, and
`fixtures.sql` only ever does
`CREATE SCHEMA IF NOT EXISTS openapi_no_comment` (line 187). The area's objects
live in schema `test` (`spec/conformance/fixtures/openapi.sql:24–41`), and the
loader deliberately does **not** mirror `openapi`
(`lib/mix/tasks/bier.fixtures.load.ex:29` — "Function-heavy areas (rpc, openapi,
headers) are intentionally NOT mirrored").

Why it is currently harmless for 32 of the 33:
`Bier.Plugs.ActionController.dispatch/3` routes the root path (`conn.path_info
== []`) straight to `dispatch_root/2` **without** calling `resolve_profile/2`,
and `build_openapi_document/2` selects `hd(config.db_schemas)`. The root document
is therefore always generated from the *first* configured schema (`test` on the
shared instance; `openapi_no_comment` on the 1654 variant), and the
`Accept-Profile` header those root cases send is ignored end to end. The labels
assert nothing today, and they would break the moment root-path profile
resolution is implemented.

**The exception is case 1652** — `GET /entities` under `Accept-Profile: openapi`,
expecting **406**. It is the only openapi case that reaches relation dispatch,
and its stated intent (`OpenApiSpec.hs:30`) is "`application/openapi+json` on a
non-root path is 406". But because the `openapi` profile does not exist, the same
request can 406 as **PGRST106 (unknown schema)** instead — i.e. it can pass
without ever exercising the media-type rule it was written for.
`reject_openapi_media/1` does run before relation resolution
(`action_controller.ex:320`, defined at `:335`), so the intended path is
plausible, but the two are indistinguishable from the outside at the current
expectation strength. **This is the case to re-check first in the conformance
run** — assert on the error `code` in the body, not just the status.

A second, related harness observation, **inert but worth recording**: the shared
conformance instance lists `openapi` in its `db_schemas`
(`test/support/conformance_server.ex:171`) even though no `openapi` namespace
exists in the loaded DB. Same root cause; fix it together.

Resolving this belongs to the harness/fixture owner — `test/**` is frozen to
spec work, and `fixtures/openapi.sql` is frozen provenance (its header still
reads "Derived from PostgREST v14.12 test/spec/fixtures/schema.sql"; the live
artifact `fixtures.sql` is what actually loads). Note this is **not** a v16.0
regression: the same mismatch existed at the previous pin and simply was not
surfaced, because the relation check only inspects the first path segment and
the other 32 cases request `/`.

### Fixture write channels

All five `*.delta.sql` files are **comment-only** — each holds a single
`-- Folded into ../fixtures.sql on 2026-08-08 (…); empty until the next delta.`
provenance line and no DDL, i.e. the write channel is empty and the folds are
recorded: `content_negotiation` (the `application/vnd.pgrst.object` /
`text/tab-separated-values` domains and their handlers), `headers`
(`test.get_vary_header_override()` + GRANT), `ordering` (`test.arrays` + seeds),
`rpc` (`test."true"()` + GRANT), `url_grammar` (`test.pgrst_reserved_chars` +
seeds).

Verified at the previous pass: the select area's new cases 1142–1149 were
authored against existing relations (`test.fav_numbers`, `test.arrays`,
`test.trash_details`, `test.project_invoices`) and added **no** fixture delta —
consistent with `select.yaml`'s `loader_exposure` gap, which deliberately
declines to create new `test`-schema relations because they would be visible to
the OpenAPI area's document assertions.

Verified this pass: the filters area's nine new cases **1191–1199** likewise
added **no** fixture delta, and `spec/conformance/fixtures/filters.delta.sql`
does not exist. `filters.yaml` states the position explicitly — "this area adds
no fixture objects at all; every filters case, old and new (1150–1199), runs on
objects already built by `mix bier.fixtures.load`" — and names the one place a
delta was considered and rejected (upstream's `client`/`clientinfo`/`contact`
tables, which would collide with `fixtures.sql:477` renaming
`test.projects`' clients FK constraint to `client`, on which case 1122 depends).

Verified this pass: the ordering area's six new cases **1227–1232** likewise
added **no** fixture delta — `ordering.delta.sql` still holds exactly its single
fold line (`-- Folded into ../fixtures.sql on 2026-08-08 (test.arrays + its two
upstream seed rows); empty until the next delta.`) and nothing else. Every
relation the six drive was confirmed present in the loaded DB
(`test.videogames`, `test.designers` + the two computed-relationship functions,
`ordering.clients`, `mutations.no_pk`, `ordering.getitemrange`). Both ordering
gaps recorded above are likewise costed as **no delta needed**.

The five delta files therefore still hold **only** the 2026-08-08 fold
provenance line, byte-for-byte as listed above (re-read this pass). Two of the
three filters gaps in this file would change that if closed: the `empty_string`
row (a first `filters.delta.sql`) and, if the eight-column-type sweep is wanted,
`items_with_different_col_types`.

## Review status

The v16.0 re-sync re-pinned **every** case `source:` from `v14.12` to `v16.0`, so
the per-area audit verdicts recorded by the v14.12 pass no longer describe the
citations on disk and are not carried forward. All 17 area behavior models are
marked with the v16.0 pin and each closes with an explicit `gaps:` list. (The
pin's *key spelling* is not uniform — 10 models use `version: v16.0`, five use
`version: PostgREST v16.0` (`errors`, `filters`, `observability`, `operators`,
`ordering`), `pagination.yaml` uses `postgrest_version: v16.0`, and
`url_grammar.md` states it in prose. Do not grep for a single spelling.)

Adversarial review summaries recorded so far cover **auth**, **headers**,
**config**, **select**, **filters** and **ordering** — 6 of 17 areas:

| Area | v16.0 audit result | Nature of findings |
|------|--------------------|--------------------|
| auth | ⚠️ revise | 4 informational gaps, **0 citation defects** — the reviewer independently re-verified each gap's justification against v16.0 sources and confirmed all four are correct. See **Known gaps → auth**. |
| headers | ⚠️ revise | 3 missing-coverage findings, **0 citation defects** — RPC-flavored `max-affected` (incl. the wholly-uncovered PGRST128), RPC-flavored `handling`, and the CORS-preflight leg of the `Vary` rule. All three are *citable but uncovered*. See **Known gaps → headers**. |
| config | ⚠️ revise | 2 missing-coverage findings, **0 citation defects** — `db-pre-config` (the v16-*recommended* in-database config mechanism, dump-observable, while cases 1724/1725/1744 cover only the deprecated `ALTER ROLE` path) and `app.settings.*` reaching SQL as a GUC (1729 pins only the dump surface). Both *citable but uncovered*. See **Known gaps → config**. |
| select | ⚠️ revise | 5 missing-coverage findings, **0 citation defects** — FK joins on views / chains of views (20 upstream it-blocks, no case *and* no gap entry), spread to-many (gap recorded but its "needs a fixture" justification does not hold), aggregates in to-one spreads + the PGRST127 rejection (entire upstream context, absent from the whole tree), FK joins on partitioned tables, and the terminal `->` on a json/jsonb column. All five *citable but uncovered*. See **Known gaps → select**. |
| filters | ⚠️ revise | 3 missing-coverage findings, **0 citation defects** — the `IN`/`NOT IN` empty set (an 11-it-block upstream `describe`, `in.()` issued by no case in the tree, while `operators.yaml` already models the `= ANY('{}')` rendering it produces), the empty filter *value* (`?string=eq.` → `""`), and the implicit AND of two plain filters. All three *citable but uncovered*. See **Known gaps → filters**. |
| ordering | ⚠️ revise | 2 missing-coverage findings, **0 citation defects** — *Order in spread to-many* (a named v16 docs section with its own worked example, exercised by upstream at `SpreadQueriesSpec.hs#L163` and `AggregateFunctionsSpec.hs#L157/#L168`, and asserted by **no case anywhere in `spec/`**; recorded only as the `order.spread_embed` gap, whose "the fixtures don't exist" justification the local `ordering.projects` → `ordering.tasks` graph defeats) and the aliased-relation PGRST118 (upstream asserts `order=pros(id)` naming the **alias** in both `details` and `message`; case 1216 covers only the unaliased twin). Both *citable but uncovered*, both case-only. See **Known gaps → ordering**. |
| the other 11 areas | not re-audited in the input to this pass | Citations are self-reported at the v16.0 pin. |

Open follow-ups:

1. Run `bier-spec-audit` over the **11** areas without a recorded v16.0
   adversarial verdict: `url_grammar`, `operators`, `pagination`,
   `representations`, `mutations`, `rpc`, `errors`, `content_negotiation`,
   `openapi`, `observability`, `domain_representations`.
2. Re-check the `openapi` label finding above — specifically whether case **1652**
   returns 406 for the media-type reason or for the unknown-schema reason —
   before trusting that area's results. It currently *passes*, which is exactly
   why it needs the stronger assertion.
3. Close the five select gaps, cheapest first: the terminal-`->` json case and
   the spread-to-many case need only case files; aggregates-in-to-one-spreads
   (+ PGRST127) needs cases plus the `db-aggregates-enabled` harness wiring; FK
   joins on views/chains and on partitioned tables need fixtures.
4. Close the two config gaps: one CLI case for `db-pre-config` (needs a
   pre-config function reachable at startup) and one HTTP case for
   `app.settings.*` via `/rpc/get_guc_value` (the fixture function already
   exists).
5. Close the three headers gaps. Two need only case files (RPC `handling`; the
   preflight `Vary` assertion); the RPC `max-affected` / PGRST128 gap
   additionally needs `delete_items_returns_setof` / `_returns_table` /
   `_returns_void` fixtures, so it is a fixture-delta decision, not a spec-only
   edit.
6. Decide the harness question behind the unhonoured `config:` blocks — case
   **1742** (config band) and the ten select cases 1129–1133/1139/1140/1147–1149.
   Until then 1742 fails for the wrong reason and the eight aggregate cases run
   with `db-aggregates-enabled` at its `False` default.
7. Decide whether to re-pin the **51** `v14.12` provenance URLs in the eight
   `spec/conformance/fixtures/*.sql` files, or to state in
   `conformance/fixtures/README.md` that they are frozen at the pin they were
   derived from.
8. Close the three filters gaps. Two are case-only — the `in.()` / `not.in.()` /
   `in.(    )` / `in.( ,3,4)` set on an existing relation, and the two-plain-
   filters AND — but both need a band decision first, because filters' primary
   band 1150–1199 is full (overflow `[10600..10799]`) and `in.`'s SQL rendering
   is claimed by `operators`. The empty-`eq.` case needs a seeded `''` row,
   which would be the filters area's first fixture delta.
9. Review the **35** cases whose `source:` anchors implementation code rather
   than an upstream assertion (list: group `grep -h '^source:' …` by directory).
   Case 1189 was moved onto a real assertion during the filters re-sync; each
   remaining one should either follow, or say in `notes:` why no upstream
   it-block exists — several already do (e.g. 1583).
10. Close the two ordering gaps — **the cheapest open work in this file**. Both
    are case-only, both land in the free 1233+ slice of ordering's own band, and
    both run on relations the loaded DB already has: one case for *Order in
    spread to-many* on `ordering.projects` → `ordering.tasks` (and, if the
    `order.spread_embed` gap is kept for the upstream-fixture variants, rewrite
    its justification so it no longer rests on an absence the local graph
    defeats), and one for the aliased-relation PGRST118 on
    `ordering.clients`/`ordering.projects`, whose envelope must name the **alias**
    (`pros`) in both `details` and `message`. Re-confirm both `#L` anchors
    against the raw upstream files when authoring — two independent reads
    disagreed on the exact line ranges, though not on the content.
11. Consider asking the Tester to tighten `case.schema.json`'s `source` pattern
    from `.../postgrest/.+#L[0-9]+$` to the pinned tag. As written, schema
    validation cannot catch a stale pin (proved by negative control this pass),
    so the pin is enforced only by an ad-hoc grep sweep that lives in this
    document rather than in CI. `case.schema.json` is the Tester's file and was
    deliberately not edited here.
