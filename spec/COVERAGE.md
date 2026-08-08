# Coverage

Maps every page of the PostgREST **v16** documentation
([postgrest.org/en/v16](https://postgrest.org/en/v16/)) to the conformance case
ids that cover it. The docs-page list follows the v16 site's **References**
section and its **API** sub-pages.

A docs page with no covering case (and not explicitly scoped out below) is
flagged **GAP**.

Pinned target: **PostgREST v16.0**. Total cases: **614** across 17 areas
(counted on disk this pass, not carried over).

## References → API sub-pages

| Docs page (`references/api/...`) | Covering case ids | Notes |
|----------------------------------|-------------------|-------|
| `tables_views` (Tables and Views) | 1000–1029 (url_grammar), 1050–1099 (operators), 1100–1141 (select), 1150–1190 (filters), 1200–1226 (ordering), 1300–1333 (representations), 1350–1397 (mutations) | Read/write of tables & views: path resolution, horizontal/logical filters, operators, vertical filtering (select), ordering, insert/update/delete/upsert. |
| `functions` (Functions as RPC) | 1400–1440 (rpc), 1005–1007 (url_grammar /rpc paths), 1023 (rpc profile), 1489–1490 (auth rpc), 1570 (rpc status GUC) | GET/POST RPC, scalar/setof/composite/void returns, args, variadic, volatility, overloaded functions, single unnamed JSON parameter, reserved-word function name (1440). |
| `schemas` (Schemas) | 1008–1012, 1022–1024 (url_grammar profile), 1557–1560, 1574 (headers profile), 1730 (`db-schema` singular alias), 1733–1734 (`db-schemas` rejects `pg_catalog` / `information_schema`) | Accept-Profile / Content-Profile, multi-schema routing, unacceptable schema, restricted system schemas (new in v16). |
| `computed_fields` (Computed Fields) | 1128 (select computed-column), 1208 (ordering computed), 1806 (domain rep. via view + computed column) | Computed (virtual) columns in select and order. |
| `domain_representations` (Domain Representations) | 1800–1820 (domain_representations) | **COVERED**: CREATE DOMAIN cast representations — read (format cast shapes output, incl. implicit `select=*` and through-embed), write (parser cast applied to bodies, `columns=` param), filter (domain-typed predicates, `in`/`not.in`, across relations), default (no cast → base type), error paths (1819–1820). |
| `pagination_count` (Pagination and Count) | 1250–1277 (pagination), 1431 (rpc Range header), 1700–1701 (db-max-rows) | limit/offset, Range header, exact/planned/estimated count, db-max-rows. |
| `resource_embedding` (Resource Embedding) | 1112–1127, 1133–1141 (select embed/spread/one-to-one/computed rels/aliases), 1181–1190 (filters embed), 1211–1224 (ordering embed/related), 1276 (nested limit), 1028 (legacy embed target name), 1736 (`url-use-legacy-target-names` dump) | Many-to-one/one-to-many/many-to-many, one-to-one (pk-as-fk, unique FK), computed relationships, nested, inner/left, disambiguation, spread, and the v16 target-name→alias migration (1028, 1138–1141, 1188–1190, 1224). |
| `resource_representation` (Resource Representation) | 1300–1333 (representations), 1550–1556 (Prefer), 1610–1615, 1629 (singular), 1630–1635 (nulls-stripped) | Prefer: return=representation/minimal/headers-only, singular object, vnd.pgrst.object, stripped nulls. |
| `media_type_handlers` (Media Type Handlers) | 1600–1646 (content_negotiation, incl. 1636–1638/1642/1644/1646 custom-media-handler), 1426 (rpc csv) | JSON/CSV/GeoJSON/octet-stream/text, Accept negotiation and precedence (1639–1641, 1645), custom media handlers (anyelement, override-builtin, any-handler, vendored-not-overridable, table aggregate, default-select requirement), plan output. |
| `aggregate_functions` (Aggregate Functions) | 1129–1133 (select aggregate), 1644 (aggregate through a custom media handler) | count/sum/group-by/alias+cast, agg in embed. |
| `openapi` (OpenAPI) | 1650–1682 (openapi), 1619–1621, 1645 (content_negotiation openapi) | Root spec, comments→summary/description, type mapping, modes, security, `db-root-spec`. |
| `preferences` (Prefer Header) | 1550–1556, 1577–1581, 1584 (headers prefer), 1302–1304, 1313–1314, 1322, 1324, 1332–1333 (return=minimal / headers-only), 1390–1392 (max-affected), 1551–1552 (handling), 1553–1554, 1577–1581, 1584 (timezone) | Prefer: return, handling=strict/lenient, timezone (incl. ± offsets, leap seconds, invalid under default/lenient/strict, and the single- vs two-token `Preference-Applied` echo in 1553/1584), max-affected, missing-defaults via `columns`. **Partial** — every `handling` and `max-affected` case is table-flavored; the RPC flavor of both preferences (incl. PGRST128) has no case. See **Known gaps → headers**. |
| `vary_header` (Vary Header) | 1575 (default `Vary: Accept, Prefer, Range` on a read), 1576 (`response.headers` GUC override replaces it verbatim), 1582 (the default is appended by `toWaiResponse` for every non-error response, witnessed on OPTIONS), 1583 (error responses carry no `Vary` — they bypass `toWaiResponse`) | **NEW page in v16** — covered. 1582/1583 match the modelled entries `headers.vary.non_read_responses` / `headers.vary.absent_on_errors`. The one remaining leg — a *CORS preflight* answered by the wai-cors middleware, which never reaches `toWaiResponse` — is a gap; see **Known gaps → headers**. |
| `cors` (CORS) | 1702–1704 (config CORS) | Allowed-origin echo, empty config allows all, non-matching origin. **Partial** — the preflight cases assert no `Vary`-absence, the third leg of the v16 `Vary` rule. See **Known gaps → headers**. |
| `options` (OPTIONS method) | 1019 (url_grammar OPTIONS Allow), 1757, 1768–1769 (observability OPTIONS server-timing on table / rpc / root) | OPTIONS Allow header; OPTIONS Server-Timing subset. Partial — no dedicated `Allow`-body assertions beyond 1019. |
| `url_grammar` (URL Grammar) | 1000–1029 (url_grammar) | Path/method resolution, reserved query params (incl. the legacy embed target name, 1028), %-encoding, `+`→space, double-quoting reserved characters in filter values and in quoted identifiers (1025–1027, 1029). |

## References → top-level pages

| Docs page (`references/...`) | Covering case ids | Notes |
|------------------------------|-------------------|-------|
| `auth` (Authentication) | 1450–1499 + 11800–11818 (auth) | JWT validation/claims, HS256 (incl. binary/base64 secret) and RS256 (JWK and JWKS), roles, role-claim-key JSON Path, anonymous, audience, pre-request, GUC claims, login-token minting, clock-skew errors. Partial — see **Known gaps**. |
| `cli` (CLI) | 1705–1738 (all 34 `request.kind: cli` cases) | `--dump-config`, `--example`, validation, env/file/db precedence, coercion, aliases. Driven in-process by `Bier.CliCase`. |
| `transactions` (Transactions) | 1387–1392 (safe-update/delete, max-affected), 1713, 1722 (db-tx-end validation + enum mapping), 1759 (transaction timing) | Tx-scoped GUCs, safe-update/safe-delete (rollback on missing WHERE), db-tx-end. Partial — no explicit characteristics/isolation-level case. |
| `connection_pool` (Connection Pool) | — (OUT OF SCOPE) | Pool sizing/acquisition behavior is operational and not observable as deterministic black-box HTTP. See **Scope decisions**. |
| `schema_cache` (Schema Cache) | — (DEFERRED) | Schema-cache reload (`NOTIFY pgrst, 'reload schema'` / SIGUSR1) needs a reload-signal harness. See **Scope decisions**. |
| `errors` (Errors) | 1500–1518 (errors), 1432–1434 (rpc errors), 1002, 1024, 1185 (not-found / invalid path), 1455–1464 + 11809–11814 (auth JWT errors), 1506, 1515–1516, 1518 (Proxy-Status envelope) | SQLSTATE→HTTP mapping, PGRST error codes, RAISE PGRST full control, 4xx/5xx envelopes, `Proxy-Status`, client-error-verbosity=minimal. |
| `configuration` (Configuration) | 1700–1738 (config) | Sources (env/file/db-role-settings), aliases, validation, coercion, precedence, app-settings, plus the v16 keys `client-error-verbosity` (1731–1732), `server-reuseport` (1735), `url-use-legacy-target-names` (1736), `admin-server-unix-socket` (1737–1738). |
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
  Neither half survives contact with the tree: the CLI band is now
  **1705–1738 (34 cases)**, and **no spec case carries `pending` or
  `pending_reason`** — those are not properties of `case.schema.json`; they were
  harness-side tags. The harness's only remaining deferral is `:status_text`
  (`test/conformance/conformance_test.exs`), which excludes the **6** cases that
  assert `expect.status_text` (1508–1511, 1513–1514) because `Req` does not
  expose the HTTP reason phrase. The `:db_config` deferrals were retired when the
  in-database config source landed. `Bier.CLI` provides the standalone,
  drop-in PostgREST-compatible CLI (`PGRST_*` env, kebab config file,
  `--dump-config`); standalone packaging (`mix release` + Dockerfile) is tracked
  in #45.

## Coverage summary

- Docs pages enumerated: **27** — 16 API sub-pages + 11 top-level reference
  pages (the `references/api` parent page is counted once, through its
  sub-pages; `url_grammar` is counted once).
- Pages with at least one covering case: **23**.
- Pages explicitly scoped: **4** — `connection_pool` (out of scope),
  `http_server` (out of scope, new in v16), `schema_cache` (deferred),
  `listener` (deferred).
- Pages flagged **GAP** (no covering case and not scoped out): **0**.

Two pages are new in v16 relative to the previous pass: `api/vary_header`
(covered, 1575–1576 and 1582–1583) and `http_server` (scoped out — see above).

Seven pages are marked **Partial** in the notes above (`options`,
`transactions`, `admin_server`, `observability`, `auth`, and — new from this
pass's headers audit — `preferences` and `cors`): they have covering cases but
not the full breadth of the docs page. These are soft gaps, itemized next.
`vary_header` stays **covered** but carries one itemized gap (the preflight
leg).

## Known gaps

Soft gaps — documented public behavior with no conformance case. **None is a
citation defect.** They fall into two kinds, and the distinction matters when
prioritizing:

- **Uncitable** — the ground truth to cite does not exist upstream at v16.0, or
  cannot be expressed in the current `case.schema.json` shape (multi-request
  sequences, signals, timing). Most of the *auth* and *observability* entries.
  These stay open until the harness or upstream changes.
- **Citable but uncovered** — upstream *does* assert the behavior at v16.0 with
  a fetchable it-block, and the case shape can express it; nobody wrote the
  case. **All three *headers* entries are of this kind**, so they are the
  actionable ones. Each is labelled below.

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
express them, so all three are actionable. Each was re-fetched from the v16.0
sources during this synthesis rather than carried over from the review summary.

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
  headers), and **`PGRST128` appears nowhere in the tree** — so the error code
  itself is entirely uncovered. `spec/rpc.yaml` explicitly delegates this
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
  (1702/1703, in the config band) and would only need `headers_absent: [Vary]`
  added — but they are frozen ground truth, and the id band is `config`'s, so
  the fix is an authoring decision (extend 1702/1703 vs. add a headers-band
  case) rather than a mechanical edit. Note case 1582 deliberately sends **no**
  `Origin` precisely so its OPTIONS is *not* treated as a preflight, which is
  why the two rules do not collide.

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

Machine-verified on **2026-08-08** at commit **`6d38e68`**
("spec(auth): re-sync to PostgREST v16.0 (area 1/17)"), with the working tree
**dirty mid-re-sync**: 9 modified spec files plus 3 untracked new cases
(1582/1583/1584). The checks cover the on-disk state *including* those; no
repository file was modified by the verification, whose scripts live in a
scratchpad. **Every check below passed.**

- **Fixture load: OK.** `mix bier.fixtures.load` exited **0**, reporting the
  mirrored area schemas (`operators, ordering, pagination, representations,
  mutations, config, domain_representations`). Post-load sanity: **23**
  non-system schemas present — `SPECIAL "@/\#~_-`, `auth`, `config`,
  `domain_representations`, `geotest`, `headers`, `headers_private`, `jwt`,
  `mutations`, `observability`, `openapi_no_comment`, `operators`, `ordering`,
  `pagination`, `postgrest`, `private`, `public`, `representations`, `rpc`,
  `test`, `v1`, `v2`, `تست` — holding **605** relations
  (`relkind in ('r','v','m','f','p')`).
- **Case count: 614** — `ls spec/conformance/cases/*.yaml | wc -l` and the
  validator agree (614 files, 614 parsed). Includes the 3 untracked new cases.
- All **614** cases parse as YAML. **0** parse errors.
- All **614** cases validate against `case.schema.json` (`jsonschema`
  Draft 2020-12, Python 3.14) — **0** invalid cases.
- **614** files, **614** distinct ids — **no duplicate ids**
  (`grep -h '^id:' … | sort | uniq -d` is empty).
- **Source pins: clean, single tag.** A regex sweep of every PostgREST
  `github`/`raw.githubusercontent` URL across `spec/*.yaml`, `spec/*.md` and
  `spec/conformance/cases/*.yaml` (in `source:` fields and in `notes:` prose
  alike) found **1548** references and **exactly one tag: `v16.0`**. Zero stale
  pins. Every case file carries exactly one `source:` (614 total).
  `conformance/INDEX.md` and `conformance/fixtures/README.md` contain no
  PostgREST version references at all.
- **Noted, out of scope (unchanged):** three frozen fixture-provenance files
  still carry `v14.12` URLs in comments — `fixtures/ordering.sql`,
  `fixtures/auth.sql`, `fixtures/config.sql`. Per
  `conformance/fixtures/README.md` those files are historical provenance and
  explicitly **not authoritative** (the live artifact is `fixtures.sql`), so they
  are deliberately left alone; the sweep above scopes to `spec/*.yaml`,
  `spec/*.md` and the case files.
- **Id bands.** Fifteen areas each occupy one contiguous band; two areas are
  non-contiguous and must stay that way: **representations** (1300–1314,
  1320–1324, 1330–1333 — the gaps are deliberate sub-feature spacing) and
  **auth** (1450–1499 **+ 11800–11818** — the overflow band, the only 5-digit
  ids in the tree).
- **Relation coverage: no genuine gaps.** A first-path-segment check against the
  loaded fixtures — run **alias-aware**, resolving each case's `schema:` *label*
  the way the real harness does (`test/support/conformance_server.ex`
  `db_schemas`/`db_schema_aliases`/`db_profile_default` and
  `lib/bier/plugs/action_controller.ex` `resolve_profile/2`: `null`/`public`/
  `test` → `test`, `unicode` → `تست`, `multi` → `{v1, v2, SPECIAL "@/\#~_-"}`,
  `headers` → `headers` plus the multi set, case 1654 → `openapi_no_comment`) —
  **skipped 76** cases that target no relation (the 34 CLI invocations plus the
  root-`/` requests), **checked 538**, and found **11** whose relation/function
  does not exist:

  | Case | Target | Expected | Why it is intentional |
  |------|--------|----------|-----------------------|
  | 1001 | `test.first` | 404 | `invalid_resource_path` |
  | 1002 | `test.invalid` | 404 | `invalid_path_proxy_status` |
  | 1360 | `mutations.garlic` | 404 | `insert_columns_unknown_table_precedence` |
  | 1368 | `mutations.fake` | 404 | `update_table_not_found` |
  | 1373 | `mutations.foozle` | 404 | `delete_table_not_found` |
  | 1432 | `rpc.fake` (function) | 404 | `rpc_unknown_proc_404` |
  | 1515 | `test.non_existent_table` | 404 | `table_not_found_pgrst205` |
  | 1516 | `test.invalid` | 404 | `invalid_path_pgrst125` |
  | 1517 | `test.itemsx` | 404 | `client_error_verbosity_minimal` |
  | 1765 | `observability.unknown` | 404 | `log_level_404_status` |
  | 1652 | `openapi.entities` | 406 | `openapi_nonroot_406` — `Accept: application/openapi+json` on a non-root path fails negotiation *before* relation resolution, so `entities` is never looked up (it does exist in 8 other schemas) |

  **Zero** case whose expected status is 2xx/3xx targets a missing relation.
  (This pass's checker resolves labels more faithfully than the previous one,
  which reported 15 missing over 535 checked; 1010, 1012, 1024 and 1560 now
  resolve correctly and are no longer listed. The set of *genuine* gaps is
  unchanged: still zero.)
- **All five `*.delta.sql` write channels are empty** — the fixture
  Consolidator folded them into `fixtures.sql`.

### Open verification finding (carry into the conformance run)

**Re-confirmed this pass, unchanged.** None of the three `openapi`-area
fixture-set labels names a schema that exists in the loaded DB, and the labels
are inert. All 33 openapi cases carry one of `openapi` (31),
`openapi_no_schema_comment` (1654) or `openapi_variadic` (1672).
`test/support/http_case.ex` turns each into an `Accept-Profile: <label>` request
header, yet `mix bier.fixtures.load` creates none of them — confirmed directly
against the loaded DB: `select nspname from pg_namespace where nspname like
'openapi%'` returns only `openapi_no_comment`. The area's objects live in schema
`test` (`spec/conformance/fixtures/openapi.sql:24–41`: `CREATE SCHEMA IF NOT
EXISTS test; CREATE TABLE test.entities …`), and the loader deliberately does
**not** mirror `openapi` (`lib/mix/tasks/bier.fixtures.load.ex:29` —
"Function-heavy areas (rpc, openapi, headers) are intentionally NOT mirrored").

Why it is currently harmless, and why that is itself worth recording:
`Bier.Plugs.ActionController.dispatch/3` routes the root path (`conn.path_info
== []`) straight to `dispatch_root/2` **without** calling `resolve_profile/2`,
and `build_openapi_document/2` selects `hd(config.db_schemas)`. The root document
is therefore always generated from the *first* configured schema (`test` on the
shared instance; `openapi_no_comment` on the 1654 variant), and the
`Accept-Profile` header these 32 root cases send is ignored end to end. The
labels assert nothing today, and they would break the moment root-path profile
resolution is implemented. Case 1652 (`GET /entities` under `Accept-Profile:
openapi`, expects 406) is the only openapi case that reaches relation dispatch;
`reject_openapi_media/1` runs before relation resolution
(`action_controller.ex:329–341`), so its 406 is plausibly reached for the right
reason, but it is the one to re-check first.

A second, related harness observation from this pass, **inert but worth
recording**: the shared conformance instance lists `openapi` in its `db_schemas`
(`test/support/conformance_server.ex:170`) even though no `openapi` namespace
exists in the loaded DB (`select count(*) from pg_namespace where
nspname='openapi'` → 0). It is harmless for the same reason as above — all 31
`openapi`-label cases request the root `/` document except 1652, the 406
negotiation case — but it is the second symptom of the same underlying
label/schema mismatch and should be fixed together with it.

Resolving this belongs to the harness/fixture owner — `test/**` is frozen to
spec work, and `fixtures/openapi.sql` is frozen provenance (its header still
reads "Derived from PostgREST v14.12 test/spec/fixtures/schema.sql"; the live
artifact `fixtures.sql` is what actually loads). Note this is **not** a v16.0
regression: the same mismatch existed at the previous pin and simply was not
surfaced, because the relation check only inspects the first path segment and
these cases request `/`.

## Review status

The v16.0 re-sync re-pinned **every** case `source:` from `v14.12` to `v16.0`, so
the per-area audit verdicts recorded by the v14.12 pass no longer describe the
citations on disk and are not carried forward. All 17 area behavior models are
marked `version: v16.0` and each closes with an explicit `gaps:` list.

Adversarial review summaries recorded so far cover **auth** and **headers**:

| Area | v16.0 audit result | Nature of findings |
|------|--------------------|--------------------|
| auth | ⚠️ revise | 4 informational gaps, **0 citation defects** — the reviewer independently re-verified each gap's justification against v16.0 sources and confirmed all four are correct. See **Known gaps → auth**. |
| headers | ⚠️ revise | 3 missing-coverage findings, **0 citation defects** — RPC-flavored `max-affected` (incl. the wholly-uncovered PGRST128), RPC-flavored `handling`, and the CORS-preflight leg of the `Vary` rule. All three are *citable but uncovered* (upstream asserts them at v16.0 and the case shape fits), so unlike the auth findings they are actionable now. Each was re-fetched from the v16.0 sources during this synthesis and confirmed. See **Known gaps → headers**. |
| the other 15 areas | not re-audited in the input to this pass | Citations are self-reported at the v16.0 pin. |

Open follow-ups:

1. Run `bier-spec-audit` over the **15** areas without a recorded v16.0
   adversarial verdict.
2. Re-check the `openapi` label finding above (both symptoms) before trusting
   that area's results.
3. Close the three headers gaps. Two need only case files
   (RPC `handling`; the preflight `Vary` assertion); the RPC `max-affected` /
   PGRST128 gap additionally needs `delete_items_returns_setof` /
   `_returns_table` / `_returns_void` fixtures, so it is a fixture-delta
   decision, not a spec-only edit.
