# Coverage

Maps every page of the PostgREST **v16** documentation
([postgrest.org/en/v16](https://postgrest.org/en/v16/)) to the conformance case
ids that cover it. The docs-page list follows the v16 site's **References**
section and its **API** sub-pages, **re-fetched from the live site this pass**
(16 API sub-pages; 12 top-level References entries, of which `api` is the parent
counted through its sub-pages).

A docs page with no covering case (and not explicitly scoped out below) is
flagged **GAP**.

Pinned target: **PostgREST v16.0**. Total cases: **668** across 17 areas
(counted on disk this pass, not carried over). The page set is unchanged from
the previous pass — `references.html` lists 12 entries (11 pages plus
the `api` parent: Authentication, API, CLI, Transactions, Connection Pool, Schema
Cache, Errors, Configuration, Observability, Admin Server, HTTP Server, Listener)
and `references/api.html` lists 16 sub-pages, matching the tables below entry for
entry. Both were re-fetched and re-enumerated rather than carried over.

State of the tree when this file was written: **HEAD `e3fb77e`**
("spec(errors): re-sync to PostgREST v16.0 (area 8/17) — FIRST AREA TO PASS
REVIEW") with an **uncommitted pagination re-sync in the working tree**:
`spec/pagination.yaml` and eight cases (**1258, 1261, 1264, 1266, 1267, 1268,
1269, 1275**) modified, eleven cases (**1278–1288**) untracked. Every count here
describes that on-disk state, including the uncommitted files. The previous
revision of this file was written at `dcebc66` + an uncommitted errors re-sync,
with **657** cases; the whole delta is the pagination area (28 → 39 cases).

## References → API sub-pages

| Docs page (`references/api/...`) | Covering case ids | Notes |
|----------------------------------|-------------------|-------|
| `tables_views` (Tables and Views) | 1000–1035 (url_grammar), 1050–1099 (operators), 1100–1149 (select), 1150–1199 (filters), 1200–1232 (ordering), 1300–1333 (representations), 1350–1397 (mutations) | Read/write of tables & views: path resolution, horizontal/logical filters, operators, vertical filtering (select), JSON/composite/array column access, ordering, insert/update/delete/upsert. **Partial** — three behaviors the page and its upstream spec assert have no case: the `IN`/`NOT IN` empty set, an empty filter *value*, and the implicit AND of two plain filters (the page's very first rule). See **Known gaps → filters**. |
| `functions` (Functions as RPC) | 1400–1440 (rpc), 1005–1007 (url_grammar /rpc paths), 1023 (rpc profile), 1031–1032 (OPTIONS `Allow` on a VOLATILE vs. a STABLE routine), 1231–1232 (ordering of an RPC result), 1271, **1280–1283, 1285** (pagination over an RPC result), 1489–1490 (auth rpc), 1570 (rpc status GUC), 1502–1503, 1505, 1507–1514 (errors raised from inside a routine) | GET/POST RPC, scalar/setof/composite/void returns, args, variadic, volatility, overloaded functions, single unnamed JSON parameter, reserved-word function name (1440), the page's "filters, order and limits inline into a function" rule (`functions.rst` L283/L290) via 1231–1232, and the volatility→`Allow` rule (1031/1032). **Materially strengthened this pass** on the pagination side: the Range header on a GET `/rpc/` (1280), limit/offset query params on a **POST** `/rpc/` whose args are in the JSON body (1281), the empty-window envelope (1282), the `count=planned` degradation (1283) and the Range header being *ignored* on a POST `/rpc/` (1285). **Still Partial** — the RPC flavor of `Prefer: handling` / `max-affected` (incl. PGRST128) is asserted by no case in any band; see **Known gaps → headers**. |
| `schemas` (Schemas) | 1008–1012, 1022–1024 (url_grammar profile), 1557–1560, 1574 (headers profile), 1730 (`db-schema` singular alias), 1733–1734 (`db-schemas` rejects `pg_catalog` / `information_schema`) | Accept-Profile / Content-Profile, multi-schema routing, unacceptable schema, restricted system schemas (new in v16). |
| `computed_fields` (Computed Fields) | 1128 (select computed-column), 1208 (ordering computed), 1806 (domain rep. via view + computed column) | Computed (virtual) columns in select and order. |
| `domain_representations` (Domain Representations) | 1800–1820 (domain_representations) | **COVERED**: CREATE DOMAIN cast representations — read (format cast shapes output, incl. implicit `select=*` and through-embed), write (parser cast applied to bodies, `columns=` param), filter (domain-typed predicates, `in`/`not.in`, across relations), default (no cast → base type), error paths (1819–1820). |
| `pagination_count` (Pagination and Count) | **1250–1288** (pagination, **39** cases), 1431 (rpc Range header), 1700–1701 (db-max-rows), 1522, 1526 (the inline 416 body's verbosity and header set) | limit/offset, Range header, exact/planned/estimated count, db-max-rows, the two properties of the **inline** out-of-range 416 that `errorResponseFor` never sees, and — new this pass — the page's table-function leg ("This also works on views and table functions", `pagination_count.rst` L61) plus the Range header's **method scoping** and its **intersection** (not override) with limit/offset. **Partial** — two gaps: embedded `<embed_path>.offset` has zero cases anywhere in the tree (**Known gaps → pagination**, and the tree's single largest *documented-parameter* hole), and the modelled suppression of `Content-Length` on a **HEAD** 416 has no case (**Known gaps → errors**). |
| `resource_embedding` (Resource Embedding) | 1112–1127, 1133–1142 (select embed/spread/one-to-one/computed rels/aliases/`!fk` hints), 1181–1199 (filters embed), 1211–1224, 1227–1229 (ordering embed/related), 1276 (nested limit), 1028 (legacy embed target name), 1736 (`url-use-legacy-target-names` dump) | Many-to-one/one-to-many/many-to-many, one-to-one (pk-as-fk, unique FK), computed relationships, nested, inner/left, disambiguation (incl. the `table!fk` hint, 1142), spread, and the v16 target-name→alias migration (1028, 1138–1141, 1188–1190, 1224). **Partial** — Foreign Key Joins on Views / Chains of Views, Spread To-Many, and FK Joins on Partitioned Tables have no case (**Known gaps → select**); the page's *Order in spread to-many* section has no case in any band (**Known gaps → ordering**); and the page's own `actors.limit=10&actors.offset=2` example is half-covered — the `.limit` half by 1276, the `.offset` half by nothing (**Known gaps → pagination**). |
| `resource_representation` (Resource Representation) | 1300–1333 (representations), 1230 (order applied to a PATCH's returned representation), 1550–1556 (Prefer), 1610–1615, 1629 (singular), 1630–1635 (nulls-stripped) | Prefer: return=representation/minimal/headers-only, singular object, vnd.pgrst.object, stripped nulls. |
| `media_type_handlers` (Media Type Handlers) | 1600–1646 (content_negotiation, incl. 1636–1638/1642/1644/1646 custom-media-handler), 1426 (rpc csv) | JSON/CSV/GeoJSON/octet-stream/text, Accept negotiation and precedence (1639–1641, 1645), custom media handlers (anyelement, override-builtin, any-handler, vendored-not-overridable, table aggregate, default-select requirement), plan output. |
| `aggregate_functions` (Aggregate Functions) | 1129–1133, 1147–1149 (select aggregate), 1644 (aggregate through a custom media handler) | count/sum/group-by/alias+cast, cast of the aggregated column and of the result (1147–1148), group-by across an embed (1149), agg in embed. **Partial** — *Aggregates in To-One Spreads* and the PGRST127 to-many-spread rejection have no case; see **Known gaps → select**. |
| `openapi` (OpenAPI) | 1650–1682 (openapi), 1619–1621, 1645 (content_negotiation openapi) | Root spec, comments→summary/description, type mapping, modes, security, `db-root-spec`. |
| `preferences` (Prefer Header) | 1550–1556, 1577–1581, 1584 (headers prefer), 1302–1304, 1313–1314, 1322, 1324, 1332–1333 (return=minimal / headers-only), 1390–1392 (max-affected), **1267–1268, 1286, 1288** (pagination: `Preference-Applied` echoed for `count=exact`, absent for the unparsed `count=none`, and `count=none` rejected under `handling=strict`) | Prefer: return, handling=strict/lenient, timezone (incl. ± offsets, leap seconds, invalid under default/lenient/strict, and the single- vs two-token `Preference-Applied` echo in 1553/1584), max-affected, missing-defaults via `columns`, count. **Partial** — every `handling` and `max-affected` case is table- or read-flavored; the RPC flavor of both preferences (incl. PGRST128) has no case. See **Known gaps → headers**. |
| `vary_header` (Vary Header) | 1575 (default `Vary: Accept, Prefer, Range` on a read), 1576 (`response.headers` GUC override replaces it verbatim), 1582 (the default is appended by `toWaiResponse` for every non-error response, witnessed on OPTIONS), 1583 (error responses carry no `Vary` — they bypass `toWaiResponse`) | **NEW page in v16** — covered. 1582/1583 match the modelled entries `headers.vary.non_read_responses` / `headers.vary.absent_on_errors`. The one remaining leg — a *CORS preflight* answered by the wai-cors middleware, which never reaches `toWaiResponse` — is a gap; see **Known gaps → headers**. |
| `cors` (CORS) | 1702 (allowed-origin echo), 1703 (empty config allows all), 1704 (non-matching origin → no header), 1742 (default/empty origin list answers a preflight permissively), 1743 (the fixed `Access-Control-Expose-Headers` list on a plain `Origin` request) | 1742/1743 are **HTTP** cases inside the config band. **Partial** — none of the preflight cases asserts `Vary`-absence, the third leg of the v16 `Vary` rule (**Known gaps → headers**), and 1742 does not yet run under the config it declares (**Known gaps → config**). |
| `options` (OPTIONS method) | 1019 (table `Allow`), 1031 (VOLATILE routine), 1032 (STABLE routine), 1033 (root path), 1034 (unknown relation → 404), 1757, 1768–1769 (observability OPTIONS server-timing on table / rpc / root), 1742 (OPTIONS preflight), 1582 (`Vary` present on an OPTIONS response) | The url_grammar re-sync covered three of upstream `OptionsSpec.hs`' four `Allow` shapes (`#L84`, `#L90`, `#L103`) plus the not-found path (`#L22`). **Still Partial** — the updatability-driven variants (auto-updatable views, trigger-backed views, partitioned tables, `OptionsSpec.hs#L24-L80`) remain uncased; see **Known gaps → options / transactions**. |
| `url_grammar` (URL Grammar) | 1000–1035 (url_grammar) | Path/method resolution, reserved query params (incl. the legacy embed target name 1028, and `limit`/`offset` forbidden on PUT 1016/1030), %-encoding (incl. `%20` in a relation *and* a column name, 1035), `+`→space, double-quoting reserved characters in filter values and in quoted identifiers (1025–1027, 1029). **Partial** — the page's *Reserved characters* section documents backslash escaping inside `in.( … )` (`\"` for a literal quote, `\\` for a literal backslash) and no case in any band exercises it; see **Known gaps → url_grammar**. |

## References → top-level pages

| Docs page (`references/...`) | Covering case ids | Notes |
|------------------------------|-------------------|-------|
| `auth` (Authentication) | 1450–1499 + 11800–11818 (auth) | JWT validation/claims, HS256 (incl. binary/base64 secret) and RS256 (JWK and JWKS), roles, role-claim-key JSON Path, anonymous, audience, pre-request, GUC claims, login-token minting, clock-skew errors. Partial — see **Known gaps**. |
| `cli` (CLI) | 1705–1741 + 1744 (all 38 `request.kind: cli` cases) | `--dump-config`, `--example`, validation, env/file/db precedence, coercion, unknown-key tolerance (1739), aliases. Driven in-process by `Bier.CliCase`. Note 1742/1743 sit inside the band but are HTTP, so the CLI set is not contiguous. |
| `transactions` (Transactions) | 1387–1392 (safe-update/delete, max-affected), 1713, 1722 (db-tx-end validation + enum mapping), 1759 (transaction timing), 1523 (a trigger cascade aborted by the statement-depth limit) | Tx-scoped GUCs, safe-update/safe-delete (rollback on missing WHERE), db-tx-end. Partial — no explicit characteristics/isolation-level case. |
| `connection_pool` (Connection Pool) | — (OUT OF SCOPE) | Pool sizing/acquisition behavior is operational and not observable as deterministic black-box HTTP. See **Scope decisions**. |
| `schema_cache` (Schema Cache) | — (DEFERRED) | Schema-cache reload (`NOTIFY pgrst, 'reload schema'` / SIGUSR1) needs a reload-signal harness. See **Scope decisions**. |
| `errors` (Errors) | **1500–1526 (errors)**, 1432–1434 (rpc errors), 1002, 1024, 1185 (not-found / invalid path), 1455–1464 + 11809–11814 (auth JWT errors), **1288** (PGRST122 from an invalid preference under `handling=strict`) | SQLSTATE→HTTP mapping (incl. the two 5xx paths 1523/1524), PGRST error codes, the PGRST205 fuzzy hint (1520/1521), RAISE PGRST full control, RAISE PT custom status, 4xx/5xx envelopes and their byte-exact key order (1525), `Proxy-Status` (1506, 1515–1516, 1519, and its documented *absence* on the inline 416, 1526), client-error-verbosity=minimal (1517, 1518, 1522). **Still Partial** — **PGRST127** and **PGRST128** appear nowhere in the tree (see **Known gaps → select / headers**), and no case in the tree issues a HEAD request that errors (see **Known gaps → errors**). |
| `configuration` (Configuration) | 1700–1744 (config) | Sources (env/file/db-role-settings, incl. `db-config = false` disabling the in-db source, 1744), aliases, validation, coercion (incl. `coerceBool` from numeric/text strings, 1740–1741), unknown-key tolerance (1739), precedence, app-settings, CORS keys (1702–1704, 1742–1743), plus the v16 keys `client-error-verbosity` (1731–1732), `server-reuseport` (1735), `url-use-legacy-target-names` (1736), `admin-server-unix-socket` (1737–1738). **Partial** — the page's *In-Database Configuration* section documents `db-pre-config` as the recommended mechanism and its *App Settings* section documents `current_setting('app.settings.*')`; neither has a case. See **Known gaps → config**. |
| `observability` (Observability) | 1750–1769 (observability), 1497 (JWT-cache Server-Timing), 1625–1628, 1643 (execution plan), 1506/1515/1516/1519/1526/1002 (Proxy-Status, present and absent) | Server-Timing, Trace header, log-level→status logging, execution plan, Proxy-Status. Partial — see **Known gaps** (Metrics, SQL query logs, Server version header, and `Proxy-Status` on a HEAD request). |
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

*(Re-verified a fourth time at the **649**-case state. All four facts still hold
unchanged — 1800–1820 = 21; 1707 is `kind: cli` / `--dump-config`;
`grep -c pending spec/case.schema.json` → **0**; the CLI set is 1705–1741 + 1744
= **38**; `expect.status_text` on exactly 1508/1510/1511. The url_grammar
re-sync — the only change since — added six cases and rewrote two, all on the
`url_grammar`, `tables_views`, `options` and `functions` pages, none of which is
scoped out. **Nothing in this section was rewritten**; only this note was
appended. `case.schema.json` was likewise **not** touched: it exists, it is the
Tester's file, and the synthesis step leaves it alone.)*

*(Re-verified a **fifth** time at the **657**-case state, fact by fact against
disk rather than carried over: `domain_representations` is 1800–1820 = **21**
cases; **1707** is a live `kind: cli` / `--dump-config` case;
`grep -c pending spec/case.schema.json` → **0**; the CLI set is 1705–1741 + 1744
= **38**; `expect.status_text` on exactly **1508/1510/1511**. The errors re-sync
— the only change since — added eight cases and two fixture objects, all on the
`errors`, `pagination_count`, `functions`, `transactions` and `observability`
pages, none of which is scoped out. In particular it did **not** touch
`connection_pool`, `schema_cache`, `listener` or `http_server`. **Nothing in
this section was rewritten**; only this note was appended, and
`case.schema.json` was again left alone as the Tester's file.)*

*(Re-verified a **sixth** time at the **668**-case state, fact by fact against
disk: `domain_representations` is 1800–1820 = **21** cases; **1707** is a live
`kind: cli` / `--dump-config` case; `grep -c pending spec/case.schema.json` →
**0**; the CLI set is **1705–1741 + 1744 = 38** (the pagination re-sync added no
CLI case); `expect.status_text` on exactly **1508/1510/1511**. The pagination
re-sync — the only change since — added eleven cases and rewrote eight, all on
the `pagination_count`, `functions`, `resource_embedding`, `preferences` and
`errors` pages, none of which is scoped out; it did **not** touch
`connection_pool`, `schema_cache`, `listener` or `http_server`, and it added no
fixture object. **Nothing in this section was rewritten**; only this note was
appended, and `case.schema.json` was again left alone as the Tester's file.)*

## Coverage summary

- Docs pages enumerated: **27** — 16 API sub-pages + 11 top-level reference
  pages (the `references/api` parent page is counted once, through its
  sub-pages; `url_grammar` is counted once). Re-fetched from
  postgrest.org/en/v16 this pass; the page set is unchanged.
- Pages with at least one covering case: **23**.
- Pages explicitly scoped: **4** — `connection_pool` (out of scope),
  `http_server` (out of scope, new in v16), `schema_cache` (deferred),
  `listener` (deferred).
- Pages flagged **GAP** (no covering case and not scoped out): **0**.

Two pages are new in v16 relative to the pre-re-sync state: `api/vary_header`
(covered, 1575–1576 and 1582–1583) and `http_server` (scoped out — see above).

**Fourteen** pages are marked **Partial** in the notes above (`options`,
`transactions`, `admin_server`, `observability`, `auth`, `preferences`, `cors`,
`configuration`, `resource_embedding`, `aggregate_functions`, `errors`,
`tables_views`, `url_grammar` and `functions`): they have covering cases but not
the full breadth of the docs page. These are soft gaps, itemized next.
`vary_header` stays **covered** but carries one itemized gap (the preflight leg).
**`pagination_count` moves from covered-with-one-gap to explicitly Partial this
pass**, on the strength of the embedded-`.offset` finding below — the first
pagination gap that is a *documented request parameter with zero coverage*
rather than a derived edge case.

The pagination pass is worth separating from the itemized gaps, because unlike
the last four re-syncs it did not only *add* coverage — it **corrected a modelled
rule**:

- **The Range-header/limit-offset relationship was modelled backwards.**
  `pagination.yaml` previously stated "Range headers override limit/offset query
  params", citing `RangeSpec.hs#L194` ("headers override get parameters", case
  1261). `getRanges` does not override; it **intersects**
  (`headerAndLimitRange = rangeIntersection headerRange limitRange`,
  `ApiRequest.hs#L185`). The upstream it-block is `?limit=3` + `Range: 0-1` —
  the one shape in which intersection and override give the same answer — so no
  existing case could have detected the error, and the case whose *filename* is
  `1261_range_header_overrides_params.yaml` is precisely the one that cannot
  discriminate. New case **1287** (`?limit=2` + `Range: 0-5`) is the
  discriminating shape. **The lesson generalizes past this area**: an
  upstream-transcribed case is evidence for the assertion it makes, not for the
  rule the model wraps around it, and eight areas still have no v16.0 audit.

`tables_views` remains the densest page in the tree (seven areas, **291** cases
feed it) and still misses the page's opening rule on combining filters. Density
is not coverage. `resource_embedding` now makes the point twice over: the
ordering audit found a **named docs section** with a worked example
(*Order in spread to-many*) and zero assertions, and the pagination audit found a
**worked example on the same page** — `&actors.limit=10&actors.offset=2` — whose
two halves have 1 case and 0 cases respectively. `url_grammar` makes it a third
time, and the errors pass a fourth: the tree's **12 HEAD cases all expect 2xx**,
so a HEAD that errors is untested across 668 cases.

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
  three *headers* entries, both *config* entries, both *ordering* entries, the
  one *url_grammar* entry, the one *pagination* entry and two of the three
  *errors* entries are of this kind**, so they are the actionable ones. Each is
  labelled below.

A third axis cuts across both kinds and is what actually decides effort:
**what does closing it cost?** Of the nineteen citable-but-uncovered entries:

- **twelve are case-only** — select's spread-to-many and terminal-`->`; filters'
  `in.()` (its core assertion; only the eight-column-type sweep needs a fixture)
  and the implicit AND; headers' RPC `handling` and the preflight `Vary`
  assertion; ordering's order-in-spread-to-many and its aliased-relation
  PGRST118; **pagination's embedded `.offset`** (new this pass, and the
  cheapest of the twelve — see below); both errors entries (a HEAD against
  `test.items`); and **url_grammar's escaped-char `in.( … )` value, but only in
  part** — see the next bullet;
- **four need fixture objects the consolidated DB does not have** — select's FK
  joins on views/chains and on partitioned tables, headers' RPC `max-affected`
  routines, filters' `empty_string` row. url_grammar's entry **straddles this
  line**: three of its four upstream it-blocks need seed rows the consolidated
  fixture lacks, but the fourth (`QuerySpec.hs#L1334`) runs against the already
  seeded `David White` row with no delta at all;
- **two are blocked on the frozen harness honouring a case's `config:` block** —
  config's `app.settings.*` and select's aggregates-in-to-one-spreads;
- **one, config's `db-pre-config`, needs a pre-config function reachable at
  startup**, which is a fixture *and* harness decision.

The case-only entries are the whole of the low-cost work available. **The
pagination entry is now the single cheapest item in this file** — one case file,
no fixture, no harness change, no band decision, closing a *documented request
parameter* rather than a derived edge case. The two errors entries follow, then
the two ordering entries and the url_grammar escaped-char case.

### pagination (adversarial review verdict: **revise** — finding is *citable but uncovered*)

One missing-coverage finding, **0 citation defects**. It was raised against the
tree *after* the eleven new cases 1278–1288 landed, so it is not closed by them.
The area's band is not full — 1250–1288 is in use, so **1289–1299** is free
before the representations band starts at 1300.

- **Embedded `<embed_path>.offset` has ZERO conformance cases anywhere in the
  tree — and unlike the other gaps in this file, the model does not even record
  it as one.** Re-verified on disk this pass:
  `grep -n '\.offset=' spec/conformance/cases/*.yaml` returns **nothing**, while
  `<embed>.limit` is covered by case **1276** (and incidentally exercised by
  1028/1138/1139/1224/1229). The model scopes the feature in under
  `inputs.query_params.embedded_limit_offset`, which names both parameters in its
  `meaning:` and cites the docs example for the offset half.

  **Both cited anchors were re-fetched and both hold** (this is not carried over
  from the reviewer):
  - [`resource_embedding.rst#L919`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/docs/references/api/resource_embedding.rst#L919)
    is the line `# curl "http://localhost:3000/films?select=*,actors(*)&actors.limit=10&actors.offset=2"`,
    under the heading paragraph "Limit and offset operations are possible:"
    (L915).
  - [`QueryLimitedSpec.hs#L42`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/QueryLimitedSpec.hs#L42)
    is `it "can offset the parent embed, being consistent with the other embed
    types"`, whose request is
    `/tasks?select=id,project:projects(id)&id=gt.5&project.offset=1` and whose
    expected body is `[{"id":6,"project":null},{"id":7,"project":null}]` — an
    offset applied to a **to-one** embed, pushing the single parent row out of
    the window and yielding `null`.

  **Why the model's existing text does not cover it.** The `constraints:` list
  under `embedded_limit_offset` says `<embed_path>.offset` "is documented (and
  only ever exercised upstream) in the single-level form … No upstream test
  asserts an embedded offset at a deeper nesting level, so this model does not
  claim one." That justifies omitting a *deeply nested* offset case. It never
  justifies omitting the **single-level** one, which is exactly the form both
  the docs and `QueryLimitedSpec.hs#L42` exercise. The area's `gaps:` list —
  eleven entries long, and unusually rigorous about *why* each behavior is not
  cased — has no entry for this at all.

  **Case-only, and emittable today with no fixture and no config.** Verified
  against the freshly loaded `bier_test`: `pagination.clients` holds 2 rows and
  `pagination.projects` 5, with client 1 owning projects 1,2 and client 2 owning
  3,4. So
  `/clients?select=id,projects(id)&order=id&projects.order=id&projects.offset=1`
  drops the first project of each client — a to-many offset, the docs' own
  shape. The upstream to-one shape (`project.offset=1` → `null`) is equally
  reproducible on `pagination.tasks` → `pagination.projects`. Either lands in
  the free 1289+ slice. **Write the case, or add a `gaps:` entry that argues
  against the single-level form rather than only against the nested one.**

### errors (adversarial review verdict: **pass** — all three findings MINOR / non-blocking)

The tree's only ✅ pass verdict. Three findings, **0 citation defects**, and
every one explicitly marked non-blocking by the reviewer. Two are *citable but
uncovered* and case-only; the third is acceptable-as-is and recorded only so it
is not rediscovered. A fourth item is not a spec gap at all but a harness gate,
filed below with the config-area constraint it shares a root cause with.

- **No case asserts `Proxy-Status` on a HEAD request — the docs' own stated
  motivation for the header.** MINOR, non-blocking.
  [`errors.rst#L461`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/docs/references/errors.rst#L461)
  introduces the header as "useful when doing HEAD requests where the HTTP
  status is not descriptive enough" — i.e. HEAD is the motivating use, and it is
  the one shape no case exercises. The tree pins `Proxy-Status` on GET
  (1506, 1515, 1516, 1519) and its absence on the inline 416 (1526), all
  GET-flavored. **Why this is non-blocking rather than actionable**: the header
  is emitted method-independently inside `errorResponseFor`
  ([`Error.hs#L88`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/src/library/PostgREST/Error.hs#L88)),
  with no HEAD branch anywhere on the path, so a HEAD case would assert the same
  code path the five existing cases already cover. Recorded for completeness, not
  prioritized.

- **`envelope.inline_416_content_length_suppressed_on_head: true` is modelled but
  exercised by no case.** MINOR, non-blocking, and the **more actionable of the
  two** — this one pins a behavior that genuinely differs by method.
  `spec/errors.yaml:154` asserts the flag and cites
  [`Response.hs#L62`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/src/library/PostgREST/Response.hs#L62)
  (relation read) and
  [`#L185`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/src/library/PostgREST/Response.hs#L185)
  (RPC read): `cLHeader = if headersOnly then mempty else [contentLengthHeader
  bod]`, where `headersOnly` is the HEAD flag off `WrappedReadPlan`. So on a HEAD
  whose Range is out of bounds, the inline 416 carries **no** `Content-Length` —
  a real, method-dependent divergence that nothing in the tree checks. The model
  asserts it; no case does. **Case-only**: `HEAD /items?offset=100` with
  `headers_absent: [Content-Length]`, in the free 1527+ slice, against a relation
  the loaded DB already has — the same request as case 1522/1526 with the method
  changed.

  > These two findings share one root, worth stating once because it is bigger
  > than the errors area: **the tree contains 12 HEAD cases (1020, 1272, 1274,
  > 1275, 1277, 1284, 1425, 1681, 1756, 1760, 1761, 1762) and every one expects a
  > 2xx.** No case anywhere in 668 issues a HEAD request that produces an error.
  > The pagination pass added the twelfth (**1284**, HEAD with a Range header
  > that is ignored → 200) without closing the hole, which is the point: HEAD
  > coverage keeps growing on the success side only. Any future HEAD-plus-error
  > behavior will land in the same blind spot, so the cheap fix is to close it
  > once, in this band, rather than per-finding.

- **The 42883 `function xmlagg(` → 406 special case has no case in any area.**
  MINOR, non-blocking, and **accepted as-is rather than filed as work.**
  [`Error.hs#L584`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/src/library/PostgREST/Error.hs#L584)
  maps the `undefined_function` SQLSTATE to a 406 when the message names
  `xmlagg`, which is PostgREST's way of turning "you asked for a media type whose
  handler does not exist" into a negotiation error. It is effectively
  **unreachable black-box** through the request shapes `case.schema.json`
  expresses, so there is nothing to write. Recorded so a later audit does not
  re-derive it as a gap.

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
re-fetched and read during that pass, so the line numbers are verified, not
carried over.

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
  **no case in the whole tree issues an `in.()` request**.
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
`bier_test` already has. Unlike filters, the ordering primary band is **not
full**: 1200–1232 is in use, so **1233+** is available without an overflow-range
decision.

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
  graph case **1229** already drives, and both relations exist in the loaded DB.
  Reproducing an upstream *shape* on local relations when the upstream fixture is
  missing is a pattern this tree already sanctions — the select area does it in
  cases **1124** and **1140**, by their own `notes:`.
  **Actionable with no fixture work**: either write the case in the 1233+ band or
  rewrite the gap text to stop resting on a fixture argument that the local graph
  defeats.

  > **Anchor caveat, recorded rather than smoothed over.** Two independent reads
  > of `resource_embedding.rst` placed the section differently — the adversarial
  > reviewer at **L1215–L1227** with the nested twin at **L1280–L1281**, a later
  > re-fetch at roughly **L1280–L1310**. Both agree on the section title
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
  cites `#L118–L127`, a later re-fetch placed the aliased it-block at roughly
  `#L113–L120`; both agree it is the block immediately following `#L107`.

### url_grammar (adversarial review verdict: **revise** — finding is *citable but uncovered*)

One missing-coverage finding, **0 citation defects**. The area's own band is not
full — 1000–1035 is in use, so **1036+** is free — so unlike filters this needs
no overflow-range decision.

- **Backslash / escaped-double-quote escaping inside `in.( … )` — a named part
  of this area's own docs page, with four upstream assertions and zero cases
  anywhere in `spec/`.** The v16 *Reserved characters* section
  ([`url_grammar.rst`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/docs/references/api/url_grammar.rst))
  states the rule and gives a worked example:

  > If the value filtered by the `in` operator has a double quote (`"`), you can
  > escape it using a backslash `"\""`. A backslash itself can be used with a
  > double backslash `"\\"`.
  >
  > `curl "http://localhost:3000/marks?name=in.(%22Quote:%5C%22%22,%22Backslash:%5C%5C%22)"`

  Upstream asserts it in `context "escaped chars"`
  ([`QuerySpec.hs#L1320`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/QuerySpec.hs#L1320)),
  three `it`-blocks against `w_or_wo_comma_names`:
  - `#L1321` "accepts escaped double quotes" — `?name=in.("Double\"Quote\"McGraw\"")`;
  - `#L1326` "accepts escaped backslashes" — `?name=in.("\\")` and
    `?name=in.("/\\Slash/\\Beast/\\")`;
  - `#L1334` "passes any escaped char as the same char" —
    `?name=in.("D\a\vid W\h\ite")` → `[{"name": "David White"}]`.

  A fourth, in the adjacent `describe "IN values without quotes"` (`#L1339`),
  covers the *unescaped* counterpart. **No case in the tree issues an escaped
  `in.( … )` value**: the nearest neighbour, case **1166**, covers plain
  double-quoted IN elements (via `AndOrParamsSpec`), which is the rule
  *preceding* this one on the same docs page.

  **Partly actionable with no fixture work, and this is the whole point of the
  finding.** `spec/url_grammar.md`'s existing gap entry declines all four on one
  justification — that the rows `'"'`, `'Double"Quote"McGraw"'`, `'\'` and
  `'/\Slash/\Beast/\'` are absent from `test.w_or_wo_comma_names` in the
  consolidated fixture. That is **true for three of them and false for the
  fourth**: `#L1334` asserts only that escaping any character yields that
  character, and its expected row is **`David White`**, which
  `fixtures.sql` already seeds. One case file in the 1036+ band closes it
  with no delta. Either write it, or rewrite the gap text so it stops resting on
  an absence that does not apply to the cheapest of the four.

  > **Two anchor corrections, recorded rather than smoothed over.** The
  > adversarial reviewer cited the it-blocks as `QuerySpec.hs#L1323-L1340` and
  > the docs as `url_grammar.rst#L68-L74`; both were re-fetched and both are off.
  > The `escaped chars` context runs **L1320–L1337** (L1323 is a body line inside
  > the first `it`, not its start), and the escaping paragraph plus its example
  > are at **L77–L81** — `L68-L74` is the *preceding* example, the plain
  > `%22`-quoted `in.(…)` form that case 1166 already covers.
  > Re-confirm both anchors against the raw files when authoring; do not copy
  > the reviewer's ranges on trust. The *content* of the finding survives both
  > corrections intact.

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
  `fixtures.sql` and already backs the auth-area GUC cases (1478–1485), so
  this needs only a case file — plus a harness that honours the case's `config:`
  block (see the next bullet).

- **Harness constraint that blocks already-written cases (not a spec gap, but it
  belongs here).** The frozen harness honours a `config:` block only for
  `kind: cli` cases and for the fixed `@variant_case_ids` list in
  `test/support/conformance_server.ex` (**18** ids — 1467–1473, 1491, 1493,
  1654, 1677, 1678, 1680, 1682, 1703, 1758, 1763, 1764; re-verified on disk at
  `:58-59` this pass). Every other HTTP case runs against a shared instance.
  Mechanically, **59** HTTP cases carry a non-empty `config:` outside that list;
  most simply restate what the shared instance already provides, so the
  interesting set is the cases whose declared config **diverges**:
  - **1742** (`config/server-cors-allowed-origins/default-preflight`) declares
    `server-cors-allowed-origins: ""` as upstream's `baseCfg` carries, but the
    shared instance is `"http://example.com, http://example2.com"`, so 1742 will
    echo the Origin instead of returning the permissive `*` and will **fail for
    the wrong reason**.
  - The **ten select cases 1129–1133, 1139, 1140, 1147–1149** (next bullet).
  - The **three errors cases 1517, 1518 and 1522**, all declaring
    `client-error-verbosity: minimal`. `spec/errors.yaml` is unusually explicit
    about this — it carries a dedicated `harness_gate:` key naming the three ids,
    the fix ("add 1517, 1518, 1522 to `@variant_case_ids`"), the harness
    reference (`test/support/conformance_server.ex#L58`) and a note that no
    PostgREST source applies because it is Bier-side wiring. **Verified on disk
    this pass**: `@variant_case_ids` still does not contain any of the three, so
    all three route to the shared *verbose* instance and their `config:` block is
    silently ignored. That the area model declares its own gate is the right
    pattern; the other two clusters do not.

  Closing any of these is a harness decision (per-`config` instance booting, or
  `@variant_case_ids` entries) behind the human harness gate, not a spec edit.
  **115** of the 668 cases carry a `config:` key (111 non-empty) — **unchanged
  this pass**: the pagination re-sync added eleven cases and no `config:` block,
  so it neither grew nor shrank this constraint.

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
  pinned by the errors area (1002, 1506, 1515–1516, 1519).
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

  > **Narrowed, not closed, by the pagination pass.** New case **1288**
  > (`GET /items?id=eq.1` with `Prefer: count=none, handling=strict` → 400
  > PGRST122, `"details": "Invalid preferences: count=none"`) is a second
  > table-flavored `handling=strict` assertion with a *different* invalid token,
  > so it strengthens the PGRST122 envelope coverage — but it is still not the
  > RPC flavor, and it lives in the pagination band rather than headers'. The
  > ownership question this gap raises is now three-way.

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
- **`Proxy-Status` on a HEAD request** — the docs' stated motivation for the
  header, exercised by no case. Cross-listed from **Known gaps → errors**; the
  behavior is method-independent in `errorResponseFor`, so it is MINOR.

### admin_server

- `/metrics` and `/schema_cache` endpoints have no case (`/live` and `/ready`
  are covered by ExUnit, not by the conformance suite).

### options / transactions

- `options`: **narrowed by the url_grammar pass, not closed.** Cases **1031**
  (VOLATILE routine → `OPTIONS,POST`), **1032** (STABLE routine →
  `OPTIONS,GET,HEAD,POST`), **1033** (root → `OPTIONS,GET,HEAD`) and **1034**
  (unknown relation → 404) joined 1019. What remains uncased is the
  **updatability-driven** half of upstream's matrix — auto-updatable views,
  trigger-backed views and partitioned tables
  ([`OptionsSpec.hs#L24-L80`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/OptionsSpec.hs#L24),
  flags at `Response.hs#L215-L222`). `spec/url_grammar.md`'s `gaps:` states the
  cost honestly: `bier_test` has no `projects_*_view_*` relations and standing
  them up means re-deriving upstream's trigger/updatability fixture set, not
  adding one object. **Fixture-blocked, not case-only** — do not group it with
  the cheap work above.
- `transactions`: no explicit transaction-characteristics / isolation-level case.

## Validation status

Machine-verified on **2026-08-09** at commit **`e3fb77e`**
("spec(errors): re-sync to PostgREST v16.0 (area 8/17)"), against a tree
**dirty mid-re-sync**: the uncommitted pagination re-sync (`spec/pagination.yaml`
+ 8 modified cases, 11 untracked cases, plus the two synthesis documents). The
checks cover the on-disk state *including* those. No repository file was modified
by the verification — its scripts live in a scratchpad outside the repo, and
`git status --porcelain | wc -l` read **22** both before and after.
**All six checks ran for real**; the substantive findings are recorded under
*Open verification findings* below.

- **Fixture load: OK.** `mix bier.fixtures.load` exited **0**, reporting the
  mirrored area schemas: `operators, ordering, pagination, representations,
  mutations, config, domain_representations`.

  > **Post-load counts, and an honest note about which number to trust.** The
  > verification recorded "22 non-system schemas, 640 relations, 783 functions".
  > Re-querying the same loaded database during synthesis gives **23** schemas,
  > **640** relations (`relkind in ('r','v','m','f','p')`, excluding
  > `pg_catalog`/`information_schema`/`pg_toast`) and **1026** functions
  > excluding only `pg_catalog`/`information_schema` (of which **993** are
  > `prokind='f'`). The relation count agrees exactly; the schema and function
  > counts differ purely by exclusion set, and this document deliberately does
  > **not** reconcile them by picking one — the divergence is the useful signal.
  > The schema list itself is stable and is what actually matters:
  > `SPECIAL "@/\#~_-`, `auth`, `config`, `domain_representations`, `geotest`,
  > `headers`, `headers_private`, `jwt`, `mutations`, `observability`,
  > `openapi_no_comment`, `operators`, `ordering`, `pagination`, `postgrest`,
  > `private`, `public`, `representations`, `rpc`, `test`, `v1`, `v2`, `تست` —
  > identical to the previous four passes. The pagination re-sync added **no**
  > fixture object, so nothing here could have moved. **No case depends on any of
  > these counts; do not cite them as evidence of anything.**
- **Case count: 668** — `ls -1 spec/conformance/cases/*.yaml | wc -l` and the
  validator agree (668 files, 668 parsed). **11** of the 668 (1278–1288) were
  untracked at verification time and **8** more were modified.
- All **668** cases parse as YAML. **0** parse errors, **0** non-mapping roots.
- All **668** cases validate against `case.schema.json` (`jsonschema` 4.26.0,
  Draft 2020-12 with `FormatChecker`, PyYAML) — **0** invalid cases. The
  validator was proved **live rather than vacuous** by negative controls on a
  mutated copy of pristine case 1000: pristine → 0 errors; an unknown key → 1
  error (`additionalProperties: false` enforced); a dropped `source` → 1 error
  (`required` enforced); a wrong-typed `id` → 1 error (`type` enforced); a
  malformed `source` shape → 1 error (`pattern` enforced).
- **Every case carries all seven keys** — `id`, `feature`, `request`, `schema`,
  `expect`, `notes`, `source` present on all 668, checked by intersecting the key
  sets rather than by trusting the schema's `required` list (which names only
  six: `notes` is not required by the schema but is universal in practice).
  **Every `NNNN_` filename prefix equals the in-file `id:`** (0 mismatches).

  > **FAILURE OF THE NEGATIVE CONTROL, recorded honestly and unchanged: the
  > schema does not enforce the pin.** The control that rewrites a `source:` URL
  > onto a *different* PostgREST tag produces **0 errors, NOT CAUGHT**. The
  > schema's pattern is
  > `^https://raw\.githubusercontent\.com/PostgREST/postgrest/.+#L[0-9]+$`, whose
  > `.+` matches any tag. So a clean schema run proves every case carries a
  > raw-host citation with a line anchor — it proves **nothing** about the
  > version. The URL sweep below is the *only* check that enforces `v16.0`;
  > do not substitute the schema run for it. (`case.schema.json` is the Tester's
  > file and was deliberately not edited here; tightening the pattern to the
  > pinned tag would be a Tester-side change.)
- **668** files, **668** distinct ids — **no duplicate ids**.
- **Source pins: clean, single tag.** The verification's prefix-aware sweep over
  its mandated scope (`spec/*.yaml` + `spec/*.md` + `spec/conformance/cases/*.yaml`
  — 687 files, of which 687 contain a PostgREST URL) found **1851** references
  and **exactly one tag: `v16.0`**. Widening the same sweep to include
  `spec/conformance/*.md` during synthesis gives **1857**, still a single tag.
  Doc links resolve to `postgrest.org/en/v16` (19 hits, no other version). This
  is the **only** check that enforces the pin — see the schema-validation caveat
  above.

  > Both figures are reported rather than reconciled: a synthesis document that
  > cites sources necessarily changes the count it is reporting. The invariant
  > that matters (**one tag, zero exceptions**) holds at both.

  > **Use a prefix-aware pattern.** A naive `grep -vE 'postgrest/v16\.0/'`
  > reports false stale hits: `github.com/PostgREST/postgrest/blob/v16.0/…`
  > lines put `blob/` between the repo and the tag. Match
  > `postgrest/(raw/|blob/|tree/)?<tag>`.

  > **Do not anchor the sweep on `https://` either.** Several in-scope URLs are
  > written scheme-less (`raw.githubusercontent.com/…` with no `https://`); a
  > scheme-anchored regex silently skips them.

  > **The only two in-scope lines that *look* like a non-v16 citation are not
  > URLs**: the literal schema regex
  > `^https://raw\.githubusercontent\.com/PostgREST/postgrest/.+#L[0-9]+$` quoted
  > in `README.md` and in this file. Both are pattern text.

  > **Bare `v14.12` occurrences are prose, not citations.** **104** remain across
  > the 17 area model files (`url_grammar.md` 15, **`pagination.yaml` 14**,
  > `errors.yaml` 13, `auth.yaml` 10, `config.yaml` 9, `filters.yaml` /
  > `observability.yaml` / `ordering.yaml` 6 each, `content_negotiation.yaml` /
  > `headers.yaml` 5 each, `select.yaml` 4, `openapi.yaml` / `rpc.yaml` 3 each,
  > `mutations.yaml` 2, `domain_representations.yaml` / `operators.yaml` /
  > `representations.yaml` 1 each), plus **25** across 24 case files.
  > `pagination.yaml` is this pass's mover (6 → 14), all of it in the expanded
  > re-sync note documenting exactly which header lines shifted in
  > `RangeSpec.hs`, `RpcSpec.hs` and `QueryLimitedSpec.hs`. Verified
  > mechanically: **zero** files in `spec/*.yaml`, `spec/*.md` or
  > `spec/conformance/cases/*.yaml` contain a `v14.12` *URL*. **Not** counted as
  > stale pins. (This count excludes `README.md`, `COVERAGE.md` and
  > `conformance/INDEX.md`, which the synthesis phase rewrites.)
  >
  > **But "prose, not a citation" is not the same as "correct".** Three of these
  > comparative notes have been found **false** and fixed, one per re-sync: case
  > **1029**'s "byte-identical parser" claim; case **1016**'s claim that v16.0
  > had no Feature-spec line for the PUT-`limit` rule; and, this pass,
  > `pagination.yaml`'s opening "no pagination behavior changed between the
  > pins", now narrowed to "no *asserted* pagination behavior changed" — the
  > re-sync found four traceable-but-unmodeled behaviors and one mis-modelled
  > rule behind that sentence. Three false claims out of ~129 prose occurrences
  > is a low rate, but the sweep above cannot detect any of them — it checks
  > tags, not truth. Treat every one of these mentions as unaudited.
- **Stale pins outside the checked globs — 51 `v14.12` URLs, unchanged.**
  Re-counted this pass with the prefix-aware pattern: **eight** files, **51**
  URLs, all in `--` provenance comments under `spec/conformance/fixtures/`:
  `ordering.sql` **27**, `observability.sql` **7**, `errors.sql` **5**,
  `auth.sql` **4**, `mutations.sql` **3**, `config.sql` **2**, `filters.sql`
  **2**, `rpc.sql` **1**. Per `conformance/fixtures/README.md` these files are
  historical provenance and explicitly **not authoritative** (the live artifact
  is `fixtures.sql`), and `.sql` is outside the pin check's declared globs — so
  this is **not** an in-scope failure. It is nonetheless real leftover pin drift
  the v16.0 re-sync has not touched. Note the pagination re-sync did **not** add
  to it, and `spec/conformance/fixtures/pagination.sql` is one of the files
  *without* a `v14.12` URL — though `spec/pagination.yaml`'s own gaps list
  records that it still carries a "PostgREST v14.12 parity" label in its header
  comment, left alone because existing `fixtures/*.sql` are off-limits.
- **Citation composition (not a check — an honesty note).** Grouping all **668**
  `source:` lines by directory: **472** cite `test/spec/Feature/Query`, 44
  `test/spec/Feature/Auth`, 34 `test/spec/Feature/OpenApi`, 15
  `test/spec/Feature/Query/Preferences`, 14 `test/spec/Feature`, **46** the
  `test/io` tree (20 fixtures, 16 top-level, 5 `configs`, 5 `configs/expected`),
  **1** the documentation itself — and **42** cite implementation code under
  `src/library/PostgREST/…` rather than an upstream assertion (32 directly under
  `src/library/PostgREST`, 7 under `.../ApiRequest`, 2 under `.../Response`, 1
  under `.../Config`). Those 42 expected bodies are *derived from reading the
  implementation*, not transcribed from an it-block, which is a weaker form of
  ground truth even though it is not a citation defect.

  The count moved 36 → **42** this pass — the largest single-pass increase so
  far, all of it pagination (**1283–1288**). Each of the six states in its
  `notes:` that PostgREST's own suite never issues the shape (count=planned on
  an RPC; a Range header on HEAD or on POST /rpc; a limit/Range combination that
  discriminates intersection from override; `Preference-Applied` on a plain
  read; `count=none` under `handling=strict`), and several are *deliberately*
  derived because the upstream gap is the point of the case — 1287 exists
  precisely because the only upstream it-block cannot discriminate the rule.
  That is a defensible use of priority-2 ground truth, but it is worth watching:
  a sixth of the increase in implementation-anchored cases since the tree was
  built came from one area in one pass.

  Separately, **case 1279 is the tree's first and only case anchored at the
  documentation** — `docs/references/api/pagination_count.rst#L52`, the
  open-ended `Range: 10-` paragraph. The docs are the primary specification, so
  this is arguably stronger than an implementation anchor, but it is a third
  citation class that neither `case.schema.json` nor any prior pass anticipated.
  Note it and decide whether it should be normalized.

  Against all that, **each of the last four area re-syncs found exactly one case
  in the implementation-anchored set that did not belong there**: filters moved
  **1189** (`Plan.hs#L855` → `QuerySpec.hs#L1187`), url_grammar moved **1016**
  (`ApiRequest.hs#L178` → `UpsertSpec.hs#L295`), errors' own new cases went the
  other way with explicit justification, and pagination re-anchored **1268**
  (`RangeSpec.hs#L160` → `#L163`) and **1269** (`#L152` → `#L153`) onto the
  actual assertion lines rather than their enclosing `context` lines. The
  remaining 42 should be re-read during their areas' audits — follow-up 10.
- **Id bands.** Fifteen areas each occupy one contiguous band; two areas are
  non-contiguous and must stay that way: **representations** (1300–1314,
  1320–1324, 1330–1333 — the gaps are deliberate sub-feature spacing) and
  **auth** (1450–1499 **+ 11800–11818** — the overflow band, the only 5-digit
  ids in the tree). Separately, the *config band* 1700–1744 is contiguous but
  **mixes shapes**: 1742/1743 are HTTP cases embedded in an otherwise CLI run
  of ids (see `conformance/INDEX.md` → *Case file shapes*). The **filters**
  primary band 1150–1199 is **fully allocated**; `spec/filters.yaml` declares
  `[10600..10799]` as the area's closed overflow range for future cases.
  **ordering** (1200–1232), **url_grammar** (1000–1035) and **errors**
  (1500–1526) remain contiguous with room — 1233+, 1036–1049 and 1527–1549
  respectively. New this pass: **pagination** grew to **1250–1288**, still
  contiguous, with **1289–1299** free before representations starts at 1300 —
  11 slots, enough for the embedded-`.offset` gap below.
- **Referenced relations: 20 flagged, 20 deliberate negatives, 0 unexplained.**
  The check resolved the first path segment of each HTTP case (percent-decoded;
  `/rpc/<fn>` → function `<fn>`; the 44 bare-`/` cases and the 38 `kind: cli`
  cases have no relation and were skipped, leaving **586** resolved) against
  `pg_class`/`pg_proc` on the freshly loaded DB, mirroring the frozen harness's
  schema resolution: `null`/`public`/`test` → `test`; `unicode` → `تست`;
  `multi` → `v1`/`v2`; `openapi_no_schema_comment` → `openapi_no_comment` (the
  1654 variant); and an explicit `Accept-Profile`/`Content-Profile` on the case
  wins over the label. **All 20 are cases that intentionally target a
  nonexistent relation/function/schema** to assert a 404 (PGRST125 / PGRST202 /
  PGRST205) or a 406: 1001, 1002, 1010, 1012, 1024, 1034, 1360, 1368, 1373,
  1432, 1515, 1516, 1517, 1520, 1521, 1525, 1560, 1583, 1652, 1765. **Zero**
  case whose expected status is 2xx targets a missing relation.

  > **Do not read 25 → 20 as a fix.** The previous pass flagged 25 and promoted
  > three (**1005**, **1008**, **1011**, all `schema: multi`) as a real finding.
  > This pass's script resolves `multi` to the `v1`/`v2` pair *itself*, so those
  > three — and the 405 pair 1006/1007 — simply stop being flagged. **The
  > underlying finding is unchanged and still open**; it rests on
  > `lib/bier/plugs/action_controller.ex:479`, not on this count. See *Open
  > verification findings → 1*. A checking script that resolves a label the way
  > the harness *intends* cannot detect that production code is what makes the
  > label resolve.

  The pagination re-sync's eleven new cases all resolve: **1278, 1279, 1284,
  1286, 1287, 1288** target `pagination.items`; **1280, 1281, 1282, 1283, 1285**
  target the function `pagination.getitemrange`. The re-sync also **repaired**
  four pre-existing cases whose path pointed at the wrong table — see *Fixture
  write channels* below.

### Open verification findings (carry into the conformance run)

Two findings, both about **fixture-set labels that resolve for the wrong
reason**. Both were open at the last pass and both still are. They share a root
cause worth naming once: a case's `schema:` label is turned into an
`Accept-Profile` header by the harness, but nothing checks that the label denotes
anything, so a label can be inert (finding 2) or can be rescued by production
code (finding 1) without any case failing.

#### 1. `schema: multi` resolves only because `lib/` hard-codes the harness's label — STILL OPEN

Re-verified on disk this pass, unchanged:

- `multi` is **not** a schema in `bier_test` (the loaded schema list above
  contains `v1` and `v2` but no `multi`), and **not** a key in
  `db_schema_aliases`, which contains exactly one entry, `"unicode" => "تست"`
  (`test/support/conformance_server.ex:181`).
- `db_profile_default: "v1"` and `db_profile_schemas: ["v1", "v2", …]`
  (`conformance_server.ex:184-185`) are real config, but they do not map the
  *string* `multi` to anything.
- What actually resolves it is an allowlist in **implementation** code:
  `@profile_aliases ~w(headers multi)` at
  `lib/bier/plugs/action_controller.ex:479`, consumed by `resolve_profile/2` at
  `:504`, which routes those two literal labels to the default profile schema
  instead of returning `{:error, {:invalid_schema, …}}`.

**Six cases send the label, not four.** The harness injects `Accept-Profile`
with `Map.put_new`, so a case escapes the injection only by spelling out
**`Accept-Profile`** itself; spelling out `Content-Profile` does not help. Of the
fourteen `multi` cases, these six receive `Accept-Profile: multi` (re-counted on
disk this pass):

| Case | Own headers | Expected | Depends on the allowlist? |
|------|-------------|---------:|---------------------------|
| 1005 | none | 200 | **yes** |
| 1006 | none | 405 | no — the RPC method check fires first |
| 1007 | none | 405 | no — same |
| 1008 | none | 200 | **yes** |
| 1011 | `Content-Profile: v2` | 201 | **yes** |
| 1012 | `Content-Profile: unknown` | 406 | no — 406 either way |

The other eight `multi` cases (1009, 1010, 1013, 1014, 1017, 1018, 1023, 1024)
set their own `Accept-Profile` and never touch the allowlist.

Why this is a finding and not bookkeeping: **case 1008's assertion is
self-contradictory as executed.** Its `notes:` read "No Accept-Profile header ->
first configured schema (v1) is used", and it expects `Content-Profile: v1` — but
the harness *always* sends `Accept-Profile: multi`, so the no-header path the
case documents is never exercised. Against real PostgREST, `Accept-Profile:
multi` against `db-schemas="v1,v2"` is a **PGRST106 / 406**, not a 200. The case
passes because `lib/` compensates for the harness, which is the one direction
this tree is supposed to forbid. 1005 (expects 200) and 1011 (expects 201) have
the same shape.

**This is a harness/implementation question, not a spec edit**, and it is
deliberately left as one: `test/**` is frozen, and removing `@profile_aliases`
from `lib/` without first giving the harness a way to send *no* profile header
would break three cases that are otherwise correct transcriptions of
`MultipleSchemaSpec`. The clean fix is harness-side — let a case opt out of the
`Accept-Profile` injection — after which `@profile_aliases` can go. Raise it with
the harness owner before the conformance run reads too much into these passing.

*(`headers`, the allowlist's other entry, is benign: it **is** a real schema in
the loaded DB, so it would resolve through the ordinary `profile in
config.db_schemas` branch even if the allowlist were removed. Only `multi` is
load-bearing.)*

#### 2. Case 1652 (`openapi.entities`) may pass for the wrong reason — CARRIED OVER, and independently re-flagged

Still open, and **this pass's machine check surfaced the same root cause from a
different direction**: it recorded that the fixture-set label `openapi` — used by
**31** cases — has no matching schema in the loaded DB
(`select nspname from pg_namespace where nspname ~ 'openapi'` returns only
`openapi_no_comment`), because `fixtures.sql` folds `openapi.sql`'s objects into
`test` while `conformance_server.ex:171` still lists `openapi` in `db_schemas`.
The verification correctly declined to call this a proven failure; it is the same
inertness described below.

The empirical data point (1652 **passes**, `mix test --only area:openapi` →
32/33) is **carried over from an earlier pass, not re-run here** — this pass ran
the static checks only, no `mix test`. Passing does not distinguish the two
possible reasons, so re-running it proves nothing new anyway; strengthening the
case is what would.

None of the three `openapi`-area fixture-set labels names a schema that exists in
the loaded DB. All 33 openapi cases carry one of `openapi` (31),
`openapi_no_schema_comment` (1654) or `openapi_variadic` (1672);
`test/support/http_case.ex` turns each into an `Accept-Profile: <label>` request
header, yet `mix bier.fixtures.load` creates none of them. The area's objects live
in schema `test` (`spec/conformance/fixtures/openapi.sql:24–41`), and the loader
deliberately does **not** mirror `openapi`
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

Resolving this belongs to the harness/fixture owner — `test/**` is frozen to
spec work, and `fixtures/openapi.sql` is frozen provenance (the live artifact
`fixtures.sql` is what actually loads). Note this is **not** a v16.0 regression:
the same mismatch existed at the previous pin and simply was not surfaced.

### Fixture write channels

All **six** `*.delta.sql` files are **comment-only** — each holds a single
`-- Folded into ../fixtures.sql on <date> …` provenance line and no DDL, i.e. the
write channel is empty and the folds are recorded: `content_negotiation` (the
`application/vnd.pgrst.object` / `text/tab-separated-values` domains and their
handlers), `headers` (`test.get_vary_header_override()` + GRANT), `ordering`
(`test.arrays` + seeds), `rpc` (`test."true"()` + GRANT) — all four dated
2026-08-08 — plus `url_grammar` (case 1035's `test."Server Today"` + its five
seed rows) and `errors` (`test.infinite_inserts` + `test.infinite_recursion`),
both dated 2026-08-09.

**The pagination re-sync added no seventh channel and no fixture object at all.**
`pagination.delta.sql` does not exist. Eleven new cases, three of them on
`/rpc/` paths, all ran against relations and functions the consolidated fixture
already had (`pagination.items`, `pagination.getitemrange`).

Instead it produced a different kind of fixture-related change, and this one is
worth flagging to the conformance run because it changes four *request paths*:
**cases 1258, 1264, 1266 and 1268 were retargeted from `/menagerie` to
`/menagerie_empty`.** Upstream's `menagerie` in `RangeSpec` is the pagination
fixture's single-column **empty** table, but `openapi.sql` contributes a
7-column type-mapping table of the same name; the consolidated `fixtures.sql`
keeps openapi's as `test.menagerie` and renames the empty one to
`test.menagerie_empty` (`fixtures.sql:75-79`, `:719-722`). All four cases assert
behavior over an **empty** relation — `Content-Range '*/*'`, `*/0`, an offset
past the end — so pointing them at the 7-row type-mapping table made them assert
the wrong thing. Both relations exist in the loaded DB; the re-sync's `notes:`
now record the collision on each of the four.

Across the last five area re-syncs — filters (9 cases), ordering (6),
url_grammar (6 + 2 rewrites), errors (8) and pagination (11 + 8 rewrites) — **40
new cases produced exactly three new relations**, all three from the errors and
url_grammar passes. Three of the gaps in this file would add more if closed:
filters' `empty_string` row (a first `filters.delta.sql`) and, if the
eight-column-type sweep is wanted, `items_with_different_col_types`; headers'
three `delete_items_returns_*` routines; and url_grammar's three
quote/backslash seed rows for `test.w_or_wo_comma_names` — though **not** the
fourth (`David White`), which is why that one is costed as case-only. **Neither
errors gap nor the pagination gap needs a delta**: the errors ones are HEAD
requests against `test.items`, and the embedded-`.offset` case runs on
`pagination.clients`/`projects`.

## Review status

The v16.0 re-sync re-pinned **every** case `source:` from `v14.12` to `v16.0`, so
the per-area audit verdicts recorded by the v14.12 pass no longer describe the
citations on disk and are not carried forward. All 17 area behavior models are
marked with the v16.0 pin. (The pin's *key spelling* is not uniform — 10 models
use `version: v16.0`, five use `version: PostgREST v16.0` (`errors`, `filters`,
`observability`, `operators`, `ordering`), `pagination.yaml` uses
`postgrest_version: v16.0`, and `url_grammar.md` states it in prose.)

> **Nor is the gap-list shape uniform, and this pass found the previous
> description of it understated.** Earlier revisions said only `errors.yaml`
> lacks a `gaps:` key. On disk **four** of the 17 models have no `gaps:` key
> anywhere: `errors.yaml` (which records coverage under `coverage:` plus a
> `harness_gate:` key) and — the part that was missed —
> **`content_negotiation.yaml`, `operators.yaml` and `representations.yaml`,
> which record no gap list at all, under any key.** `url_grammar.md` uses a
> `## Gaps` markdown section. All three silent models are among the eight areas
> with no recorded v16.0 verdict, so their silence is not evidence of
> completeness — it is un-audited absence, and it should raise their audit
> priority rather than lower it.

Adversarial review summaries recorded so far cover **auth**, **headers**,
**config**, **select**, **filters**, **ordering**, **url_grammar**, **errors**
and **pagination** — **9 of 17** areas:

| Area | v16.0 audit result | Nature of findings |
|------|--------------------|--------------------|
| auth | ⚠️ revise | 4 informational gaps, **0 citation defects** — the reviewer independently re-verified each gap's justification against v16.0 sources and confirmed all four are correct. See **Known gaps → auth**. |
| headers | ⚠️ revise | 3 missing-coverage findings, **0 citation defects** — RPC-flavored `max-affected` (incl. the wholly-uncovered PGRST128), RPC-flavored `handling`, and the CORS-preflight leg of the `Vary` rule. All three *citable but uncovered*. See **Known gaps → headers**. |
| config | ⚠️ revise | 2 missing-coverage findings, **0 citation defects** — `db-pre-config` (the v16-*recommended* in-database config mechanism, dump-observable, while cases 1724/1725/1744 cover only the deprecated `ALTER ROLE` path) and `app.settings.*` reaching SQL as a GUC (1729 pins only the dump surface). Both *citable but uncovered*. See **Known gaps → config**. |
| select | ⚠️ revise | 5 missing-coverage findings, **0 citation defects** — FK joins on views / chains of views (20 upstream it-blocks, no case *and* no gap entry), spread to-many (gap recorded but its "needs a fixture" justification does not hold), aggregates in to-one spreads + the PGRST127 rejection (entire upstream context, absent from the whole tree), FK joins on partitioned tables, and the terminal `->` on a json/jsonb column. All five *citable but uncovered*. See **Known gaps → select**. |
| filters | ⚠️ revise | 3 missing-coverage findings, **0 citation defects** — the `IN`/`NOT IN` empty set (an 11-it-block upstream `describe`, `in.()` issued by no case in the tree, while `operators.yaml` already models the `= ANY('{}')` rendering it produces), the empty filter *value* (`?string=eq.` → `""`), and the implicit AND of two plain filters. All three *citable but uncovered*. See **Known gaps → filters**. |
| ordering | ⚠️ revise | 2 missing-coverage findings, **0 citation defects** — *Order in spread to-many* (a named v16 docs section with its own worked example, exercised by upstream at `SpreadQueriesSpec.hs#L163` and `AggregateFunctionsSpec.hs#L157/#L168`, and asserted by **no case anywhere in `spec/`**) and the aliased-relation PGRST118 (upstream asserts `order=pros(id)` naming the **alias** in both `details` and `message`; case 1216 covers only the unaliased twin). Both *citable but uncovered*, both case-only. See **Known gaps → ordering**. |
| url_grammar | ⚠️ revise | 1 missing-coverage finding, **0 citation defects** — backslash / escaped-double-quote values inside `in.( … )`, a named part of the area's own docs page with three upstream `it`-blocks (plus one in the adjacent describe) and **no case anywhere in `spec/`**. *Citable but uncovered*, and **partly case-only**. The pass also produced two case repairs that are *not* review findings but belong on the record — **1016** re-anchored off implementation code onto `UpsertSpec.hs#L295` (retiring a false "no Feature spec line exists" claim) and **1029**'s overstated "byte-identical parser" note corrected. See **Known gaps → url_grammar**. |
| errors | **✅ pass** | **The tree's only pass verdict.** 3 findings, **all explicitly MINOR / non-blocking**, **0 citation defects** — no `Proxy-Status` assertion on a HEAD request (the docs' stated motivation, but the behavior is method-independent in `errorResponseFor`), the modelled `inline_416_content_length_suppressed_on_head` flag that no case exercises (the one genuinely method-dependent behavior, and case-only to close), and the 42883 `xmlagg` → 406 special case (effectively unreachable black-box, accepted as-is). The pass additionally confirmed by reproduction in a scratch DB that cases **1523/1524**'s fixtures behave as asserted, and flagged a **harness gate** (1517/1518/1522 need `@variant_case_ids` entries) that is Bier-side wiring, not a spec defect. See **Known gaps → errors**. |
| **pagination** | ⚠️ **revise** | 1 missing-coverage finding, **0 citation defects** — embedded **`<embed_path>.offset` has zero cases anywhere in the tree**, while `<embed>.limit` has one (1276); the model names both parameters and cites the docs example for the offset half, and its `constraints:` only justify omitting a *deeper-nested* offset case, never the single-level one both `resource_embedding.rst#L919` and `QueryLimitedSpec.hs#L42` exercise. *Citable but uncovered*, **case-only**, and now the cheapest open item in this file. The pass is also the tree's most substantial **model correction** to date: the Range header was documented as *overriding* limit/offset when `getRanges` **intersects** them (new discriminating case 1287), four traceable-but-unmodeled behaviors were added (PAG-025..PAG-028), four cases were retargeted off a fixture name collision (`/menagerie` → `/menagerie_empty`), and two `source:` anchors were moved onto their actual assertion lines (1268, 1269). See **Known gaps → pagination**. |
| the other 8 areas | not re-audited at this pin | Citations are self-reported at the v16.0 pin. Three of them (`content_negotiation`, `operators`, `representations`) additionally record **no gap list at all**. |

Open follow-ups:

1. Run `bier-spec-audit` over the **8** areas without a recorded v16.0
   adversarial verdict: `operators`, `representations`, `mutations`, `rpc`,
   `content_negotiation`, `openapi`, `observability`, `domain_representations`.
   **Prioritize `operators`, `representations` and `content_negotiation`**: they
   are the three models with no gap list under any key, so nothing on disk
   distinguishes "audited and complete" from "never examined".
2. **Close the pagination gap — now the cheapest open work in this file.** One
   case in the free **1289–1299** slice: an embedded `<embed>.offset`, either the
   docs' to-many shape
   (`/clients?select=id,projects(id)&order=id&projects.order=id&projects.offset=1`
   on `pagination.clients`/`projects`, both verified present with 2 and 5 rows)
   or upstream's to-one shape (`QueryLimitedSpec.hs#L42`,
   `…&project.offset=1` → `"project": null`). No fixture, no config, no band
   decision. Alternatively, add a `gaps:` entry that argues against the
   single-level form — the current `constraints:` text argues only against the
   nested one.
3. Re-check the `openapi` label finding — specifically whether case **1652**
   returns 406 for the media-type reason or for the unknown-schema reason —
   before trusting that area's results. It currently *passes*, which is exactly
   why it needs the stronger assertion. This pass's machine check independently
   re-surfaced the same root cause (label `openapi` names no schema; 31 cases
   carry it).
4. **Raise the `schema: multi` finding with the harness owner** (*Open
   verification findings → 1*). Cases **1005**, **1008** and **1011** pass only
   because `lib/bier/plugs/action_controller.ex:479` hard-codes the conformance
   labels `headers` and `multi`; 1008's own `notes:` describe a
   no-`Accept-Profile` request the harness never sends. Note this pass's
   relation check no longer flags them — it resolves `multi` itself — which is a
   change in the script, **not** a fix. Needs a harness affordance (opt out of
   the profile-header injection) before the `lib/`-side allowlist can be
   removed; do not "fix" it from the spec side. Pairs naturally with item 3.
5. **Close the two errors gaps.** Both are a single HEAD request in the free
   **1527+** slice of the errors band against `test.items`: `HEAD
   /items?offset=100` asserting `headers_absent: [Content-Length]` (the modelled
   `inline_416_content_length_suppressed_on_head` flag, the one method-dependent
   behavior with no case) and, if wanted, the same request asserting
   `Proxy-Status` — MINOR by the reviewer's own assessment. Closing the first
   also closes the tree's only *request-shape* blind spot: all **12** existing
   HEAD cases expect 2xx, and the pagination pass added the twelfth without
   closing it.
6. **Wire the errors harness gate.** `spec/errors.yaml`'s `harness_gate:` key
   asks for **1517, 1518, 1522** to be added to `@variant_case_ids`
   (`test/support/conformance_server.ex:58`); verified on disk this pass that
   none of the three is there, so all three run against the shared *verbose*
   instance with their `client-error-verbosity: minimal` block silently ignored.
   Human harness gate, not a spec change. Group it with item 9.
7. Close the five select gaps, cheapest first: the terminal-`->` json case and
   the spread-to-many case need only case files; aggregates-in-to-one-spreads
   (+ PGRST127) needs cases plus the `db-aggregates-enabled` harness wiring; FK
   joins on views/chains and on partitioned tables need fixtures.
8. Close the two config gaps: one CLI case for `db-pre-config` (needs a
   pre-config function reachable at startup) and one HTTP case for
   `app.settings.*` via `/rpc/get_guc_value` (the fixture function already
   exists).
9. Decide the harness question behind **all** the unhonoured `config:` blocks —
   case **1742** (config band), the ten select cases
   1129–1133/1139/1140/1147–1149, and the three errors cases 1517/1518/1522.
   Until then 1742 fails for the wrong reason, the eight aggregate cases run with
   `db-aggregates-enabled` at its `False` default, and the three verbosity cases
   run verbose. The count is stable at **115** cases carrying `config:` (111
   non-empty); pagination added none.
10. Review the **42** cases whose `source:` anchors implementation code rather
    than an upstream assertion, plus **case 1279**, the tree's only
    docs-anchored citation. **Every one of the last four re-syncs produced
    movement here** — 1189 (filters) and 1016 (url_grammar) moved *off*
    implementation code, errors added two with explicit justification, and
    pagination added six and re-anchored two (1268, 1269) onto their actual
    assertion lines. Each remaining one should either follow 1189/1016, or say
    in `notes:` why no upstream it-block exists — several already do. Treat this
    as a real defect source, not hygiene, and note the set grew fastest this
    pass.
11. Close the two ordering gaps — both case-only, both landing in the free 1233+
    slice, both running on relations the loaded DB already has: one case for
    *Order in spread to-many* on `ordering.projects` → `ordering.tasks`, and one
    for the aliased-relation PGRST118 on `ordering.clients`/`ordering.projects`,
    whose envelope must name the **alias** (`pros`) in both `details` and
    `message`. Re-confirm both `#L` anchors against the raw upstream files when
    authoring — two independent reads disagreed on the exact line ranges, though
    not on the content.
12. Close the url_grammar gap, or at least its cheap half. One case in the free
    **1036–1049** slice reproduces `QuerySpec.hs#L1334` ("passes any escaped
    char as the same char") against the already-seeded `David White` row with no
    fixture delta; the other three it-blocks need `'"'`,
    `'Double"Quote"McGraw"'`, `'\'` and `'/\Slash/\Beast/\'` seeded into
    `test.w_or_wo_comma_names`. Either write the cheap one or rewrite
    `spec/url_grammar.md`'s gap text, which currently declines all four on a
    fixture argument that only applies to three. Re-fetch both anchors first —
    the reviewer's `QuerySpec.hs#L1323-L1340` and `url_grammar.rst#L68-L74` are
    both off (correct: `#L1320-L1337` and `#L77-L81`).
13. Close the three filters gaps. Two are case-only — the `in.()` / `not.in.()` /
    `in.(    )` / `in.( ,3,4)` set on an existing relation, and the two-plain-
    filters AND — but both need a band decision first, because filters' primary
    band 1150–1199 is full (overflow `[10600..10799]`) and `in.`'s SQL rendering
    is claimed by `operators`. The empty-`eq.` case needs a seeded `''` row,
    which would be the filters area's first fixture delta. Note this collides
    with item 12: three separate gaps are about `in.( … )` and they are spread
    over three areas. Settle ownership once.
14. Decide whether to re-pin the **51** `v14.12` provenance URLs in the eight
    `spec/conformance/fixtures/*.sql` files, or to state in
    `conformance/fixtures/README.md` that they are frozen at the pin they were
    derived from. Note neither the errors nor the pagination re-sync added to the
    count, but `fixtures/pagination.sql` still carries a "PostgREST v14.12
    parity" **label** in its header comment (recorded in `pagination.yaml`'s
    gaps, left alone because existing fixture fragments are off-limits).
15. Consider asking the Tester to tighten `case.schema.json`'s `source` pattern
    from `.../postgrest/.+#L[0-9]+$` to the pinned tag. As written, schema
    validation cannot catch a stale pin (re-proved by negative control this
    pass), so the pin is enforced only by an ad-hoc grep sweep that lives in this
    document rather than in CI. While there, decide whether a **docs**-anchored
    `source:` (case 1279, the pattern's first) should be allowed explicitly
    rather than by accident — the current pattern requires a
    `raw.githubusercontent.com/PostgREST/postgrest/…#L<n>` URL, which a docs file
    satisfies, so the third citation class is currently indistinguishable from
    the other two. `case.schema.json` is the Tester's file and was deliberately
    not edited here.
