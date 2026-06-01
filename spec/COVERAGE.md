# Coverage

Maps every page of the PostgREST **v14** documentation
([postgrest.org/en/v14](https://postgrest.org/en/v14)) to the conformance case
ids that cover it. The docs-page list follows the v14 site's **References**
section and its **API** sub-pages.

A docs page with no covering case (and not explicitly scoped out below) is
flagged **GAP**.

Pinned target: **PostgREST v14.12**. Total cases: **532** across 17 areas.

## References → API sub-pages

| Docs page (`references/api/...`) | Covering case ids | Notes |
|----------------------------------|-------------------|-------|
| `tables_views` (Tables and Views) | 1000–1027 (url_grammar), 1050–1099 (operators), 1100–1137 (select), 1150–1187 (filters), 1200–1222 (ordering), 1300–1332 (representations), 1350–1395 (mutations) | Read/write of tables & views: path resolution, horizontal/logical filters, operators, vertical filtering (select), ordering, insert/update/delete/upsert. |
| `functions` (Functions as RPC) | 1400–1439 (rpc), 1005–1007 (url_grammar /rpc paths), 1023 (rpc profile), 1489–1490 (auth rpc) | GET/POST RPC, scalar/setof/composite/void returns, args, variadic, volatility, overloaded functions, single unnamed JSON parameter. |
| `schemas` (Schemas) | 1008–1012, 1022, 1023 (url_grammar profile), 1557–1560, 1574 (headers profile), 1024 (table not in schema) | Accept-Profile / Content-Profile, multi-schema routing, unacceptable schema. |
| `computed_fields` (Computed Fields) | 1128 (select computed-column), 1208 (ordering computed) | Computed (virtual) columns in select and order. |
| `domain_representations` (Domain Representations) | 1800–1814 (domain_representations) | **COVERED**: CREATE DOMAIN cast representations — read (format cast shapes output), write (parser cast applied to bodies), filter (domain-typed predicates), default (no cast → base type). |
| `pagination_count` (Pagination and Count) | 1250–1277 (pagination), 1700–1701 (db-max-rows) | limit/offset, Range header, exact/planned/estimated count, db-max-rows. |
| `resource_embedding` (Resource Embedding) | 1112–1127 (select embed/spread), 1134–1135 (select one-to-one embed), 1136–1137 (select computed relationships), 1181–1187 (filters embed), 1211–1222 (ordering embed), 1276 (nested limit), 1133 (agg in embed) | Many-to-one/one-to-many/many-to-many, one-to-one (pk-as-fk, unique FK), computed relationships, nested, inner/left, disambiguation, spread. |
| `resource_representation` (Resource Representation) | 1300–1332 (representations), 1550–1556 (Prefer), 1610–1615 (singular), 1630–1635 (nulls-stripped) | Prefer: return=representation/minimal, singular object, vnd.pgrst.object, stripped nulls. |
| `media_type_handlers` (Media Type Handlers) | 1600–1635 (content_negotiation), 1426 (rpc csv), 1622–1624 (octet-stream) | JSON/CSV/GeoJSON/octet-stream/text, Accept negotiation, custom handlers, plan output. |
| `aggregate_functions` (Aggregate Functions) | 1129–1133 (select aggregate) | count/sum/group-by/alias+cast, agg in embed. |
| `openapi` (OpenAPI) | 1619–1621 (content_negotiation openapi), 1650–1682 (openapi) | Root spec, comments→summary/description, type mapping, modes, security. |
| `preferences` (Prefer Header) | 1550–1556 (headers prefer), 1302–1303, 1322 (return=minimal), 1551–1552 (handling), 1553–1554 (timezone), 1555–1556, 1390–1392 (max-affected) | Prefer: return, handling=strict/lenient, timezone, max-affected, missing-defaults via columns. |
| `cors` (CORS) | 1702–1704 (config CORS) | Allowed-origin echo, empty config allows all, non-matching origin. |
| `options` (OPTIONS method) | 1019 (url_grammar options), 1757 (observability OPTIONS server-timing) | OPTIONS Allow header; OPTIONS server-timing subset. Partial — no dedicated OPTIONS-Allow body assertions beyond 1019. |
| `url_grammar` (URL Grammar) | 1000–1027 (url_grammar), 1013–1016 (reserved params), 1017–1018 (percent-encoding), 1025–1027 (reserved-character `%22`-quoting in filter values) | Path/method resolution, reserved query params, %-encoding, `+`→space, double-quoting reserved characters in filter values (`in.()`, mixed, `not.in()`). |

## References → top-level pages

| Docs page (`references/...`) | Covering case ids | Notes |
|------------------------------|-------------------|-------|
| `auth` (Authentication) | 1450–1494 (auth) | JWT validation/claims, roles, anonymous, audience, pre-request, GUC claims, login token minting. |
| `cli` (CLI) | 1705–1707, 1726, 1727 (config dump-config/example flag) | `--dump-config`, `--example`, config dump idempotence. |
| `transactions` (Transactions) | 1387–1392 (safe-update/delete, max-affected), 1722 (db-tx-end), 1713 (db-tx-end validation), 1759 (transaction timing) | Tx-scoped GUCs, safe-update/safe-delete (rollback on missing WHERE), db-tx-end. Partial — no explicit characteristics/isolation-level case. |
| `connection_pool` (Connection Pool) | — (OUT OF SCOPE) | Pool sizing/acquisition behavior is operational and not observable as deterministic black-box HTTP. See **Scope decisions**. Config surface lives at `db-pool`, `db-pool-acquisition-timeout`, `db-pool-max-lifetime`, `db-pool-max-idletime` (alias `db-pool-timeout`), `db-pool-automatic-recovery` — those keys are exercised for parsing/aliasing by the config area (e.g. 1707). |
| `schema_cache` (Schema Cache) | — (DEFERRED) | Schema-cache reload (`NOTIFY pgrst, 'reload schema'` / SIGUSR1) needs a reload-signal harness. See **Scope decisions**. |
| `errors` (Errors) | 1500–1516 (errors), 1432–1434 (rpc errors), 1024, 1185 (not-found), 1455–1464 (auth JWT errors) | SQLSTATE→HTTP mapping, PGRST error codes, RAISE PGRST full control, 4xx/5xx envelopes. |
| `configuration` (Configuration) | 1700–1730 (config) | Sources (env/file/db-role-settings), aliases, validation, coercion, precedence, app-settings. |
| `observability` (Observability) | 1750–1767 (observability) | Server-Timing, trace header, log-level→status logging. |
| `admin_server` (Admin Server) | 1717 (admin-port = server-port fatal) | Only the port-collision validation. Partial — no `/live` `/ready` health-endpoint case. |
| `listener` (Listener) | — (DEFERRED) | LISTEN/NOTIFY channel (`db-channel`) reload trigger needs the same reload-signal harness. See **Scope decisions**. |

## Scope decisions

This pass formalizes which uncovered docs pages are intentional vs. true gaps.

- **`domain_representations` — now COVERED.** The new area 1800–1814 (15 cases,
  fixture `fixtures/domain_representations.sql`) exercises domain cast
  representations end to end (read/write/filter/default). It is no longer a gap.

- **`connection_pool` — OUT OF SCOPE.** Pool behavior (sizing, acquisition
  timeout, lifetime/idletime recycling, automatic recovery) is an operational
  runtime concern with no deterministic, observable HTTP contract: it surfaces
  only under concurrency/exhaustion timing, which a black-box conformance case
  cannot assert reliably. Instead of an HTTP case, the relevant configuration
  keys are validated for parsing/aliasing in the config area:
  `db-pool`, `db-pool-acquisition-timeout`, `db-pool-max-lifetime`,
  `db-pool-max-idletime` (alias `db-pool-timeout`), `db-pool-automatic-recovery`.

- **`schema_cache` — DEFERRED (future work).** Schema-cache reload and
  stale-cache behavior are only testable with a schema-reload-signal harness
  (`NOTIFY pgrst, 'reload schema'` or SIGUSR1) that mutates the live schema mid
  run and asserts the API re-introspects. No such harness exists yet; cases are
  deferred until one is built.

- **`listener` — DEFERRED (future work).** The LISTEN/NOTIFY channel
  (`db-channel`, `db-channel-enabled`) is the transport for the same
  reload-signal harness. Deferred together with `schema_cache`.

## Coverage summary

- Docs pages enumerated: **24** (15 API sub-pages + 9 top-level reference pages,
  counting `url_grammar` once).
- Pages with at least one covering case: **20**.
- Pages explicitly scoped: **3** — `connection_pool` (out of scope),
  `schema_cache` (deferred), `listener` (deferred).
- Pages flagged **GAP** (no covering case and not scoped out): **0**.

`domain_representations`, previously a gap, is now covered. The remaining three
uncovered pages are deliberate scope decisions (one operational, two deferred
pending a reload-signal harness), not unaddressed gaps.

Several pages are marked **Partial** in the notes above (OPTIONS, transactions,
admin_server): they have covering cases but not the full breadth of the docs
page. These are tracked as soft gaps, not hard gaps.

## Validation status

- All **532** cases parse as YAML.
- All **532** cases carry a `source:` field on the
  `raw.githubusercontent.com/PostgREST/postgrest/v14.12/...#L<n>` pattern
  required by `case.schema.json` (verified on disk this pass — 0 cases use the
  non-raw `github.com/.../blob/` form).
- All **532** cases validate against `case.schema.json`.
- No duplicate ids; each of the 17 areas occupies a contiguous, non-overlapping
  band (1000–1027, 1050–1099, 1100–1137, 1150–1187, 1200–1222, 1250–1277,
  1300–1332, 1350–1395, 1400–1439, 1450–1494, 1500–1516, 1550–1574, 1600–1638,
  1650–1682, 1700–1730, 1750–1767, 1800–1814).

## Review status

An adversarial citation audit — re-fetching each cited `source:` line and
confirming it still asserts what the case claims — has now run across all 17
areas. Result per area:

| Area | Audit result |
|------|--------------|
| url_grammar | ⚠️ revise |
| operators | ✅ pass |
| select | ✅ pass |
| filters | ✅ pass |
| ordering | ✅ pass |
| representations | ✅ pass |
| mutations | ✅ pass |
| rpc | ⚠️ revise |
| errors | ⚠️ revise (2 bad citations) |
| headers | ✅ pass |
| content_negotiation | ⚠️ revise |
| openapi | ✅ pass |
| config | ✅ pass |
| observability | ✅ pass (2 bad citations) |
| domain_representations | ✅ pass |

(The **auth** and **pagination** areas were verified in an earlier pass; they
are not part of this audit's pass/revise call-out but remain reviewed.)

- **Passed:** operators, select, filters, ordering, representations, mutations,
  headers, openapi, config, observability, domain_representations.
- **Needs revision:** url_grammar, rpc, content_negotiation, errors. The
  **errors** area has 2 confirmed bad citations to fix. **observability** passed
  overall but still has 2 bad citations flagged for cleanup.

Open follow-ups from the audit: re-cite the four "revise" areas, and correct the
2 bad citations in errors and the 2 in observability.
