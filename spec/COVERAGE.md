# Coverage

Maps every page of the PostgREST **v16** documentation
([postgrest.org/en/v16](https://postgrest.org/en/v16/)) to the conformance case
ids that cover it. The docs-page list follows the v16 site's **References**
section and its **API** sub-pages, **re-fetched from the live site this pass**
(16 API sub-pages; 12 top-level References entries, of which `api` is the parent
counted through its sub-pages).

A docs page with no covering case (and not explicitly scoped out below) is
flagged **GAP**.

Pinned target: **PostgREST v16.0**. Total cases: **746** across 17 areas
(counted on disk this pass, not carried over). The page set is unchanged from
the previous pass — `references.html` lists 12 entries (11 pages plus
the `api` parent: Authentication, API, CLI, Transactions, Connection Pool, Schema
Cache, Errors, Configuration, Observability, Admin Server, HTTP Server, Listener)
and `references/api.html` lists 16 sub-pages, matching the tables below entry for
entry. Both were **re-fetched live this pass** (not carried over) and
re-enumerated; the API sub-page order on the live site is Tables and Views,
Functions as RPC, Schemas, Computed Fields, Domain Representations, Pagination and
Count, Resource Embedding, Resource Representation, Media Type Handlers, Aggregate
Functions, OpenAPI, Prefer Header, Vary Header, CORS, OPTIONS method, URL Grammar.

State of the tree when this file was written: branch **`spec/postgrest-v16`**,
**HEAD `9b72e09`** ("spec(content_negotiation): re-sync to PostgREST v16.0
(area 15/17)") with an **uncommitted openapi re-sync in the working tree**.
`git status --short` shows **34** modified spec files (`spec/openapi.yaml` plus
all **33** cases in the band's committed range **1650–1682**) and **6 untracked
new cases** (**1683**–**1688**). **Nothing under `conformance/fixtures/` and no
line of `conformance/fixtures.sql` is modified** — this re-sync added no fixture
object. Every count here describes that on-disk state, including the uncommitted
files. The previous revision was written at **740** cases; the whole delta since
is the **openapi** area (**33 → 39** cases).

> **This revision re-derives every number from disk**, at the **746**-case state
> — including the whole *Validation status* section. Where a number did not move,
> it is because the tree did not move, not because it was carried over. **Four**
> numbers the previous revision reported are **corrected** rather than carried
> forward, and all four are called out where they appear: the method distribution
> (`PATCH` **26 → 27**, a counting slip in the previous revision — it was 27 at
> HEAD too, so nothing moved on disk), the `Feature/Query` citation bucket
> (**530** is right only if `Query/Preferences` is excluded; the same sweep
> including it reads **547**, and the previous revision's "up from 525" was
> comparing two different scopes), the non-system schema count
> (**23**, not 22 — this pass's machine verification *labelled* its list "22"
> while enumerating 23 names; re-queried directly against `bier_test` during
> synthesis, the answer is **23**, so the list was right and the label was
> wrong), and the "all 740 cases (757 files)" figure in *Validation status*,
> correct when written and stale by six cases and six files by the time the
> openapi re-sync landed in the working tree.
>
> **One more number in the handoff needs restating rather than correcting, and
> it revives a figure this file had already retired.** The verification reported
> "**791** functions" in the loaded database. Re-queried here: `pg_proc` holds
> **1034** rows in non-system schemas (1001 `prokind='f'`, 26 aggregates,
> 7 window functions) across **791** distinct `(schema, name)` pairs. So 791 and
> 1034 are both correct measurements of different things, and 791 is the right
> denominator for the check it was feeding — the relation check resolves targets
> by *name*, and overloads collapse. **It is not a routine count.** *Validation
> status* already carries the full reconciliation of 791 / 1036 / 1034, including
> the fact that **827** of the 1034 are PostGIS and pgcrypto functions in
> `public`; read it before quoting any of these numbers.

The openapi pass is the **sixteenth** of 17 areas to carry a recorded v16.0
adversarial verdict — ⚠️ ***revise***, **0 citation defects**, and **two**
missing-coverage findings, the *smallest* count any *revise* verdict has
produced. **Only `domain_representations` is now un-audited at this pin.** Four
things make this pass structurally different from every earlier one:

- **It is the first pass whose largest correction is a `schema:` label, not a
  citation or an assertion.** All **33** committed cases in the band were
  relabelled; **31** carried `schema: openapi`, naming a schema that **does not
  exist** in `bier_test`. The frozen harness turns any label other than
  `nil`/`public`/`test` into an `Accept-Profile:` header
  (`test/support/http_case.ex#L60-71`), so those 33 shipped
  `Accept-Profile: openapi` — and PostgREST generates the root document *for the
  requested profile* (`IgnorePrivOpenApiSpec.hs#L49-58`, `#L81-89`), so against a
  faithful implementation every path and definition assertion in the area would
  have been read out of an **empty** document. They passed only because Bier
  dispatches the root path before resolving the profile. **A green case can be
  green because of a defect in the thing it is testing**, and this is the
  cleanest instance of it in the tree — a sibling of the content_negotiation
  fixture defect, in a different field. Case **1654** moved to
  `openapi_no_comment`, which does exist; the rest to `test`, the label
  upstream's own `baseCfg` reproduces (`SpecHelper.hs#L151`).
- **It is the first pass to WITHDRAW a case rather than delete or reuse one.**
  **1689** (`openapi-server-proxy-uri`) was authored, found red for a *harness*
  reason rather than a behavior reason, and removed before commit — so 1689 never
  reached git history and the band is a contiguous **1650–1688**. The behavior
  survives as a modelled entry with `cases: []` that spells the case out verbatim
  for restoration. Three passes, three conventions for a dropped case; see
  follow-up 26, which now has the data point that arguably settles it.
- **It is the first pass to REMOVE non-empty `preconditions:` rather than add
  them**, taking the tree-wide non-empty count 44 → **42**. Both of the area's
  two were also *wrong* had they ever run: case 1654's
  `COMMENT ON SCHEMA test IS NULL` would have broken case 1656, and case 1672's
  `CREATE FUNCTION` omitted the `DEFAULT '{}'` its own assertion depends on.
  **Two inert-and-wrong statements survived an entire prior re-sync of this
  area** — follow-up 25's strongest evidence yet.
- **It wrote everything down, and the audit still found two holes.** The model
  went from **6** gap entries to **14** and added the tree's **second**
  `fixture_notes:` key (five entries) — and the reviewer still found two
  behaviors emitted by *every* document with neither a case nor a disclosure: the
  `/rpc/*` per-operation `produces` / `responses.200` pair
  (`OpenAPI.hs#L357-358`) and the shared `$.parameters.on_conflict` definition
  (`#L239-245`). Confirmed on disk during synthesis: `on_conflict` appears in
  four case files, **none in the openapi band**, and nowhere in `openapi.yaml`.
  **A gap list records the gaps its author saw.**

Its findings are itemized under **Known gaps → openapi**.

The content_negotiation pass is the **fifteenth** of 17 areas to carry a recorded
v16.0 adversarial verdict — ⚠️ ***revise***, **0 citation defects**, and
**seven** missing-coverage findings, the largest count any single area audit has
produced. Four things make it structurally different from every earlier pass:

- **It is the first pass to correct a FIXTURE rather than a citation or a case.**
  `fixtures.sql` transcribed `test.unnamed_bytea_param(bytea)` as
  `RETURNS bytea`; upstream declares it `returns "application/octet-stream"`, the
  mime-named DOMAIN (`schema.sql#L2372`). Because a routine's **return type** is
  the only thing that registers an octet-stream handler
  (`SchemaCache.hs#L1016`), case **1622**'s expected 200 was **unreachable
  against a faithful implementation** — and every mechanical check in this
  document passed on it, *and the case passed*, because `lib/bier/rpc.ex:288` is
  over-permissive in exactly the way the new case 1623 pins. See
  **Fixture write channels**.
- **It is the first pass to delete a case and REUSE its id.** Old **1623**
  (`octet-stream/no-charset`) is gone, its assertion folded into 1622, and
  `1623` re-issued to an unrelated **406** negative. The mutations pass deleted
  11406 and left the id vacant on purpose. Two deletions, two opposite
  conventions — see follow-up 26.
- **It opened the tree's FOURTH 5-digit band (12400–12401) with no declaration**,
  after its primary 1600–1649 filled. Four areas, four ad-hoc placements, one
  declaration between them — follow-up 19, now overtaken a second time.
- **It was audited and STAYED SILENT**, which retires the "silence = never
  examined" reading for good. `content_negotiation.yaml` still carries no
  `gaps:` key under any name, so all seven findings live only in this file. It
  did, however, add a **`fixture_notes:`** key with no precedent in the tree —
  three entries naming the exact fixture property each case depends on and what
  breaks if it changes. **That key is the only artifact in the tree that would
  have caught this pass's own fixture defect.** See **Review status**.

Its findings are itemized under **Known gaps → content_negotiation**.

> **Follow-up 24 remains CLOSED end to end and nothing re-opened it.** Its
> fixture half closed at `6b25f05` (`fixtures/rpc.sql#L15` re-pinned to
> `blob/v16.0`; the file carries **zero** `v14.12` URLs). Its documentation half
> closed at `75388d6`, which rewrote `spec/rpc.yaml`'s `operator_action` gap
> entry to open with "RESOLVED 2026-08-09 (commit 6b25f05) — kept as a record, no
> action left" while **retaining the original finding verbatim for provenance**.
> That retention is why a prefix-aware sweep *still* finds exactly one `v14.12`
> URL in the audited set — at `spec/rpc.yaml:574`, inside a quotation of the
> historical problem rather than as a live report. **The surviving URL is correct
> behavior, not drift.** Re-verified mechanically this pass: one non-v16.0 URL in
> scope, at that line.

## References → API sub-pages

| Docs page (`references/api/...`) | Covering case ids | Notes |
|----------------------------------|-------------------|-------|
| `tables_views` (Tables and Views) | 1000–1035 (url_grammar), 1050–1099 + 10200–10236 (operators, 87 cases), 1100–1149 (select), 1150–1199 (filters), 1200–1232 (ordering), 1300–1333 (representations), **1350–1399 + 11400–11415 (mutations, 65 cases)** | Read/write of tables & views: path resolution, horizontal/logical filters, operators, vertical filtering (select), JSON/composite/array column access, ordering, insert/update/delete/upsert. **Materially strengthened this pass on the write side** — the page's *Insert*, *Update*, *Delete* and *Upsert* sections gained 17 cases: the `x-www-form-urlencoded` insert body (**11402**, the page's own alternative-payload rule), insignificant leading/trailing whitespace around a JSON body (**11403**), the empty-body PGRST102 envelope (**1398**), the unique-violation 409/`23505` path (**11401**), multi-row `PATCH` answering 204 with `Content-Range: 0-1/*` and no `Content-Type`/`Content-Length` (**11400**), the only-pk-table upsert pair (**11410**/**11411**, where merge- and ignore-duplicates diverge precisely because there is no non-key column to update), composite-pk upsert by POST and PUT (**11414**, **11408**) and its partial-key PGRST105 rejection (**11409**), `PUT` ignoring a `Range` header (**11407**), `Prefer: max-affected` exceeded on an UPDATE (**11405**), and the ignore-duplicates-with-nothing-created empty body (**11404**). **Previously strengthened** on the operator side — the page's *Operators* table is now exercised far past its previous depth: the `IN`/`NOT IN` **empty set** (10200–10205, closing what this file listed as a *filters* gap), whole-range/whole-array `eq`/`neq`/`isdistinct` (10206–10207, 10211–10213), the `gte(all)`/`lte(all)` quantifier corners (10209–10210), four more `not`-prefixed shapes incl. three inside logic trees (10208, 10214–10216), the `(language)` modifier on `plfts`/`wfts`/`phfts` (10217–10219), and the whole **automatic `to_tsvector()` coercion** rule for fts against non-tsvector columns (10220–10230) plus the tsquery/websearch operand grammar (10231–10236). **Still Partial, and now on both sides of the page** — read: an empty filter *value* (`=eq.` with nothing after the dot) and the implicit AND of two plain filters (the page's very first rule) have no case; write: the *Update* and *Delete* sections' `web_content` / `artists` flavors, the GENERATED ALWAYS insert rejection (428C9), the case-sensitive-identifier upsert flavors and the SERIAL/GENERATED-BY-DEFAULT `missing=default` upsert legs are all fixture-blocked. See **Known gaps → filters**, **Known gaps → operators** for the residual per-operator variants, and **Known gaps → mutations**. |
| `functions` (Functions as RPC) | **1400–1443** (rpc), 1005–1007 (url_grammar /rpc paths), 1023 (rpc profile), 1031–1032 (OPTIONS `Allow` on a VOLATILE vs. a STABLE routine), 1231–1232 (ordering of an RPC result), 1271, **1280–1283, 1285** (pagination over an RPC result), 1489–1490 (auth rpc), 1570 (rpc status GUC), 1502–1503, 1505, 1507–1514 (errors raised from inside a routine) | GET/POST RPC, scalar/setof/composite/void returns, args, variadic, volatility, overloaded functions, single unnamed JSON parameter, reserved-word function name (1440), the page's "filters, order and limits inline into a function" rule (`functions.rst` L283/L290) via 1231–1232, and the volatility→`Allow` rule (1031/1032). **Materially strengthened this pass** on the pagination side: the Range header on a GET `/rpc/` (1280), limit/offset query params on a **POST** `/rpc/` whose args are in the JSON body (1281), the empty-window envelope (1282), the `count=planned` degradation (1283) and the Range header being *ignored* on a POST `/rpc/` (1285); and on the rpc side by three new cases — **1441** (`Prefer: handling=strict, max-affected=20` on a void-returning routine → 400 **PGRST128**, the tree's only assertion of that code), **1442** (the form-urlencoded variadic POST) and **1443** (the closest-proc **PGRST202** hint for `GET /rpc/sayhell`, full envelope plus upstream's `Content-Length: 291`). **Still Partial, and this page now carries the tree's densest cluster of open findings.** The rpc audit named **five** documented behaviors of this page with no case anywhere in `spec/`: the *Untyped functions* H2 (routines returning `record` / `SETOF record`), the *Functions with array parameters* H2 (a **non**-variadic array-typed parameter bound from a JSON body, from a GET array literal and from a form body), the **text** and **xml** flavors of *Functions with a single unnamed parameter* (only the bytea flavor is covered, and from another area), *Resource Embedding on table-valued functions*, and `?columns=` on a POST to `/rpc/`. Two RPC **preference** legs also remain uncased: `Prefer: handling=strict` on `/rpc/*` (PGRST122, `HandlingSpec.hs#L35`) and the *count* form of RPC `max-affected` (PGRST124, `MaxAffectedSpec.hs#L86`). See **Known gaps → rpc** and **Known gaps → headers**. |
| `schemas` (Schemas) | 1008–1012, 1022–1024 (url_grammar profile), 1557–1560, 1574 (headers profile), 1730 (`db-schema` singular alias), 1733–1734 (`db-schemas` rejects `pg_catalog` / `information_schema`) | Accept-Profile / Content-Profile, multi-schema routing, unacceptable schema, restricted system schemas (new in v16). |
| `computed_fields` (Computed Fields) | 1128 (select computed-column), 1208 (ordering computed), 1806 (domain rep. via view + computed column) | Computed (virtual) columns in select and order. |
| `domain_representations` (Domain Representations) | 1800–1820 (domain_representations) | **COVERED**: CREATE DOMAIN cast representations — read (format cast shapes output, incl. implicit `select=*` and through-embed), write (parser cast applied to bodies, `columns=` param), filter (domain-typed predicates, `in`/`not.in`, across relations), default (no cast → base type), error paths (1819–1820). |
| `pagination_count` (Pagination and Count) | **1250–1288** (pagination, **39** cases), 1431 (rpc Range header), 1700–1701 (db-max-rows), 1522, 1526 (the inline 416 body's verbosity and header set) | limit/offset, Range header, exact/planned/estimated count, db-max-rows, the two properties of the **inline** out-of-range 416 that `errorResponseFor` never sees, and — new this pass — the page's table-function leg ("This also works on views and table functions", `pagination_count.rst` L61) plus the Range header's **method scoping** and its **intersection** (not override) with limit/offset. **Partial** — two gaps: embedded `<embed_path>.offset` has zero cases anywhere in the tree (**Known gaps → pagination**, and the tree's single largest *documented-parameter* hole), and the modelled suppression of `Content-Length` on a **HEAD** 416 has no case (**Known gaps → errors**). |
| `resource_embedding` (Resource Embedding) | 1112–1127, 1133–1142 (select embed/spread/one-to-one/computed rels/aliases/`!fk` hints), 1181–1199 (filters embed), 1211–1224, 1227–1229 (ordering embed/related), 1276 (nested limit), 1028 (legacy embed target name), 1736 (`url-use-legacy-target-names` dump), **1300, 11412, 11413, 11415 (embedding in a mutation's returned representation)** | Many-to-one/one-to-many/many-to-many, one-to-one (pk-as-fk, unique FK), computed relationships, nested, inner/left, disambiguation (incl. the `table!fk` hint, 1142), spread, the v16 target-name→alias migration (1028, 1138–1141, 1188–1190, 1224), and — **new this pass** — the *mutation* flavor: `select=` with an embed on a `DELETE` returning its parent (**11412**), on a `PATCH` returning a one-to-one child (**11413**) and on a `PATCH` returning many-to-many children each with their own parent (**11415**), all three under `Prefer: return=representation`. **Partial** — Foreign Key Joins on Views / Chains of Views, Spread To-Many, and FK Joins on Partitioned Tables have no case (**Known gaps → select**); the page's *Order in spread to-many* section has no case in any band (**Known gaps → ordering**); the page's own `actors.limit=10&actors.offset=2` example is half-covered — the `.limit` half by 1276, the `.offset` half by nothing (**Known gaps → pagination**); and embedding **through a table-valued function** — which the *Table-Valued Functions* section of `functions.rst` explicitly says "can also use Resource Embedding" — is exercised only incidentally, by case **1023** in the `url_grammar` band, whose actual subject is `/rpc` profile routing (**Known gaps → rpc**); and the *mutation* flavor is covered only for the relations the consolidated fixture happens to have — the four `web_content` self-reference flavors, the `artists` order and batch-upsert flavors and the DELETE one-to-one reverse direction have no case (**Known gaps → mutations**). |
| `resource_representation` (Resource Representation) | **1300–1327 + 1330–1333 (representations, 32 cases)**, 1230 (order applied to a PATCH's returned representation), 1550–1556 (Prefer), 1610–1615, 1629, **1649** (singular), 1630–1635, **12400–12401** (nulls-stripped), **11412–11415** (representations carrying an embed) | Prefer: return=representation/minimal/headers-only, singular object, vnd.pgrst.object, stripped nulls. **Strengthened this pass on the nulls-stripped rule, and the strengthening is a scope correction**: `nulls=stripped` was cased only on reads, which left it readable as a read-only formatting flag. Cases **12400** (`POST … Prefer: return=representation` → 201 and a stripped array, so explicitly-sent `null` columns are absent from the echoed row) and **12401** (the `PATCH` counterpart, where a column set to `null` by the patch is stripped while untouched non-null columns remain) pin that it governs the **mutation representation** too; case **1649** adds the stripped *singular* type composed with an explicit `select=` naming the null columns. | **Materially strengthened this pass** — the page's `return=` rule gained the eight cases the area had modelled but never exercised: the two remaining **Location suppressions** under `return=headers-only` (a bulk insert, **1315**, and a relation with no PK at all, **1317**, each sufficient on its own — `Query/Statements.hs#L48`/`#L49`), the rule that `return=representation` **never** carries a Location even on a PK'd table (**1316**), the three `Prefer`-parsing rules the page's token grammar implies but does not spell out — a **duplicate** `return=` resolving to the *first* token in request order rather than the first in `prefMap` (**1318**, `return=minimal, return=representation` → 201 with an empty body), an **unrecognized** `return=` value being *ignored* rather than rejected (**1319**, and it is only a 400 if `handling=strict` is also sent), and `Preference-Applied` emitting its tokens in the **fixed `prefsVals` order** rather than the client's (**1327**, `count=exact, return=representation` echoed back as `return=representation, count=exact`) — plus the two halves of the *"`return=` is echoed only for mutations"* rule, on a plain read (**1325**) and on an RPC (**1326**, the representations band's only `schema: rpc` case). Case **1309** was rewritten in the same pass. **Ownership note, not a gap**: the `PUT` + `return=minimal` wire contract (204, no `Content-Type`, `Preference-Applied: return=minimal`) is owned by case **1332** here; the mutations re-sync authored a band-local clone of it (11406) and **dropped it again** as strictly weaker — same anchor (`UpsertSpec.hs#L543`), same it-block, fewer assertions. That deletion is why the mutations band is **11400–11405 + 11407–11415**, with 11406 absent by design. **The representations audit has now retro-justified that deletion**: 1332 was the *unaudited* case a cross-area deletion leaned on, and it is unaudited no longer. **Still Partial** — the `is.null` rendering of a NULL key column in a headers-only `Location` is modelled and citable but **unreachable on a base table**, and upstream reaches it only through a multi-base-table view; see **Known gaps → representations**. |
| `media_type_handlers` (Media Type Handlers) | **1600–1649 + 12400–12401** (content_negotiation, **52** cases, incl. 1636–1638/1642/1644/1646 custom-media-handler), 1426 (rpc csv), **11402** (`x-www-form-urlencoded` **request** payload on a table insert), 1442 (the same on an RPC POST) | JSON/CSV/GeoJSON/octet-stream/text, Accept negotiation and precedence (1639–1641, 1645), custom media handlers (anyelement, override-builtin, any-handler, vendored-not-overridable, table aggregate, default-select requirement), plan output. **Materially strengthened this pass, and materially re-scoped**: new cases pin the unparsable-`Accept` echo (**1647** — `Accept: undefined` is *not* rejected at parse time; it becomes `MTOther` and is echoed verbatim in the PGRST107 message), case-insensitive media-type matching (**1648** — `ApplicatIon/vnd.PgRsT.object+json` negotiates the singular handler and the response `Content-Type` comes back canonically lowercase, upstream issue #3478) and the **negative** that anchors the whole octet-stream rule (**1623**, re-issued: a scalar RPC with no mime-named-domain return is **not** negotiable as octet-stream → 406/PGRST107). Case **1622** was rewritten to assert byte equality (`body_raw`) and to cite its status, `Content-Type` and negotiability *separately*, because its anchored it-block asserts only `respBody == file`. **Still Partial, and this page now carries the tree's densest cluster of open findings** — the audit named **five** behaviors of this page with no case: the `db-plan-enabled = false` **406** gate (declared in five cases' inert `preconditions:` and pinned by none), the `*/*` handler's `Content-Type` **override** from inside the function *and* its rejection of non-matching types, the `*/*` handler on **TABLES/VIEWS** (only the function flavor, 1638, exists) , overriding the builtin **`application/geo+json`** handler for a single relation, and **q-factor ordering** of the `Accept` list (case 1601 carries q values but resolves identically with or without q-sorting). The *single unnamed parameter* trio remains covered only in its **bytea** flavor (**case 1622 alone** — 1623 no longer names that case); the `text/plain` and `text/xml` flavors have no case, leaving the `MTTextPlain`/`MTTextXML` PGRST202 branches unexercised, recorded under **Known gaps → rpc** because the rule is RPC parameter binding rather than negotiation. **Retained**: the `application/x-www-form-urlencoded` *request* payload is pinned on both sides of the API — **11402** on a table insert and **1442** on an RPC POST. See **Known gaps → content_negotiation**. |
| `aggregate_functions` (Aggregate Functions) | 1129–1133, 1147–1149 (select aggregate), 1644 (aggregate through a custom media handler) | count/sum/group-by/alias+cast, cast of the aggregated column and of the result (1147–1148), group-by across an embed (1149), agg in embed. **Partial** — *Aggregates in To-One Spreads* and the PGRST127 to-many-spread rejection have no case; see **Known gaps → select**. |
| `openapi` (OpenAPI) | **1650–1688 (openapi, 39 cases)**, 1619–1621, 1645 (content_negotiation openapi) | Root spec, comments→summary/description, type mapping, modes, security, `db-root-spec`. **Materially strengthened this pass, and the strengthening is mostly about the document's *own* structure rather than about any relation in it**: the root path item the document emits for itself (**1687** — `paths./` with `tags: ["Introspection"]`, the two-element `produces`, `responses.200.description == "OK"` and **no** `parameters` key), the document-level four-element `produces`/`consumes` list asserted **in order** (**1688**), the shared `preferParams` definition asserted whole together with the **absence** of its `enum` key (**1686**, the empty-enum suppression of `OpenAPI.hs#L177`), the all-OUT-parameters args schema that emits neither `properties` nor `required` (**1683**), its INOUT-with-no-DEFAULT complement (**1684**) and the **IMMUTABLE** arm of the volatility→methods switch (**1685**, which 1674 covered only for VOLATILE and STABLE). Three of the six are anchored at the generator rather than at an `it`-block **because upstream has no Feature test that reads those keys** — its only witness is the whole-document schema validation of `SpecHelper.hs#L115-123`. **Now Partial, and it was not marked Partial before**: the audit found two behaviors emitted by *every* document with zero coverage *and* zero disclosure — the per-operation `produces` / `responses.200` on every `/rpc/*` path item (`OpenAPI.hs#L357-358`) and the shared `$.parameters.on_conflict` definition (`#L239-245`). Six further legs are fixture-blocked and correctly disclosed (foreign table, partitioned table, materialized view, UNIQUE-key FK view, O2O FK, fk-points-to-TABLE), one is the INOUT-with-DEFAULT half of `OpenApiSpec.hs#L1032-1038`, one is Accept-Profile schema scoping, and one — `openapi-server-proxy-uri` — is modelled in full with `cases: []` and blocked on the harness. See **Known gaps → openapi**. |
| `preferences` (Prefer Header) | 1550–1556, 1577–1581, 1584 (headers prefer), 1302–1304, 1313–1314, 1322, 1324, 1332–1333 (return=minimal / headers-only), **1318, 1319, 1325, 1326, 1327** (the `return=` token grammar and its echo rule), 1390–1392, **11404–11405, 11407, 11410–11411, 11414** (mutations max-affected + resolution), 1441 (rpc PGRST128), 1267–1268, 1286, 1288 (pagination count preferences) | Prefer: return, handling=strict/lenient, timezone (incl. ± offsets, leap seconds, invalid under default/lenient/strict, and the single- vs two-token `Preference-Applied` echo in 1553/1584), max-affected, missing-defaults via `columns`, count, the RPC-only **PGRST128** rule (1441), the `resolution=merge-duplicates` / `resolution=ignore-duplicates` pair asserted with its **exact two-token `Preference-Applied` echo** (11410/11411/11414), the `max-affected` **UPDATE** flavor (11405) and the ignore-duplicates-yet-201 case (11404). **New this pass, and it closes the page's own header-grammar rules rather than any one preference**: duplicate-token resolution is *first in **request** order*, not first in the parser's list (**1318**); an unknown token value is **ignored**, becoming a 400 PGRST122 only under `handling=strict` (**1319**); `Preference-Applied` renders in the **fixed `prefsVals` order**, independent of the order the client sent (**1327**); and `return=` is echoed **only** for mutations — never on a read (**1325**) or an RPC (**1326**), and its presence there is not an error either, because the token is in `acceptedPrefs` and so never reaches the strict guard. **Partial** — the RPC flavor of `handling=strict` (PGRST122) and of the `max-affected` **count** check (PGRST124) still has no case. See **Known gaps → headers**. |
| `vary_header` (Vary Header) | 1575 (default `Vary: Accept, Prefer, Range` on a read), 1576 (`response.headers` GUC override replaces it verbatim), 1582 (the default is appended by `toWaiResponse` for every non-error response, witnessed on OPTIONS), 1583 (error responses carry no `Vary` — they bypass `toWaiResponse`) | **NEW page in v16** — covered. 1582/1583 match the modelled entries `headers.vary.non_read_responses` / `headers.vary.absent_on_errors`. The one remaining leg — a *CORS preflight* answered by the wai-cors middleware, which never reaches `toWaiResponse` — is a gap; see **Known gaps → headers**. |
| `cors` (CORS) | 1702 (allowed-origin echo), 1703 (empty config allows all), 1704 (non-matching origin → no header), 1742 (default/empty origin list answers a preflight permissively), 1743 (the fixed `Access-Control-Expose-Headers` list on a plain `Origin` request) | 1742/1743 are **HTTP** cases inside the config band. **Partial** — none of the preflight cases asserts `Vary`-absence, the third leg of the v16 `Vary` rule (**Known gaps → headers**), and 1742 does not yet run under the config it declares (**Known gaps → config**). |
| `options` (OPTIONS method) | 1019 (table `Allow`), 1031 (VOLATILE routine), 1032 (STABLE routine), 1033 (root path), 1034 (unknown relation → 404), 1757, 1768–1769 (observability OPTIONS server-timing on table / rpc / root — presence of jwt/parse/response only; `plan` and `transaction` are emitted too, see `spec/observability.yaml` → `observability.server_timing.options_subset`), 1742 (OPTIONS preflight), 1582 (`Vary` present on an OPTIONS response) | The url_grammar re-sync covered three of upstream `OptionsSpec.hs`' four `Allow` shapes (`#L84`, `#L90`, `#L103`) plus the not-found path (`#L22`). **Still Partial** — the updatability-driven variants (auto-updatable views, trigger-backed views, partitioned tables, `OptionsSpec.hs#L24-L80`) remain uncased; see **Known gaps → options / transactions**. |
| `url_grammar` (URL Grammar) | 1000–1035 (url_grammar), 10200, 10204, 10205 (the `in.( … )` value-list grammar: an empty list, a whitespace-only list, and a blank element alongside real ones), **1383, 1399** (the mutations-band twins of the PUT `limit`/`offset` rule) | Path/method resolution, reserved query params (incl. the legacy embed target name 1028, and `limit`/`offset` forbidden on PUT 1016/1030 — **double-covered**, see the ownership note below), %-encoding (incl. `%20` in a relation *and* a column name, 1035), `+`→space, double-quoting reserved characters in filter values and in quoted identifiers (1025–1027, 1029). **Strengthened this pass on the list-grammar leg** — 10204 pins that `lexeme`'s surrounding-whitespace consumption makes `in.(    )` identical to `in.()`, and 10205 pins that a blank element *alongside* real ones is **not** collapsed (`in.( ,3,4)` → 400 / `22P02`), which is the discriminating pair for a hand-written parser. **Still Partial** — the page's *Reserved characters* section documents backslash escaping inside `in.( … )` (`\"` for a literal quote, `\\` for a literal backslash) and no case in any band exercises it; see **Known gaps → url_grammar**. **Ownership note (new this pass, and verified case-by-case)**: the PGRST114 "limit/offset not allowed for PUT" rule is now asserted **twice over, in two areas, from the same two upstream it-blocks** — `limit` by url_grammar's **1016** and mutations' **1383** (both `PUT /tiobe_pls?name=eq.Javascript&limit=1`, both `UpsertSpec.hs#L295`), and `offset` by url_grammar's **1030** and mutations' **1399** (both `PUT /tiobe_pls?name=eq.Javascript&offset=1`, `UpsertSpec.hs#L302` vs `#L303`, the same block). The four differ only in `schema:` label (`test` vs `mutations`) and in how much of the mechanism their `notes:` explain — 1016/1030 are substantially the richer pair. The mutations pass did not introduce the duplication (1383 already twinned 1016); it **restored its symmetry** by adding the missing offset twin. Decide once whether the mutations band should keep both, drop both, or keep them as deliberate profile-variant coverage; see **Known gaps → mutations**. |

## References → top-level pages

| Docs page (`references/...`) | Covering case ids | Notes |
|------------------------------|-------------------|-------|
| `auth` (Authentication) | 1450–1499 + 11800–11818 (auth) | JWT validation/claims, HS256 (incl. binary/base64 secret) and RS256 (JWK and JWKS), roles, role-claim-key JSON Path, anonymous, audience, pre-request, GUC claims, login-token minting, clock-skew errors. Partial — see **Known gaps**. |
| `cli` (CLI) | 1705–1741 + 1744 (all 38 `request.kind: cli` cases) | `--dump-config`, `--example`, validation, env/file/db precedence, coercion, unknown-key tolerance (1739), aliases. Driven in-process by `Bier.CliCase`. Note 1742/1743 sit inside the band but are HTTP, so the CLI set is not contiguous. |
| `transactions` (Transactions) | 1387–1392, **11405** (safe-update/delete, max-affected), 1713, 1722 (db-tx-end validation + enum mapping), 1759 (transaction timing), 1523 (a trigger cascade aborted by the statement-depth limit) | Tx-scoped GUCs, safe-update/safe-delete (rollback on missing WHERE), db-tx-end, and the `max-affected` rollback on an **UPDATE** (11405) alongside the existing DELETE flavors. Partial — no explicit characteristics/isolation-level case. **A live dependency on this page's subject is now load-bearing for the mutations band and should be read here**: **ten** of the seventeen new mutations cases target relations the loader does *not* isolate into real tables (11402, 11403, 11408–11415), so nine of them write through auto-updatable view mirrors onto the shared `test.*` tables and are contained only by the conformance server's `db_tx_end: :rollback` (`test/support/conformance_server.ex:194`); the tenth, 11409, expects a 405 and never reaches the database. See **Known gaps → mutations**. |
| `connection_pool` (Connection Pool) | — (OUT OF SCOPE) | Pool sizing/acquisition behavior is operational and not observable as deterministic black-box HTTP. See **Scope decisions**. |
| `schema_cache` (Schema Cache) | — (DEFERRED) | Schema-cache reload (`NOTIFY pgrst, 'reload schema'` / SIGUSR1) needs a reload-signal harness. See **Scope decisions**. |
| `errors` (Errors) | **1500–1526 (errors)**, 1432–1434, 1441, 1443 (rpc errors), 1002, 1024, 1185 (not-found / invalid path), 1455–1464 + 11809–11814 (auth JWT errors), 1288 (PGRST122 under `handling=strict`), **1393, 1395, 1398, 1399, 11401, 11405, 11409** (mutation errors) | SQLSTATE→HTTP mapping (incl. the two 5xx paths 1523/1524), PGRST error codes, the PGRST205 fuzzy hint (1520/1521), RAISE PGRST full control, RAISE PT custom status, 4xx/5xx envelopes and their byte-exact key order (1525), `Proxy-Status` (1506, 1515–1516, 1519, and its documented *absence* on the inline 416, 1526), client-error-verbosity=minimal (1517, 1518, 1522), **PGRST128** (1441), the closest-proc **PGRST202** envelope with its upstream-asserted `Content-Length` (1443), and — new this pass — the write-path envelopes: **PGRST102** on an empty request body (**1398**), **PGRST105** on a PUT whose filters do not name all and only the pk columns (**11409**, a **405** rather than a 400), **PGRST114** on a PUT carrying `offset` (**1399**), **PGRST124** on an UPDATE exceeding `max-affected` (**11405**) and the raw-SQLSTATE **409 / `23505`** unique-violation path (**11401**, which asserts the SQLSTATE as the envelope `code` rather than a PGRST code). **Still Partial** — **PGRST127** still appears nowhere in the tree (see **Known gaps → select**), the two residual RPC preference legs (PGRST122/PGRST124 on `/rpc/*`) are uncased (see **Known gaps → headers**), and no case in the tree issues a HEAD request that errors (see **Known gaps → errors**). |
| `configuration` (Configuration) | 1700–1744 (config) | Sources (env/file/db-role-settings, incl. `db-config = false` disabling the in-db source, 1744), aliases, validation, coercion (incl. `coerceBool` from numeric/text strings, 1740–1741), unknown-key tolerance (1739), precedence, app-settings, CORS keys (1702–1704, 1742–1743), plus the v16 keys `client-error-verbosity` (1731–1732), `server-reuseport` (1735), `url-use-legacy-target-names` (1736), `admin-server-unix-socket` (1737–1738). **Partial** — the page's *In-Database Configuration* section documents `db-pre-config` as the recommended mechanism and its *App Settings* section documents `current_setting('app.settings.*')`; neither has a case. See **Known gaps → config**. |
| `observability` (Observability) | **1750–1771** (observability, **22** cases), 1497 (JWT-cache Server-Timing), 1625–1628, 1643 (execution plan), 1506/1515/1516/1519/1526/1002 (Proxy-Status, present and absent) | The live page has three top-level sections — **Logs** (SQL Query Logs, Database Logs), **Metrics** (Schema Cache / Connection Pool / JWT Cache / GHC Runtime), **Traces** (Server Version Header, Trace Header, Proxy-Status Header, Server-Timing Header, Content-Length Header, Execution plan). Covered: Server-Timing, Trace header, log-level→status signal, execution plan, Proxy-Status, and — **new this pass** — the **Server Version Header** (1771, `HEAD /` asserting the `Server: postgrest/…` prefix, which closes a gap this file listed last pass). **1770 is not a second copy of 1750**: 1750 uses the loose upstream-style presence regex (any separator, any number of decimals, mirroring `matchServerTimingHasTiming`), while 1770 pins the **exact wire render** in the doctest form — `\A` / `\z`-anchored, `", "` separators, exactly one fractional digit per metric, all five metrics in the fixed order (`Response/Performance.hs#L29`). **Partial** — the whole **Metrics** section and the whole **Logs** section have no case, and three further legs are uncovered; see **Known gaps → observability**. |
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

*(Re-verified a **seventh** time at the **670**-case state, fact by fact against
disk: `domain_representations` is 1800–1820 = **21** cases; **1707** is a live
`kind: cli` / `--dump-config` case; `grep -c pending spec/case.schema.json` →
**0**; the CLI set is **1705–1741 + 1744 = 38** (the observability re-sync added
no CLI case); `expect.status_text` on exactly **1508/1510/1511**. The
observability re-sync — the only change since — added two cases (**1770**,
**1771**), rewrote six (1757, 1765–1769) and re-pinned the provenance comments in
`fixtures/observability.sql`, all on the `observability` page plus the `options`
page (1757/1768/1769); none of those is scoped out. It did **not** touch
`connection_pool`, `schema_cache`, `listener` or `http_server`, and it added no
fixture object. One scoped-out page is worth re-reading in its light:
`admin_server` stays out of case coverage, and the observability review's
**Metrics** finding is the same wall from the other side — the metric families
live behind the admin server, so both need a `request.kind: admin` shape the
frozen harness does not have. **Nothing in this section was rewritten**; only this
note was appended, and `case.schema.json` was again left alone as the Tester's
file.)*

*(Re-verified an **eighth** time at the **707**-case state, fact by fact against
disk: `domain_representations` is 1800–1820 = **21** cases; **1707** is a live
`kind: cli` / `--dump-config` case; `grep -c pending spec/case.schema.json` →
**0**; the CLI set is **1705–1741 + 1744 = 38** (the operators re-sync added no
CLI case, and added **no `config:` block at all** — none of its 37 cases is
config-gated); `expect.status_text` on exactly **1508/1510/1511**. The operators
re-sync — the only change since — added **37** cases (10200–10236) and rewrote
none, all on the `tables_views` page plus the `in.( … )` list-grammar leg of
`url_grammar`; neither is scoped out. It did **not** touch `connection_pool`,
`schema_cache`, `listener` or `http_server`. Unlike the last two re-syncs it
**did** add fixture objects — two tables, two domains and one computed field,
through the new `operators.delta.sql` — but every one of them lands in schema
`test` and none is reachable from a scoped-out page. **Nothing in this section was
rewritten**; only this note was appended, and `case.schema.json` was again left
alone as the Tester's file.)*

*(Re-verified a **ninth** time at the **710**-case state, fact by fact against
disk: `domain_representations` is 1800–1820 = **21** cases; **1707** is a live
`kind: cli` / `--dump-config` case; `grep -c pending spec/case.schema.json` →
**0**; the CLI set is **1705–1741 + 1744 = 38** (the rpc re-sync added no CLI
case, and none of its three new cases declares a `config:` block);
`expect.status_text` on exactly **1508/1510/1511**. The rpc re-sync — the only
change since — added **three** cases (1441–1443) and rewrote **six** (1402, 1422,
1432, 1433, 1439, 1440), all on the `functions`, `preferences` and `errors`
pages, none of which is scoped out. It did **not** touch `connection_pool`,
`schema_cache`, `listener` or `http_server`, and it added **no fixture object** —
`rpc.delta.sql` is still the comment-only placeholder it became when
`test."true"()` was folded. **Nothing in this section was rewritten**; only this
note was appended, and `case.schema.json` was again left alone as the Tester's
file.)*

*(Re-verified a **tenth** time at the **727**-case state, fact by fact against
disk: `domain_representations` is 1800–1820 = **21** cases; **1707** is a live
`kind: cli` / `--dump-config` case; `grep -c pending spec/case.schema.json` →
**0**; the CLI set is **1705–1741 + 1744 = 38** (the mutations re-sync added no
CLI case, and none of its 17 new cases declares a `config:` block);
`expect.status_text` on exactly **1508/1510/1511**. The mutations re-sync — the
only spec change since — added **17** cases (1398, 1399, 11400–11405,
11407–11415) and rewrote **one** (1352), all on the `tables_views`,
`resource_embedding`, `resource_representation`, `preferences`,
`media_type_handlers`, `errors`, `transactions` and `url_grammar` pages, none of
which is scoped out. It did **not** touch `connection_pool`, `schema_cache`,
`listener` or `http_server`, and it added **no fixture object** — there is still
no `mutations.delta.sql`. **Nothing in this section was rewritten**; only this
note was appended, and `case.schema.json` was again left alone as the Tester's
file.)*

*(Re-verified an **eleventh** time at the **735**-case state — the previous pass — fact by fact
against disk: `domain_representations` is 1800–1820 = **21** cases; **1707** is a
live `kind: cli` / `--dump-config` case; `grep -c pending spec/case.schema.json`
→ **0**; the CLI set is **1705–1741 + 1744 = 38** (the representations re-sync
added no CLI case, and none of its eight new cases declares a `config:` block);
`expect.status_text` on exactly **1508/1510/1511**. The representations re-sync —
the only spec change since — added **eight** cases (1315–1319, 1325–1327) and
rewrote **one** (1309), all on the `resource_representation` and `preferences`
pages, neither of which is scoped out. It did **not** touch `connection_pool`,
`schema_cache`, `listener` or `http_server`, and it added **no fixture object** —
there is no `representations.delta.sql`. **Nothing in this section was
rewritten**; only this note was appended, and `case.schema.json` was again left
alone as the Tester's file.)*

*(Re-verified a **twelfth** time at the **740**-case state — the previous pass — fact by fact against
disk rather than carried over: `domain_representations` is 1800–1820 = **21**
cases; **1707** is a live `kind: cli` / `--dump-config` case (`request.kind:
cli`, `flag: "--dump-config"`, with a `config.file:` block);
`grep -c pending spec/case.schema.json` → **0**; the CLI set is
**1705–1741 + 1744 = 38**, enumerated id by id (the content_negotiation re-sync
added no CLI case, and **none of its six new cases declares a `config:` block**);
`expect.status_text` on exactly **1508/1510/1511**. The content_negotiation
re-sync — the only spec change since — added **six** cases (the re-issued 1623,
1647, 1648, 1649, 12400, 12401), **deleted one** (the old 1623) and rewrote
**three** (1600, 1622, 1637), all on the `media_type_handlers` and
`resource_representation` pages, neither of which is scoped out. It did **not**
touch `connection_pool`, `schema_cache`, `listener` or `http_server`. Unlike the
last two re-syncs it **did** change `fixtures.sql` — one new domain and one
routine re-declared in place — but both land in schemas `public`/`test` and
neither is reachable from a scoped-out page. **Nothing in this section was
rewritten**; only this note was appended, and `case.schema.json` was again left
alone as the Tester's file.)*

*(Re-verified a **thirteenth** time at the **746**-case state, fact by fact against
disk rather than carried over: `domain_representations` is 1800–1820 = **21**
cases; **1707** is a live `kind: cli` / `--dump-config` case;
`grep -c pending spec/case.schema.json` → **0**; the CLI set is
**1705–1741 + 1744 = 38**, re-enumerated id by id and confirmed to equal exactly
that set (the openapi re-sync added no CLI case, and **none of its six new cases
declares a `config:` block** — the fifth consecutive pass for which that is true);
`expect.status_text` on exactly **1508/1510/1511**. The openapi
re-sync — the only spec change since — added **six** cases (**1683–1688**) and
rewrote **33** (the whole committed band, 1650–1682), all on the `openapi` page,
which is not scoped out. It did **not**
touch `connection_pool`, `schema_cache`, `listener` or `http_server`, and unlike
the previous pass it changed **no** fixture file at all: neither
`conformance/fixtures.sql` nor anything under `conformance/fixtures/` appears in
`git status`. **Nothing in this section was
rewritten**; only this note was appended, and `case.schema.json` was again left
alone as the Tester's file — it exists, so per this pass's brief it stays the
Tester's to own.)*

> **One scope bullet was re-read in this pass's light and does NOT change, but
> the reason is worth recording because it is the third variety of "inert
> declaration" this section has had to distinguish from a scope decision.** The
> `cli` bullet's claim that "no spec case carries `pending` or `pending_reason`"
> still holds mechanically. The openapi audit's own inert-declaration finding is
> narrower than content_negotiation's and points the other way: the area's two
> non-empty `preconditions:` lists were not concealing missing coverage, they
> were **wrong** — 1654's `COMMENT ON SCHEMA test IS NULL` would have broken case
> 1656, and 1672's `CREATE FUNCTION` omitted the `DEFAULT '{}'` its own assertion
> needs. Both were removed. That is a defect in the cases, not a scope question,
> and it is filed under *Known gaps → openapi* and follow-up 25.
>
> **The area's genuinely out-of-reach item is a HARNESS gate, not a scope
> decision, and it is named here only so it is not re-derived as one.**
> `openapi-server-proxy-uri` is fully modelled with `cases: []` because a
> config-carrying case needs an entry in the frozen harness's
> `@variant_case_ids`. The `openapi` docs page stays **in scope** and **Partial**;
> see follow-up 30.

> **One scope bullet deserves re-reading in this pass's light, and — as with the
> rpc audit before it — the conclusion is that it should NOT change.** The `cli`
> bullet's claim that "no spec case carries `pending` or `pending_reason`" still
> holds mechanically. But the content_negotiation audit's sharpest finding is a
> *different* way for a declaration to be inert: five cases (**1625–1628**,
> **1643**) state the `db-plan-enabled = true` requirement in a
> **`preconditions:`** string, which the harness parses and never runs, and no
> case anywhere pins the **406** the default `db-plan-enabled = false` produces
> (upstream asserts it at `PlanSpec.hs#L544`). That is not a scope decision — the
> `media_type_handlers` page is fully in scope and the behavior is ordinary
> black-box HTTP — so it is filed under *Known gaps → content_negotiation*. It is
> recorded here only so nobody re-derives it as a scope question, exactly as the
> rpc fixture-ownership note below is. **The relevant follow-ups are 25
> (`preconditions:` is inert) and 9 (unhonoured `config:` blocks); this finding is
> the first to sit squarely on both.**

> **The one thing that DID change outside this section since the last revision is
> a fixture provenance re-pin, and it does not touch any scope bullet.** Commit
> `6b25f05` re-pinned `conformance/fixtures/rpc.sql#L15` from `blob/v14.12` to
> `blob/v16.0`. `fixtures/*.sql` files are not scope decisions and none of the
> four scoped-out pages reads from `rpc.sql`; the consequence is confined to
> follow-up 14 (the remaining fragments) and follow-up 24 (the now-stale
> `rpc.yaml` gap entry that reported it).
>
> **Both halves of that consequence have since closed**, at `6b25f05` and
> `75388d6` respectively — see follow-up 24 — and neither touched a scope bullet
> either. Follow-up 14 (the other six fragments' **43** `v14.12` URLs) is
> unchanged and still open.

> **One scope bullet is worth re-reading in the rpc audit's light, without
> changing it.** The `cli` bullet's claim that "no spec case carries `pending` or
> `pending_reason`" still holds. But three of the audit's five findings —
> *Untyped functions*, *array parameters* and the *single unnamed text/xml*
> flavors — are blocked on routines the **human-owned** `fixtures/rpc.sql` cannot
> receive from a workflow agent, so their objects would land in schema `test` via
> `rpc.delta.sql` (`spec/rpc.yaml` → `loader_exposure`). That is a fixture
> **ownership** constraint, not a scope decision, so it is filed under
> *Known gaps → rpc* rather than here — but it is the same class of wall the
> `schema_cache` / `listener` deferrals describe, and it should not be
> rediscovered as a scope question.

## Coverage summary

- Docs pages enumerated: **27** — 16 API sub-pages + 11 top-level reference
  pages (the `references/api` parent page is counted once, through its
  sub-pages; `url_grammar` is counted once). **Re-fetched live from
  postgrest.org/en/v16 this pass** (both `references.html` and
  `references/api.html`); the page set is unchanged, entry for entry.
- Pages with at least one covering case: **23**.
- Pages explicitly scoped: **4** — `connection_pool` (out of scope),
  `http_server` (out of scope, new in v16), `schema_cache` (deferred),
  `listener` (deferred).
- Pages flagged **GAP** (no covering case and not scoped out): **0**.

Two pages are new in v16 relative to the pre-re-sync state: `api/vary_header`
(covered, 1575–1576 and 1582–1583) and `http_server` (scoped out — see above).

**Seventeen** pages are marked **Partial** in the notes above (`options`,
`transactions`, `admin_server`, `observability`, `auth`, `preferences`, `cors`,
`configuration`, `resource_embedding`, `aggregate_functions`, `errors`,
`tables_views`, `url_grammar`, `functions`, `media_type_handlers`,
`resource_representation` and — new this pass — **`openapi`**): they have
covering cases but not the
full breadth of the docs page. These are soft gaps, itemized next.
`media_type_handlers` changed *character* in the previous pass: it went
from Partial-on-one-borrowed-finding (the rpc area's `text/plain`/`text/xml`
flavors) to carrying **five findings of its own** — the densest cluster in the
tree, displacing `functions`. Its cases grew 47 → 52 in the same pass, which was
the fourth consecutive demonstration that **case density and coverage are
independent**.

> **`openapi` is the fifth such demonstration, and the cheapest to act on.** The
> page went from *not marked Partial at all* to Partial on **two** findings, in
> the same pass that took it 33 → 39 cases and its model 6 → 14 gap entries. Both
> findings are **case-only** and **zero-fixture**: `$.parameters.on_conflict` is a
> single shared definition emitted into every document, and the `/rpc/*`
> per-operation `produces` (a three-element list) and `responses.200 = "OK"` are
> emitted on every routine path item the document already contains. Cases 1686,
> 1687 and 1688 prove the assertion shape works — each reads a fixed key of the
> generated document by JSONPath and asserts it whole. **Two cases, no new
> objects, no harness change.** They are, collectively, cheaper than any other
> open block in this file, including content_negotiation's seven.
>
> **They are also the strongest available evidence that a long gap list is not
> coverage.** `openapi.yaml` carries **14** entries and a five-entry
> `fixture_notes:` key — behind only `config`/`observability` (16 each) and
> `auth` (15), level with `filters` — and neither of these two behaviors appears in
> it under any wording. The same shape the rpc audit found (seven rigorous
> entries, five findings none of them anticipated), reproduced against an author
> who wrote *more* down, not less.

> **`resource_representation` gained its Partial mark in the same pass that
> gained it eight cases, and the two facts are the same fact.** The page went
> from *silent* (no gap list under any key, no recorded verdict) to *audited,
> ✅ pass, and Partial*. Its one residual is unusual enough to be worth stating
> here rather than only in the gaps section: the `is.null` rendering of a NULL
> key column inside a headers-only `Location` is **modelled, citable and
> mechanically understood** (`locationF` emits
> `key || '=' || coalesce('eq.' || value, 'is.null')`), and it is nonetheless
> **unreachable on a base table**, because `PRIMARY KEY` implies `NOT NULL`.
> Upstream reaches it only through a rule-backed view over *two* base tables. So
> this is not "nobody wrote the case" and not "the fixture is missing a table" —
> it is a behavior whose only witness requires a different area's mechanism
> (multi-base-table view key inference). See **Known gaps → representations**.
`vary_header` stays **covered** but carries one itemized gap (the preflight leg).
`pagination_count` is explicitly Partial on the strength of the
embedded-`.offset` finding below — the first pagination gap that is a
*documented request parameter with zero coverage* rather than a derived edge
case.

**`observability` keeps its Partial mark this pass but for a sharper reason.**
The re-sync closed one of its four listed gaps (Server Version Header → case
**1771**) and the adversarial review then re-drew the rest against the live page
structure: **two of the page's three top-level sections — Logs and Metrics — have
no conformance case at all**, and neither is closable without a new assertion
shape (`expect.stdout_matches` for Logs, `request.kind: admin` for Metrics). This
is the largest *structural* hole in the tree — a whole docs section rather than a
rule inside one — and it is the one gap class that no amount of case authoring
can close on its own. See **Known gaps → observability**.

The pagination pass remains worth separating from the itemized gaps, because
unlike the surrounding re-syncs it did not only *add* coverage — it **corrected a
modelled rule**:

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
  rule the model wraps around it, and **three** areas still have no v16.0 audit.

The representations pass is a fourth species again, and the one most worth
copying: it **narrowed a citation whose anchor was real but proved less than the
model claimed**.

- **`InsertSpec.hs#L745` proved the Location-absence rule for a VIEW only.**
  `representations.yaml` cited it for "a POST without `return=headers-only`
  carries no `Location`". The line exists, is fetchable and is correctly pinned —
  but it sits under `describe "Inserting into VIEWs"` and posts to
  `/compound_pk_view`, so it witnesses the rule on a view and says nothing about
  a table. The model now cites `#L157` (the no-`Prefer` it-block on the
  `projects` **table**) and `#L99` (the `return=representation` it-block), and
  case **1309** was rewritten alongside it. **No check in this document could
  have found that**: the pin sweep passes (right tag), schema validation passes
  (right shape), and the adversarial audit's own "does the cited line support the
  claim?" test passes if you read the line without its enclosing `describe`. The
  failure mode is *scope of the citation*, and the only defence is reading the
  block, not the line.

The observability pass produced the same shape of result and is the second
consecutive re-sync to **retract** a modelled rule rather than only add cases:

- **The OPTIONS Server-Timing "subset" rule did not exist.** Cases
  1757/1768/1769 asserted `headers_absent_in_value: {Server-Timing: [plan,
  transaction]}`. `withTiming` branches only on `configServerTimingEnabled`
  (`App.hs#L272`), never on the action, so a real `OPTIONS /organizations`
  carries all five metrics; `Plan.actionPlan` returns `NoDb …` and `MainTx.mainTx`
  returns `NoDbTx`, but both stages are still wrapped and still produce a
  duration. The claim was false at **both** pins, so it was an inherited
  authoring error rather than a v16.0 behavior change — and, unlike the
  pagination correction, it had a live consequence: `lib/` implements the
  invented behavior (`lib/bier/plugs/observability.ex:159` emits a three-metric
  OPTIONS header) and must be fixed by the conformance pass.

The content_negotiation pass is the sixth consecutive re-sync worth separating
out, and its lesson is the one no earlier pass could have taught, because no
earlier pass looked below the case layer:

- **The ground truth a case rests on is not only its `source:` — it is also the
  fixture, and nothing in this tree was checking the fixture.** Case **1622**
  asserted a 200 that a faithful PostgREST could not have produced, because
  `fixtures.sql` declared `test.unnamed_bytea_param` as `RETURNS bytea` where
  upstream declares it over the mime-named DOMAIN. Every check in this document
  passed: the pin was v16.0, the schema validated, the filename matched the id,
  the cited line was real, the relation existed in the loaded DB — the relation
  check confirms *existence*, never *declaration*. And the case **passed**,
  because `lib/` is over-permissive in the matching direction. **A green case
  over a wrong fixture is indistinguishable from a green case over a right one**,
  and the only artifact that would have surfaced it is the `fixture_notes:` key
  this pass invented. Every area whose cases depend on a *declaration* (return
  type, volatility, domain, generated-column-ness) rather than on seed data
  should carry one.
- **A mechanism can be modelled wrongly and stay undetectable because the
  fixtures make both rules agree.** The model said a custom media handler is an
  aggregate whose **stype** is the mime-named domain. Discovery actually keys on
  the **return type** (`proc.prorettype`), with a whole second branch for plain
  non-set-returning functions that stype cannot express at all. The two rules
  coincide exactly when an aggregate has no finalfunc — true of every fixture
  here. **This is the pagination lesson (an it-block that cannot discriminate)
  one layer down: a fixture set that cannot discriminate.** Upstream's own docs
  phrase the rule loosely enough ("the return type of their transition or final
  functions") to have licensed the error.

`tables_views` remains the densest page in the tree: **seven areas and 353
cases** feed it (unchanged this pass — content_negotiation contributes to
`media_type_handlers` and `resource_representation` instead), and it *still*
misses the page's opening rule on combining filters. Density is not
coverage — a page can absorb a 21 % case increase across three passes without
closing the rule stated in its own first paragraph. `resource_embedding` now
makes the point twice over: the
ordering audit found a **named docs section** with a worked example
(*Order in spread to-many*) and zero assertions, and the pagination audit found a
**worked example on the same page** — `&actors.limit=10&actors.offset=2` — whose
two halves have 1 case and 0 cases respectively. `url_grammar` makes it a third
time, and the errors pass a fourth: the tree's **13 HEAD cases all expect 2xx**,
so a HEAD that errors is untested across **746** cases. The observability pass
added the thirteenth (**1771**, `HEAD /` for the `Server:` header) without closing
it — the same pattern the pagination pass showed with the twelfth. **The operators
pass added 37 cases and not one HEAD, the rpc pass three more, the mutations pass
seventeen more, the representations pass eight more, the content_negotiation
pass six more and the openapi pass six more — not one HEAD between them** — so the
blind spot is now eight
re-syncs old and its denominator has grown by **11.5 %** since it was first named,
while the numerator has not moved at all. The openapi pass is a near-miss of its
own: the band already owns **1681** (`HEAD /`, asserting the absence of
`Content-Length`), so the area demonstrably knows how to write one, and all six
of its new cases are `GET /`.
Re-derived on disk at the **746**-case state: **13** HEAD cases (1020, 1272,
1274, 1275, 1277, 1284, 1425, 1681, 1756, 1760, 1761, 1762, 1771), **0** of them
expecting a non-2xx status.

> **The content_negotiation pass is the cleanest miss of the seven, and for a
> reason specific to the area.** `Content-Type` is the *one* response header a
> HEAD response still carries in full, and negotiation is the *one* subject whose
> entire assertion is that header. The pass authored six cases whose expectations
> are dominated by `Content-Type` — including two 406 envelopes (**1623**,
> **1647**) whose status and header set are exactly what a HEAD-that-errors case
> would assert — and issued no HEAD at all. An area could hardly be better placed
> to close this, and it is now the seventh in a row not to.

> **The representations pass is now the sharpest miss of the six, displacing
> mutations.** Six of its eight new cases assert a response whose entire subject
> is the **header set** — 1315/1316/1317 turn on `Location` being *absent*,
> 1325/1326 on `Preference-Applied` being *absent* — and every one of them uses
> `headers_absent` on a POST or GET. That is the exact assertion vocabulary a
> HEAD case needs, applied eight times in one pass, in an area whose model is
> about response *shape*. The tree still has no HEAD that errors. **The
> content_negotiation pass has since displaced it as the sharpest miss** — see
> the note above.

> **The mutations pass is retained here as the first with an obvious occasion to
> close the HEAD hole.** Three of its
> new cases assert *header-only* response shapes — **11400** (`PATCH` → 204,
> `Content-Range: 0-1/*`, both `Content-Type` and `Content-Length` absent) and
> **11402** (`POST` → 201, `Content-Length: 0`, no `Content-Type`) — which is
> exactly the assertion vocabulary a HEAD case uses. Method coverage across the
> whole tree, re-derived at **746**: GET **510**, POST **107**, CLI **38**, PATCH
> **27**, DELETE **21**, PUT **18**, HEAD **13**, OPTIONS **12**. (The previous
> revision printed PATCH as **26**; recounted on disk it is **27**, and it was 27
> at HEAD too — a slip in this document, not a change in the tree.) The write
> methods grew by 17 in the mutations pass, 7 more in the representations pass and
> **1 more** (case 12401's PATCH) in the content_negotiation pass; the openapi
> pass added **six GETs and nothing else**; **HEAD has not
> grown at all in eight re-syncs**.

The `functions` page now makes the same point a fifth time, and more sharply than
any of the four before it, because the missing pieces are not corners:

- **Two of the docs page's own H2 sections have no case at all.** *Untyped
  functions* (routines returning `record` / `SETOF record`) and *Functions with
  array parameters* (a **non**-variadic array-typed parameter) are named,
  worked-example-carrying sections of `functions.rst`, each with its own upstream
  `it`-blocks, and neither has a case, a model entry, or — before this pass — a
  `gaps:` note. That is the failure mode `resource_embedding` showed with *Order
  in spread to-many*, reproduced on the page the tree covers most heavily: **106**
  cases across **nine** areas issue a `/rpc/` request, and the page still misses
  two of its own headings.

The mutations pass is the fifth consecutive re-sync worth separating out, and its
lesson is new: it is the first whose audit findings were **partly closed inside
the pass itself**, and the first to make an *editorial* decision — deleting a
case it had already written — rather than only adding or correcting.

- **A case was authored and then deleted, and the deletion is recorded.** Case
  **11406** was to be the mutations-band assertion of PUT + `Prefer:
  return=minimal` (204, no `Content-Type`, `Preference-Applied: return=minimal`,
  `UpsertSpec.hs#L543`). It was dropped on discovering that case **1332** in the
  *representations* band already mirrors the same it-block and additionally
  asserts the empty body — same anchor, strictly stronger assertions, only the
  derived relation differing. `mutations.yaml`'s gaps say so in as many words,
  and the gap then re-aims at what actually *is* uncovered: the **case-sensitive
  identifier** half (upstream's target is the quoted `/UnitTest` relation with pk
  `"idUnitTest"`, absent from the fixture DB). **This is the behavior to copy** —
  a deleted case is a finding, and an unrecorded deletion is indistinguishable
  from a gap nobody noticed. The visible artifact is the band's shape: the new
  ids are **11400–11405 + 11407–11415**, with 11406 missing on purpose.
- **But the same pass shows the opposite failure, and it is worth costing.** The
  PGRST114 PUT-`limit`/`offset` rule is now asserted **four times across two
  areas** from the same two upstream it-blocks: 1016/1383 for `limit`, 1030/1399
  for `offset`. The pass did not create the pattern — 1383 already twinned 1016
  before it — but it *completed* it by adding 1399 rather than reusing 1030. So
  one duplicate was found and deleted (11406) while another was found and
  extended (1399). Both decisions are defensible in isolation; what is not on
  disk anywhere is the **rule** that distinguishes them. See
  **Known gaps → mutations**.
- **The gap list nearly doubled, 6 → 11, and its new entries are the most
  operationally specific in the tree.** Each names the missing relation, quotes
  the blocking it-block and closes with a `loader_exposure:` clause. One
  decomposes composite-pk UPSERT **leg by leg**: `car_models` exists (unlike
  upstream's `employees`) but seeds **zero** rows, so the POST merge-duplicates
  leg *is* derivable (both payload rows simply insert — cased as **11414**),
  the ignore-duplicates leg is **not** (its whole assertion is that a conflicting
  row is *omitted*, which needs something to conflict against), and the PUT-update
  leg is **not** (it first GETs a seeded row, so with no seed it degenerates into
  the insert leg already covered by 11408). That is the standard the other eleven
  gap-carrying models should be read against.

The rpc pass is the fourth consecutive re-sync worth separating out, and its
lesson is the inverse of the operators pass's:

- **Density hid the holes rather than revealing them.** Operators found silence
  in an area with 50 cases; rpc found it in the area with the second-most
  cross-area reach in the tree. The audit returned **five** missing-coverage
  findings — the most any single area audit has produced — against an area that
  had just been re-synced, and every one of them is *citable*: upstream asserts
  all five at v16.0 with fetchable `it`-blocks (`RpcSpec.hs` L486/L496, L515/L545/
  L564, L1170/L1177/L1207, L324, L855), and each was re-fetched and confirmed
  during synthesis. **A freshly re-synced area is not a covered area**, and the
  count of cases pointing at a docs page says nothing about which of its sections
  they point at.
- **It is also the first pass whose gaps are blocked by fixture *ownership*
  rather than fixture *absence*.** Three of the five need routines
  (`returns_record`, `returns_setof_record`, `varied_arguments`,
  `unnamed_text_param`, `unnamed_xml_param`) that `fixtures/rpc.sql` — a
  human-owned live loader input — cannot receive from a workflow agent, so they
  would have to land in schema `test` through `rpc.delta.sql` and the cases would
  carry `schema: test` rather than `schema: rpc`, exactly as case 1440 already
  does. That is a decision to make once, not per gap.

The operators pass is the third consecutive re-sync worth separating out, and its
lesson is different from the two before it. It neither corrected a modelled rule
(pagination) nor retracted one (observability):

- **It closed another area's gap, and found a rule that had been modelled in one
  area and asserted in none.** `IN`/`NOT IN` with an empty set was filed under
  **Known gaps → filters** on the strength of `QuerySpec.hs#L1359`'s eleven
  it-blocks — while `operators.yaml` had, all along, modelled the very
  `SqlFragment` branch that produces the behavior (`[""] -> "= ANY('{}')"`). The
  gap was real, but it was recorded by the area that owns the *docs page* and
  closable only by the area that owns the *SQL rendering*. Cases 10200–10205 close
  it from the operators side, together with the folded
  `test.items_with_different_col_types`. **The generalizable warning**: a gap
  section in this file names the area that *noticed* the hole, which is not
  reliably the area that can fill it. Re-read the other areas' gaps with that in
  mind before costing them.
- **It found that "nothing changed between the pins" had been silently read as
  "nothing is missing".** `operators.yaml`'s re-sync note asserted — correctly —
  that every operator token, SQL table, `not` prefix and quantifier is
  byte-identical across v14.12 and v16.0. The audit re-proved that by byte-diffing
  the regions rather than reading changelogs, and then found that an entire
  upstream `context` block (`"text and json columns"`, the automatic
  `to_tsvector()` coercion) existed at **both** pins with **zero** coverage,
  along with the tsvector-domain, recursive-domain and computed-field variants and
  the tsquery/websearch operand grammar. Seventeen cases (10220–10236) close them.
  A correct delta claim is not a coverage claim, and this is the second time in
  three passes that the tree's own prose was the thing that hid the hole.

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
  wrote the case. **All five *select* entries, all five *rpc* entries, all
  *seven* *content_negotiation* entries, **both new *openapi* entries**, the two
  remaining *filters* entries, all three *headers* entries, both *config*
  entries, both *ordering* entries, both *operators* entries plus its column-type
  residual, the one *url_grammar* entry, the one *pagination* entry and two of
  the three *errors* entries are of this kind**, so they are the actionable ones.

  > **The two *openapi* entries are the cheapest block in this list and displace
  > content_negotiation's seven for that title.** Two cases, both `GET /` with
  > `Accept: application/json` and `schema: test`, both reading a fixed JSONPath
  > into the emitted document, both landing in the free **1689+** slice: no
  > fixture object, no harness change, no band decision. Cases **1686**, **1687**
  > and **1688** from the same pass prove the shape end to end. They are also the
  > only entries in this list that came from an area whose model *already*
  > disclosed 14 gaps — see **Known gaps → openapi** for why that matters.
  Each is labelled below. (Filters' third entry — the `in.()` empty set — was of
  this kind too and is now **closed**, by the operators area; see below.)

  > **The content_negotiation entries are the largest single-area addition this
  > list has ever taken, and every one of the seven is case-only.** No fixture, no
  > harness change, no band decision beyond the already-open 12402+ — the seven
  > need seven case files and nothing else. That makes them, collectively, the
  > cheapest large block of work in this document. Their anchors were re-fetched
  > during synthesis and read as claimed: `PlanSpec.hs#L544`,
  > `CustomMediaSpec.hs#L188`, `#L208`, `#L346`, `#L369`, and `RpcSpec.hs#L1168`.
  > **One caveat that applies to none of the other areas**: two of the seven need
  > a fixture *property* rather than a fixture *object* — the `*/*`-domain
  > handler on a table and the geo+json override both need an aggregate the
  > consolidated fixture may or may not already have in the right shape, and this
  > pass proved that "the relation exists" is not the same as "the relation is
  > declared the way the case needs". Check the declaration, not the name.

  > **The mutations entries sit almost entirely in the FIRST bucket, which is
  > unusual and is the most useful single fact about that area's gap list.** Of
  > its open items, **one** is citable-but-uncovered in the ordinary sense (the
  > cross-area PGRST114 duplication, which is an editorial decision rather than
  > missing coverage) and the rest are **blocked on relations the consolidated
  > fixture database does not have** — `foo` (GENERATED ALWAYS), `UnitTest`
  > (case-sensitive identifier), `employees`, `web_content`, `artists`/`albums`,
  > `surr_serial_upsert` / `surr_gen_default_upsert` / `Surr_Gen_Default_Upsert`,
  > `compound_pk`, `with_multiple_pks`, `tbl_w_json`, `bitchar_with_length`,
  > `items3`, `empty_table`, `complex_items_view`, `app_users`,
  > `unsafe_update_items` / `unsafe_delete_items`. Upstream asserts all of them;
  > the citations exist and the area model quotes them. **So mutations' gap list
  > is long not because the area is under-researched but because the fixture DB is
  > a subset** — a materially different situation from rpc's, where the objects
  > are blocked by *ownership* of a file that could otherwise hold them.

  > **The rpc audit makes this the largest single-area contribution to the
  > citable-but-uncovered list, and every one of its five anchors was re-fetched
  > during synthesis rather than taken on the reviewer's word.** `RpcSpec.hs` at
  > v16.0 is 1500 lines; L486 is `it "returns a record type"`, L496 `it "returns a
  > setof record type"`, L515/L545/L564 the three array-parameter binding paths
  > (JSON body, GET `?arr=%7Ba,b,c%7D` literal, `x-www-form-urlencoded` body),
  > L1170/L1177 the `text/plain` and `text/xml` single-unnamed-parameter inserts,
  > L1207 the `text/plain` PGRST202 envelope, L324 the table-valued-function
  > embed, and L855 `it "ignores json keys not included in ?columns"`. All nine
  > lines read as claimed.

> **The observability audit added a third kind, and it should not be filed under
> either heading above.** Its four findings split 3/1: three (Metrics, access-log
> line emission, the trace-header empty echo) are **blocked on something other
> than authoring effort** — an assertion style the schema does not have
> (`expect.stdout_matches`), a request shape the harness cannot issue
> (`request.kind: admin`), or a direct conflict with an existing frozen case
> (1573's `headers_no_blank` on the shared instance). Upstream *does* assert all
> three, so they are not uncitable in the auth sense — the citation exists and is
> verified; the **harness** is what is missing. The fourth
> (`server_timing.success_path_only`) is the mirror image: black-box observable
> and trivially expressible, deliberately left uncased because **upstream never
> asserts it** and this tree does not pin behavior upstream does not check. It is
> promotable on an operator's say-so, and it is the only observability item that
> is.

A third axis cuts across both kinds and is what actually decides effort:
**what does closing it cost?** The buckets below are re-derived on disk this pass
(the mutations entries are costed separately, under
**Known gaps → mutations**, because all but one are relation-blocked; the single
open **representations** entry is costed separately too, under
**Known gaps → representations**, because it is neither case-only nor closable by
adding a table — see the fourth-blocker note at the end of this list):

> **A bookkeeping correction, made rather than carried forward.** The previous
> revision opened this list with "Of the **twenty-five** citable-but-uncovered
> entries" and then enumerated buckets summing to **twenty-four**. The headline
> and its own contents disagreed, and neither matched a per-area recount. This
> revision therefore **states the buckets and drops the headline total** — the
> buckets are what costing actually uses, and a total nobody can reconcile is
> worse than no total. The content_negotiation audit adds **five** new entries to
> the case-only bucket and **one** to the harness bucket; its sixth finding is
> the `text/plain`/`text/xml` pair already counted among rpc's, and its seventh
> is editorial (the id-reuse hazard), like mutations' PGRST114 duplication.

- **nineteen are case-only** — select's spread-to-many and terminal-`->`;
  filters' implicit AND; headers' RPC `handling` and the preflight `Vary`
  assertion; ordering's order-in-spread-to-many and its aliased-relation
  PGRST118; **pagination's embedded `.offset`**; both errors entries (a HEAD
  against `test.items`); **both operators entries** (`not.` on the three
  non-`fts` full-text operators, and an fts filter inside an `or=()` tree) plus
  **the operators residual** (the five unswept `in.()` column types, now that the
  fixture is folded); **two of the five rpc entries** — the table-valued-function
  embed (`test.getproject` returns `SETOF test.projects`, and `test.clients` /
  `test.tasks` are both seeded) and `?columns=` on a POST to `/rpc/sayhello`
  (`test.sayhello(name text)` exists and is IMMUTABLE) — both verified against
  `fixtures.sql` during synthesis; **url_grammar's escaped-char `in.( … )`
  value, but only in part** — see the next bullet; and **four of the seven
  content_negotiation entries** — the `*/*` handler's `Content-Type` override and
  its type rejection, the `*/*` handler on a TABLE/VIEW, the `application/geo+json`
  single-relation override, and a **q-factor-discriminating** `Accept` list. All
  four are one case each against relations and routines the loaded DB already
  has, in the open **12402+** slice;
- **six need fixture objects the consolidated DB does not have** — select's FK
  joins on views/chains and on partitioned tables, headers' RPC `max-affected`
  routines, and **the other three rpc entries**: *Untyped functions* needs
  `returns_record` / `returns_setof_record` (+ the `_params` twins), *array
  parameters* needs a routine that **echoes** a non-variadic array param, and the
  *text/xml single unnamed parameter* pair needs `unnamed_text_param` /
  `unnamed_xml_param`. All five names were grepped against `fixtures.sql`,
  `fixtures_local.sql` and `fixtures/rpc.sql` this pass and are absent from all
  three; the only array-typed parameter anywhere in the fixture set is the
  **VARIADIC** `test.variadic_param(VARIADIC v text[])`, which is the rule the
  tree already covers, and the only other array-parameter routine,
  `test.varied_arguments_openapi`, **does not echo its arrays** (its body is
  `json_build_object('double', double, 'integer', "integer")`), so it cannot
  substitute. **Filters' `empty_string` row is the seventh and it is unchanged.**
  url_grammar's entry **straddles this line**: three of its four upstream
  it-blocks need seed rows the consolidated fixture lacks, but the fourth
  (`QuerySpec.hs#L1334`) runs against the already seeded `David White` row with
  no delta at all;
- **three are blocked on the frozen harness honouring a case's `config:` block** —
  config's `app.settings.*`, select's aggregates-in-to-one-spreads, and — **new
  this pass** — content_negotiation's `db-plan-enabled = false` **406** gate,
  whose answer depends on the shared instance's own `db-plan-enabled` state.
  Note this one is *doubly* blocked, and the second blocker is cheaper to fix:
  five cases already declare the requirement in `preconditions:`, a key the
  harness parses and never runs (follow-up 25), so even an honoured `config:`
  block would leave those five declarations inert;
- **one, config's `db-pre-config`, needs a pre-config function reachable at
  startup**, which is a fixture *and* harness decision.

The case-only entries are the whole of the low-cost work available. **The
operators residual is still the single cheapest item in this file** — five case
files against a relation and a seed row that are *already loaded*, no fixture, no
harness change, and no band decision (the operators overflow band 10237+ is
open). **The four case-only content_negotiation entries now sit level with the
two rpc ones**, and all six are cheaper than everything else: one case each,
against routines and tables the loader already builds, in the free **1444+**
(rpc) and **12402+** (content_negotiation) slices. Then the
pagination entry — still the cheapest item that closes a *documented request
parameter* rather than a type sweep — the two errors entries, the two operators
findings, the two ordering entries and the url_grammar escaped-char case.

> **A caution the content_negotiation pass earned, and it applies to all six of
> those "cheap" entries.** "Against relations the loader already builds" is the
> phrase this document has used to cost work for six consecutive passes, and this
> pass showed it is not sufficient: case 1622 targeted a routine that existed,
> was reachable, and was declared **wrongly**, which no existence check can see.
> Before costing any of the six as one case file, read the *declaration* of the
> object it needs — for the `*/*`-on-a-table and geo+json-override entries that
> means confirming an aggregate whose **return type** (not stype) is the
> mime-named domain, and whose argument is the relation's row type.

> **A caveat on the three fixture-blocked rpc entries that does not apply to any
> other fixture gap in this file.** The objects they need belong, by upstream's
> own layout, in the `rpc` fixture set — but `spec/conformance/fixtures/rpc.sql`
> is a **human-owned live loader input** that no workflow agent may edit
> (`spec/rpc.yaml` → `loader_exposure`, `conformance/fixtures/README.md`). The
> available channel is `rpc.delta.sql`, which folds into `fixtures.sql` and
> therefore lands in schema `test`, so the cases would carry `schema: test` and
> the `rpc` profile would still not expose the routines. Case **1440**
> (`test."true"()`) is the precedent and it worked, but it was one
> zero-argument routine; five routines is where the pattern should be confirmed
> or replaced by a reviewed human commit to `rpc.sql`. **Decide this once, before
> authoring any of the three** — see follow-up 22.

> **The representations pass adds a FOURTH blocker class, and it is the only one
> in this file that more cases and more fixtures cannot clear.** Its `is.null`
> gap is not uncitable (the it-block exists at `InsertSpec.hs#L783`), not
> case-only (no request against any existing relation produces it), not
> harness-blocked (the assertion shape exists) and not merely relation-blocked in
> the mutations sense (adding a table would not help). It is **unreachable by
> construction**: `PRIMARY KEY` implies `NOT NULL`, so a NULL key column can only
> arise in a **view** whose key columns are inferred from more than one base
> table. Closing it means reproducing upstream's rule-backed
> `test_null_pk_competitors_sponsors` view — which would simultaneously pin
> multi-base-table view-key inference, a `select`/`url_grammar` mechanism. **File
> it as a cross-area fixture-and-ownership question, not as a representations
> case that nobody got around to.**

### openapi (adversarial review verdict: **revise** — 2 missing-coverage findings, **0 citation defects**)

**0 citation defects**, and the **smallest finding count any *revise* verdict has
produced** — two, against an area whose gap list is **joint fourth-longest** in
the tree (14 entries, level with `filters`, behind `config`/`observability` at 16
and `auth` at 15). Both
are ***citable but uncovered***, both are **case-only**, and both are emitted by
**every** OpenAPI document the server can produce, in every configuration. What
makes them worth reading is not their size but their disclosure status: **neither
appears in `openapi.yaml` under any wording**, in a model that carries 14 gap
entries and a five-entry `fixture_notes:` key. Verified during synthesis:
`grep -l on_conflict spec/conformance/cases/*.yaml` matches **four** files —
**1013** (url_grammar, `on_conflict` as a reserved query param), **1307**,
**1377**, **1378** (representations/mutations upserts) — and **none in the
1650–1688 band**; `on_conflict`, `L357`, `L358`, `L239` and `L245` appear nowhere
in `openapi.yaml`.

1. **The `/rpc/*` path item's per-operation `produces` and `responses.200` — no
   case, no gap entry.** `makeProcPathItem` gives every routine operation a
   fixed three-element `produces` list and a single `200` response whose
   `description` is `"OK"`
   ([`OpenAPI.hs#L357-358`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/src/library/PostgREST/Response/OpenAPI.hs#L357)).
   Every `/rpc/*` item in every document carries both. The area's rpc cases
   (1670–1674, 1683–1685) read `summary`, `description`, `parameters` and the
   presence of `get`/`post`, and **stop short of the response block**.
   **Distinguish this from the two lists case 1688 pins**: 1688 asserts the
   *document-level* four-element `produces`/`consumes`
   (`OpenAPI.hs#L405-406`), and case 1687 asserts the *root path item's* own
   two-element `produces` (`#L367-376`). This is a **third** list, on a third
   scope, and case 1687's own `notes:` explicitly flags the root/data distinction
   without noticing that the routine scope is a third one. **Citable but
   uncovered, case-only**: one case reading
   `$.paths['/rpc/<fn>'].post.produces` and
   `$.paths['/rpc/<fn>'].post.responses['200'].description` over a routine the
   fixture already exposes (`test.three_defaults` and `test.many_out_params` are
   both in the document — 1683/1685 read them today).

2. **The shared `$.parameters.on_conflict` definition — no case, no gap entry.**
   `postgrestSpec` emits a fixed set of shared parameter definitions, and
   `on_conflict` is one of them
   ([`OpenAPI.hs#L239-245`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/src/library/PostgREST/Response/OpenAPI.hs#L239)).
   It appears in **every** document regardless of schema, role or configuration.
   Case **1686** proves the assertion shape works — it reads
   `$.parameters.preferParams` and asserts the whole definition object plus the
   **absence** of `enum` — so this is the same request, the same JSONPath depth
   and a sibling key. **Citable but uncovered, case-only**, and arguably the
   single cheapest open item anywhere in this document.

**Correctly disclosed and verified accurate — do NOT re-raise these as findings.**
The audit independently re-read each of the following against v16.0 and confirmed
`openapi.yaml`'s justification holds. Every one is blocked on **new fixture
objects the pass declined to invent**, which is a materially different situation
from the two findings above:

- **Foreign table properties** (`OpenApiSpec.hs#L242-270`) — needs a FOREIGN
  TABLE `projects_dump` with a specific two-paragraph COMMENT.
- **Partitioned table properties** (`#L274-294`) — needs a PARTITIONED
  `car_models`. `test.car_models` exists (`fixtures.sql#L740`) but is an ordinary
  compound-PK table built for the headers area's multi-PK `Location` cases;
  altering it would break those.
- **Materialized view properties** (`#L298-326`) — needs
  `materialized_projects`.
- **A VIEW whose source FK targets a UNIQUE (not primary) key** (`#L330-343`) —
  needs the `referrals`/`pages` pair.
- **A one-to-one FK description** (`#L225-238`) — needs the `first`/`second`
  pair; case 1660 covers the many-to-one shape only.
- **`fk points to destination TABLE instead of the VIEW`** (`#L347-360`) —
  `test.projects` and `test.clients` exist with exactly that FK
  (`fixtures.sql#L591-601`), but the openapi GRANT block
  (`fixtures.sql#L2009-2013`) does not grant anon SELECT on `projects`, so under
  the default follow-privileges mode it is **absent from the document**. The pass
  verified this by fetching the live document from a loaded `bier_test`.
- **The INOUT-with-DEFAULT leg of `OpenApiSpec.hs#L1032-1038`** — upstream's
  `many_inout_params(INOUT num int, INOUT str text, INOUT b bool DEFAULT true)`
  witnesses two rules at once; case **1684** covers the no-DEFAULT half over
  `test.single_inout_param`, and the DEFAULT half needs a routine with both kinds
  of INOUT parameter, which the fixtures do not have.
- **Accept-Profile schema scoping of the document**
  (`IgnorePrivOpenApiSpec.hs#L49` for tables, `#L81` for functions) — not new at
  v16.0 (the identical blocks ran under v14.12's `testIgnorePrivOpenApiCfg`,
  `SpecHelper.hs#L189-190`). Uncased because the shared conformance instance
  exposes **23** schemas at once, so the exact present/absent path set for a
  given profile is a property of Bier's fixture layout rather than of an upstream
  fixture. **Note the tension with finding 1 of this section**: the pass fixed
  every case's `schema:` label *because* profile scoping is real, and then
  correctly declined to assert the scoping itself, because doing so needs a
  two-schema instance with non-overlapping relation names.

**Modelled in full, correctly disclosed, and blocked on the harness — not a
defect, but it is the one uncased public config option in this area.**
`openapi-server-proxy-uri` lives under `openapi/root/server-proxy-uri` with
`cases: []`, and the entry states the expected document fragment exactly:
`host == "postgrest.com:443"`, `basePath == "/"`, `schemes == ["https"]`, printed
verbatim by `docs/references/configuration.rst#L854-870` and independently
re-derivable from `pickProxy`/`proxyUri` (`OpenAPI.hs#L416-451`) plus
`postgrestSpec`'s wiring (`#L392-393`, `#L401`, `#L410-411`). The block is the
frozen harness: a config-carrying case is served from its own instance **only**
when its id is in `@variant_case_ids`
(`test/support/conformance_server.ex#L58-59`). **Verified during synthesis that
the list is exactly 1467–1473, 1491, 1493, 1654, 1677, 1678, 1680, 1682, 1703,
1758, 1763, 1764 — 18 ids** — so a config-carrying case outside it falls through
`url_for/1` to the shared auth instance, its config silently ignored, and would
read `$.host == "127.0.0.1:<port>"`. The pass shipped exactly that case as
**1689**, saw the red, and **withdrew it**. Closing this is a one-line harness
edit followed by restoring the case verbatim from the entry; it is the one
deliverable of the openapi pass that a `spec/`-only change cannot complete.

**Two further `harness_gate:` entries are open in the same file** and have the
same shape: the `openapi-mode = disabled` / `db-root-spec` precedence of
`ApiRequest.hs#L122` (needs **both** keys set at once) and any second
`openapi-mode = ignore-privileges` case beyond **1677**. Both need
`@variant_case_ids` entries; both were recorded rather than written-and-broken.

### content_negotiation (adversarial review verdict: **revise** — 7 missing-coverage findings, **0 citation defects**)

**0 citation defects**, and the **largest finding count any single area audit has
produced** — seven, against the area that had been silent since the tree was
built. All seven are ***citable but uncovered***: upstream asserts every one at
v16.0 with a fetchable `it`-block, and the existing `case.schema.json` shape
expresses all of them. **All seven are case-only.** The area's own model records
none of them — `content_negotiation.yaml` still carries no `gaps:` key — so this
section is the only place they exist. See **Review status** and follow-up 19.

1. **The `db-plan-enabled = false` gate — no case pins the 406.** The model
   states the rule **twice** (`plan_parameters.gated_by_config` →
   `Plan/Negotiate.hs#L74`, and the last claim under `behaviors.plan`), and five
   cases — **1625, 1626, 1627, 1628, 1643** — carry it as a `preconditions:`
   string ("Requires db-plan-enabled = true; otherwise the plan media type does
   not resolve and negotiation returns 406 / PGRST107"). **The harness never
   executes `preconditions:`**, so those five sentences assert nothing, and the
   406 they describe — which upstream asserts at
   [`PlanSpec.hs#L544`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/PlanSpec.hs#L544)
   — is pinned by no case in any band. **This is the tree's clearest instance of
   a documented config gate that is described five times and tested zero.**
   Closing it needs one case requesting a plan media type under the *default*
   config and asserting 406/PGRST107 — and, because the shared instance's
   `db-plan-enabled` state decides the answer, it also needs the harness question
   in follow-up 9 settled, or an entry in `@variant_case_ids`. *Citable but
   uncovered; case-only, but harness-gated in the same way the select aggregate
   cases are.*
2. **The `*/*` ("Any") handler's `Content-Type` override — no case.**
   `media_type_handlers.rst#L227` documents that the default
   `application/octet-stream` `Content-Type` an `*/*` handler produces **can be
   overridden from inside the function** via `response.headers`, and that the
   function may **reject** non-matching types. Case **1638** covers only the
   default half (`GET /rpc/ret_any_mt` → `application/octet-stream`); neither the
   override nor the rejection has a case. Upstream:
   [`CustomMediaSpec.hs#L346`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/CustomMediaSpec.hs#L346).
   *Citable but uncovered; case-only.*
3. **The `*/*` handler on TABLES and VIEWS — no case.** The model's
   `negotiation.handler_lookup_order` step (1) is the `(RelId, MTAny)` probe, and
   the documented consequence is that such a handler **overrides all others** for
   that relation. Every existing case exercises the *function* flavor (1638);
   **nothing exercises the relation flavor**, so the step this tree models first
   is the step it tests least. Upstream:
   [`CustomMediaSpec.hs#L369`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/CustomMediaSpec.hs#L369).
   *Citable but uncovered; case-only.*
4. **Overriding the builtin `application/geo+json` handler for a single
   relation — no case.** The model asserts it (`behaviors.geojson`, fourth
   claim): geo+json is *not* a vendored type, so an aggregate over the row type
   replaces it while the builtin `Content-Type` is kept. The three geojson cases
   on disk (**1616**, **1617**, **1618**) cover the FeatureCollection, the empty
   collection and the missing-geometry 400 — **none covers the override**. This
   is the same rule case 1637 pins for `application/json`, unexercised on the
   other overridable builtin. Upstream:
   [`CustomMediaSpec.hs#L188`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/CustomMediaSpec.hs#L188).
   *Citable but uncovered; case-only.*
5. **q-factor ordering of the `Accept` list — modelled, and no case can
   discriminate it.** `negotiation.accept_list_construction` records that
   `iAcceptMediaType` runs the header through `parseHttpAccept`, which orders by
   q factor (`ApiRequest.hs#L71`), and even cites the upstream test. The tree's
   only q-carrying case, **1601**, sends a browser `Accept`
   (`text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8`) and
   resolves to `application/json` **whether or not the list is q-sorted** — the
   same defect shape the pagination audit found in case 1261, one layer up.
   Upstream's discriminating shape is at
   [`CustomMediaSpec.hs#L208`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/CustomMediaSpec.hs#L208).
   **A modelled rule with only a non-discriminating case is indistinguishable
   from an unmodelled one**; this is the second time this tree has recorded that
   exact failure. *Citable but uncovered; case-only.*
6. **`text/plain` and `text/xml` single-unnamed-parameter request bodies — no
   case anywhere in `spec/`.** `resource_representation.rst#L165-L171` lists all
   three alongside each other; the `application/octet-stream` sibling is case
   **1622**, and `grep -r 'unnamed_text_param\|unnamed_xml_param' spec/` matches
   only `COVERAGE.md` and `INDEX.md` — i.e. only the documents recording the gap.
   Upstream:
   [`RpcSpec.hs#L1168`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/RpcSpec.hs#L1168).
   **This entry is shared with *Known gaps → rpc*, where it is costed as
   fixture-blocked** — the two routines do not exist in `fixtures.sql`,
   `fixtures_local.sql` or `fixtures/rpc.sql`, and the blocker is *ownership* of
   the human-owned `rpc.sql` (follow-up 22). It is listed here too because the
   *docs page* is `media_type_handlers`, and because this pass proved the
   related point: the octet-stream flavor works only because of the routine's
   **return type**, which is exactly the property the text/xml twins would need.
   *Citable but uncovered; **fixture-blocked by ownership**, the one exception to
   this section's case-only rule.*
7. **The 1623 id-reuse leaves a documentation hazard, recorded as a finding
   rather than as bookkeeping.** The old case 1623 asserted the no-charset
   `Content-Type`; that assertion now lives inside case **1622**, and `1623`
   names an unrelated 406. Any document, commit message or issue predating this
   pass that cites "1623" for the charset rule now points at the wrong case.
   **Nothing mechanical can detect a stale id reference** — the id resolves, the
   file validates, the pin is right. See follow-up 26 for the rule that would
   have prevented it.

> **What this area did instead of writing a gap list is worth more than the list
> would have been, and it should be copied.** `content_negotiation.yaml` gained a
> top-level **`fixture_notes:`** key — three entries, each naming an object, the
> exact property its cases depend on, and what silently breaks if that property
> changes: `test.unnamed_bytea_param` **must** return the
> `"application/octet-stream"` DOMAIN (with plain `bytea`, case 1622 answers 406);
> `public."application/octet-stream"` must exist **and** be some routine's return
> type, because declaring a domain alone registers nothing; and `test.add_them`
> **must keep** its plain `integer` return, because giving it a mime-named domain
> would silently turn case 1623's 406 into a 200. **No other model in the tree
> records a fixture dependency at all**, and this is the area where that absence
> bit — see *Fixture write channels*. Every area whose cases depend on a
> *declaration* rather than on seed data should carry one.

### representations (adversarial review verdict: **pass** — 0 citation defects; findings CLOSED in-pass, one structural residual)

**0 citation defects**, and the tree's **third ✅ *pass*** verdict after `errors`
and `operators`. It is also the first *pass* verdict on a model that carried **no
gap list at all**, and the audit's most durable output is that the model now
carries one: `representations.yaml` gained a `gaps:` key with **five** entries
where it previously had none under any key.

The area went **24 → 32** cases (**8** added — 1315–1319, 1325–1327 — **1**
rewritten, 1309, **0** deleted, **no fixture object**, no
`representations.delta.sql`). Its band is **1300–1327 + 1330–1333**, so its only
free primary ids are **1328, 1329 and 1334–1349**; an earlier revision of
`conformance/INDEX.md` described 1315–1319 and 1325–1329 as empty spacing, which
was already stale before this pass and is now wrong twice over.

**What the audit closed, in-pass.** Every finding but one was turned into a case:

- the two remaining **`Location` suppressions** under `return=headers-only`, each
  sufficient on its own — a **bulk** insert (affected rows ≠ 1, the `CASE`
  guard's `ELSE` arm, `Query/Statements.hs#L48`, case **1315**) and a relation
  with **no PK at all** (`locationF`'s `WHERE json_data.key IN ('')` matches
  nothing, `array_agg` returns NULL and the coalesce falls through to
  `noLocationF`, `#L49` + `SqlFragment.hs#L223-L231`/`#L102-L103`, case **1317**);
- the complementary rule that `return=representation` carries **no** `Location`
  even on a PK'd table (case **1316**, `InsertSpec.hs#L228` — the area's only new
  case anchored at a Feature spec);
- three `Prefer`-parsing rules the model stated but never exercised: a
  **duplicate** `return=` resolving to the first token in **request** order
  rather than the first in `prefMap` (**1318**, `Preferences.hs#L100`/`#L165-L167`
  — `return=minimal, return=representation` yields the *minimal* response even
  though `Full` is listed first in `parsePrefs [Full, None, HeadersOnly]`); an
  **unrecognized** value being *ignored* rather than rejected (**1319**,
  `Preferences.hs#L133`/`#L140` + `Plan.hs#L207` — it lands in `invalidPrefs` and
  becomes a 400 PGRST122 **only** under `handling=strict`); and
  `Preference-Applied` rendering in the **fixed `prefsVals` order** independent of
  the client's token order (**1327**, `Preferences.hs#L179-L188`);
- both halves of *"`return=` is echoed only for mutations"* — on a plain read
  (**1325**, `Response.hs#L283`, `WrappedReadPlan`) and on an RPC (**1326**,
  `#L281`, `CallReadPlan`, the band's only `schema: rpc` case). Both also pin that
  it is **not an error**: the token is in `acceptedPrefs`, so it never reaches
  `invalidPrefs` and cannot trip the `handling=strict` guard.

**A citation was narrowed, and this is the finding to carry forward.** The model
cited `InsertSpec.hs#L745` for "a POST without `return=headers-only` carries no
`Location`". That block is under `describe "Inserting into VIEWs"` and posts to
`/compound_pk_view`, so it proved the rule **for a view only**. The model now
cites `#L157` (no-`Prefer`, on the `projects` TABLE) and `#L99`
(`return=representation`), and case **1309** was rewritten. Note what did *not*
catch this: the pin sweep (correct tag), schema validation (correct shape), and a
line-level "does the citation support the claim?" read (the line does support a
claim — a narrower one). **Read the enclosing `describe`, not the line.**

**A gap entry was CORRECTED rather than carried forward.** An earlier revision of
the `with_multiple_pks` / `compound_pk_view` entry claimed the `compound_pk_view`
leg "additionally carries a view-specific angle (key columns inferred through a
view) that 1309 does not cover". That is **false**: `car_models` is not in
`isolate_representations`' real-table list (`items`, `projects`, `clients`,
`complex_items`, `auto_incrementing_pk`;
`lib/mix/tasks/bier.fixtures.load.ex:460`), so under `schema: representations`
case 1309's target is the plain mirror **VIEW** `representations.car_models`.
1309 therefore *already* exercises composite key-column inference through a view.

**Open residual — one entry, and it is structural rather than unwritten:**

- **`is.null` in a headers-only `Location`** (`InsertSpec.hs#L783`, block
  L783–L794, asserting
  `Location: /test_null_pk_competitors_sponsors?id=eq.1&sponsor_id=is.null`).
  The mechanism is fully citable — `locationF` builds each pair as
  `key || '=' || coalesce('eq.' || value, 'is.null')`
  (`Query/SqlFragment.hs#L226`) — but a base table can never produce it, because
  `PRIMARY KEY` implies `NOT NULL`. Upstream reaches it only through
  `test_null_pk_competitors_sponsors`, a `LEFT JOIN` view over `competitors` and
  `sponsors` plus an `ON INSERT … DO INSTEAD` rule
  (`test/spec/fixtures/schema.sql#L754-L763`), and its two-column `Location`
  proves PostgREST treats **both** view columns as key columns because each
  traces back to a *different* base table's PK. `loader_exposure:` the three
  relations would have to exist under the `representations` schema, and since the
  area's mirror is view-only outside its five isolated real tables, a fixtures
  delta alone cannot reproduce a rule-based insert path. **Not case-only, not
  merely relation-blocked; see the note above.**

**Two further entries are recorded as deliberate non-gaps, not as omissions:**

- `with_multiple_pks` (`InsertSpec.hs#L756-L767`) and `compound_pk_view`
  (`#L770-L781`) are upstream's composite-PK headers-only `Location` targets and
  neither relation exists in the consolidated fixture. **No case was added on
  purpose**: case **1309** derives the identical claim onto `car_models`
  (`Location: /car_models?name=eq.Enzo&year=eq.2021`, `InsertSpec.hs#L142-L154`).
  Recorded so the omission reads as de-duplication rather than oversight.
- No upstream it-block asserts `Content-Range` on a **PATCH/DELETE that also
  sends `count=exact`**, so the `0-(N-1)/N` and `*/N` halves of the per-action
  entries are modelled from `Response.hs#L122-L124`/`#L161` rather than from a
  test. The `count=exact` half **is** cased for POST (1300, 1327 → `*/1`) and for
  DELETE (1320, `DeleteSpec.hs#L27-L34` → `*/1`); only the multi-row PATCH form is
  uncased here, and the **mutations** band owns that case (11400).

**The cost note.** Nothing in this section is on the cheap-work list: the one
open item needs a fixture *and* a cross-area ownership decision, and the other
two entries are arguments for *not* writing cases. That is the correct outcome
for a *pass* verdict — but do not read the short list as "almost nothing left",
because the area's own model now says where the remaining risk is and it is not
in this band.

### mutations (adversarial review verdict: **revise** — findings partly CLOSED in-pass; the residue is relation-blocked)

**0 citation defects.** This is the tree's thirteenth recorded v16.0 verdict and
the first whose findings were substantially addressed *before* this file was
written: the review drove **four** new cases (**11412–11415**) and **five** new
gap entries, taking `mutations.yaml` from 6 gaps to **11**. The verdict stays
*revise* because what remains is real, but read this section knowing the shape is
different from every other *revise* area — the open items are mostly **not**
"nobody wrote the case".

The area's bands: **1350–1399** is now **fully allocated** (50 ids, all in use),
and the pass opened an overflow band at **11400–11415** — **15** ids, and
**deliberately non-contiguous**: **11406 is absent**, because the case that would
have held it was written and then deleted (see below). **11416+ is free.** Like
`operators.yaml`, `mutations.yaml` **declares no overflow range**; the band exists
only as the ids on disk. That is now the **third** area in this situation and it
is the case follow-up 19 was written to prevent — see it before picking a number.

- **CLOSED in-pass: resource embedding on mutations, for every flavor the fixture
  DB can reach.** The review found the mutation flavor of resource embedding
  uncased. Four cases now cover it, each transcribing upstream's exact seed values
  with no derivation and no fixture change: **11412** (`DELETE
  /tasks?id=eq.8&select=id,name,project:projects(id)` → the to-one parent,
  `DeleteSpec.hs#L71`), **11413** (`PATCH
  /students?id=eq.1&select=name,students_info(address)` → one-to-one,
  `UpdateSpec.hs#L579`) and **11415** (`PATCH
  /users?id=eq.1&select=name,tasks(name,project:projects(name))` →
  many-to-many with a nested parent, `UpdateSpec.hs#L539`); POST + embed was
  already covered by representations case **1300**.
  **The residue is relation-shaped, not feature-shaped**, and the area records it:
  the DELETE one-to-one *reverse* direction (`DeleteSpec.hs#L91`, skipped by
  choice — same rule as 11412/11413), the four `web_content` self-reference
  flavors on PATCH (`UpdateSpec.hs#L432`, `#L471`, `#L513`, `#L740`) and on PUT
  (`UpsertSpec.hs#L558`), DELETE embed + top-level order on `artists`
  (`DeleteSpec.hs#L158`) and batch-upsert POST + embed on `artists`
  (`UpsertSpec.hs#L569`). **`web_content` and `artists`/`albums` must exist and be
  exposed under the `mutations` schema before any of those can be asserted;
  nothing about the embedding rules themselves is unknown.**

- **A case was authored and DELETED, and that is a finding, not bookkeeping.**
  **11406** was to assert PUT + `Prefer: return=minimal` (204, `Content-Type`
  absent, `Preference-Applied: return=minimal`,
  [`UpsertSpec.hs#L543`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/UpsertSpec.hs#L543)).
  It was dropped because case **1332** in the *representations* band already
  mirrors that it-block **and** asserts the empty body — same anchor, strictly
  stronger, only the derived relation differing. What is genuinely uncovered is
  the **case-sensitive-identifier** half of the same upstream block: upstream's
  target is the quoted `/UnitTest` relation (pk `"idUnitTest"`), and its camel-case
  POST siblings at `UpsertSpec.hs#L501-L530` assert merge-duplicates echoing both
  payload rows and ignore-duplicates echoing only the inserted one. `test."UnitTest"`
  exists nowhere in the fixture DB. **Relation-blocked.**

- **Composite-pk UPSERT is only PARTLY caseable, and the model argues it leg by
  leg rather than as one gap.** Upstream asserts every leg twice — once on
  `employees` (pk `first_name`+`last_name`, plus a `money` column rendered
  `'$24,000.00'`) and once on the partitioned `car_models` (pk `name`+`year`).
  `employees` is absent; **`car_models` is present** —
  `test.car_models(name text, year integer)`, `fixtures.sql:710-715` — but seeds
  **zero rows**, and that is what decides each leg:
  - **POST merge-duplicates IS derivable** and is cased as **11414**
    ([`UpsertSpec.hs#L62`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/UpsertSpec.hs#L62)):
    with an empty table both payload rows simply insert and upstream's assertion
    holds verbatim (201, `Preference-Applied: resolution=merge-duplicates,
    return=representation`, both rows echoed in payload order), minus upstream's
    third column `car_brand_name`, which the fixture table lacks.
  - **POST ignore-duplicates is NOT derivable** (`#L189-L199`): the whole
    assertion is that the *conflicting first row is omitted* from the RETURNING
    set, which cannot happen with nothing to conflict against.
  - **The PUT *update* leg is NOT derivable** (`#L453-L463`): it first GETs a
    seeded `DeLorean/1981` row and PUTs over it; with no seed it degenerates into
    the insert leg, which **11408** already covers from upstream's own
    "succeeds on a partitioned table with composite pk" (`#L388`).
  - **11409** (partial composite pk → **405 PGRST105**) is the one genuinely
    *derived* case here, from upstream's `employees` block at `#L332-L342`.
  **Cheapest fix in this section**: seed `test.car_models` with `Murcielago/2001`
  (leg b) and `DeLorean/1981` (leg c). Verified during synthesis that neither
  collides with 11408's `Supra/2021` nor with the `Enzo/2021` of cases 1309/1562.

- **The GENERATED ALWAYS insert error (428C9) is the area's one *behavior change*
  across the pins and has no case.** `InsertSpec.hs` dropped the
  PostgreSQL-version conditional in v16.0, so the rejection is now unconditional —
  a direct consequence of v16.0 dropping PostgreSQL 13. The model records the rule
  under `missing_default.generated_always_column`. **Relation-blocked, and
  specifically so**: upstream's target is `foo(a text, b text GENERATED ALWAYS AS
  (…) STORED)`, and **no `is_generated='ALWAYS'` column exists anywhere in `test.*`
  or `mutations.*`**. It additionally needs a **real table**, not the area's view
  mirror, which does not preserve the generated-column rejection.

- **`?columns=` on PUT: a modelled rule WITHDRAWN for having no source.** The
  section header previously claimed `columns=` applies to PUT. Nothing at v16.0
  says so: every `columns=` occurrence in `UpsertSpec.hs` is a POST (L108/L121/L134,
  L236/L248/L260), the docs reference `specify_columns` only from Insert
  ([`tables_views.rst#L565`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/docs/references/api/tables_views.rst#L565))
  and Update (`#L607`), and the PUT subsection states the opposite — "All the
  columns must be specified in the request body, including the primary key
  columns" (`#L689`). The claim is **withdrawn rather than approximated**;
  `applies_to` now reads `[POST, PATCH]`. **Nothing to case until upstream asserts
  it** — but note the failure mode, because no sweep in this document detects it:
  an *unexercised model entry* is unverified by construction, however well-cited
  its neighbours are.

- **Cross-area duplication the pass completed rather than resolved — the one
  *editorial* open item, and it is case-only either way.** The PGRST114
  "limit/offset querystring parameters are not allowed for PUT" rule is now
  asserted **four times in two areas** from the same two upstream it-blocks:
  `limit` by url_grammar **1016** and mutations **1383**
  (`UpsertSpec.hs#L295`, identical request `PUT
  /tiobe_pls?name=eq.Javascript&limit=1`), `offset` by url_grammar **1030** and
  mutations **1399** (`#L302` vs `#L303`, the same block, identical request).
  Verified by reading all four: they differ only in `schema:` label (`test` vs
  `mutations`) and in how much of the mechanism their `notes:` explain — 1016/1030
  cite `ApiRequest.hs#L178`, `Error.hs#L111/#L158/#L185` and `QueryParams.hs#L152`'s
  `offset`→`limit` rewrite, while 1383/1399 do not. The pass did **not** create the
  duplication (1383 predates it) but it **completed the symmetry** by adding 1399
  instead of reusing 1030 — the opposite call from the one it made on 11406 twenty
  ids earlier, with no rule on disk distinguishing the two.
  **Decide once**: keep both pairs as deliberate profile-variant coverage (and say
  so in both models), or retire the weaker pair. Either way it is case-only.

- **Relations upstream targets that the consolidated fixture simply lacks —
  enumerated so nobody re-derives them.** `compound_pk`/`compound_pk_view` (bulk
  insert + composite `Location`, `InsertSpec.hs#L257-L281`/`#L770-L781`; case
  **1352** derives the bulk half onto `no_pk` and representations case **1309**
  the `Location` half onto `car_models`), `withUnique` (unique-constraint 409,
  `#L320-L322` — derived onto `single_unique` as **11401**), `with_multiple_pks`
  (`#L756`), `test_null_pk_competitors_sponsors` (a `Location` with a null pk
  component, `#L783-L791`), `tbl_w_json`, `bitchar_with_length`, `items3`,
  `empty_table`, `complex_items_view` (the **VIEW** flavor of `missing=default`,
  `InsertSpec.hs#L514-L527` and `UpdateSpec.hs#L395-L400`), `app_users`
  (column-privilege DELETE, `DeleteSpec.hs#L122-L133`), and
  `unsafe_update_items`/`unsafe_delete_items` (`PgSafeUpdateSpec.hs#L53-L66`, the
  pg-safeupdate-**disabled** spec, which additionally needs an instance whose
  `db-safe-update-tables` excludes them — a harness variant, not just a fixture).
  Also absent: the three SERIAL / GENERATED-BY-DEFAULT surrogate-pk tables
  `surr_serial_upsert`, `surr_gen_default_upsert` and the case-sensitive
  `Surr_Gen_Default_Upsert` behind `UpsertSpec.hs#L107/#L120/#L133` and
  `#L235/#L247/#L259`, which must be **real tables** under `mutations` because the
  view mirror carries neither column DEFAULTs nor identity.

- **Not a gap, but the constraint every future mutations case inherits.** The
  `mutations` schema is a view mirror of `test` except for ten relations
  `isolate_mutations/1` replaces with real tables (`items`, `articles`,
  `complex_items`, `tiobe_pls`, `simple_pk`, `no_pk`, `single_unique`,
  `compound_unique`, `safe_update_items`, `safe_delete_items` —
  `lib/mix/tasks/bier.fixtures.load.ex:541-544`, hard-coded, so a fixtures delta
  alone can never extend it). **Ten of the pass's seventeen new cases target
  relations outside that list** (11402, 11403, 11408–11415), so nine of them write
  through auto-updatable views straight onto the shared `test.*` tables and are
  contained only by `db_tx_end: :rollback`
  (`test/support/conformance_server.ex:194`). The area's own gaps disclose this.
  Two consequences worth stating: a new mutations case against an un-isolated
  relation inherits the dependency **silently**, and a change to `db-tx-end` on
  the shared instance would corrupt the read-only areas rather than fail a case.

- **`preconditions:` — this area is the heaviest user of a key the harness never
  executes.** **25** of its 65 cases carry one. They pass only because
  `mix bier.fixtures.load`'s `isolate_mutations` pre-bakes the same state and the
  server rolls each request back, so the listed SQL is documentation of a required
  starting state rather than a setup step. **All 17 new cases carry
  `preconditions: []`**, which is the right response to the constraint. Either wire
  the key up in the harness or re-document it as advisory; see follow-up 25.

### rpc (adversarial review verdict: **revise** — findings are *citable but uncovered*)

**Five** missing-coverage findings, **0 citation defects** — the largest finding
count any single area audit has produced, against an area that had *just* been
re-synced. Every anchor below was re-fetched from
[`RpcSpec.hs` at v16.0](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/RpcSpec.hs)
during synthesis and reads as claimed; the file is 1500 lines at this pin.

The area's band **1400–1443** is contiguous and **1444–1449** is free before the
auth band starts at 1450 — six slots, which is not enough for all five findings
if each takes more than one case. Note the area's own `gaps:` list does **not**
record any of the five: counted on disk, `rpc.yaml` carries **seven** gap entries
and they cover multi-request sequences, `params=single-object`, singular-media
ownership, `loader_exposure`, the global `Vary` header, the two delegated
preference legs and the stale `rpc.sql` provenance pin — none of them these.
**The absence of a gap note is itself part of each finding**, and it is the
reason a *revise* verdict landed on an area that had just been re-synced: the
model is thorough about what it deliberately declines and silent about what it
never considered.

- **Untyped functions — routines returning `record` / `SETOF record` have no
  model entry, no case, and no gap note.** The v16 docs page carries a dedicated
  H2 *Untyped functions*; upstream asserts it in two `it`-blocks,
  [`RpcSpec.hs#L486`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/RpcSpec.hs#L486)
  (`it "returns a record type"` — `POST /rpc/returns_record` with an empty body →
  `{"id":1,"name":"Windows 7","client_id":1}`, plus `returns_record_params` with
  a JSON body) and
  [`#L496`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/RpcSpec.hs#L496)
  (`it "returns a setof record type"` — the two-row array, plus the `_params`
  twin). **Verified across the whole tree, not just the area**: `grep -rniE
  "returns_record|setof record|untyped function" spec/` returns **zero** matches,
  so nothing anywhere covers it or explains its absence. **Fixture-blocked** —
  none of the four routines is in `fixtures.sql`, `fixtures_local.sql` or
  `fixtures/rpc.sql`; see the ownership caveat above.

- **Functions with array parameters — a NON-variadic array-typed parameter is
  bound by three distinct paths upstream and by no case here.** Another named H2
  of the docs page. Upstream's `context "proc argument types"` runs the same
  `varied_arguments` routine three ways:
  [`#L515`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/RpcSpec.hs#L515)
  a POST whose JSON body carries `"arr": ["a","b","c"]`,
  [`#L545`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/RpcSpec.hs#L545)
  a GET with the array **literal** `?arr=%7Ba,b,c%7D`, and
  [`#L564`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/RpcSpec.hs#L564)
  the same payload as an `x-www-form-urlencoded` body — all three echoing
  `"arr": ["a","b","c"]` back. **This is a different rule from the VARIADIC one
  the tree already models** (`rpc.args.variadic.*`, cases 1415/1416 and the new
  1442): variadic parameters collect *repeated* scalars, array parameters take
  *one* array-shaped value. The only place array parameters appear anywhere in
  `spec/` is the **openapi** area, and only as schema *output* — cases 1667
  (`openapi/types/mapping`), 1671 (`openapi/rpc/get-params`) and 1673
  (`openapi/rpc/post-body`) assert the generated document's type mapping, never an
  invocation. **Fixture-blocked, and specifically so**: the fixture set's only
  array-parameter routine is `test.varied_arguments_openapi`, whose body is
  `SELECT json_build_object('double', double, 'integer', "integer")` — it accepts
  fifteen array parameters and **echoes none of them**, so it cannot assert
  binding. Upstream's `varied_arguments` (which does echo) is absent.

- **Functions with a single unnamed parameter — the `text` and `xml` flavors have
  no case, and only the `bytea` flavor is covered, from another area.** Upstream
  asserts all three side by side:
  [`#L1170`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/RpcSpec.hs#L1170)
  (`POST /rpc/unnamed_text_param`, `Content-Type: text/plain`, body echoed
  verbatim), [`#L1177`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/RpcSpec.hs#L1177)
  (`/rpc/unnamed_xml_param`, `text/xml`, the `<note>…</note>` document echoed) and
  the bytea one immediately after. Bier covers **only** bytea, and from the
  *content_negotiation* area: cases **1622**/**1623**, both `POST
  /rpc/unnamed_bytea_param` with `application/octet-stream`. Two consequences,
  and the second is the one that matters: `rpc.single_unnamed_param.*` models only
  the **json** flavor, and the `MTTextPlain` / `MTTextXML` branches of the PGRST202
  "no such function" envelope
  ([`#L1207`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/RpcSpec.hs#L1207),
  rendered at `Error.hs#L262-L264`) are **never exercised** — the tree pins the
  json branch (case 1439, `RpcSpec.hs#L1158`) and nothing else. Verified on disk:
  `text/xml` appears in **no** case file, and `text/plain` in exactly one (1641,
  a content-negotiation precedence case unrelated to unnamed parameters).
  **Fixture-blocked**: `unnamed_text_param`, `unnamed_xml_param` and
  `unnamed_int_param` (the routine upstream's PGRST202 cases probe) are all
  absent.

- **Resource Embedding on table-valued functions — covered only incidentally, by
  a case in another area whose subject is something else.** The docs' *Table-Valued
  Functions* section states that functions returning a table type "can also use
  Resource Embedding", and upstream gives it a dedicated context — `context
  "foreign entities embedding"` /
  [`#L324`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/RpcSpec.hs#L324)
  `it "can embed if related tables are in the exposed schema"`, asserting
  `/rpc/getproject?select=id,name,client:clients(id),tasks(id)` by **both** POST
  and GET. `spec/rpc.yaml` has neither an entry nor a gap note. The only case in
  the tree that exercises the shape is **1023**, in the `url_grammar` band, whose
  actual subject is that `/rpc/<fn>` resolves within the `Accept-Profile`-selected
  schema — the embed is incidental to it. **Case-only, and cheap**: verified in
  `fixtures.sql` that `test.getproject(id int) RETURNS SETOF test.projects` is
  `STABLE` (so the GET leg works — case 1422 already relies on that) and that
  `test.clients` and `test.tasks` both exist, so the upstream request reproduces
  verbatim with no delta.

- **`?columns=` on a POST to `/rpc/<fn>` — no case in any area.** MINOR,
  note-only in the reviewer's assessment, and recorded so it is not re-derived.
  Upstream's `context "only for POST rpc"` asserts at
  [`#L855`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/RpcSpec.hs#L855)
  that `POST /rpc/sayhello?columns=name` with a body carrying three extra keys
  (`smth`, `other`, `fake_id`) succeeds and returns `"Hello, John"` — i.e. the
  `columns` parameter filters the RPC argument payload exactly as it filters an
  insert payload. The tree covers `?columns=` only on **table** mutations
  (mutations area, `columns-param` sub-feature). **Case-only**:
  `test.sayhello(name text)` is in `fixtures.sql` and already backs cases 1400 and
  1443.

### operators (adversarial review verdict: **pass** — both findings MINOR / non-blocking)

The tree's **second** ✅ pass verdict, after errors. Two findings, **0 citation
defects**, both explicitly marked non-blocking by the reviewer, both *citable but
uncovered* and both **case-only**. A third item below is not a review finding but
a residual of the pass's own work, and it is the cheapest open item in this file.

The area's bands: the primary band **1050–1099 is fully allocated** (50 ids, all
in use), and the pass opened an overflow band at **10200–10236** (37 ids,
contiguous, no gaps). **10237+ is free.** Note `operators.yaml` does **not**
declare a closed overflow range the way `filters.yaml` does for
`[10600..10799]` — that is worth settling before the next author picks a number
(follow-up 19).

- **`not.plfts` / `not.phfts` / `not.wfts` have no case.** MINOR, non-blocking.
  Upstream asserts the negated form of each full-text operator separately —
  [`QuerySpec.hs#L253`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/QuerySpec.hs#L253),
  `#L260`, `#L279` (tsvector columns) and `#L436`, `#L452`, `#L477` (the
  to_tsvector-coerced text columns). **Why this is non-blocking rather than
  actionable**: the `not` prefix is not per-operator behavior. It is a single
  parse-level flag rendered as one `NOT` wrapper
  (`grammar.not_prefix` in `spec/operators.yaml`), and the tree already pins it on
  `fts` at **both** flavors — case **1090** on a tsvector column, case **10227**
  on a to_tsvector-coerced text column — plus **twelve** other operators, counted
  on disk: `eq`, `lt`, `gt`, `gte`, `lte`, `in`, `is`, `like`, `ilike`,
  `isdistinct`, `cs` and `cd`, across cases 1051, 1052, 1054, 1061, 1066, 1089,
  1098, 1099, 10203, 10208 and 10214–10216. The three missing operators would take
  six cases (three operators × the tsvector and coerced flavors) to exercise the
  same wrapper a fourteenth through nineteenth time. Recorded so a later audit does
  not re-derive it as a gap; not prioritized.

- **No case puts an fts filter inside an `or=()` logic tree with three different
  dictionaries.** MINOR, non-blocking. Upstream's `it "can be used with or query
  param"` runs at
  [`QuerySpec.hs#L287`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/QuerySpec.hs#L287)
  (tsvector columns) and `#L494` (the coerced flavor), combining `fts(english)`,
  `fts(french)` and `fts(german)` in one `or=(…)`. **Why this is non-blocking**:
  both halves are pinned independently. Case **1099** puts `not.fts` inside an
  `and()` tree — so an fts operator surviving logic-tree composition is asserted —
  and `or=()` composition itself is owned and covered by the filters area
  (`filters/logical/or`). What is uncovered is only the *conjunction* of the two,
  plus the incidental fact that three `(language)` modifiers can coexist in one
  tree. Case-only if wanted: `test.tsearch` already seeds an english, a french and
  a german document.

- **Residual of this pass, not a reviewer finding: five of the eight `in.()`
  column types are unswept.** Upstream's `describe "IN and NOT IN empty set"`
  asserts `?<col>=in.()` → `[]` for **eight** column types across
  [`QuerySpec.hs#L1361–L1384`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/QuerySpec.hs#L1361).
  Cases **10200–10202** cover three (int, text, bool); **bytea, char, date, real
  and time** have no case. The **fixture is no longer the blocker** — the folded
  `test.items_with_different_col_types` declares all eight columns (`int_data`,
  `text_data`, `bool_data`, `bin_data`, `char_data`, `date_data`, `real_data`,
  `time_data`) and carries upstream's single seed row. So this is five case files
  in the free 10237+ slice, no delta, no config, no band decision — **the cheapest
  open item in this document**.

  > **Whether to write them is a real question, not a formality.** The empty-set
  > semantics are *type-independent by construction*: `pListVal` yields the
  > singleton `[""]` before any type is involved, and `pgFmtFilter` special-cases
  > it to `= ANY('{}')`
  > ([`SqlFragment.hs#L409`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/src/library/PostgREST/Query/SqlFragment.hs#L409)),
  > so the five missing cases would exercise the same branch the three existing
  > ones already do. Upstream writes all eight anyway, and this tree's rule is to
  > transcribe what upstream asserts. Either write the five, or record in
  > `operators.yaml` why three suffice — what is **not** defensible is the current
  > state, where the tree covers an arbitrary three-eighths of an upstream
  > `describe` with nothing on disk saying so.

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
  > than the errors area: **the tree contains 13 HEAD cases (1020, 1272, 1274,
  > 1275, 1277, 1284, 1425, 1681, 1756, 1760, 1761, 1762, 1771) and every one
  > expects a 2xx.** No case anywhere in **746** issues a HEAD request that
  > produces an error (re-derived mechanically at the 746-case state: 13 HEAD
  > cases, 0 with a non-2xx `expect.status`). The pagination pass added the
  > twelfth (**1284**, HEAD with a Range header that is ignored → 200) and the
  > observability pass the thirteenth (**1771**, `HEAD /` for the `Server:`
  > header) without closing the hole; the operators pass then added **37 cases and
  > not one HEAD**, the rpc pass **three more and not one HEAD**, and the
  > mutations pass **seventeen more and not one HEAD** — the last of these while
  > authoring 11400 and 11402, two cases whose whole subject is a bodyless
  > response with an exactly-specified header set. That is the
  > point: HEAD coverage grows on the success side only, or not at all, while the
  > denominator keeps rising. Any future HEAD-plus-error behavior will land in the
  > same blind spot, so the cheap fix is to close it once, in this band, rather
  > than per-finding.

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

Originally three missing-coverage findings, **0 citation defects**. **One is now
CLOSED** — by the *operators* area, not by filters (see immediately below) — so
two remain open on disk. The filters re-sync that produced cases 1191–1199 closed
a different set of gaps (embed null-filtering, third-level filters,
or-across-embeds) and did **not** touch any of the three. Each upstream anchor
below was re-fetched and read during that pass, so the line numbers are verified,
not carried over.

- **CLOSED this pass — `IN` / `NOT IN` with an empty set.** This entry read: "an
  entire upstream `describe` block with no entry, no case, and until now no gap",
  against
  [`QuerySpec.hs#L1359`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/spec/Feature/Query/QuerySpec.hs#L1359)
  (`describe "IN and NOT IN empty set"`, eleven it-blocks against
  `items_with_different_col_types`). Verified on disk: **six cases now issue an
  `in.()`-shaped request**, all in the operators overflow band —
  - **10200/10201/10202** — `?int_data=in.()`, `?text_data=in.()`,
    `?bool_data=in.()` → `[]` (L1362/L1365/L1368);
  - **10203** — `?int_data=not.in.()&select=int_data` → **all** rows,
    `[{"int_data": 1}]` (L1387);
  - **10204** — `?int_data=in.(    )` → `[]`, whitespace consumed by `lexeme`
    (L1391);
  - **10205** — `?int_data=in.( ,3,4)` → **400** / `22P02`, an empty *element* is
    not an empty *set* (L1395).

  The relation is folded: `test.items_with_different_col_types` is now in
  `fixtures.sql` with all eight typed columns and upstream's single seed row (via
  `operators.delta.sql`). **The previous entry's "verified: `grep -c` → 0" no
  longer holds and has been replaced rather than carried forward.**

  > **Two things this closure teaches, both worth more than the closure.**
  > (1) **The band question answered itself the right way round.** The entry said
  > "decide the owning band first: the *value grammar* is filters, but the `in`
  > operator's SQL rendering is claimed by operators". It landed in **operators**,
  > and that is defensible on the evidence: `operators.yaml` already modelled the
  > `[""] -> "= ANY('{}')"` branch
  > ([`SqlFragment.hs#L409`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/src/library/PostgREST/Query/SqlFragment.hs#L409))
  > and the pass extended that model with the `lexeme` whitespace rule
  > (`QueryParams.hs#L283`) rather than duplicating it in filters. It also avoided
  > filters' full primary band. **One of the three `in.`-shaped ownership
  > questions is therefore settled; two are not** (see
  > `conformance/INDEX.md` → *Cross-area ownership caveat*).
  > (2) **The residual is real and is now filed under operators**: only three of
  > the eight column types are swept. See **Known gaps → operators**.

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
  **Lowest severity of the three as originally filed — and now, with the `in.()`
  entry closed, the lower-severity of the two that remain.** The shape is
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
  Mechanically, **60** HTTP cases carry a non-empty `config:` outside that list
  (re-derived on disk this pass; an earlier revision of this bullet said 59 and
  the follow-up list said 60 — 60 is correct, and the two are now consistent);
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
  **116** of the **746** cases carry a `config:` key (112 non-empty), spread over
  six areas: config 45, auth 33, observability 21, select 10, openapi 4, errors 3.
  **The count did not move for a FOURTH consecutive pass**: none of the operators
  re-sync's 37 new cases, none of the rpc re-sync's 3, none of the mutations
  re-sync's 17 and none of the representations re-sync's 8 declares a `config:`
  block, because none of those areas is config-gated. So the diverging set below is
  unchanged, and the ratio of unhonoured blocks improved only by dilution —
  **60** HTTP cases still carry a non-empty `config:` outside
  `@variant_case_ids` (re-derived on disk this pass against the harness's live
  18-id list), now out of **702** HTTP cases. **Five consecutive
  config-silent passes is itself worth reading**: the `config:` key is used
  almost exclusively by the six areas that already had it, and every re-sync since
  has been in an area that needs none. The 60 unhonoured blocks are therefore a
  fixed, aging set, not a growing one.

  > **The mutations band introduces a harness dependency of a different kind, and
  > it should be read alongside these.** Its cases declare no `config:` at all, so
  > nothing here is inert — but ten of the seventeen new ones depend on the shared
  > instance's `db_tx_end: :rollback` to contain writes through un-isolated view
  > mirrors. That is not a `config:` block being ignored; it is an *undeclared*
  > dependency on a shared-instance setting, which no mechanical check in this
  > document can surface. See **Known gaps → mutations**.

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
express them, so all three are actionable. **One has since been partly closed**:
the PGRST128 leg of the first finding is now case **1441**, authored by the rpc
re-sync (details inline below). The PGRST124 leg and the other two findings
stand.

- **`Prefer: max-affected` on RPC — the PGRST128 half is now CLOSED; the
  PGRST124 half remains open.** Upstream has a whole `context "test Prefer:
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
  (the RPC paragraph plus the closing `.. note::` that names PGRST128).

  > **Closed for PGRST128 by the rpc re-sync.** The last `it`-block of that
  > context is not a flavor of a generic preference — it is an RPC-only rule
  > decided in `callReadPlan` from the routine's return type
  > (`failMaxAffectedRpcReturnsSingle … if funcReturnsSingle rout then Left $
  > ApiRequestErr MaxAffectedRpcViolation`, `Plan.hs#L238`) — so the rpc area
  > took ownership rather than delegating: model entry
  > `rpc.prefer.max_affected.returns_single` and case **1441**, `POST
  > /rpc/ret_void` with `Prefer: handling=strict, max-affected=20` → 400 and the
  > verbatim four-key PGRST128 envelope. It needed **no fixture delta**: the
  > check never touches the arguments or the body, so the already-loaded
  > void-returning `ret_void` substitutes for upstream's
  > `delete_items_returns_void` (the substitution is recorded in the case's
  > `notes:`). `grep -rl PGRST128 spec/conformance/cases` now matches 1441 —
  > the only PGRST128 assertion in the tree.

  **Still open — the PGRST124 (count) half.** The other four `it`-blocks of the
  same context need routines that *do* return SETOF/TABLE **and** delete rows, so
  the row count is observable: `delete_items_returns_setof` /
  `delete_items_returns_table` with `max-affected=10` against 15 rows → 400
  PGRST124 (`"details": "The query affects 15 rows"`), and the same two with
  `max-affected=20` → 200 plus the 15-row body. Bier's only PGRST124 cases are
  table-flavored (1390–1392 mutations, 1555–1556 headers). **Actionable, but not
  free**: no equivalent routine exists in `fixtures.sql`, so this is a fixture
  delta plus case files — and because a mutating routine cannot live in the
  human-owned `rpc.sql`, the delta would land in schema `test` (see the
  `loader_exposure:` gap in `spec/rpc.yaml`). Decide the owning band first.

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

### observability (adversarial review verdict: **revise** — four missing-coverage findings, **0 citation defects**)

The verdict is *revise*, and unusually for this tree **none of the four findings
is closable by writing a case alone** except the last, which is deliberately left
open. Read them against the live docs page, whose three top-level sections are
**Logs**, **Metrics** and **Traces**: the tree covers most of *Traces* and
**nothing** of *Logs* or *Metrics*.

- **The entire Metrics section has no case — the largest structural hole in the
  tree.** The admin `/metrics` endpoint and every family the page documents —
  `pgrst_schema_cache_query_time_seconds`, `pgrst_schema_cache_loads_total`,
  `pgrst_db_pool_timeouts_total` / `_available` / `_waiting` / `_max`,
  `pgrst_jwt_cache_requests_total` / `_hits_total` / `_evictions_total`, and the
  `ghc_*` runtime family — are asserted by no conformance case. This is **not**
  an oversight: `spec/observability.yaml` models it in **five** entries and its
  `gaps:` names the blocker precisely — the metrics live on the admin server
  (`admin-server-port`), the harness knows only the main API base URL, and a case
  would need a `request.kind: admin` shape plus a Prometheus-text body matcher
  that `case.schema.json` does not have (`needed_assertion:
  admin_endpoint_request`). The reviewer verified the citation against
  [`test_admin.py#L132`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/test/io/test_admin.py#L132).
  **Cross-listed with `admin_server` below — they are the same wall from two
  sides**, and closing either closes both.

- **The Logs section has no case either, in both its halves.**
  - *Access-log line emission* (docs L15–L48): the Apache-combined format, the
    `-` placeholders for the user and byte-count fields, and the per-level line
    counts are asserted by **nothing**. Cases **1764–1767** assert only the status
    the level filter keys on, never a log line — and 1765/1766/1767's `config:`
    blocks are **inert** (see the next bullet), so even the level they name is not
    in force. Justified by the missing `expect.stdout_matches` assertion style,
    not by absence of upstream ground truth.
  - *SQL query logs* (`log-query`, docs L50–L74): no case. The model entry
    `observability.log_query.emits_sql` is **source-accurate** — the reviewer
    confirmed the gate at `App.hs#L223` and the rendering at `Logger.hs#L192-195`
    — but the SQL goes to **stderr**, so there is no request/response signal. The
    gap is justified. Worth flagging to the implementation side: Bier *has*
    the `log-query` CLI config key, so this is implemented-but-unpinned rather
    than absent.

- **`log-level` is not actually exercised by any case.** 1765/1766/1767 declare
  `log-level: warn|info|crit`, but the harness only boots variant instances for
  the ids in `@variant_case_ids` (`test/support/conformance_server.ex:58`, which
  carries 1758/1763/1764 from this band — re-verified on disk this pass), so those
  blocks are inert and the cases run at the shared `log_level: :error`. They
  assert log-level-independent statuses, so they remain sound — just narrower than
  their names, and each case's `notes:` now says so in as many words. Closing this
  needs **both** `needed_assertion: log_capture` and harness-owned changes to
  `@variant_case_ids`.

- **`server-trace-header` empty echo has no case, and is *blocked*, not merely
  unwritten.** PostgREST echoes the configured trace header with an **empty
  value** when the request omits it
  ([`App.hs#L289`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/src/library/PostgREST/App.hs#L289)).
  A case cannot be added under the frozen harness: the shared conformance
  instances set `server_trace_header`, and case **1573** (headers area) asserts
  `headers_no_blank: true` against that same instance, so the two assertions would
  contradict each other on the wire. It needs its own variant instance, i.e. an
  `@variant_case_ids` entry — frozen harness code. Listed under *issues* rather
  than *authoring*.

- **`Server-Timing` absent on error responses — uncovered *deliberately*, and the
  only promotable item here.** The model entry
  `observability.server_timing.success_path_only` derives it from the App.hs
  control flow: errors are rendered by `Error.errorResponseFor`
  ([`App.hs#L154`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/src/library/PostgREST/App.hs#L154))
  and never reach `toWaiResponse` (`App.hs#L253`), which is where the header is
  attached. It is **black-box observable and cheap to express** — unlike every
  other entry in this section. It is left uncased because **upstream asserts it
  nowhere**, and this tree's rule is not to pin behavior PostgREST does not check.
  Promote it to a case if the operator wants it enforced; that is a policy call,
  not a research one.

- **`Proxy-Status` on a HEAD request** — the docs' stated motivation for the
  header, exercised by no case. Cross-listed from **Known gaps → errors**; the
  behavior is method-independent in `errorResponseFor`, so it is MINOR. Note the
  observability pass added a thirteenth HEAD case (**1771**) that still expects
  2xx, so the tree-wide "no HEAD case ever errors" blind spot is untouched.

- **Closed this pass: the Server version header.** The previous revision listed
  "no case asserts the `Server: postgrest/<version>` response header" as a gap.
  Case **1771** (`HEAD /`, `headers_present: [Server]` +
  `headers_match: {Server: "^postgrest/.+"}`) closes it. Only the **prefix** is
  asserted, matching upstream, which derives the version from the header rather
  than hard-coding it (`test_io.py:1065`); the version component is
  `prettyVersion` (`Version.hs:23-26`), so pinning digits would assert the release
  number rather than the wire contract. This is the tree's first `Server:`
  assertion — an earlier revision of `spec/observability.yaml` wrongly delegated
  the header to the *headers* area, which carries no entry for it.

- **`Server-Timing` on OPTIONS — corrected this pass, and `lib/` is wrong.**
  Cases 1757/1768/1769 previously asserted
  `headers_absent_in_value: {Server-Timing: [plan, transaction]}`. PostgREST has
  no such behavior at v16.0 (nor at v14.12): `withTiming` branches only on
  `configServerTimingEnabled`
  ([`App.hs#L272`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/src/library/PostgREST/App.hs#L272)),
  so the plan (`App.hs#L210`) and transaction (`App.hs#L225`) stages are timed
  on OPTIONS too — `Plan.actionPlan` returns `NoDb …` and `MainTx.mainTx`
  returns `NoDbTx`, but both are still wrapped. A real `OPTIONS /organizations`
  response carries all five metrics. The absence assertions are gone; the three
  cases now assert only what upstream asserts (presence of jwt/parse/response,
  `ServerTimingSpec.hs#L87-L111`, whose matcher is presence-only). **Action for
  the conformance pass**: `lib/bier/plugs/observability.ex:159` still emits the
  three-metric OPTIONS header and must be fixed. Note the shape of this one — it
  is the only finding in the file where a *spec* error and a *`lib/`* error
  matched each other, so the suite was green on an invented behavior. No case
  pins the true five-metric OPTIONS shape either, because upstream asserts only
  presence of jwt/parse/response (`ServerTimingSpec.hs#L87-L111`) and this area
  does not pin what upstream does not check.

  > **One more docs sub-section under *Traces* is worth naming before someone
  > re-derives it as a gap: *Content-Length Header*.** It is not listed above
  > because it is covered from the pagination and errors bands rather than this
  > one — case **1282** asserts `Content-Length: 2` on the empty-window envelope,
  > and the errors model's `inline_416_content_length_suppressed_on_head` flag
  > (uncased, see **Known gaps → errors**) is the one leg still open. Recorded
  > here so the cross-band ownership is explicit.

### admin_server

- `/metrics` and `/schema_cache` endpoints have no case (`/live` and `/ready`
  are covered by ExUnit, not by the conformance suite). **Same blocker as
  *Known gaps → observability → Metrics*** — the harness has no request shape
  that targets the admin server (`needed_assertion: admin_endpoint_request`).
  This page and the observability page's Metrics section should be closed
  together or not at all; counting them as two independent gaps overstates the
  work.

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

Machine-verified on **2026-08-09** at commit **`9b72e09`**
("spec(content_negotiation): re-sync to PostgREST v16.0 (area 15/17)"), on
branch **`spec/postgrest-v16`**, against a tree **dirty mid-re-sync**: the
uncommitted openapi re-sync (34 modified spec files, 6 untracked cases —
enumerated in the header above). The checks cover the on-disk
state *including* those. No
repository file was modified by the verification — its scripts live in a
scratchpad outside the repo. **All six checks ran for real, none was
skipped, and all six came back clean: 0 defects.**

**Headline, stated plainly because it is unusual:** 746 case files, **0**
schema-invalid, **0** YAML parse errors, **0** duplicate ids, **0** stale
`source:` pins, and **0 *unexpected*** missing relations. The **20** relations the
relation check flags as absent all belong to cases that assert **404** or
**406** — their absence *is* the assertion. Every headline number was
**independently re-derived during synthesis** rather than transcribed from the
verification handoff: 746 files / 746 distinct ids / `{'v16.0': 746}` source tags
/ 0 schema violations, using PyYAML + `Draft202012Validator` over
`spec/case.schema.json`.

> **Two numbers in the handoff did not survive that re-derivation, and both are
> corrected here rather than reprinted.** (1) It reported "**22** non-system
> schemas" while enumerating **23** names; re-queried directly against `bier_test`
> the answer is **23**, so the label was wrong and the list was right.
> (2) It reported "**791** functions"; `pg_proc` holds **1034** rows in
> non-system schemas across **791** distinct `(schema, name)` pairs. 791 is the
> correct denominator for the check it fed — relation resolution is by name and
> overloads collapse — but it is not a routine count. **Neither error changes any
> pass/fail result**, and both are the kind that propagate silently once
> reprinted.

> **The absent-relation count moved 17 → 20 and NONE of the three is new.** The
> classifier that produced 17 and the one that produced 20 differ in how they
> resolve a case's `schema:` label to a live schema, not in what is on disk. All
> 20 are self-describing negatives: `test.first`/`test.invalid` (1001, 1002),
> the four `Accept-Profile: unknown` cases (1010, 1012, 1560, 1583),
> `v1.another_table` (1024 — it exists in `v2`, which *is* the assertion),
> `test.unknown`/`observability.unknown` (1034, 1765), three table-not-found
> mutations (1360, 1368, 1373), the unknown-proc pair (1432, 1443) and six
> errors-area PGRST205/hint cases (1515–1517, 1520, 1521, 1525). **Reporting them
> as missing would be a false alarm**, which is why `missing_relations` is `[]`.

> **Read that clean sheet against what the audits actually find, because the two
> keep sitting uncomfortably together — for the second consecutive pass.** The
> content_negotiation audit's most consequential discovery was a **fixture
> defect**: `test.unnamed_bytea_param` was declared
> `RETURNS bytea` where upstream returns the mime-named DOMAIN, which made case
> 1622's assertion unreachable. **Every check in this section passed on that
> case, before and after.** The relation check confirmed the routine *exists*;
> nothing checks how it is *declared*.
>
> **This pass supplies the same lesson in a second field, and it is arguably
> worse.** Thirty-one openapi cases carried `schema: openapi`, a **label naming a
> schema that does not exist**, and shipped `Accept-Profile: openapi` on every
> request. Not one of the six checks looks at `schema:` at all — the relation
> check resolves the *target*, and its label-resolution table treats an unknown
> label as a case that "deliberately sends `Accept-Profile: unknown`". A
> six-for-six clean run is evidence about shape, ids, pins and target existence —
> and about nothing else. **Two consecutive passes have now found a defect in a
> field no check reads.** See **Fixture write channels**, follow-up 28, and
> *Open verification findings* → item 2.

- **Fixture load: OK.** `mix bier.fixtures.load` exited **0** against
  `bier_test` (localhost:5432), reporting the same mirrored area schemas as every
  previous pass: `operators, ordering, pagination, representations, mutations,
  config, domain_representations`. No `psql` fallback was needed.

  > **This pass had NOTHING new to load, so the check is back to its weakest
  > form.** Neither `conformance/fixtures.sql` nor any file under
  > `conformance/fixtures/` appears in `git status`: the openapi re-sync added no
  > fixture object and opened no delta channel. A clean exit therefore proves
  > only that previously-folded DDL still loads. The load was run **twice**, clean
  > both times. It does **not** prove any case passes; **no `mix test` was run by
  > this verification.**
  >
  > **What that leaves unchecked is exactly what this pass's largest correction
  > touched.** Thirty-three cases changed their `schema:` label, and the fixture
  > load has no opinion about labels — it builds schemas, and
  > `mix bier.fixtures.load` reported the same seven mirrored area schemas it
  > always does (`operators, ordering, pagination, representations, mutations,
  > config, domain_representations`), none of which is named `openapi`. **That
  > report was the evidence for the correction, and it has been printed by every
  > pass for ten passes without anyone reading it against the labels on disk.**

  > **Retained, because it describes the previous pass:** unlike the three before
  > it, the content_negotiation re-sync HAD something new to load.
  > `fixtures.sql` *was* modified in `git status`: it gains the
  > `public."application/octet-stream"` domain (section 3c) and re-declares
  > `test.unnamed_bytea_param(bytea)` over it (section 6). A clean exit therefore
  > proves the new DDL loads and the edited routine still compiles — not merely
  > that previously-folded DDL still loads. It still does **not** prove any case
  > passes; **no `mix test` was run by this verification.** (The re-sync itself
  > reports an A/B suite run in the `fixtures.sql` fold note — identical failing
  > set, 96 ids, zero regressions and zero flips — which is a claim from the area
  > pass, not a measurement made here.)

  > **Retained, because it still applies to the other areas: this check is weak —
  > for the third consecutive pass.** The representations re-sync added **no**
  > DDL: `fixtures.sql` does not appear in `git status` and there is no
  > `representations.delta.sql`. A clean load therefore proves only that the
  > previously folded DDL still loads. It does **not** prove any case passes;
  > **no `mix test` was run this pass**.

  > **The representations band inherits the SAME undeclared write dependency the
  > mutations band does, in a smaller dose, and it is worth stating because the
  > previous revision named it as a mutations-only property.** Six of the eight
  > new cases mutate: **1315, 1318, 1319, 1327** POST to `complex_items` and
  > **1316, 1317** POST to `no_pk`. `isolate_representations/1`
  > (`lib/mix/tasks/bier.fixtures.load.ex:459-460`) replaces exactly **five**
  > relations with independent real tables — `items`, `projects`, `clients`,
  > `complex_items`, `auto_incrementing_pk` — so `complex_items` is isolated but
  > **`no_pk` is not**: `representations.no_pk` is a plain view mirror, and cases
  > 1316/1317 write through it onto `test.no_pk`. They are contained only by the
  > conformance server's `db_tx_end: :rollback`
  > (`test/support/conformance_server.ex:194`), exactly as nine mutations cases
  > are, and neither case declares the dependency. **The hard-coded five-table
  > list is the mirror image of `isolate_mutations/1`'s hard-coded ten**, with the
  > same consequence: a fixtures delta cannot extend it. The remaining two cases
  > (**1325** `GET /items`, **1326** `POST /rpc/add_them`) are pure reads. See
  > **Known gaps → representations** and follow-up 25.

  > **Post-load catalog, re-measured this pass rather than carried over — and
  > re-queried a second time during synthesis, not taken from the handoff.** The
  > non-system schema list is unchanged for an **eleventh** consecutive pass:
  > `SPECIAL "@/\#~_-`, `auth`,
  > `config`, `domain_representations`, `geotest`, `headers`, `headers_private`,
  > `jwt`, `mutations`, `observability`, `openapi_no_comment`, `operators`,
  > `ordering`, `pagination`, `postgrest`, `private`, `public`, `representations`,
  > `rpc`, `test`, `v1`, `v2`, `تست` — **23** non-system schemas
  > (`select count(*) from pg_namespace where nspname not like 'pg\_%' and
  > nspname <> 'information_schema'` → **23**; the handoff labelled the same list
  > "22"). Relations hold at **656**. This pass added **no** object of any kind,
  > so both totals are expected to be flat — which is why the flatness proves
  > nothing this time.
  >
  > **`openapi` is not in that list and never has been, which is the whole of the
  > label finding.** The one schema in the list whose name starts with `openapi`
  > is **`openapi_no_comment`**, created at `fixtures.sql#L247` for case 1654's
  > variant instance. Every other object the openapi area asserts over lives in
  > `test`. The list above has been printed by this document for eleven passes.
  >
  > **The function total finally has an explanation, and this retires three
  > contradictory numbers rather than adding a fourth.** Successive revisions have
  > reported **791**, then **1036**, and this pass measures **1034** — a swing far
  > too large for a tree that added no routine. The cause is not the tree: the
  > `public` schema carries the **pgcrypto** and **postgis** extensions
  > (`pg_extension` confirms both), and **827** of the 1034 are extension-owned
  > functions in `public`. Excluding `public` leaves **207** fixture-owned
  > routines (`test` 77, `rpc` 25, then 12 each in the seven mirrored area
  > schemas), and *that* is the number that tracks the fixture set. Any pass that
  > quotes a raw non-system function total is measuring PostGIS. **No case depends
  > on any of these counts; do not cite them as evidence of anything** — but if
  > one is quoted, quote the 207.
- **Case count: 746** — `ls spec/conformance/cases/*.yaml | wc -l` and the
  validator agree (746 files, 746 parsed), re-run independently during synthesis.
  **6** of the 746 were untracked at
  verification time (**1683**–**1688**) and **33** were modified — the entire
  committed openapi band, **1650–1682**. Nothing was deleted.
  **The ratio is the inverse of the previous pass's**: a net +6 on a gross churn
  of 39, so a reader comparing 740 → 746 will under-count the work by a factor of
  six and a half. **Rewrite-heavy passes are invisible to a case count**, and this
  is the most extreme instance the tree has recorded.
  Breakdown of the 746 by request shape, re-derived: **38** `request.kind: cli`
  + **51** root-path (`/`) cases + **657** relation-targeting HTTP cases.
- All **746** cases parse as YAML. **0** parse errors.
- All **746** cases validate against `case.schema.json` — **0** invalid cases
  (`invalid_cases: []`). Toolchain: PyYAML + jsonschema `Draft202012Validator`,
  over every `spec/conformance/cases/*.yaml`. Verification tail:
  `{"parse_errors": [], "invalid_cases": [], "case_count": 746}`. Re-run during
  synthesis with the same toolchain: `CASES 746 IDS 746 DUP [] INVALID 0`.

  > **The negative-control battery is NOT re-run every pass.** The controls
  > described below (unknown key, dropped `required` key, wrong-typed `id`,
  > malformed `source`) were run in an **earlier** pass on a mutated copy of
  > pristine case 1000 and proved the validator live rather than vacuous. This
  > pass ran the schema check itself plus `check_schema`, not the controls. The
  > distinction matters because the one control that **failed** — the stale-pin
  > rewrite — is what justifies the separate URL sweep, and that failure is a
  > property of the schema's pattern, which has not changed.
- **Every case carries all seven keys** — `id`, `feature`, `request`, `schema`,
  `expect`, `notes`, `source` present on all **746**, re-checked during synthesis
  by intersecting the key sets rather than by trusting the schema's `required` list
  (which names only six: `notes` is not required by the schema but is universal in
  practice). The full key vocabulary on disk is exactly those seven plus
  `preconditions` (on **745** — case **1330** still the only omission) and
  `config` (on **116**, four of them the empty `config: {}` — 1705, 1719, 1727,
  1743) — no case carries anything else. **42** of the 745 carry a *non-empty*
  `preconditions:` list, and **25 of those 42 are mutations cases** — the area is
  the heaviest user of a key the harness never executes (see
  **Known gaps → mutations**). Full non-empty distribution, re-derived at the
  746-case state: mutations **25**, content_negotiation **11**,
  pagination **4**, url_grammar **1**, representations **1**. All
  six new openapi cases correctly carry `preconditions: []`, which is
  the fourth consecutive pass to follow a convention nobody has written down.

  > **The 44 → 42 is the first DECREASE this key has recorded, and both removals
  > were also wrong.** The openapi area carried 2 and now carries 0. Case
  > **1654**'s precondition was `COMMENT ON SCHEMA test IS NULL`, which — had the
  > harness executed it — would have broken case **1656**, whose entire assertion
  > is that very comment appearing as the document title. Case **1672**'s was a
  > `CREATE FUNCTION` that omitted the `DEFAULT '{}'` on which 1672's own
  > `required: false` assertion depends. **Two statements that were inert, wrong,
  > and survived a full prior re-sync of this area.** An unexecuted key is not
  > neutral: it accumulates claims nobody can falsify. Follow-up 25.
  **Every `NNNN_` filename prefix equals the in-file `id:`** (0 mismatches,
  re-derived across all 746 including the **four** 5-digit bands).

  > **content_negotiation is the SECOND-heaviest user of the inert
  > `preconditions:` key, and this pass turned that from trivia into a finding.**
  > Its 11 non-empty lists did not move, but the audit showed what five of them
  > cost: **1625, 1626, 1627, 1628** and **1643** use the key to state the
  > `db-plan-enabled = true` requirement, and **no case pins the 406** that the
  > default produces. Where mutations' 25 inert preconditions are harmless
  > (`isolate_mutations` pre-bakes the same state) and pagination's three are
  > accidentally satisfied (the loader runs `ANALYZE`), these five describe a
  > **config gate that is genuinely untested**. That is the first time the inert
  > key has been shown to conceal missing coverage rather than merely to
  > duplicate satisfied setup. See **Known gaps → content_negotiation** and
  > follow-up 25.

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
- **746** files, **746** distinct ids — **no duplicate ids**. Cross-checked two
  independent ways: the verification's own duplicate map
  (`grep -h '^id:' … | sort | uniq -d | wc -l` → **0**, and
  `sort -u | wc -l` → **746** == the file count) and a
  synthesis-side re-derivation over the parsed `id:` values (`IDS_TOTAL 746
  UNIQUE 746 MIN 1000 MAX 12401`). The check keeps
  earning its keep: the tree now carries **four** 5-digit bands
  (operators **10200–10236**, mutations **11400–11405 + 11407–11415**, auth
  **11800–11818**, content_negotiation **12400–12401**), and a collision would be
  invisible in a lexical listing.
  Mutations' band lands **between** operators' and auth's numerically while
  sorting between `1140` and `1141` lexically — i.e. it interleaves with the
  *select* area's 1140-block, a third distinct false-neighbourhood in the tree.

  > **This check was load-bearing in the PREVIOUS pass in a way it had never been
  > before, and it passed for a reason no earlier pass could have produced.** The
  > content_negotiation re-sync **deleted a case and re-issued its id**: old
  > `1623_octet_stream_no_charset.yaml` is gone and
  > `1623_octet_stream_not_registered_scalar_rpc_406.yaml` carries `id: 1623`.
  > Had the deletion been staged but the file left on disk — or had the new file
  > been added before the old one was removed — this would be the tree's first
  > duplicate id. It is not: exactly one file carries 1623, and its filename
  > prefix matches. **Id uniqueness is now a check against a real editing
  > pattern, not a hypothetical one.**
  >
  > The **fourth** 5-digit band, 12400–12401, is also the first to land in an
  > *empty* lexical neighbourhood: `12400` sorts between `1232` and `1250`, into
  > the free 1233–1249 slice, so unlike the other three it interleaves with no
  > occupied block. That makes it the easiest of the four to miss in a listing and
  > the least likely to cause visible confusion — a combination worth naming.
  >
  > **This pass opened NO fifth band and consumed no id twice**, because the
  > openapi band had room: it grew 1650–1682 → **1650–1688**, contiguous, with
  > 1689 free. It is also the first pass to author a case and remove it before
  > commit (**1689**, withdrawn on a harness gate), so the id never entered the
  > uniqueness check at all — the cheapest of the three deletion conventions the
  > tree now carries. See follow-up 26.
- **Source pins: clean, single tag.** The verification's sweep over its mandated
  scope (`spec/*.yaml` + `spec/*.md` + `spec/conformance/*.md` +
  `spec/conformance/cases/*.yaml`) found **zero** non-v16.0 `source:` lines
  (`stale_pin_citations: []`), and its tag histogram over every PostgREST URL in
  the audited set reads `{'v16.0': 2119, 'v14.12': 3}` — the three `v14.12` hits
  being `spec/rpc.yaml:574` plus this document's and `README.md`'s
  meta-commentary about that one line, all of which the tree documents as
  correct. **746/746 cases carry a `source:` line**, and
  every one of them is v16.0 — re-derived independently during synthesis by
  parsing each case's `source:` value and extracting its tag
  (`{'v16.0': 746}`, no other value). The verification separately parsed every
  key literally named `source:` across the 746 cases **and** the 16 area `.yaml`
  models — **1250** structured fields, **0** off-pin — which synthesis reproduced
  exactly.

  > **The prefix-aware re-sweep finds exactly one `v14.12` URL, and that URL is
  > CORRECT rather than stale.** This file's own rule is to match
  > `postgrest/(raw/|blob/|tree/)?<tag>` rather than the raw host alone. Applying
  > it to the 17 area models plus all 746 cases (**763** files, **every one**
  > carrying at least one citation) yields **2051** `raw…/v16.0/` +
  > **3** `github.com/…/blob/v16.0/` = **2054** v16.0 links, and **one**
  > `github.com/PostgREST/postgrest/blob/v14.12/…` at **`spec/rpc.yaml:574`**.
  > Re-derived during synthesis with a scheme-optional, prefix-aware pattern; the
  > full histogram over the 763-file scope is
  > `{('raw.githubusercontent.com','v16.0'): 2051, ('github.com','v16.0'): 3,
  > ('github.com','v14.12'): 1}`.
  >
  > **The raw count grew +20 while the tree grew by +6 cases, and for the second
  > consecutive pass that ratio is the finding.** Much of the growth is *inside
  > existing files* — case **1683** alone cites six distinct lines in its `notes:`
  > (the `WHERE type IS NOT NULL` input-argument filter in `SchemaCache.hs`, the
  > `properties` and `required` lens defaults in `OpenAPI.hs`, and two upstream
  > aesonQQ literals that independently prove swagger2 drops default-valued
  > fields), because its single `source:` cannot carry the drop rule *and* the
  > `required`-is-absent rule *and* the safety of asserting the whole schema
  > object. The previous pass recorded the same shape at larger magnitude (+45 on
  > +5 cases, driven by case 1622).
  > **Citing inside `notes:` is the tree's only remedy for a case that
  > asserts more than one anchor can prove** — `case.schema.json` allows exactly
  > one `source:` — and it moves this number far more than new cases do. Do not
  > read link growth as case growth.
  >
  > **Both halves of the condition it reported are now closed.** The fixture half
  > closed at `6b25f05` (`fixtures/rpc.sql:15` reads `blob/v16.0/…` plus
  > "Re-pinned v14.12 -> v16.0 after verifying all 23 vendored routines…"; the
  > file carries **zero** `v14.12` URLs). The documentation half closed at
  > **`75388d6`**, which rewrote the `operator_action` entry to open "RESOLVED
  > 2026-08-09 (commit 6b25f05) — kept as a record, no action left" and then
  > **deliberately retains the original finding, quoted URL and all, for
  > provenance**. So the surviving `v14.12` URL is a quotation inside a closed
  > record. **Do not re-open it as drift, and do not delete it to make a sweep
  > read zero** — the retention is the point. See follow-up 24, now fully closed.
  >
  > Note what this means for the sweep as a *check*: a prefix-aware pattern will
  > report `v14.12: 1` forever, and that is the correct steady state. The
  > verification's raw-host-only pattern scores it 0 for a different reason (wrong
  > host), so the two agree by accident, not by construction.

  > **The `blob/v16.0` count is THREE, re-derived again this pass rather than
  > carried forward.** Enumerating *every*
  > `github.com/PostgREST/postgrest…` URL in the models+cases scope — a host match
  > with no tag pattern at all — returns exactly **four**: three `blob/v16.0`
  > (`spec/domain_representations.yaml:44` and `spec/select.yaml:27`, both prose
  > notes *about* URL shape rather than citations, plus **`spec/rpc.yaml:564`**,
  > the re-pinned URL inside the now-RESOLVED gap entry) and
  > the single `blob/v14.12` above. **A whole-tree sweep that also includes this
  > file and `README.md` sees SIX `blob/v16.0`** — the extra three are the two
  > meta-documents quoting the pattern at themselves, which is why the
  > models+cases scope is the honest one. Every other citation in the tree uses the
  > `raw.githubusercontent.com` host. The earlier "71 `blob/v16.0` links" figure
  > remains retired rather than reconciled. **The invariant is unaffected** — one
  > tag among citations, zero exceptions.
  >
  > **A prior sweep of this file missed both scheme-less `blob/v16.0` URLs** and
  > reported 1984 raw + 1 blob instead of 1986 + 3, because its pattern required
  > a leading `//`. That is the third time this document has recorded a
  > sweep-pattern defect (after the `blob/` prefix and the `https://` anchor).
  > **Match `(?:https?://)?(raw\.githubusercontent\.com|github\.com)/PostgREST/postgrest/(?:raw/|blob/|tree/)?<tag>`
  > and nothing narrower.**

  > **Two reference counts appear in this file and neither is wrong**; they
  > differ in *scope*. Including the synthesis documents (`README.md`, this file
  > and `conformance/INDEX.md`) the sweep sees more of everything, and the extra
  > `v14.12` hits outside the models are all those three documents *quoting*
  > `rpc.yaml`. Excluding them — the honest measurement, since counting a document
  > against itself proves nothing — the sweep sees **2051** raw + **3** blob at
  > v16.0 and **1** at v14.12. Including the meta-documents it sees **2113** raw +
  > **6** blob at v16.0 and **3** at v14.12, i.e. **2122** PostgREST URLs in the
  > whole `spec/` tree, of which **2119** are v16.0. The invariant that matters
  > holds under both, and
  > the sweep is the **only** check that enforces the pin — see the
  > schema-validation caveat above. Doc links in the area models and cases resolve
  > to `postgrest.org/en/v16` (**7** hits, no other version — re-derived this
  > pass, unchanged).

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

  > **Bare `v14.12` occurrences are prose, not citations.** **119 occurrences**
  > remain across the 17 area model files — counted by
  > *occurrence*, not by line, and re-derived at the 746-case state:
  > `url_grammar.md` 15,
  > `pagination.yaml` 14, `errors.yaml` 13, `observability.yaml` 12,
  > `auth.yaml` 10, `config.yaml` 9, **`rpc.yaml` 7**,
  > `filters.yaml` / `ordering.yaml` 6 each,
  > `content_negotiation.yaml` / `headers.yaml` / **`openapi.yaml` 5** each,
  > `mutations.yaml` 4, `select.yaml` 4, `operators.yaml` 2,
  > `domain_representations.yaml` / `representations.yaml` 1 each — plus **27
  > occurrences across 26 case files**.
  >
  > **The whole +2 is `openapi.yaml` (3 → 5), and every one of its five is in a
  > comparative claim rather than a citation.** The file's re-sync header read
  > "v14.12 -> v16.0 re-sync: no behavior change in this area." (one occurrence,
  > line 18 at HEAD). It now reads "re-verified by diffing both pins rather than
  > carried over" and states the *scope* of that diff
  > (`git diff v14.12..v16.0 -- test/spec/Feature/OpenApi/…`) and how the configs
  > compare — three occurrences where there was one. The other two (the
  > `.../en/v14/...` externalDocs delta and the `testIgnorePrivOpenApiCfg` note in
  > the schema-scoping gap) are unchanged from HEAD. **A flat "nothing changed"
  > became a checkable one; the occurrence count is the only trace that leaves**,
  > which is exactly why it must not be read as drift.
  >
  > **CORRECTION, and it is a correction to THIS DOCUMENT rather than to the
  > tree: `rpc.yaml` holds SEVEN occurrences, not six, and always did.** The
  > previous revision recorded 6 and inferred a "7 → 6" movement caused by commit
  > `75388d6` rewriting a gap entry. Re-counting by occurrence on disk — lines 20
  > (×1), 21 (×1), 44, 444, 497, 573, 574 — gives **7**, and `rpc.yaml` is
  > **unmodified** in `git status`, so nothing moved and the inference was
  > spurious. The tree total is **117**, not 116. **The trap is lines 20–21**: two
  > occurrences on two adjacent lines in one comment block, trivially collapsed to
  > one when counting by line. **Count by occurrence, and say which you counted.**
  > A metric that changes because of how it was measured, in a document that reads
  > movement as evidence, is worse than no metric.
  >
  > **The lesson the retired "7 → 6" reading reached for still stands, and
  > `representations.yaml` is its better example.** That file went 1 → 1 in
  > *count* while its single occurrence
  > was **rewritten**: its re-sync note used to assert "no behavior in this area
  > changed" flatly, and now says so "re-verified by diffing both pins rather than
  > carried over", then itemizes exactly what *did* move — the four cited Feature
  > specs shifted 1–3 lines from a harness signature change
  > (`SpecWith ((), Application)` → `SpecWithConfig`), plus a further 7-line shift
  > on every `InsertSpec.hs` anchor after `#L554-L559`, where the generated-column
  > error block dropped its `actualPgVersion < pgVersion140` branch. It also names
  > the one `Preferences.hs` behavior change in its window (`Prefer: timezone`
  > lost the `TimezoneNames` schema-cache check) **and states why it is
  > out of scope** — it does not touch `return=`. That is the shape a "nothing
  > changed" note should have.
  > **Occurrence counts move for editorial reasons — and, as this correction
  > shows, for counting-method reasons. Never read them as research.**
  > Verified mechanically: **one** file in `spec/*.yaml`, `spec/*.md` or
  > `spec/conformance/cases/*.yaml` contains a `v14.12` *URL* — `rpc.yaml:574`,
  > the quoted (and now **resolved**) `fixtures/rpc.sql` pin its own gap entry
  > reports. **Not** counted as a stale pin. (This count excludes `README.md`,
  > `COVERAGE.md` and `conformance/INDEX.md`, which the synthesis phase rewrites.)
  >
  > **But "prose, not a citation" is not the same as "correct".** **Five** of these
  > comparative notes have been found **false or misleading** and fixed, one per
  > re-sync: case **1029**'s "byte-identical parser" claim; case **1016**'s claim
  > that v16.0 had no Feature-spec line for the PUT-`limit` rule;
  > `pagination.yaml`'s opening "no pagination behavior changed between the
  > pins", now narrowed to "no *asserted* pagination behavior changed" — the
  > re-sync found four traceable-but-unmodeled behaviors and one mis-modelled
  > rule behind that sentence; `observability.yaml`'s
  > "the OPTIONS subset ... UNCHANGED on the wire from v14.12" — the *unchanged*
  > half was true, the *subset* half was false at **both** pins (see
  > **Known gaps → observability**); and `operators.yaml`'s mid-pass claim that
  > cases 10200–10219 had closed everything in the "existed at both pins, never
  > modeled" bucket. **The fifth is a new species and the most instructive**:
  > unlike the other four it was not wrong about PostgREST — the byte-diff behind
  > it was re-proved and holds — it was wrong about *this tree*, asserting a
  > coverage claim in the middle of a change-log note. **The rpc pass produced no
  > sixth correction, and that is not the same as producing none.** Its five
  > findings are the same failure in a different register: not a false "nothing
  > changed" note, but *no note at all* on five behaviors that existed at both
  > pins. Five out of ~142 prose occurrences is a low correction rate, but the
  > sweep above cannot detect any of them — it checks tags, not truth, and it
  > certainly cannot detect a sentence that was never written. Treat every one of
  > these mentions as unaudited, and treat a "nothing changed" note as evidence
  > about upstream only.
  >
  > **The representations pass produced no sixth correction either, and this time
  > the reason is instructive rather than worrying.** Its "no behavior changed"
  > note was **the same claim as before**, but it was re-derived by diffing both
  > pins instead of being carried forward, and the re-derivation *survived* while
  > adding four concrete line-shift causes and one explicitly-out-of-scope
  > behavior change. A comparative note that names what moved is checkable; one
  > that only says "nothing moved" is not. Prefer the former even when the
  > conclusion is identical.
  >
  > **The content_negotiation pass supplies the SIXTH and SEVENTH corrections,
  > and both are over-claims rather than falsehoods — which makes them the
  > hardest species to notice.** (6) `version_delta.source_moves` asserted that
  > negotiateContent's body is "**byte-identical** to v14.12's"; v16.0 re-aligned
  > the `case` alternatives, so the entry now reads identical **modulo
  > whitespace**, with the (true, weaker) supporting statement that a
  > whitespace-insensitive diff is empty — same clauses, guards, results and
  > order. (7) A `behaviors.plan` claim opened "**NEW in v16.0**: the JSON plan
  > includes a `Query Identifier` field when `options=verbose`"; the cited lines
  > support no such thing. Upstream *added a test*; the field is emitted by
  > PostgreSQL's `EXPLAIN (VERBOSE, FORMAT JSON)` when the server computes query
  > ids, so it appears only on such a server and PostgREST introduced nothing.
  > The claim is now filed under `version_delta.test_changes`, where it belongs.
  > **Note what makes this pair worth the ink**: the old wording of (7)
  > **contradicted the same file's own `version_delta.behavior_changes: []`**, two
  > hundred lines apart, and no check in this document compares a model against
  > itself. **A model can be internally inconsistent and pass every gate here.**
  > Running total: **seven** corrections across ~143 prose occurrences.
- **Stale pins outside the checked globs — now 43 `v14.12` URLs across SIX
  files, down from 44 across seven.** Re-counted this pass with the prefix-aware
  pattern, all in `--` provenance comments under `spec/conformance/fixtures/`:
  `ordering.sql` **27**, `errors.sql` **5**, `auth.sql` **4**, `mutations.sql`
  **3**, `config.sql` **2**, `filters.sql` **2**. **Two** fragments now carry
  zero: `observability.sql` (**7** → 0, by the observability re-sync, which
  re-pinned its whole header block to `v16.0` raw URLs with all seven anchored
  line numbers confirmed unchanged) and, **new since the last revision**,
  `rpc.sql` (**1** → 0, by commit `6b25f05`, after verifying all 23 vendored
  routines are still defined at v16.0 with unchanged argument signatures).
  Per `conformance/fixtures/README.md` these files are
  historical provenance and explicitly **not authoritative** (the live artifact
  is `fixtures.sql`), and `.sql` is outside the pin check's declared globs — so
  this is **not** an in-scope failure. It is nonetheless real leftover pin drift.

  > **Two precedents, still no rule, and two consecutive passes have now declined
  > to set one.** Follow-up 14 asks whether to re-pin the remaining fragments or
  > declare them frozen at the pin they were derived from. `observability.sql` and
  > `rpc.sql` say "re-pin"; nothing says it is the rule. The mutations re-sync
  > **re-read and re-anchored every `source:` in its own model and in its whole
  > band** — upstream checkout open, anchors verified — and left
  > `fixtures/mutations.sql`'s **3** `v14.12` URLs untouched. **The
  > representations re-sync had nothing to decline**: `fixtures/representations.sql`
  > carries **zero** `v14.12` URLs already (its one `v14.12` occurrence is prose),
  > so the count held at 43 across the same six files for a second pass. That is
  > *not* evidence the drift is stabilising — it is evidence that the fragments
  > still carrying it (`ordering.sql` alone holds 27 of the 43) have not been
  > touched by a re-sync since the practice started. The drift will shrink only by
  > decision.
  > Separately, `spec/conformance/fixtures/pagination.sql` still carries a
  > "PostgREST v14.12 parity" **label** in its header comment (recorded in
  > `pagination.yaml`'s gaps, left alone for the same reason).
- **Citation composition (not a check — an honesty note).** Grouping all **746**
  `source:` lines by directory, re-derived on disk this pass: **530** cite
  `test/spec/Feature/Query`, 44 `test/spec/Feature/Auth`, 34
  `test/spec/Feature/OpenApi`, **17** `test/spec/Feature/Query/Preferences`, 14
  `test/spec/Feature`, **1** `test/spec/SpecHelper.hs`, **47** the `test/io` tree
  (20 fixtures, 17 top-level, 5
  `configs`, 5 `configs/expected`), **2** the documentation itself — and **57**
  cite implementation code under `src/library/PostgREST/…` rather than an upstream
  assertion (**38** directly under `src/library/PostgREST`, **9** under
  `.../ApiRequest`, **7** under `.../Response` (was 3), **2** under `.../Query`,
  1 under `.../Config`). Those 57 expected bodies are *derived from reading the
  implementation*, not transcribed from an it-block, which is a weaker form of
  ground truth even though it is not a citation defect.

  > **CORRECTION to the previous revision's `Feature/Query` figure, and it is a
  > scope error rather than a miscount.** **530** is right only when
  > `test/spec/Feature/Query/Preferences` is counted *separately*, as the row
  > above does; a sweep that matches the `Feature/Query` prefix inclusively reads
  > **547**. The previous revision's "525 → 530 (+5)" compared the exclusive count
  > against a figure derived differently. Re-derived both ways this pass: the
  > exclusive bucket is **530 at HEAD and 530 now** — it did not move, because the
  > openapi pass touched no `Feature/Query` anchor. **State which bucketing you
  > used or the number is unreadable.**

  **THE IMPLEMENTATION-ANCHORED TOTAL MOVED 53 → 57, AND THE COMPOSITION MOVED
  FURTHER THAN THE TOTAL.** Five motions, all in the openapi band, which went
  3 → **7**:

  | Motion | Case | Anchor before → after |
  |--------|------|-----------------------|
  | arrived (re-anchored **onto** impl) | **1651** | `RootSpec.hs#L27` → `Response.hs#L208` |
  | arrived (re-anchored **onto** impl) | **1662** | `OpenApiSpec.hs#L117` → `OpenAPI.hs#L321` |
  | arrived (**new**) | **1684** | `OpenAPI.hs#L158` — `required .~ fmap ppName (filter ppReq …)` |
  | arrived (**new**) | **1687** | `OpenAPI.hs#L367` — the root path item the document emits for itself |
  | arrived (**new**) | **1688** | `OpenAPI.hs#L405` — the document-level `produces`/`consumes` list |
  | left (re-anchored **off** impl) | **1682** | `ApiRequest.hs#L123` → `docs/references/api/openapi.rst#L71` |

  The share is **7.6 %** (57/746), up on both numerator and denominator.
  **Two of the five arrivals (1687, 1688) exist precisely because upstream's
  black-box suite reads neither key** — its only witness for both is the
  whole-document schema validation of `SpecHelper.hs#L115-123` — so the growth
  measures a hole in upstream's Feature coverage rather than lazy anchoring.
  **1682's departure is the mirror image and the more unusual motion**: it moved
  *off* implementation code onto the **documentation**, because
  `docs/references/api/openapi.rst#L71` is the only place upstream prints the
  `db-root-spec` document this case asserts byte for byte. That is the tree's
  second docs anchor, joining pagination's **1279**.
  Case **1650** produced a sixth motion of a kind with no precedent: `RootSpec.hs#L18`
  → **`SpecHelper.hs#L104`**, the first case in the tree to anchor at upstream's
  shared helper rather than at a Feature spec — the audit found that at v16.0
  `RootSpec` runs under a `db-root-spec` config, so its it-blocks witness the
  root-spec-FUNCTION path, not the generated document this case models.

  > **The previous revision's prediction about this metric was WRONG, and the
  > correction is more useful than the number.** It read the growth pattern as
  > "the set grows when an audited area's subject is *response shape*"
  > (observability +4, representations +7) and predicted `content_negotiation` —
  > the response-shape area par excellence — would grow it again. It netted
  > **zero**. What actually distinguishes the growing passes is narrower:
  > both pinned rules upstream asserts **nowhere black-box**. The
  > content_negotiation audit found the opposite situation — real, fetchable
  > upstream it-blocks (`PlanSpec.hs#L544`, `CustomMediaSpec.hs#L188`/`#L208`/
  > `#L346`/`#L369`, `RpcSpec.hs#L1168`) with **no case pointing at them**.
  > **Missing black-box coverage and implementation-anchored coverage are
  > different failure modes**, and conflating them produced a prediction that a
  > single pass falsified. Follow-up 10's review list is **53** cases, with two
  > entries swapped rather than added.

  **Retained for context — the previous pass's movement, 46 → 53.** Seven of the
  representations pass's eight new cases were the cause:

  | Case | Anchor | Rule it pins |
  |------|--------|--------------|
  | 1315 | `Query/Statements.hs#L48` | affected rows ≠ 1 ⇒ no `Location` (the `CASE` guard's `ELSE` arm) |
  | 1317 | `Query/Statements.hs#L49` + `Query/SqlFragment.hs#L223-L231`/`#L102-L103` | no PK columns ⇒ `locationF` matches nothing ⇒ `noLocationF` |
  | 1318 | `ApiRequest/Preferences.hs#L100` (+ `#L165-L167`) | duplicate `return=` ⇒ **first in request order** wins |
  | 1319 | `Plan.hs#L207` (+ `Preferences.hs#L133`/`#L140`) | unknown `return=` value ignored; 400 only under `handling=strict` |
  | 1325 | `Response.hs#L283` | `return=` not echoed on a read (`WrappedReadPlan`) |
  | 1326 | `Response.hs#L281` | `return=` not echoed on an RPC (`CallReadPlan`) |
  | 1327 | `ApiRequest/Preferences.hs#L179` | `Preference-Applied` renders in fixed `prefsVals` order |

  Only **1316** cites a Feature spec (`InsertSpec.hs#L228`), which is why
  `test/spec/Feature/Query` moved 524 → **525** — the smallest movement that
  directory has ever recorded against an 8-case pass.

  > **Is this a defect? No — and saying why matters more than the number.** Every
  > one of the seven pins a rule upstream **never asserts black-box**: PostgREST's
  > Feature specs contain no it-block for a duplicate `return=` token, none for an
  > unrecognized one, none for `Preference-Applied` ordering, and none for
  > `return=` on a read or an RPC. Two of them (1318's duplicate-token rule) are
  > backed by upstream **doctests** in `Preferences.hs` — "If a preference is set
  > more than once, only the first is used" — which is ground truth of a different
  > kind, not an absence of it. Each case says so in its own `notes:`. This is the
  > same justification the observability pass gave for 1770.
  >
  > **The pattern claim this paragraph used to make has been retired** — see the
  > correction above. The set has grown in three of the last seven re-syncs, shrunk
  > in none, and stayed flat in four; the content_negotiation pass is the first to
  > hold it flat *through* motion rather than through inactivity.

  > **"No anchor moved off implementation code" is not "no anchor moved".** The
  > mutations re-sync moved **one** `source:` anchor, **within** the test suite and
  > to a different it-block: case **1352** went from
  > `InsertSpec.hs#L218` — the *single-object* no-pk block — to **`#L268`**,
  > `context "with bulk insert"` / `it "returns 201 but no location header"`. The
  > case is a *bulk* insert (a two-element JSON array), so it had been citing an
  > assertion about a different request shape. **This was a third species of
  > anchor motion**, alongside moving *off* implementation code (1189, 1016, 1767)
  > and *onto* it (1757/1768/1769): moving **sideways**, from a plausible it-block
  > to the right one.
  >
  > **The representations pass adds a FOURTH species: narrowing an anchor whose
  > enclosing `describe` made it prove less than the model claimed.** The model
  > cited `InsertSpec.hs#L745` for "a POST without `return=headers-only` carries
  > no `Location`"; that block is under `describe "Inserting into VIEWs"` and
  > posts to `/compound_pk_view`, so it witnesses the rule **on a view only**. The
  > model now cites `#L157` (no-`Prefer`, on the `projects` TABLE) and `#L99`
  > (`return=representation`), and case **1309** was rewritten. Note that the old
  > anchor passes every mechanical check in this document *and* passes a
  > line-level "does the cited line support the claim?" read — it supports a
  > narrower claim. **Read the enclosing `describe`, not the line.**
  >
  > **The content_negotiation pass adds a FIFTH species, and it is the inverse of
  > narrowing: SPLITTING one anchor across many citations without moving it.**
  > Case **1622** kept `RpcSpec.hs#L1184`, but the audit established that the
  > anchored it-block asserts **only** `respBody == file` — no status, no
  > `Content-Type` — while the case asserts all three. Since `case.schema.json`
  > permits exactly one `source:`, the remedy was not a different anchor but
  > **five more citations inside `notes:`**: the fixture declaration that makes
  > octet-stream negotiable (`schema.sql#L2372`), both branches of the
  > handler-discovery query (`SchemaCache.hs#L1062`, `#L1080-L1086`), the built-in
  > handler map that excludes octet-stream (`#L1016`), the sibling it-block that
  > pins the 200 (`RpcSpec.hs#L1257`) and the charset rule (`MediaType.hs#L62`).
  > **The generalizable rule: when a case asserts more than its anchor proves,
  > the fix is more citations, not a different anchor.** The same pass also moved
  > **1600** in the ordinary direction — *off* `MediaType.hs#L69` onto
  > `RawOutputTypesSpec.hs#L15` — joining 1189/1016/1767.
  >
  > **Five species now, each found by a different area's audit**, which is the
  > real point: re-anchoring is a *finding*, not hygiene.

  **The previous pass, retained for context.** All 37 operator cases anchored in
  `test/spec/Feature/Query` (**29** `QuerySpec.hs`, **8** `AndOrParamsSpec.hs`),
  moving that directory 469 → 506 and the implementation-anchored share 6.9 % →
  6.5 % without a single re-anchoring. That area's own *model*, by contrast, is
  heavily implementation-cited (`SqlFragment.hs`, `QueryParams.hs`, `Plan.hs`,
  `SchemaCache.hs`) — which is the right division, and the same division
  `rpc.yaml` uses: the *model* explains the mechanism from the source, the *cases*
  transcribe what upstream asserts.

  **The prior movement, retained for context: the count moved 42 → 46, and for
  that pass the movement was mostly *backwards*.** Earlier passes reported cases
  migrating *off* implementation code onto it-blocks (1189, 1016). The
  observability pass produced net +4 from four separate motions, and three of them
  went the other way:
  - **1757, 1768, 1769 were re-anchored FROM `ServerTimingSpec.hs#L87/#L96/#L104`
    ONTO `App.hs#L225` / `Plan.hs#L174` / `Plan.hs#L177`.** This is not a
    downgrade of evidence: the upstream it-blocks are still cited in each case's
    `notes:` for the presence assertion they do make, and the anchors moved
    because the *retracted* claim (plan/transaction absent on OPTIONS) could only
    be refuted at the control flow, not at a spec line that never asserted it.
    Still, three of the four are now priority-2 ground truth where they were
    priority-1.
  - **1767 moved the other way**, off `Logger.hs#L63` onto `test_io.py#L523`,
    joining 1765/1766 on the parametrized upstream test.
  - **1770 and 1771 are new and both implementation-anchored** — 1770 at
    `Response/Performance.hs#L29` (the module **doctest**, which is the only place
    upstream pins the exact wire rendering; the Feature-spec matcher
    `matchServerTimingHasTiming` accepts any separator and any number of decimals)
    and 1771 at `App.hs#L143` (`setServerName`), with `test_io.py:1065` cited in
    `notes:` as the request shape it mirrors.

  **Retained: the representations pass added +7 in a single pass**, more than
  observability's +4. It remains a defensible use of priority-2
  ground truth when the case's whole point is a behavior upstream does not
  assert — every one of the seven says exactly that in its `notes:`. **What this
  revision withdraws is the *reading* that was drawn from it**: that the set grows
  whenever an audited area's subject is *response shape*. The
  content_negotiation pass tested that prediction directly and falsified it —
  see the correction above. Follow-up 10's list stands at **53**, with two
  entries swapped this pass rather than added.

  Separately, **case 1279 is the tree's first and only case anchored at the
  documentation** — `docs/references/api/pagination_count.rst#L52`, the
  open-ended `Range: 10-` paragraph. The docs are the primary specification, so
  this is arguably stronger than an implementation anchor, but it is a third
  citation class that neither `case.schema.json` nor any prior pass anticipated.
  Note it and decide whether it should be normalized.

  Against all that, **six of the last seven area re-syncs moved at least one
  anchor**: filters moved **1189** (`Plan.hs#L855` → `QuerySpec.hs#L1187`),
  url_grammar moved **1016** (`ApiRequest.hs#L178` → `UpsertSpec.hs#L295`),
  errors' own new cases went the other way with explicit justification,
  pagination re-anchored **1268** (`RangeSpec.hs#L160` → `#L163`) and **1269**
  (`#L152` → `#L153`) onto the actual assertion lines rather than their enclosing
  `context` lines, observability moved **four** (1757/1768/1769 onto
  implementation code, 1767 off it), and **mutations moved one sideways**
  (**1352**, `InsertSpec.hs#L218` → `#L268`). The two exceptions in that run
  broke the streak differently: operators moved none because it rewrote no
  existing case at all, and **the rpc pass moved none while rewriting six**
  (1402, 1422, 1432, 1433, 1439, 1440) — every rewrite touched
  `notes:` and expectations, none touched `source:`, which says those six anchors
  were already right and removes the easy inference that rewriting implies
  re-anchoring. **The mutations pass is the mirror image and the sharper data
  point**: it rewrote exactly **one** case and that one rewrite *was* an
  re-anchoring, because the anchor was the defect. **The representations pass
  makes it seven of the last eight**, and its motion is the fourth direction:
  *narrowing* — `InsertSpec.hs#L745` → `#L157` + `#L99`, because the old anchor's
  enclosing `describe` scoped it to views. **The content_negotiation pass makes it
  eight of the last nine** and supplies the fifth direction, *splitting*: case
  1622's anchor stayed put while five citations were added around it in `notes:`,
  and case 1600 moved off implementation code in the same diff. That the motion is
  multidirectional —
  off implementation code, onto it, sideways within the suite, narrower
  within the same file, and now *supplemented in place* — is the useful signal:
  re-anchoring is a *finding*, not hygiene. The remaining **53** should be
  re-read during their areas' audits — follow-up 10.
- **Id bands, re-derived on disk this pass.** Twelve areas each occupy one
  contiguous band; **five** are non-contiguous and must stay that way:
  **representations** (**1300–1327 + 1330–1333** — a single internal hole at
  **1328–1329**, which is per-sub-feature spacing before the PUT block; the
  earlier description of this band as "1300–1314, 1320–1324, 1330–1333" is
  **retired**, because 1315–1319 and 1325–1327 are now all occupied), **auth**
  (1450–1499 **+ 11800–11818**), **operators**
  (**1050–1099 + 10200–10236**), **content_negotiation**
  (**1600–1649 + 12400–12401**, new this pass — its primary band is now fully
  allocated, 1647/1648/1649 having taken the last three ids, and **12402+ is
  free**) and **mutations**
  (**1350–1399 + 11400–11405 + 11407–11415**), whose *internal* gap at **11406**
  is deliberate in a way none of the others is: it marks a case that was written
  and then deleted as redundant with representations case **1332**, not a
  sub-feature boundary. Do not close it up. Separately, the *config band* 1700–1744 is
  contiguous but **mixes shapes**: 1742/1743 are HTTP cases embedded in an
  otherwise CLI run of ids (see `conformance/INDEX.md` → *Case file shapes*).
  The **filters** primary band 1150–1199 is **fully allocated**;
  `spec/filters.yaml` declares `[10600..10799]` as the area's closed overflow
  range for future cases. **ordering** (1200–1232), **url_grammar** (1000–1035)
  and **errors** (1500–1526) remain contiguous with room — 1233+, 1036–1049 and
  1527–1549 respectively. **pagination** holds **1250–1288**, still contiguous,
  with **1289–1299** free before representations starts at 1300 — 11 slots, enough
  for the embedded-`.offset` gap below. **observability** holds **1750–1771**
  (22 cases), still contiguous, with the whole of **1772–1799** free — by a wide
  margin the roomiest *primary* band in the tree.

  > **The representations pass is the first re-sync in four to need no band
  > decision at all**, and the reason is worth recording as an argument for
  > follow-up 19. It added eight cases without opening a band, minting a 5-digit
  > id, or picking a convention — because its area still had *interior spacing*
  > (1315–1319 and 1325–1329) reserved by an earlier author for exactly this. The
  > four areas that did have to pick a number (filters by declaration, operators,
  > mutations and soon rpc by ad-hoc choice) are all areas whose primary band was
  > allocated to the last id. **Reserve spacing inside a band and the overflow
  > question never arises.** Its residual free primary ids are now **1328, 1329
  > and 1334–1349**.

  > **`rpc` is now the tightest band in the tree, and its audit is the reason.**
  > The area extended to **1400–1443** (44 cases, contiguous), leaving
  > **1444–1449 — six ids** before auth starts at 1450. The area's five open
  > findings would consume most or all of that: the *Untyped functions* finding
  > alone mirrors two upstream `it`-blocks covering four routines, and the array
  > parameter finding covers three binding paths. **Decide the rpc overflow band
  > before authoring any of them**, and decide it under whatever convention
  > follow-up 19 settles — this is exactly the third-area-picks-a-number-ad-hoc
  > situation that follow-up warns about, and it is no longer hypothetical.

  > **There are now FOUR 5-digit bands, and the fourth arrived exactly as
  > follow-up 19 warned — while that follow-up was open, from the very area the
  > follow-up list had flagged as the next audit.** `content_negotiation` filled
  > its primary **1600–1649** (50/50 in use, after 1647/1648/1649 took the last
  > three) and opened **12400–12401** — 2 ids, **12402+ free** — **declaring no
  > overflow range anywhere in `content_negotiation.yaml`**, exactly as
  > `mutations.yaml` and `operators.yaml` did before it and unlike
  > `filters.yaml`, which declares `[10600..10799]` and has used none of it.
  > **Four areas, one declaration, four ad-hoc placements, in five passes.** The
  > previous revision closed this note with "settle it before a fourth"; a fourth
  > happened first. Settle it before a **fifth** — and `rpc`, with six free ids and
  > five open findings, is that fifth.
  >
  > **Retained: `mutations` opened the third band the same way** — 11400–11415, 15
  > ids, **11406 deliberately skipped**, 11416+ free.
  >
  > In a **lexical** listing three of the four 5-digit bands sort into false
  > neighbourhoods:
  > auth's `11800` after `1180` (interleaving with *filters*), operators' `10200`
  > after `1020` (interleaving with *ordering*), and mutations' `11400` after
  > `1140` (interleaving with **select**, whose 1140–1149 block is fully used).
  > **content_negotiation's `12400` is the exception**: it sorts between `1232`
  > and `1250`, into the free 1233–1249 slice, so it interleaves with nothing.
  > That makes it the *least* confusing of the four to encounter and the *most*
  > likely to be missed entirely when scanning a listing.
  > **`ls | sort -n`, never plain `ls`.** The `feature:` prefix
  > remains authoritative; an id's numeric neighbourhood never decides its area.
- **Referenced relations: 0 unexpected misses, 17 flagged, 17 deliberate
  negatives, 81 excluded** (`missing_unexpected: []`). The excluded set is the
  cases that target no relation at all: bare-`/` root-document cases, `kind: cli`
  cases, and bare `/rpc`. The check resolved the
  first path
  segment of each HTTP case (percent-decoded; `/rpc/<fn>` → function `<fn>`; the
  bare-`/` cases and the 38 `kind: cli` cases have no relation and were skipped)
  against a `pg_class`/`pg_proc` dump of the freshly loaded DB, mirroring the
  frozen harness's schema resolution rather than the label string: `test`/
  `public`/`null` → `test`; `unicode` → `تست` (`db_schema_aliases`,
  `conformance_server.ex:181`); `multi` → the `v1`/`v2`/`SPECIAL "@/\#~_-`
  profile set (`db_profile_schemas`, `:185`); `openapi_no_schema_comment` →
  `openapi_no_comment` (the 1654 variant instance); an explicit
  `Accept-Profile`/`Content-Profile` on the case wins over the label (which is
  what makes case **1574**'s `SPECIAL "@/\#~_-`.names resolve — confirmed by a
  direct catalog query this pass); and a case-level `config.db-schemas` wins over
  both.

  **Every one of the seventeen is a deliberate negative whose assertion IS the
  absence** — the case expects a 4xx *because* the target does not exist.
  Verified per case by reading each `expect.status` —
  e.g. **1024** expects `Could not find the table 'v1.another_table' in the schema
  cache`, and `another_table` does exist, in `v2` only. The seventeen:
  **1001** (`test.first`), **1002** (`test.invalid`), **1024**
  (`v1.another_table`), **1034** (`test.unknown`), **1360** (`mutations.garlic`),
  **1368** (`mutations.fake`), **1373** (`mutations.foozle`), **1432**
  (`rpc.fake`, a function), **1443** (`test.sayhell`, a function),
  **1515** (`test.non_existent_table`), **1516** (`test.invalid`),
  **1517** (`test.itemsx`), **1520** (`test.projectx`), **1521**/**1525**
  (`test.projxxxx`), **1652** (`openapi.entities`, 406 — the `openapi` schema is
  deliberately not mirrored, `bier.fixtures.load.ex:28-34`) and **1765**
  (`observability.unknown`). **These are not fixture gaps.**
  **Missing on a success-expecting case: 0** — not one case expecting a 2xx
  targets a relation or function absent from the loaded DB, which is the check's
  actual invariant and the only line in this bullet worth acting on.

  > **The flagged set moved 21 → 17, and — for the FIFTH time — the movement is a
  > property of the checking script, not of the tree.** This generation resolves
  > labels against the real model the frozen harness and `lib/` implement jointly
  > (`test/support/http_case.ex:60-70`'s `Map.put_new` injection;
  > `lib/bier/plugs/action_controller.ex:475-527`'s `resolve_profile/2`, its
  > `db_schema_aliases` lookup and its `@profile_aliases ~w(headers multi)`
  > allowlist; the per-case `config: db-schemas` override; the 1654 variant), and
  > it therefore no longer flags **1010, 1012, 1560, 1583** — the four cases that
  > send an explicit `Accept-Profile: unknown` and assert 406. Those four are
  > unchanged on disk; they are simply now classified as *profile* negatives
  > rather than *relation* negatives, which is the correct classification. A naive
  > label-equals-schema pass produced **34** false positives at this state before
  > the resolution model was applied. **Record the script generation alongside the
  > number, or the series 25 → 20 → 16 → 20 → 21 → 21 → 21 → 17 reads as tree
  > churn when it is measurement churn.**

  **All six new content_negotiation cases resolve.** Their targets are
  `test.organizations` (12400, 12401, 1649), `test.items` (1647, 1648) and the
  routine `test.add_them` (the re-issued 1623) — and **1623's resolution is the
  point of the case**: `add_them` exists and returns plain `integer`, which is
  precisely why `Accept: application/octet-stream` must answer 406. **Note what
  this check does and does not prove, in the sharpest available example**: it
  confirmed `test.unnamed_bytea_param` existed for case 1622 in every previous
  pass, while the routine was declared with the **wrong return type** and the
  case's assertion was unreachable. Existence is not declaration; see the
  headline caveat at the top of this section and follow-up 28.

  **Retained for context: the eight representations cases** resolve too —
  `representations.complex_items`, `representations.no_pk` (the six POSTs),
  `representations.items` (1325) and `rpc.add_them` (1326). Cases
  **1316/1317** write through `representations.no_pk`, which
  `isolate_representations/1` does **not** turn into a real table, so they carry
  the same undeclared `db_tx_end: :rollback` dependency the mutations band does.
  That is a `mix test` question, not a catalog question. See
  **Known gaps → representations** and **→ mutations**.

  **Retained for context: the seventeen mutations cases** resolved as intended
  too, including the seven that area reaches only through a **view mirror**
  rather than an isolated real table (`menagerie`, `json_table`, `car_models`,
  `only_pk`, `students`/`students_info`, `users`, `tasks`/`projects`).

  **Retained for context: the seventeen mutations cases and the three rpc cases**
  resolved as intended too — **1441**/**1442** target `rpc.ret_void` and
  `rpc.variadic_param`, both loaded and both reached through the `rpc` profile,
  and **1443** is one of the seventeen flags *by design*: it requests
  `GET /rpc/sayhell` (one character
  short of `sayhello`) and asserts the closest-proc PGRST202 envelope, so the
  target's absence is the assertion.

  > **The series is now 25 → 20 → 16 → 20 → 21 → 21 → 21 → 17, and NOT ONE of the
  > eight numbers is a measurement of the tree.** Each generation of the checking
  > script resolves labels a little more like the harness
  > *intends*: one pass stopped flagging 1005/1008/1011 by resolving `multi`
  > itself; the next stopped flagging 1010/1012/1560/1583 by honouring explicit
  > profile headers; the pass after that re-flagged those four and classified them
  > as deliberate negatives; **this pass drops them again**, correctly, because a
  > case that sends `Accept-Profile: unknown` and asserts 406 is a *profile*
  > negative, not a relation negative. Case 1443 (+1) remains the only movement
  > ever that is a property of `spec/` rather than of the script.
  > **The previous revision read two flat passes as "a baseline" and asked that
  > future movement be treated as a finding about `spec/`. This pass moved it by
  > four and the cause was, again, the script.** That prediction is withdrawn:
  > **stability across passes is not evidence that a metric tracks the tree when
  > the measuring instrument is rewritten each time.** Record the script
  > generation alongside the number, and prefer the invariant to the count —
  > *"0 success-expecting cases target a missing relation"* has held under every
  > generation and is the only line here worth acting on.
  > The method caveat is unchanged and still load-bearing: a naive
  > label→schema mapping yields **34** false positives at this state, because
  > several `schema:` labels are harness selectors rather than Postgres schema
  > names (`unicode` → `تست` via `db_schema_aliases`; `multi` and `headers` via
  > `lib/`'s `@profile_aliases`; an explicit `Accept-Profile`/`Content-Profile` on
  > the case winning over the label; a per-case `config: db-schemas` winning over
  > both). **The verification independently rediscovered every one of those rules
  > this pass** — it began at 34 "absent" and reached 17 only after applying them.
  > A checker that skips any of them reports twice the failures that exist.
  >
  > **Two cases sit outside this check entirely and are worth naming so nobody
  > re-derives them as misses**: **1654** (`openapi_no_schema_comment`) and
  > **1672** (`openapi_variadic`) carry `schema:` labels that name no schema, but
  > both request path `/` — the root OpenAPI document — so they target no relation
  > at all.
  >
  > **The sharpest instance is 1652, and it must not be read as closed.** Previous
  > passes singled it out as "the one to act on": the only flagged target that was
  > not a 404 negative. Recent scripts classify it as *EXPECTED-ABSENT (case
  > asserts 406 non-root-openapi)* and fold it into the deliberate negatives —
  > because it expects a 4xx, which the classifier treats as sufficient. This
  > pass's verification independently reported the same root cause a **fifth** way,
  > listing `openapi -> openapi` among its *unknown label schemas* while noting the
  > absence is intentional per `lib/mix/tasks/bier.fixtures.load.ex:28-34`
  > ("Function-heavy areas (rpc, openapi, headers) are intentionally NOT
  > mirrored"). **That is a reclassification, not a
  > reclassification, not a fix.** The underlying finding is unchanged and still
  > open: label `openapi` names no schema in the loaded DB, so 1652 can return 406
  > for the *unknown-schema* reason instead of the *media-type* reason it was
  > written for, and the two are indistinguishable at the current expectation
  > strength. See *Open verification findings → 2*. Likewise the `multi` finding
  > rests on `lib/bier/plugs/action_controller.ex:479`, not on any count
  > (*→ 1*). **A checking script that resolves a label the way the harness intends
  > cannot detect that production code is what makes the label resolve** — and a
  > classifier that accepts "expects 4xx" as proof of intent cannot detect that the
  > 4xx has two possible causes.

  > **The label-override enumeration was re-derived from disk this pass rather
  > than carried over, because an earlier verification got it wrong.** Mechanical
  > result, re-derived at the 746-case state: **15** cases spell out a profile header of their
  > own — **12** an `Accept-Profile` (1009, 1010, 1013, 1014, 1017, 1018, 1023,
  > 1024, 1558, 1560, 1574, 1583) and **3** only a `Content-Profile` (1011, 1012,
  > 1559). Only `Accept-Profile` suppresses the harness's `Map.put_new` injection,
  > so of the **14** `multi` cases exactly **six** actually receive
  > `Accept-Profile: multi`: **1005, 1006, 1007, 1008, 1011, 1012**. Three of those
  > six expect success and therefore depend on the `lib/` allowlist: **1005**,
  > **1008**, **1011**. Unchanged from the previous two passes. An earlier
  > verification listed the injected set as *1005, 1008, 1009, 1013, 1014, 1017,
  > 1018, 1023*, which is wrong in both directions; the *finding* it drew from that
  > list (the label resolves only via production code) is sound regardless.
  > Recorded rather than silently corrected, because the two findings below rest on
  > the enumeration.

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

#### 2. Case 1652 (`openapi.entities`) may pass for the wrong reason — the LABEL half is RESOLVED; a NEW half opened in its place

> **RESOLVED this pass, the half that four previous passes reported.** The
> openapi re-sync relabelled all 33 committed cases in the band: **31**
> `schema: openapi` → `test`, **1** `openapi_variadic` → `test`, and case
> **1654** `openapi_no_schema_comment` → **`openapi_no_comment`**, a schema that
> **does** exist. No case in the tree now carries a label naming a non-existent
> schema, so 1652 no longer sends `Accept-Profile: openapi` and can no longer
> 406 as PGRST106. **The finding's premise is gone.** Everything below it is
> retained as the record of how it was found and why it stayed open for four
> passes; read it as history, not as an open item.
>
> **A NEW half opened in the same edit, and it is a harness-routing change nobody
> declared.** `Bier.ConformanceServer.auth_case?/1` routes a case to the **auth**
> instance when `schema in ["auth", "openapi"] or path == "/"`
> (`test/support/conformance_server.ex:70-71`). **1652 is the only case in the
> 1650–1688 band whose path is not `/`** — verified on disk during synthesis — so
> at HEAD it reached the auth instance *via its label*, and with `schema: test`
> it now reaches the **base** instance instead. Every other case in the band is
> routed by its path and is unaffected. The assertion should still hold
> (`test.entities` exists on both instances and `reject_openapi_media/1` runs
> before relation resolution), but **the case now runs against a different server
> than it did before, and no `notes:` in the tree says so.** This is a
> spec-side edit changing harness routing through a predicate the spec cannot
> see — file it with follow-up 25's class of undeclared harness dependencies, and
> **re-check 1652 first in the conformance run**, exactly as the original finding
> asked, for a now-different reason.
>
> **The strengthening the original finding asked for was NOT done**: 1652 still
> asserts a bare status. Asserting the error `code` (PGRST107 rather than
> PGRST106) remains the change that would make the case self-evidently correct
> under any routing.

Still open at the time it was written, and that pass it surfaced by
*disappearing*. The previous pass's
machine check hit it head-on: 1652 was the only one of 16 flagged relation targets
that was not a deliberate 404 negative, and a direct catalog query confirmed
`select count(*) from pg_namespace where nspname='openapi'` → **0** — the
fixture-set label `openapi`, carried by **31** cases, has no matching schema in
the loaded DB, because `fixtures.sql` folds `openapi.sql`'s objects into `test`
while `conformance_server.ex:171` still lists `openapi` in `db_schemas`.

**This pass's script classified 1652 as `EXPECTED-ABSENT (case asserts 406
non-root-openapi)` and filed it with the nineteen deliberate negatives.** Nothing
on disk changed; the classifier simply now treats "expects a 4xx" as sufficient
evidence that an absent target is intentional. For nineteen of the twenty that
reasoning is right. For 1652 it is exactly the reasoning the finding warns
against: the case expects 406 **for the media-type rule**, and the absent schema
gives it a *second*, independent route to the same status. A classifier keyed on
status cannot tell those apart — which is why the finding is about assertion
*strength*, not about the flag.

Four passes have now surfaced this by four different routes (incidental
label audit → direct catalog query → head-on flag → silent absorption into the
negatives). **The fourth route is the most dangerous**, because it is the first
that makes the item look resolved. That is itself the argument for closing it.

The empirical data point (1652 **passes**, `mix test --only area:openapi` →
32/33) is **carried over from an earlier pass, not re-run here** — this pass ran
the static checks only, no `mix test`. Passing does not distinguish the two
possible reasons, so re-running it proves nothing new anyway; strengthening the
case is what would.

**(Historical — true at HEAD `9b72e09`, no longer true on disk; see the RESOLVED
banner above.)**
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

All **seven** `*.delta.sql` files are **comment-only** — re-verified mechanically
this pass (each file's only non-blank, non-comment content is nothing: `grep -v`
of comment and blank lines returns zero lines for all seven). Each holds a single
`-- Folded into ../fixtures.sql on <date> …` provenance line and no DDL, i.e. the
write channel is empty and the folds are recorded: `headers`
(`test.get_vary_header_override()` + GRANT), `ordering`
(`test.arrays` + seeds) and `rpc` (`test."true"()` + GRANT) — three dated
2026-08-08 — plus `url_grammar` (case 1035's `test."Server Today"` + its five
seed rows), `errors` (`test.infinite_inserts` + `test.infinite_recursion`),
`operators`, and **`content_negotiation`**, all four dated 2026-08-09.

**`content_negotiation.delta.sql` is the first channel folded TWICE, and its
second fold is the first in this tree to CHANGE an existing definition rather
than append a new object.** Its 2026-08-08 fold added the
`application/vnd.pgrst.object` / `text/tab-separated-values` domains and their
handlers; its 2026-08-09 fold adds `public."application/octet-stream"`
(section 3c) and **re-declares `test.unnamed_bytea_param(bytea)` in place**
(section 6): `RETURNS bytea` → `RETURNS public."application/octet-stream"`. The
delta shipped a `DROP FUNCTION IF EXISTS` guard so a blind append would also
converge; the guard was dropped on folding because the definition is edited in
place and `fixtures.sql` loads into a fresh DB.

**Why this is the most consequential fixture change the tree has recorded, and
why it is NOT a green-maker.** A routine's **return type** is the only thing that
registers an octet-stream handler — `initialMediaHandlers` ships json / csv /
geo+json / `*/*` and nothing else (`SchemaCache.hs#L1016`), and the discovery
query keys on `proc.prorettype` (`#L1062-L1071` for aggregates, `#L1080-L1086`
for plain non-set-returning functions). Under the old `RETURNS bytea`
transcription, case **1622**'s expected 200 was **unreachable against a faithful
PostgREST**; it would have answered 406/PGRST107. The `fixtures.sql` fold note
says the rest plainly and it should be read before anyone claims credit: **1622
was already passing**, because `lib/bier/rpc.ex:288` offers octet-stream for
*any* scalar RPC result regardless of return type — which is exactly the
over-permissive behavior the re-issued case **1623** exists to catch (1623
currently fails with `42846 cannot cast type integer to bytea`, not the expected
406/PGRST107). **Under the old fixture, 1622 and 1623 could not both be green.**
The fold is upstream-fidelity groundwork so that when `lib/` narrows handler
discovery, 1623 flips to passing and 1622 stays reachable.

Three properties of the fold are worth recording. **No aggregate over the new
domain and no GRANT** — that is what keeps 1623 (`test.add_them`, scalar) and
1624 (`test.get_lines`, `SETOF`, excluded by the discovery query's
`NOT proretset`) at 406; wiring either would silently turn both negatives into
200s. **No name collided**, so unlike the `menagerie` case below nothing was
renamed. And an **A/B run of the whole suite** against the pre-fold file reported
an identical failing-case set — the same 96 ids, zero regressions and zero flips
— with the new `public` domain perturbing nothing that enumerates types (OpenAPI;
the datarep cast lookup ignores it, since it carries no `CREATE CAST`). That A/B
is a claim from the area pass, not a measurement made by this document's
verification.

> **The generalizable finding, and it is the one to carry into every future
> area.** No check in this document inspects a fixture *declaration*. The
> relation check confirms an object exists; schema validation confirms a case's
> shape; the pin sweep confirms its tag. A case can therefore rest on a
> mis-transcribed return type, volatility, domain, or generated-column property
> **indefinitely, while passing**, if `lib/` happens to be wrong in the matching
> direction. `content_negotiation.yaml`'s new **`fixture_notes:`** key is the only
> artifact in the tree that records such dependencies; see follow-up 28.

**The mutations re-sync added no channel, no object and no date either — and it
is the pass where that decision costs the most.** There is no
`mutations.delta.sql`; `fixtures.sql` does not appear in `git status`. All 17 new
cases run against relations the consolidated fixture already had. **That is the
right call and it is also why the area's gap list nearly doubled**: the behaviors
it could not reach need *fifteen or more* relations the fixture DB simply lacks
(`foo`, `UnitTest`, `employees`, `web_content`, `artists`/`albums`, the three
`surr_*_upsert` tables, `compound_pk`, `with_multiple_pks`, `tbl_w_json`,
`bitchar_with_length`, `items3`, `empty_table`, `complex_items_view`, `app_users`,
`unsafe_update_items`/`unsafe_delete_items`), and several of them must be **real
tables** exposed under `mutations`, which a delta alone cannot achieve because
`isolate_mutations/1`'s table list is hard-coded in the loader
(`lib/mix/tasks/bier.fixtures.load.ex:541-544`). **So mutations is the first area
whose fixture gap is blocked by loader code rather than by DDL or by ownership** —
a third species alongside filters' "the row does not exist" and rpc's "the file is
human-owned". Costing any of these as "write a delta" understates them.

**The rpc re-sync added no channel, no object and no date.** `rpc.delta.sql` is
unchanged from the `test."true"()` fold; `fixtures.sql` does not appear in
`git status` at all. All three new cases run against routines the consolidated
fixture already had — `rpc.ret_void` (1441, shared with case 1409),
`rpc.variadic_param` (1442, shared with 1415/1416) and, for 1443, the *absence*
of `test.sayhell` next to the present `test.sayhello`. **That is the right
outcome for a pass whose findings are all fixture-blocked**: the three gaps that
need routines were left open and recorded rather than half-closed with
substitutes. The one substitution the pass did make — `ret_void` standing in for
upstream's `delete_items_returns_void` in case 1441 — is stated in the case's own
`notes:` with the argument for why it is sound (the PGRST128 check reads only the
routine's return type and the `Prefer` header, never the arguments).

**The operators re-sync opened the seventh channel and was the first in three
re-syncs to add fixture objects at all.** `operators.delta.sql` records the fold
of, in `fixtures.sql` section order:

- **`test.tsvector_not_null`** and **`test.tsvector_not_empty`** domains, in a new
  **section 3d**. Unlike the `public` domains of 3b/3c these live in `test`,
  because upstream creates them unqualified under its `test` search_path. The
  second is defined **over the first** — a domain over a domain — which is the
  only thing that lets cases **10229** and **10230** distinguish a tsvector domain
  from a *recursive* one. Both must be exempt from the automatic `to_tsvector()`
  coercion, and are, because PostgREST's introspection resolves `base_type`
  transitively.
- **`test.items_with_different_col_types`** (section 4) with upstream's single
  seed row `(1, null × 7)` (section 8) — eight columns, one per base type, for
  the `in.()` sweep. Cases 10200–10205.
- **`test.tsearch_to_tsvector`** (section 4, immediately after the pre-existing
  and **distinct** `test.tsearch`) with upstream's five seed rows and three
  derive-`UPDATE`s (section 8). Where `tsearch` stores ready-made tsvectors, this
  one stores the same five documents unconverted as text/jsonb/domain, which is
  what exercises the coercion. Cases 10220–10227, 10229, 10230.
- **`test.text_search_vector(test.tsearch_to_tsvector)`** computed field
  (section 6). Case 10228.

Three properties of the fold are worth recording because they are the kind of
thing a later reader would otherwise have to re-derive: **no name collided**, so
unlike the `menagerie` case below nothing was renamed; **no `GRANT` was added**
(section 9 untouched), because the loader mirrors `test` relations into the area
schemas as views owned by the connecting role — the same path by which the
operators area already reaches `test.entities`/`ranges`; and upstream's
`test.get_tsearch_to_tsvector()` was **deliberately not folded**, since it is an
`/rpc` target no operators case needs and folding it would make the loader emit a
wrapper into all seven mirrored area schemas for nothing.

The two re-syncs before it added **no** channel and no fixture object:
`pagination.delta.sql` and `observability.delta.sql` do not exist. Pagination's
eleven new cases, three of them on `/rpc/` paths, all ran against relations and
functions the consolidated fixture already had (`pagination.items`,
`pagination.getitemrange`); observability's two new cases ran against
`observability.organizations` (1770) and the root path (1771).

**The observability re-sync did touch `fixtures/observability.sql`, and it is
worth being precise about how**, because that file is otherwise off-limits: the
change is **comment-only**. It re-pinned the header's provenance URLs from
`github.com/.../blob/v14.12/…` to `raw.githubusercontent.com/.../v16.0/…` — all
seven anchored line numbers confirmed unchanged between the pins — and added two
missing provenance lines for objects the file already created (`projects`,
`tiobe_pls`). No DDL, no seed row, and no object was added, removed or altered;
`git diff` on the file is entirely `--` comment lines. It is the first fixture
fragment in the tree to be re-pinned to v16.0, which is why the stale-pin count
above dropped from 51 to 44 across seven files rather than eight. **`rpc.sql` has
since become the second** (commit `6b25f05`), taking it to **43 across six**.

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

**The mutations pass makes that rename load-bearing in both directions, which is
new.** Case **11402** POSTs an `x-www-form-urlencoded` body with seven typed
fields to `/menagerie` — upstream's own target at `InsertSpec.hs#L171`, and the
7-column type-mapping table is exactly the relation it needs. So one set of cases
now depends on `menagerie` being the 7-column table and another on
`menagerie_empty` being the empty one. Neither name is free to move, and a future
fold that "resolves" the collision by renaming either would break one set
silently.

Across the seven area re-syncs before the operators one — filters (9 cases),
ordering (6), url_grammar (6 + 2 rewrites), errors (8), pagination
(11 + 8 rewrites) and observability (2 + 6 rewrites) — **42 new cases produced
exactly three new relations**, all three from the errors and url_grammar passes.
The rpc (3 cases) and mutations (17 + 1 rewrite) passes since have produced
**zero**. **The operators
pass broke that pattern hard**: 37 new cases, **two new tables, two new domains
and one new computed field** — more fixture surface than the previous six passes
combined, and the reason is structural rather than stylistic. Where those passes
found uncovered *rules* on relations that already existed, this one found two
uncovered *upstream fixtures* (`items_with_different_col_types`,
`tsearch_to_tsvector`) whose whole purpose is to have column types the rest of the
fixture set does not.

**The content_negotiation pass adds a species to that taxonomy, and it is neither
"a new rule on an existing relation" nor "an uncovered upstream fixture".** It
found an **existing** relation that was *transcribed wrongly* — one line of DDL,
no new coverage surface, and yet the difference between a case being reachable
and not. Costing fixture work as "does this add objects?" misses this class
entirely: the fold added one domain and changed one signature, which is the
smallest fixture diff any re-sync has produced and the only one that fixed a
false assertion.

**The gaps remaining in this file that would still add fixture surface, re-costed
at the 746-case state.** Previously two: filters' `empty_string` row (which would
be a first `filters.delta.sql`) and headers' three `delete_items_returns_*`
routines; plus url_grammar's three quote/backslash seed rows for
`test.w_or_wo_comma_names` — though **not** the fourth (`David White`), which is
why that one is costed as case-only. **The rpc audit added three more, and they
are the largest block of fixture-blocked work in the file**:

- `returns_record`, `returns_record_params`, `returns_setof_record`,
  `returns_setof_record_params` (Untyped functions);
- a routine that **echoes** a non-variadic array parameter — upstream's
  `varied_arguments` — since `test.varied_arguments_openapi` accepts arrays but
  returns only `{"double": …, "integer": …}`;
- `unnamed_text_param`, `unnamed_xml_param` and `unnamed_int_param` (the
  `text/plain` / `text/xml` single-unnamed-parameter pair and the PGRST202
  envelopes that go with them).

All eight names were grepped against `fixtures.sql`, `fixtures_local.sql` and
`fixtures/rpc.sql` this pass and are absent from all three. **They are also the
first fixture gaps in this file whose blocker is ownership rather than
absence** — see the caveat under *Known gaps* and follow-up 22.

**Two costs this file previously listed are still gone**:
`items_with_different_col_types` is folded, so the `in.()` eight-column-type
sweep is pure case work, and the filters `in.()` entry is closed outright.
**Neither errors gap, nor the pagination gap, nor either operators finding, nor
the two case-only rpc findings needs a delta**: the errors ones are HEAD requests
against `test.items`, the embedded-`.offset` case runs on
`pagination.clients`/`projects`, both operators findings run on `test.tsearch`
(which already seeds an english, a french and a german document), and the two rpc
ones run on `test.getproject`/`test.clients`/`test.tasks` and `test.sayhello`
respectively — all verified present in `fixtures.sql` this pass.

**Four of the seven content_negotiation findings need no delta either — but
"present in `fixtures.sql`" is no longer a sufficient check, and this pass is
why.** The `db-plan-enabled` 406 and the q-factor `Accept` case run against
`test.items`/`test.organizations` and need nothing at all. The `*/*`-handler-on-a-
TABLE and `application/geo+json`-override cases need an aggregate whose **return
type** (not stype) is the mime-named domain and whose argument is the relation's
row type — a *declaration*, not a name. **Confirm the declaration before costing
either as one case file**; case 1622 spent this whole pass proving that a
present, reachable, correctly-named object can still be the wrong object.

## Review status

The v16.0 re-sync re-pinned **every** case `source:` from `v14.12` to `v16.0`, so
the per-area audit verdicts recorded by the v14.12 pass no longer describe the
citations on disk and are not carried forward. All 17 area behavior models are
marked with the v16.0 pin. (The pin's *key spelling* is not uniform — 10 models
use `version: v16.0`, five use `version: PostgREST v16.0` (`errors`, `filters`,
`observability`, `operators`, `ordering`), `pagination.yaml` uses
`postgrest_version: v16.0`, and `url_grammar.md` states it in prose.)

> **Nor is the gap-list shape uniform.** Re-counted on disk this pass, entry by
> entry: **three** of the 17 models have no `gaps:` key anywhere — `errors.yaml`
> (which records coverage under `coverage:` plus a `harness_gate:` key) and
> **`content_negotiation.yaml` and `operators.yaml`, which record no gap list at
> all, under any key.** `url_grammar.md` uses a
> `## Gaps` markdown section. The remaining **thirteen** `.yaml` models carry
> between **5** and **16**
> entries: `config.yaml` and `observability.yaml` **16** each (the joint longest
> — an earlier revision credited observability alone), `auth.yaml` **15**,
> **`openapi.yaml` 14** (6 → 14 this pass, the largest single-pass growth this
> key has had), `filters.yaml` **14**, `mutations.yaml` **11**,
> `pagination.yaml` / `select.yaml` **11** each,
> `headers.yaml` / `rpc.yaml` **7** each,
> `ordering.yaml` **6**, `domain_representations.yaml` /
> `representations.yaml` **5** each. **The set of silent models did not change
> this pass** — `errors`, `content_negotiation` and `operators` remain the three.
>
> **`openapi.yaml` is now joint fourth-longest (14, level with `filters`) AND the
> second model to carry `fixture_notes:`, and its audit still returned two
> findings.** That
> combination is the most useful data point this section has: disclosure volume
> does not predict coverage. Its 14 entries include **four** marked RESOLVED and
> retained as a record (the `schema:` label correction, the `preferParams`
> empty-enum, the `produces`/`consumes` list, and the server-proxy-uri premise
> that was *wrong on its face* and is now modelled with `cases: []`), **two**
> `harness_gate:` entries naming the exact `@variant_case_ids` edit required, one
> `operator_action:` on the inert `preconditions:` key, and one
> `needed_assertion: nothing` — the second instance of the entry
> `representations.yaml` introduced, recording that the existing schema keys were
> sufficient so a later pass can tell "checked and fine" from "nobody looked".
>
> **`content_negotiation.yaml` invented a NEW key instead of writing the missing
> one, and the new key is better than the one it skipped.** It added top-level
> **`fixture_notes:`** — three entries, each naming an object, the exact property
> its cases depend on, and what breaks if that property changes: that
> `test.unnamed_bytea_param` **must** return the `"application/octet-stream"`
> DOMAIN (with plain `bytea`, case 1622 answers 406); that
> `public."application/octet-stream"` must exist **and** be some routine's return
> type, because a domain alone registers nothing; and that `test.add_them` **must
> keep** its plain `integer` return, because a mime-named domain there would
> silently turn case 1623's 406 into a 200. **No other model records a fixture
> dependency at all.** This pass is the reason that matters: the area's own
> fixture defect made a case's assertion unreachable while every mechanical check
> in this document stayed green. The key belongs in every area whose cases depend
> on a *declaration* rather than on seed data — see follow-up 28.
>
> **`representations.yaml` is new to this list, and that is the pass's most
> durable output.** It went from *no gap key under any name* to **five entries**,
> and the five are unusually well sorted by *kind* rather than by topic: one live
> structural gap (`is.null`, unreachable on a base table), two entries whose whole
> purpose is to argue that a case should **not** be written (the
> `with_multiple_pks` / `compound_pk_view` de-duplication, and the uncased
> `count=exact` Content-Range halves), one `operator_action:` entry about the
> inert `preconditions:` key, and one `needed_assertion: nothing` entry recording
> that every behavior cased this pass was expressible with the existing schema
> keys. **That last entry has no precedent in the tree** and is worth copying: it
> pre-empts a later pass re-deriving the question, and it is the only way a reader
> can distinguish "the harness was sufficient" from "nobody checked".
>
> **A long gap list is not a covered area, and the rpc pass is the proof.**
> `rpc.yaml`'s seven entries are unusually rigorous — two of them argue at length
> against approximating a behavior rather than omitting it — and its audit still
> returned **five** findings, none of which any entry anticipated. Length measures
> how carefully an author declined the gaps they *saw*.
>
> **`mutations.yaml` is the counter-example, and it sets the standard the others
> should be read against.** Its list grew 6 → 11 *because of* its audit rather
> than in spite of one, and the new entries are the most operationally specific in
> the tree: each names the missing relation, quotes the upstream it-block it
> blocks, and closes with a `loader_exposure:` clause stating what the loader
> would have to build (often "a **real table**, because the area's view mirror
> does not preserve column DEFAULTs / identity / the generated-column
> rejection"). One entry decomposes composite-pk UPSERT **leg by leg**, cases one
> leg (11414) and argues the other two down against a verified fact — that
> `car_models` exists but seeds **zero** rows. **Specificity, not length, is what
> distinguishes a gap list you can act on from one you can only read.**
>
> **The "silence = un-audited" heuristic is now fully dead, and the two
> exceptions point opposite ways.** It once held that all three silent models
> were also un-audited, so silence and absence of scrutiny were
> indistinguishable. `operators.yaml` broke it first: **audited (✅ pass, 0
> citation defects) and still silent** — its re-sync more than doubled the area's
> cases and rewrote a third of the model while adding **no `gaps:` key**, so its
> two open findings and its five-column-type residual live only in this file.
> That is a defensible choice (the model is a mechanism description, not a
> coverage ledger) but it is a *choice*, and it should be made explicitly rather
> than inherited: see follow-up 19.
>
> **`representations.yaml` broke it the other way, which settles the argument.**
> It was audited to the same verdict (✅ pass, 0 citation defects) and **wrote a
> gap list**, five entries, including one recording that *nothing* was needed
> from the harness. Two ✅ *pass* areas, two opposite conventions, in consecutive
> passes. The evidence now favours writing the list: `operators`' residual is
> discoverable only by reading this 3 000-line file, while `representations`'
> is discoverable by reading the model it belongs to. **Follow-up 19 should
> resolve to "an audited area writes its gaps into its model", and `operators.yaml`
> should be backfilled.**
>
> **`content_negotiation.yaml` has now been AUDITED and stayed silent, which
> empties the "silent and un-audited" category and makes `operators` a pattern
> rather than an exception.** The one remaining un-audited model —
> `domain_representations` (5 gap entries) — carries a list, so **no model
> in the tree is now both silent and unexamined**. What is left is two audited
> areas, **seven findings between them**, and **zero gap entries written**:
> `operators`' two findings plus its five-column-type residual, and
> `content_negotiation`'s seven, all of which exist only in this file. **Follow-up
> 19's resolution should now be stated as work, not as a principle: backfill both
> models.**
>
> **The openapi pass is the third audited-area data point and it splits the
> argument rather than settling it.** It wrote its findings into its model
> *before* the audit — 6 → 14 entries plus a five-entry `fixture_notes:` — and
> the audit still found two behaviors with neither a case nor an entry. So:
> writing the list is clearly better (its 14 entries are the most operationally
> specific in the tree after `mutations`', and two of them hand a Bier maintainer
> an exact one-line harness edit), **and it is not sufficient**. Follow-up 19
> should resolve to "an audited area writes its gaps into its model" on the
> evidence of `openapi` and `representations`, while nothing in the evidence
> suggests a written list reduces the value of an independent audit.

Adversarial review summaries recorded so far cover **auth**, **headers**,
**config**, **select**, **filters**, **ordering**, **url_grammar**, **errors**,
**pagination**, **observability**, **operators**, **rpc**, **mutations**,
**representations**, **content_negotiation** and **openapi** — **16 of 17**
areas. **Thirteen** are ⚠️ *revise* and **three** are ✅ *pass*; **every one of the
sixteen reports 0 citation defects**, so no verdict in this table has ever turned
on a mis-cited line. What separates them is entirely coverage:

> **Only `domain_representations` is now un-audited at this pin, and it is the
> one area whose entire subject is TYPE DECLARATIONS.** Two consecutive passes
> have found a defect in a field no mechanical check reads — a fixture return
> type (content_negotiation) and a `schema:` label (openapi) — and
> `domain_representations` is 21 cases about `CREATE DOMAIN` cast behavior, i.e.
> the area where a declaration defect would be hardest to see and cheapest to
> make. **Run it before treating the tree as audited.**

| Area | v16.0 audit result | Nature of findings |
|------|--------------------|--------------------|
| auth | ⚠️ revise | 4 informational gaps, **0 citation defects** — the reviewer independently re-verified each gap's justification against v16.0 sources and confirmed all four are correct. See **Known gaps → auth**. |
| headers | ⚠️ revise | 3 missing-coverage findings, **0 citation defects** — RPC-flavored `max-affected`, RPC-flavored `handling`, and the CORS-preflight leg of the `Vary` rule. **The PGRST128 leg of the first is now closed** by rpc case **1441** (the rpc area took ownership, the rule having no table flavor to delegate); its PGRST124 leg and the other two findings remain *citable but uncovered*. See **Known gaps → headers**. |
| config | ⚠️ revise | 2 missing-coverage findings, **0 citation defects** — `db-pre-config` (the v16-*recommended* in-database config mechanism, dump-observable, while cases 1724/1725/1744 cover only the deprecated `ALTER ROLE` path) and `app.settings.*` reaching SQL as a GUC (1729 pins only the dump surface). Both *citable but uncovered*. See **Known gaps → config**. |
| select | ⚠️ revise | 5 missing-coverage findings, **0 citation defects** — FK joins on views / chains of views (20 upstream it-blocks, no case *and* no gap entry), spread to-many (gap recorded but its "needs a fixture" justification does not hold), aggregates in to-one spreads + the PGRST127 rejection (entire upstream context, absent from the whole tree), FK joins on partitioned tables, and the terminal `->` on a json/jsonb column. All five *citable but uncovered*. See **Known gaps → select**. |
| filters | ⚠️ revise | 3 missing-coverage findings, **0 citation defects** — the `IN`/`NOT IN` empty set (an 11-it-block upstream `describe`, `in.()` issued by no case in the tree, while `operators.yaml` already models the `= ANY('{}')` rendering it produces), the empty filter *value* (`?string=eq.` → `""`), and the implicit AND of two plain filters. All three *citable but uncovered*. See **Known gaps → filters**. |
| ordering | ⚠️ revise | 2 missing-coverage findings, **0 citation defects** — *Order in spread to-many* (a named v16 docs section with its own worked example, exercised by upstream at `SpreadQueriesSpec.hs#L163` and `AggregateFunctionsSpec.hs#L157/#L168`, and asserted by **no case anywhere in `spec/`**) and the aliased-relation PGRST118 (upstream asserts `order=pros(id)` naming the **alias** in both `details` and `message`; case 1216 covers only the unaliased twin). Both *citable but uncovered*, both case-only. See **Known gaps → ordering**. |
| url_grammar | ⚠️ revise | 1 missing-coverage finding, **0 citation defects** — backslash / escaped-double-quote values inside `in.( … )`, a named part of the area's own docs page with three upstream `it`-blocks (plus one in the adjacent describe) and **no case anywhere in `spec/`**. *Citable but uncovered*, and **partly case-only**. The pass also produced two case repairs that are *not* review findings but belong on the record — **1016** re-anchored off implementation code onto `UpsertSpec.hs#L295` (retiring a false "no Feature spec line exists" claim) and **1029**'s overstated "byte-identical parser" note corrected. See **Known gaps → url_grammar**. |
| errors | **✅ pass** | **The tree's only pass verdict.** 3 findings, **all explicitly MINOR / non-blocking**, **0 citation defects** — no `Proxy-Status` assertion on a HEAD request (the docs' stated motivation, but the behavior is method-independent in `errorResponseFor`), the modelled `inline_416_content_length_suppressed_on_head` flag that no case exercises (the one genuinely method-dependent behavior, and case-only to close), and the 42883 `xmlagg` → 406 special case (effectively unreachable black-box, accepted as-is). The pass additionally confirmed by reproduction in a scratch DB that cases **1523/1524**'s fixtures behave as asserted, and flagged a **harness gate** (1517/1518/1522 need `@variant_case_ids` entries) that is Bier-side wiring, not a spec defect. See **Known gaps → errors**. |
| **pagination** | ⚠️ **revise** | 1 missing-coverage finding, **0 citation defects** — embedded **`<embed_path>.offset` has zero cases anywhere in the tree**, while `<embed>.limit` has one (1276); the model names both parameters and cites the docs example for the offset half, and its `constraints:` only justify omitting a *deeper-nested* offset case, never the single-level one both `resource_embedding.rst#L919` and `QueryLimitedSpec.hs#L42` exercise. *Citable but uncovered*, **case-only**, and now the cheapest open item in this file. The pass is also the tree's most substantial **model correction** to date: the Range header was documented as *overriding* limit/offset when `getRanges` **intersects** them (new discriminating case 1287), four traceable-but-unmodeled behaviors were added (PAG-025..PAG-028), four cases were retargeted off a fixture name collision (`/menagerie` → `/menagerie_empty`), and two `source:` anchors were moved onto their actual assertion lines (1268, 1269). See **Known gaps → pagination**. |
| **observability** | ⚠️ **revise** | 4 missing-coverage findings, **0 citation defects** — and unusually, **three of the four are blocked on the harness rather than on authoring effort**: the entire docs **Metrics** section (admin `/metrics`, `pgrst_db_pool_*`, `pgrst_schema_cache_*`, `pgrst_jwt_cache_*`, `ghc_*`; modelled in 5 entries, needs `request.kind: admin`, verified against `test_io/test_admin.py#L132`), **access-log line emission** (docs L15–L48: Apache-combined format, `-` placeholders, per-level line counts; needs `expect.stdout_matches`, and cases 1764–1767 assert only the status the filter keys on), and the **`server-trace-header` empty echo** (`App.hs#L289`, blocked by a direct conflict with case 1573's `headers_no_blank` on the shared instance). The fourth — **`Server-Timing` absent on error responses** (`App.hs#L154` vs `#L253`) — is black-box observable and cheap, left uncased *deliberately* because upstream never asserts it; promotable on request. Separately confirmed source-accurate: the **SQL query log** entry (`log-query`, gate at `App.hs#L223`, rendering at `Logger.hs#L192-195`), stderr-only, gap justified. The pass also **retracted a modelled rule** — the OPTIONS Server-Timing "subset" never existed at either pin — and **closed one gap**, the Server version header (case 1771). See **Known gaps → observability**. |
| **operators** | **✅ pass** | **The tree's second pass verdict**, and the pass with the largest coverage delta of any so far: **50 → 87** cases (37 new, ids 10200–10236, **0 rewritten**). 2 findings, **both explicitly MINOR / non-blocking**, **0 citation defects** — no case for `not.plfts` / `not.phfts` / `not.wfts` (the `not` prefix is a single wrapper already pinned on `fts` at both flavors, cases 1090/10227, and on nine other operators), and no case putting an fts filter inside an `or=()` tree with three dictionaries (case 1099 already pins `not.fts` inside `and()`, and `or=()` composition is covered by filters). Both *citable but uncovered*, both case-only. The pass's substance was elsewhere: it **closed the filters area's `IN`/`NOT IN` empty-set gap** (cases 10200–10205 + the folded `test.items_with_different_col_types`) and it found that an entire upstream `context` block — the automatic `to_tsvector()` coercion for fts against **non**-tsvector columns, plus the tsvector-domain, recursive-domain and computed-field variants and the tsquery/websearch operand grammar — existed at **both** pins with **zero** coverage (cases 10220–10236, new model entry `grammar.fts_auto_tsvector`). It is the first re-sync in three to add fixture objects and the first ever to close another area's recorded gap. Residual: only **three of eight** `in.()` column types are swept. See **Known gaps → operators**. |
| **rpc** | ⚠️ **revise** | **5 missing-coverage findings — the most any single area audit has produced — and 0 citation defects.** Against an area that had *just* been re-synced (41 → 44 cases, 3 new / 6 rewritten, **no fixture object**): the *Untyped functions* docs H2 (routines returning `record` / `SETOF record`, `RpcSpec.hs#L486`/`#L496`; `grep -rniE "returns_record\|setof record\|untyped function" spec/` → **zero** matches tree-wide), the *Functions with array parameters* docs H2 (a **non**-variadic array param bound three ways — JSON body `#L515`, GET literal `?arr=%7Ba,b,c%7D` `#L545`, form body `#L564` — distinct from the VARIADIC rule the area already models; the only other mention of array params in `spec/` is openapi's *schema output* cases 1667/1671/1673, never an invocation), the **text** and **xml** flavors of the single unnamed parameter (`#L1170`/`#L1177`, leaving the `MTTextPlain`/`MTTextXML` PGRST202 branches at `#L1207` unexercised while only the bytea flavor is covered, and from the *content_negotiation* area at that), *Resource Embedding on table-valued functions* (`#L324`; covered only incidentally by case **1023**, whose real subject is `/rpc` profile routing), and `?columns=` on a POST to `/rpc/` (`#L855`, note-only). All five *citable but uncovered*; **two are case-only** (the embed, `?columns=`) and **three are fixture-blocked by ownership**, not absence — the routines belong in the human-owned `fixtures/rpc.sql`. All nine cited lines were re-fetched during synthesis and read as claimed. See **Known gaps → rpc**. |
| **mutations** | ⚠️ **revise** | **0 citation defects**, and the first verdict whose findings were substantially **closed inside the pass** (48 → 65 cases: 17 new, 1 rewritten, **1 authored then deleted**, **no fixture object**). Closed in-pass: resource embedding on mutations, for every flavor the fixture DB can reach — **11412** (DELETE + to-one parent, `DeleteSpec.hs#L71`), **11413** (PATCH + one-to-one, `UpdateSpec.hs#L579`), **11415** (PATCH + m2m with a nested parent, `UpdateSpec.hs#L539`), joining representations case 1300 for POST. Also closed: the form-urlencoded insert body (11402), insignificant whitespace (11403), the empty-body PGRST102 (1398), the unique-violation 409/`23505` (11401), multi-row PATCH `Content-Range` (11400), the only-pk-table upsert pair (11410/11411), composite-pk upsert POST/PUT (11414/11408) and its PGRST105 rejection (11409), PUT ignoring `Range` (11407), UPDATE-flavored `max-affected` (11405), ignore-duplicates-with-nothing-created (11404) and the PUT-`offset` PGRST114 (1399). **One modelled rule WITHDRAWN**: `?columns=` on PUT, which nothing at v16.0 asserts and the PUT docs contradict (`tables_views.rst#L689`) — the first correction in this tree of a rule that was never a version claim, merely uncited. **One case DELETED** (11406, PUT `return=minimal`) as strictly weaker than representations case 1332, leaving a deliberate hole in the new band. Open residue: almost entirely **relation-blocked** — 15+ upstream relations the fixture DB lacks, several needing **real tables** the loader's hard-coded `isolate_mutations/1` list cannot be extended to by a delta — plus one editorial item, the four-way cross-area duplication of the PGRST114 PUT rule (1016/1383, 1030/1399). See **Known gaps → mutations**. |
| **representations** | **✅ pass** | **The tree's third pass verdict**, **0 citation defects**, and the **first pass verdict on a model that carried no gap list at all** — it now carries five. 24 → **32** cases (8 new, 1 rewritten, 0 deleted, **no fixture object**). Findings closed in-pass: the two remaining `Location` suppressions under `return=headers-only` (bulk insert **1315**, no-PK relation **1317** — each sufficient alone, `Query/Statements.hs#L48`/`#L49`), `return=representation` never carrying a `Location` (**1316**), and the four `Prefer`-grammar rules the model stated but never exercised — duplicate `return=` resolving to the first token in **request** order (**1318**), an unknown value being *ignored* rather than rejected (**1319**), `Preference-Applied` rendering in the fixed `prefsVals` order (**1327**), and `return=` echoed **only** for mutations, on a read (**1325**) and an RPC (**1326**). **One citation NARROWED, a fourth species of anchor motion**: `InsertSpec.hs#L745` proved the no-`Location` rule only for a **view** (it sits under `describe "Inserting into VIEWs"`), replaced by `#L157` + `#L99`; case **1309** rewritten with it. **One gap entry CORRECTED**: the claim that `compound_pk_view` adds a view-specific angle 1309 misses is **false** — `car_models` is not in `isolate_representations`' real-table list, so 1309 *already* runs against a view mirror. **It also broke the implementation-anchored plateau**: 7 of its 8 new cases anchor at `src/library/PostgREST/…`, taking the tree 46 → **53** (6.3 % → 7.2 %), every one pinning a rule upstream never asserts black-box. Open residue: **one** entry, and it is unreachable by construction rather than unwritten — the `is.null` key-column `Location`, which needs a multi-base-table view because `PRIMARY KEY` implies `NOT NULL`. See **Known gaps → representations**. |
| **content_negotiation** | ⚠️ **revise** | **SEVEN missing-coverage findings — the most any single area audit has produced, surpassing rpc's five — and 0 citation defects.** 47 → **52** cases (6 new, 1 deleted, **1 id reused**, 3 rewritten, and — uniquely — **1 fixture object corrected**). Uncovered: the **`db-plan-enabled = false` 406** gate (modelled twice, declared in five cases' inert `preconditions:`, pinned by none; `PlanSpec.hs#L544`); the `*/*` handler's **`Content-Type` override** from inside the function *and* its rejection of non-matching types (case 1638 covers only the default half; `CustomMediaSpec.hs#L346`); the `*/*` handler on **TABLES/VIEWS**, i.e. the `(RelId, MTAny)` probe the model documents as step (1) and that "overrides all other handlers" (`#L369`); overriding the builtin **`application/geo+json`** handler for a single relation (asserted in the model, no case; `#L188`); **q-factor ordering** of the `Accept` list (modelled with a cited test, but case 1601 resolves identically with or without q-sorting — the same non-discriminating shape the pagination audit found; `#L208`); and the **`text/plain`/`text/xml`** unnamed-parameter bodies (shared with rpc; `RpcSpec.hs#L1168`). The seventh is the **id-reuse hazard** left by deleting old case 1623. **Three corrections beyond coverage**: a **FIXTURE** was wrong (`test.unnamed_bytea_param` returned plain `bytea`, not the mime DOMAIN, making case 1622 unreachable while it passed); the modelled handler-discovery mechanism keyed on an aggregate's **stype** when upstream keys on `proc.prorettype` and has a second branch for plain functions (`SchemaCache.hs#L1062-L1071`/`#L1080-L1086`); and two claims were weakened to what their citations support ("byte-identical" → *modulo whitespace*; "NEW in v16.0: Query Identifier" → *upstream added a test*, the field being PostgreSQL's). **Audited and still silent** — no `gaps:` key — but it invented **`fixture_notes:`**, the tree's first record of fixture dependencies. All seven *citable but uncovered*; six case-only, one fixture-blocked by ownership. See **Known gaps → content_negotiation**. |
| **openapi** | ⚠️ **revise** | **The SMALLEST finding count any *revise* verdict has produced — two — against an area whose gap list is joint fourth-longest in the tree (14 entries), and 0 citation defects.** 33 → **39** cases (6 new, **33 rewritten**, 1 authored then **withdrawn**, **no fixture object**, no delta channel). Uncovered *and undisclosed*: the `/rpc/*` path item's per-operation `produces` (a 3-element list) and `responses.200 = "OK"` (`OpenAPI.hs#L357-358`), emitted on **every** routine item in **every** document; and the shared **`$.parameters.on_conflict`** definition (`#L239-245`), emitted in every document regardless of schema, role or config. Both *citable but uncovered*, both **case-only**, and both absent from `openapi.yaml`'s 14 gap entries under any wording — verified during synthesis (`on_conflict` matches four case files, none in the 1650–1688 band, and zero lines of `openapi.yaml`). **Four corrections beyond coverage, and the first of them is the pass's real subject**: (1) all **33** committed cases were relabelled — **31** carried `schema: openapi`, a schema that **does not exist**, so they shipped `Accept-Profile: openapi` and would have described an **empty document** against a faithful implementation, passing only because Bier dispatches the root path before resolving the profile; (2) **1689** was authored, found red on a harness gate (`@variant_case_ids`, verified to be exactly 18 ids) and **withdrawn** rather than shipped broken — the tree's third and cheapest deletion convention; (3) the area's **two** non-empty `preconditions:` were removed, both of them *wrong* as well as inert (1654's would have broken 1656; 1672's contradicted its own assertion), taking the tree-wide count 44 → 42; (4) **six** anchors moved, four *onto* implementation code, one *off* it onto the documentation (1682 → `openapi.rst#L71`) and one onto `SpecHelper.hs#L104` — the tree's first shared-helper anchor — after the audit found `RootSpec`'s it-blocks run under a `db-root-spec` config and so witness a different path than case 1650 models. It wrote the tree's **second** `fixture_notes:` key (5 entries) and took its gap list 6 → 14, **and the audit still found two holes** — the same lesson `rpc.yaml`'s seven rigorous entries taught, now against an author who disclosed more, not less. See **Known gaps → openapi**. |
| the other 1 area | not re-audited at this pin | `domain_representations`. Citations are self-reported at the v16.0 pin. It carries a gap list (5 entries), so **no model in the tree is both silent and un-audited** — the category `content_negotiation` used to occupy is empty. |

Open follow-ups:

1. Run `bier-spec-audit` over the **2** areas without a recorded v16.0
   adversarial verdict: **`openapi`** and **`domain_representations`**.
   (`observability` came off this list with a *revise* verdict; `operators` with
   a **pass** verdict; `rpc` with a *revise* verdict and **five** findings;
   `mutations` with a *revise* verdict; `representations` with a **pass** verdict
   and a newly written five-entry gap list; **`content_negotiation` came off it
   this pass** with a *revise* verdict and **seven** findings — the largest count
   yet. **A completed re-sync is not evidence of coverage; only an audit is.**)
   **The content_negotiation result strengthens that argument in a new
   direction and supersedes the rpc one as the headline**: rpc showed that a
   *freshly re-synced* area can hide two whole docs-page H2 sections;
   content_negotiation showed that a *silent* area can hide seven findings **and a
   defective fixture that made one of its own cases unreachable while passing**.
   The two remaining areas are both silent about nothing — they carry gap lists —
   but neither has had its citations or its **fixtures** re-read.
   **Name the specific exposure now, rather than after the fact**, as this
   follow-up did successfully for case 1332 and unsuccessfully for
   content_negotiation (whose exposure it predicted as *implementation anchors*,
   which did not materialise, while missing the fixture defect entirely):
   `openapi`'s 33 cases all carry a `schema:` label naming **no schema that
   exists** (finding 2 below), and `domain_representations` is the one area whose
   entire subject is a **type declaration** — `CREATE DOMAIN` plus casts — which
   is precisely the class of fixture property no check in this document inspects.
   **If one of the two is run first, run `domain_representations`.**
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
   also closes the tree's only *request-shape* blind spot: all **13** existing
   HEAD cases expect 2xx (re-derived at the 746-case state), and the last **eight**
   re-syncs added **73** cases between them without adding a single HEAD of any
   kind. **The content_negotiation pass is now the sharpest miss, displacing
   representations**, and for a reason specific to it: `Content-Type` is the one
   response header a HEAD response still carries in full, negotiation is the one
   subject whose whole assertion is that header, and two of the pass's six new
   cases (**1623**, **1647**) are 406 envelopes — exactly the status-plus-header
   shape a HEAD-that-errors case asserts. **Retained**: six of representations'
   eight new cases turned on `headers_absent` on a POST or GET, which is the same
   vocabulary. Two consecutive passes with an obvious occasion, and neither took
   it.
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
   1129–1133/1139/1140/1147–1149, the three errors cases 1517/1518/1522, and
   the three observability cases **1765/1766/1767**. Until then 1742 fails for
   the wrong reason, the eight aggregate cases run with `db-aggregates-enabled`
   at its `False` default, the three verbosity cases run verbose, and the three
   log-level cases run at the shared instance's `:error`. **116** cases carry
   `config:` (112 non-empty), unchanged for a fourth consecutive pass; **60** HTTP
   cases carry a non-empty block outside
   `@variant_case_ids`, of which those seventeen are the ones whose assertion
   actually diverges from the shared instance.
   **The content_negotiation audit adds an eighteenth case to this question and it
   is of a new kind: the case that OUGHT to carry a `config:` block and does not.**
   Closing that area's `db-plan-enabled = false` 406 finding requires a request
   answered under a config that *differs* from the shared instance, so it needs
   either an `@variant_case_ids` entry or the general fix. Note the five existing
   plan cases (1625–1628, 1643) declare the requirement in `preconditions:`
   instead — a key that is inert for a *different* reason — so this item and
   item 25 are two halves of one problem. **Settle them together.**
10. Review the **53** cases whose `source:` anchors implementation code rather
    than an upstream assertion, plus **case 1279**, the tree's only
    docs-anchored citation. **The total did not move this pass, and that is a
    coincidence — the membership changed by four.** Out: **1600** (re-anchored
    onto `RawOutputTypesSpec.hs#L15`) and the **deleted** old 1623. In: the
    **re-issued 1623** (`SchemaCache.hs#L1016`) and **1648**
    (`MediaType.hs#L127-L129`, a module doctest). **Do not read a flat total as a
    flat set.**
    **Motion here now runs in FIVE directions** — 1189 (filters), 1016
    (url_grammar) and now **1600** (content_negotiation) moved *off*
    implementation code; errors added two with explicit justification; pagination
    added six and re-anchored two (1268, 1269) onto their actual assertion lines;
    observability moved **1757, 1768, 1769 onto** implementation code while moving
    **1767 off** it and adding two more (1770, 1771); mutations moved **1352**
    *sideways* to the correct it-block; representations **narrowed** the model's
    `InsertSpec.hs#L745` citation to `#L157` + `#L99` because the old anchor's
    enclosing `describe` scoped it to views; and content_negotiation **split**
    case 1622's evidence — anchor unmoved, five supporting citations added inside
    `notes:` because the anchored it-block asserts only `respBody == file` and the
    case asserts a status and a `Content-Type` too. Each remaining entry should
    either follow 1189/1016/1600 back to an it-block, or say in `notes:` why no
    it-block exists. **The 1622 pattern is the one to generalize**: when a case
    asserts more than one anchor proves, add citations rather than move the
    anchor. Treat this as a real defect source, not hygiene. It has grown in
    three of the last seven passes, shrunk in none, and held flat *through
    motion* once.
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
13. Close the **two remaining** filters gaps. **The third — the `in.()` /
    `not.in.()` / `in.(    )` / `in.( ,3,4)` set — is CLOSED**, by the operators
    pass (cases 10200–10205, band 10200+, fixture
    `test.items_with_different_col_types` folded). Of the two left, the
    two-plain-filters AND is case-only but still needs a band decision, because
    filters' primary band 1150–1199 is full (overflow `[10600..10799]`); the
    empty-`eq.` case needs a seeded `''` row, which would be the filters area's
    first fixture delta. Note the collision with item 12 has **narrowed but not
    gone**: of the three gaps about `in.( … )` spread over three areas, the
    empty-set one is now settled in `operators`, leaving url_grammar's escaped-char
    values (item 12) and the general value grammar. Settle the remaining ownership
    once.
14. Decide whether to re-pin the remaining **43** `v14.12` provenance URLs in the
    **six** `spec/conformance/fixtures/*.sql` files (`ordering.sql` 27,
    `errors.sql` 5, `auth.sql` 4, `mutations.sql` 3, `config.sql` 2,
    `filters.sql` 2), or to state in
    `conformance/fixtures/README.md` that they are frozen at the pin they were
    derived from. **There are now TWO precedents and still no rule**:
    `fixtures/observability.sql` (7 URLs → 0, by the observability re-sync) and
    `fixtures/rpc.sql` (1 → 0, commit `6b25f05` — see item 24), both comment-only
    changes with every anchored line number re-verified across the pins. Either
    bless that as the pattern for the remaining six or say why those two were
    special. **The mutations pass is the first to decline it where it plainly
    could have acted**: it re-read and re-anchored every `source:` in its own model
    and band, with the v16.0 checkout open, and left `fixtures/mutations.sql`'s
    three URLs untouched. So the precedent has not become a habit and the drift
    will now shrink only by decision. `fixtures/pagination.sql` still carries a
    "PostgREST v14.12 parity" **label** in its header comment (recorded in
    `pagination.yaml`'s gaps, left alone because existing fixture fragments are
    off-limits).
15. Consider asking the Tester to tighten `case.schema.json`'s `source` pattern
    from `.../postgrest/.+#L[0-9]+$` to the pinned tag. As written, schema
    validation cannot catch a stale pin (proved by negative control in an earlier
    pass and unchanged since, since the pattern has not changed), so the pin is
    enforced only by an ad-hoc grep sweep that lives in this document rather than
    in CI. While there, decide whether a **docs**-anchored
    `source:` (case 1279, the pattern's first) should be allowed explicitly
    rather than by accident — the current pattern requires a
    `raw.githubusercontent.com/PostgREST/postgrest/…#L<n>` URL, which a docs file
    satisfies, so the third citation class is currently indistinguishable from
    the other two. `case.schema.json` is the Tester's file and was deliberately
    not edited here.
16. **Fix `lib/bier/plugs/observability.ex:159`** — a conformance-pass item, not
    a spec one, recorded here because the spec is what changed under it. Cases
    1757/1768/1769 no longer assert that OPTIONS omits the `plan` and
    `transaction` Server-Timing metrics, because PostgREST does not omit them at
    either pin; `lib/` implements the retracted behavior. **It is no longer the
    only place in this document where a green suite was green on something
    invented** — see the content_negotiation fixture defect, where a case passed
    against a *wrong fixture* because `lib/` was over-permissive in the matching
    direction (item 28). Together they are the
    strongest available argument for finishing the remaining **two** audits —
    joined by the rpc result, which showed that even a freshly re-synced area
    can hide two whole docs-page sections; by the mutations result, which showed
    that a modelled rule can survive indefinitely simply by never being cased; by
    the representations result, which showed that a **✅ pass verdict is still
    worth the run**; and by the content_negotiation result, which showed that a
    *silent* model can hide seven findings. **Do
    not deprioritize an area because you expect it to pass, and do not assume a
    passing case proves its fixture right.**
17. **Decide whether to promote `observability.server_timing.success_path_only`
    to a case.** It is the only observability gap that is black-box observable,
    expressible today, and blocked on nothing but policy — the tree's rule is not
    to pin behavior upstream never asserts. An operator's call, not a
    researcher's.
18. **Give the harness the two assertion shapes the observability area is waiting
    on**, or accept that two of the docs page's three top-level sections stay
    uncovered indefinitely: `expect.stdout_matches` / `expect.stderr_matches`
    (a regex list plus a line-count bound, evaluated against the instance's
    captured output for the duration of the request) unlocks the whole Logs
    section and the `log-level` cases' inert `config:` blocks;
    `request.kind: admin` plus a Prometheus-text body matcher unlocks the Metrics
    section **and** the `admin_server` page's `/metrics` and `/schema_cache`
    entries. Both are named in `spec/observability.yaml`'s `gaps:` as
    `needed_assertion:` entries. This is the single highest-leverage harness
    change in this document: two capabilities close two docs sections and one
    scoped page.
19. **Settle the overflow-band and gap-list conventions. This follow-up has now
    been overtaken by events TWICE: a THIRD and then a FOURTH area picked a number
    ad hoc while it was open, and the fourth did so in the very pass the follow-up
    list had scheduled as the next audit.** `filters.yaml` *declares*
    `[10600..10799]` as a closed overflow range
    and has used none of it; `operators.yaml` declares nothing and has used
    **10200–10236** (10237+ free); `mutations.yaml` declares nothing and has
    used **11400–11405 + 11407–11415** (11416+ free, 11406 deliberately skipped);
    **`content_negotiation.yaml` declares nothing and has used 12400–12401**
    (12402+ free). `auth` holds **11800–11818**. Note that mutations' choice lands
    *between* operators' and auth's ranges and content_negotiation's lands above
    all of them, so the numeric space is interleaved as well
    as the lexical ordering. Pick one
    convention — declare the range in the area model, or record all bands
    centrally in `conformance/INDEX.md` — before a **fifth** area does the same.
    **Still not hypothetical: `rpc` holds 1400–1443 with only
    1444–1449 free, and its five open findings need more than six ids.** Whoever
    closes them will pick a band; settle the rule first.
    **The counter-example still argues for a different fix than "declare an
    overflow range".** The representations re-sync added eight cases
    and needed **no band decision at all**, because the area still had interior
    spacing (1315–1319, 1325–1329) reserved by an earlier author. Every area that
    *has* had to pick a number — filters, operators, mutations, content_negotiation
    and rpc next — is
    an area whose primary band was allocated to the last id. **Consider making the
    convention "leave interior spacing when allocating a band", which removes the
    question, rather than only "declare an overflow range", which answers it.**
    **The gap-list half is no longer a question of principle but a list of work.**
    `operators.yaml` is audited (✅ pass) *and* silent — two findings plus a
    five-column-type residual, recorded only here. **`content_negotiation.yaml` is
    now audited (⚠️ revise) and silent too — SEVEN findings, recorded only here.**
    `representations.yaml`, audited to a ✅ pass, wrote a five-entry list including
    a `needed_assertion: nothing` entry with no precedent in the tree. **Two
    audited-and-silent areas now hold nine findings between them in a 3 000-line
    file nobody opens by choice.** Resolve to "an audited area writes its gaps into
    its model", write it down in `conformance/fixtures/README.md` or the
    area-model conventions, and **backfill both `operators.yaml` and
    `content_negotiation.yaml`**.
    **While backfilling, standardize on `content_negotiation.yaml`'s
    `fixture_notes:` key as well** — see item 28.
20. **Sweep the remaining five `in.()` column types, or say why three suffice.**
    The cheapest open item in this file: five case files in the free 10237+ slice
    against `test.items_with_different_col_types`, which is now folded with all
    eight typed columns and upstream's seed row. Cases 10200–10202 cover int, text
    and bool; **bytea, char, date, real and time** have none, so the tree
    transcribes an arbitrary three-eighths of an upstream `describe` with nothing
    on disk explaining the choice. The behavior is type-independent by
    construction (`pListVal` → `[""]` → `= ANY('{}')`, before any type is
    involved), so this is genuinely a policy call — but it should be a recorded
    one. See **Known gaps → operators**.
21. **Close the two operators findings if the effort is wanted — both are
    case-only and both MINOR.** `not.plfts` / `not.phfts` / `not.wfts` against
    `test.tsearch` and their to_tsvector-coerced twins against
    `test.tsearch_to_tsvector` (six cases, or three if only one flavor is wanted);
    and one case putting `fts(english)` / `fts(french)` / `fts(german)` in a single
    `or=(…)` tree — `test.tsearch` already seeds one document per dictionary. The
    reviewer marked both non-blocking because the underlying mechanisms (`not` as
    a single wrapper; fts surviving logic-tree composition) are each pinned
    elsewhere, so treat these as completeness work, not risk reduction.
22. **Decide once how the rpc area gets fixture routines, before authoring any of
    its three fixture-blocked findings.** They need eight objects that
    `fixtures.sql`, `fixtures_local.sql` and `fixtures/rpc.sql` all lack:
    `returns_record`, `returns_record_params`, `returns_setof_record`,
    `returns_setof_record_params`, an array-echoing `varied_arguments`,
    `unnamed_text_param`, `unnamed_xml_param`, `unnamed_int_param`. The rule
    (`spec/rpc.yaml` → `loader_exposure`, `conformance/fixtures/README.md`) is
    that `fixtures/rpc.sql` is a **human-owned live loader input** no workflow
    agent may edit, so a spec pass can only reach `rpc.delta.sql` → `fixtures.sql`
    → schema `test`, which means the cases carry `schema: test` and the `rpc`
    profile never exposes the routines. Case **1440** (`test."true"()`) is the
    working precedent, but it was one zero-argument routine. **Two clean options**:
    bless the delta path explicitly for these eight (and accept `schema: test` on
    the cases, as 1433 and 1440 already do), or land them in `rpc.sql` in a
    reviewed human commit so the `rpc` profile carries them. Pick one and record
    it; do not decide it per gap.
23. **Close the two case-only rpc findings — the cheapest work in this file after
    item 20, and both verified against the loaded fixture.** One case for
    *Resource Embedding on table-valued functions*:
    `/rpc/getproject?select=id,name,client:clients(id),tasks(id)` by POST and/or
    GET (`test.getproject` is `STABLE` and returns `SETOF test.projects`;
    `test.clients` and `test.tasks` both exist), which upstream asserts at
    `RpcSpec.hs#L324` and which today is exercised only incidentally by case 1023
    in another band. One case for `?columns=` on an RPC POST:
    `POST /rpc/sayhello?columns=name` with extra JSON keys → `"Hello, John"`
    (`RpcSpec.hs#L855`; `test.sayhello(name text)` already backs cases 1400 and
    1443). Both land in **1444–1449** — which is exactly enough for these two and
    nothing else, so see item 19 first if more than two cases are wanted.
24. **CLOSED — end to end, by two outside commits, and the first follow-up in
    this document to reach that state.** The fixture half closed at **`6b25f05`**:
    `conformance/fixtures/rpc.sql#L15` re-pinned to
    `github.com/PostgREST/postgrest/blob/v16.0/test/spec/fixtures/schema.sql`,
    with a note recording that all 23 vendored routines were re-verified as
    present at v16.0 with unchanged signatures; `rpc.sql` carries **zero**
    `v14.12` URLs. The documentation half closed at **`75388d6`**, which rewrote
    `spec/rpc.yaml`'s `operator_action` entry to open "RESOLVED 2026-08-09 (commit
    6b25f05) — kept as a record, no action left" and then **deliberately retains
    the original finding verbatim, quoted URL included**, for provenance. It also
    records a second fact worth keeping: the local `rpc.sql` intentionally adds
    IMMUTABLE/STABLE/VOLATILE markers upstream omits, because routine volatility
    drives the OPTIONS `Allow` cases 1031/1032, and that divergence must survive
    future re-syncs.
    **Two consequences to carry forward, neither of them work.** (a) The surviving
    `v14.12` URL — now at `spec/rpc.yaml:574` rather than `:564` — is **correct**.
    A prefix-aware sweep will report `v14.12: 1` forever and that is the steady
    state; do not re-open it as drift and do not delete the quotation to make a
    number read zero. (b) `rpc.yaml:564` now holds a `blob/v16.0` URL, which is
    why this file's `blob/v16.0` count moved 2 → **3**.
    **The process lesson is the durable one**: nothing in this document detected
    either closure. The fixture half surfaced only because a machine-verification
    run happened to report the file already re-pinned; the documentation half
    surfaced only because a synthesis pass re-read the entry. A follow-up list
    with no mechanism for noticing its own items closing will accumulate
    false-open entries.
25. **Decide what `preconditions:` means — and note that this pass ESCALATES the
    item from bookkeeping to a coverage finding.** The frozen harness parses the
    key and never executes it
    (`test/support/conformance_case.ex`); only CLI cases' `config.preconditions_sql`
    runs (`test/support/cli_case.ex#L22`). **42** cases tree-wide carry a
    non-empty list — mutations **25**, content_negotiation **11**, pagination
    **4**, url_grammar **1**, representations **1** — and mutations
    is by far
    the heaviest user of a key that does nothing, though its cases pass because
    `mix bier.fixtures.load`'s `isolate_mutations` pre-bakes the same state and
    the server rolls each request back.
    **The content_negotiation audit found the first case where the inert key
    CONCEALS missing coverage rather than merely restating satisfied setup.**
    Cases **1625, 1626, 1627, 1628** and **1643** use `preconditions:` to state
    "Requires db-plan-enabled = true; otherwise … returns 406 / PGRST107" — and
    **no case in any band pins that 406**, which upstream asserts at
    `PlanSpec.hs#L544`. Mutations' 25 are harmless and pagination's three are
    accidentally satisfied by a database-wide `ANALYZE`; these five describe a
    real, untested config gate. **Sweep the other 39 non-empty lists for the same
    shape before closing this item** — a `preconditions:` string that describes a
    *branch* rather than a *setup* is a missing case wearing a declaration.
    **The openapi audit ESCALATES it again, and this time the evidence is that an
    inert declaration can be flatly WRONG and nobody notices.** The area carried
    the last two `openapi` entries in the distribution above; the pass removed
    both, taking the tree-wide count **44 → 42** — the first decrease this key has
    recorded. Both were also incorrect: case **1654**'s
    `COMMENT ON SCHEMA test IS NULL` would, had it run, have broken case **1656**,
    whose whole assertion is that comment appearing as the document title; and
    case **1672**'s `CREATE FUNCTION` omitted the `DEFAULT '{}'` on which 1672's
    own `required: false` assertion depends. **Both survived a full prior re-sync
    of this area.** So the sweep this item asks for should look for two shapes,
    not one: a `preconditions:` string that describes a *branch* (missing
    coverage) **and** one that describes a *setup that would break another case*
    (a latent bug waiting for the day the key is wired up). **Wiring the key up
    without sweeping first would turn green cases red for reasons unrelated to
    `lib/`.**
    Four consecutive passes (mutations, representations, content_negotiation,
    openapi) have given every new case `preconditions: []`, establishing a
    convention nobody has written down, and
    `representations.yaml`'s gaps flag the same problem from its own side under
    `operator_action:`. Either wire the key up in the harness (a human
    harness-gate change) or re-document it as advisory in `case.schema.json`'s
    description and in `README.md`. Pairs with item 9 — both are about the gap
    between what a case *declares* and what the harness *does*.
26. **Settle the cross-area duplication rule, using the two opposite decisions
    this pass made as the worked example.** The mutations pass **deleted** case
    11406 for duplicating representations case 1332, and in the same pass
    **added** case 1399, which duplicates url_grammar case 1030 (same request,
    same it-block, same envelope; `#L302` vs `#L303`) — completing a pattern
    1383/1016 had already started for the `limit` spelling. Both calls are
    defensible; what is missing is a rule. Two candidate rules, either of which
    would settle all four cases: *(a)* one it-block, one case, owned by the area
    that models the rule (retire 1383 and 1399); or *(b)* per-profile duplication
    is deliberate coverage of the fixture-set labels, in which case say so in both
    models and add the missing `limit` twin nowhere, because it already exists.
    Until then a future author has two precedents pointing opposite ways, twenty
    ids apart, in the same uncommitted diff.
    **The representations audit adds a third data point and it favours rule (a).**
    The deletion of 11406 leaned on case 1332, which at the time sat in an
    **unaudited** band; that band has now been audited to a ✅ *pass*, so the
    deletion is retro-justified. Meanwhile the area's own gap list records a
    *deliberate non-duplication* — `with_multiple_pks` and `compound_pk_view` get
    no case because 1309 already derives the identical claim — and argues it
    explicitly rather than leaving the absence to be rediscovered. That is rule
    (a) applied and written down. **Adopt it, and require the declining area to
    record the de-duplication in its `gaps:` as `representations.yaml` does.**
    **The content_negotiation pass adds a FOURTH data point and widens this item
    beyond duplication: it deleted a case and REUSED the id.** Old
    `1623_octet_stream_no_charset.yaml` was removed, its assertion folded into
    case **1622**, and `1623` re-issued to an unrelated 406 negative. Compare
    11406, whose id the mutations pass left permanently vacant so the deletion
    would stay legible. **Two deletions, two opposite conventions, and no rule on
    disk** — and the id-reuse convention has a cost the vacancy convention does
    not: every document, commit message and issue that cited "1623" for the
    charset rule now points at a different case, and **nothing mechanical can
    detect a stale id reference**, because the id resolves and the file validates.
    Settle both halves together: *(a)* when a case is deleted, is its id retired
    or recycled? and *(b)* when two areas assert the same it-block, which owns it?
    Recommend: **retire deleted ids** (the tree is nowhere near exhausting any
    band) and **record the deletion in the area's `gaps:`**, exactly as
    `mutations.yaml` did for 11406.
    **The openapi pass adds a FIFTH data point that arguably settles half (a) by
    sidestepping it.** Case **1689** was authored, found red on a harness gate
    rather than on a behavior, and **withdrawn before commit** — so it never
    entered git history, never entered the uniqueness check, and 1689 is simply
    the next free id in a contiguous 1650–1688 band. The behavior is not lost:
    `openapi.yaml` carries it as an entry with `cases: []` that spells the case
    out verbatim, so restoring it is a copy once `@variant_case_ids` grows. **Three
    conventions now exist — reuse (1623), permanent vacancy (11406),
    never-consumed (1689) — and the third dominates the other two**: it costs no
    id, leaves no stale reference, and keeps the assertion legible in the model.
    **Recommend adding it as the preferred path: if a case cannot pass for a
    reason outside `lib/`, model it with `cases: []` rather than shipping it
    red or deleting it silently.**
27. **Add a `preconditions:` / write-containment declaration to the case shape,
    or accept that the dependency stays invisible.** Two areas now write through
    un-isolated view mirrors and are contained only by the conformance server's
    `db_tx_end: :rollback`: nine mutations cases, and representations cases
    **1316**/**1317** (`representations.no_pk` is a view, not one of
    `isolate_representations/1`'s five real tables). **Neither area declares the
    dependency and nothing mechanical can surface it** — the relation check
    confirms the target exists and says nothing about containment. Both loader
    lists (`isolate_mutations/1`'s ten, `isolate_representations/1`'s five) are
    hard-coded and cannot be extended by a fixtures delta, so this will recur in
    every future write-flavored re-sync. Either give the case shape a way to say
    "this case writes and needs rollback containment", or record the constraint in
    `conformance/fixtures/README.md` so the next author reads it before choosing a
    target relation. Pairs with items 9, 25 and **28** — all four are the same
    class of problem: something a case depends on that nothing records and nothing
    checks.
28. **NEW — adopt `fixture_notes:` tree-wide, because nothing in this document
    checks a fixture DECLARATION and this pass showed what that costs.** The
    content_negotiation audit found `test.unnamed_bytea_param(bytea)` transcribed
    into `fixtures.sql` as `RETURNS bytea` where upstream declares it over the
    mime-named DOMAIN `"application/octet-stream"` (`schema.sql#L2372`). Because a
    routine's return type is the only thing that registers an octet-stream handler
    (`SchemaCache.hs#L1016`), case **1622**'s asserted 200 was **unreachable
    against a faithful PostgREST**. **Every check in this file passed on it** —
    the pin was v16.0, the schema validated, the filename matched the id, the
    cited line was real, and the relation check confirmed the routine *exists*.
    **And the case passed**, because `lib/bier/rpc.ex:288` is over-permissive in
    the matching direction. Existence is not declaration, and a green case over a
    wrong fixture is indistinguishable from a green case over a right one.
    `content_negotiation.yaml`'s new top-level **`fixture_notes:`** key is the
    tree's only remedy: per object, the exact property the cases depend on and
    what silently breaks if it changes. **Two actions.** *(a)* Require the key in
    every area whose cases depend on a *declaration* rather than on seed data —
    return type, volatility, `proretset`, domain/base type, generated-column-ness,
    identity, `NOT NULL`. The obvious first candidates are
    **`domain_representations`** (whose entire subject is `CREATE DOMAIN` plus
    casts), **`rpc`** (volatility drives the OPTIONS `Allow` cases 1031/1032, a
    divergence `fixtures/rpc.sql` deliberately introduces and that must survive
    re-syncs) and **`mutations`** (DEFAULTs, identity, GENERATED ALWAYS). *(b)*
    Consider a **declaration check** in the machine-verification battery — for
    each `fixture_notes:` entry, assert the named property against `pg_proc` /
    `pg_type` / `pg_attribute` on the loaded DB. That is the only check proposed
    in this document that would have caught this pass's own defect, and it is
    cheap precisely because the notes name what to look at. Pairs with items 9,
    25 and 27.
    **UPDATE — `openapi.yaml` adopted the key voluntarily, which is the first
    evidence this recommendation travels.** It carries **five** entries, written
    without a fixture defect to prompt them, and every one names a *declaration*
    rather than seed data: `test.root()`'s plain `json` return (which is why case
    1682 asks for `application/json` and not `application/openapi+json`),
    `test.jwt_test()`'s **missing volatility keyword** (upstream's is IMMUTABLE;
    transcribing upstream's it-block literally against this fixture would assert
    the *opposite* of upstream, which is why case 1685 uses
    `test.three_defaults` instead), `test.variadic_param`'s `DEFAULT '{}'` (the
    source of case 1672's `required: false`, which is **not** a consequence of the
    parameter being VARIADIC), the argument modes behind cases 1683/1684 together
    with the fact that both routines are visible only through PostgreSQL's default
    `PUBLIC EXECUTE`, and `openapi_no_comment` having no comment. **The jwt_test
    entry is the model for the whole key**: it records a deliberate divergence
    from upstream *and* what a well-meaning future edit ("add the missing
    IMMUTABLE") would silently break. Action *(b)* — a declaration check driven by
    these entries — now has ten entries across two areas to run against, which is
    enough to prototype.

29. **NEW — close the two openapi findings, and note that they are the cheapest
    open items in this document.** Both are **case-only**, need **no fixture
    object** and **no harness change**, and both assert keys that appear in
    **every** OpenAPI document the server can produce:
    *(a)* the `/rpc/*` path item's per-operation `produces` (a 3-element list) and
    `responses.200.description == "OK"`
    ([`OpenAPI.hs#L357-358`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/src/library/PostgREST/Response/OpenAPI.hs#L357)),
    which is a **third** `produces` scope distinct from the document-level list
    case 1688 pins and the root path item's list case 1687 pins; and
    *(b)* the shared `$.parameters.on_conflict` definition
    ([`#L239-245`](https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/src/library/PostgREST/Response/OpenAPI.hs#L239)),
    a sibling of the `preferParams` definition case **1686** already asserts whole.
    Both land in the free **1689+** slice of the openapi band, both are `GET /`
    with `Accept: application/json` and `schema: test`, and both read a fixed
    JSONPath into the emitted document — the exact shape three cases from this
    pass already use. **Two case files closes the openapi page's Partial mark.**
    Worth recording *why* they were missed: `openapi.yaml` carries 14 gap entries
    and a five-entry `fixture_notes:` key and mentions neither behavior under any
    wording (verified: `on_conflict` matches four case files, none in the
    1650–1688 band, and zero lines of the model). **A gap list records the gaps
    its author saw**; it is not a substitute for an independent read of the
    generator.

30. **NEW — add ONE id to `@variant_case_ids` and restore case 1689.** This is
    the only item in this document that a `spec/`-only change cannot complete, and
    it is a one-line edit to a frozen file
    (`test/support/conformance_server.ex:58-59`, whose list is **exactly** 1467–1473,
    1491, 1493, 1654, 1677, 1678, 1680, 1682, 1703, 1758, 1763, 1764 — 18 ids,
    verified on disk). Without it, a case carrying
    `config: {openapi-server-proxy-uri: "https://postgrest.com"}` falls through
    `url_for/1` to the shared auth instance, its config silently ignored, and
    fails on `$.host == "127.0.0.1:<port>"` for a reason unrelated to the behavior
    under test. `openapi.yaml`'s `openapi/root/server-proxy-uri` entry holds the
    case verbatim for restoration — `GET /`, `Accept: application/json`,
    `schema: test`, expecting 200 and `$.host == "postgrest.com:443"`,
    `$.basePath == "/"`, `$.schemes == ["https"]`, sourced to
    `docs/references/configuration.rst#L854`. **Two further behaviors in the same
    area are blocked on the same list** and are recorded rather than
    written-and-broken: the `openapi-mode = disabled` / `db-root-spec` precedence
    of `ApiRequest.hs#L122` (needs both keys set at once) and any second
    `openapi-mode = ignore-privileges` case beyond 1677. Pairs with item 9 — this
    is the concrete, single-case form of the general question that item asks.

31. **NEW — check `schema:` labels mechanically, because nothing does.** Thirty-one
    cases shipped `Accept-Profile: openapi` for an entire re-sync cycle against a
    schema that does not exist in `bier_test`, and **not one of the six
    machine-verification checks looks at the `schema:` field**. The relation check
    resolves the *target* and treats an unrecognised label as a case that
    deliberately sends `Accept-Profile: unknown`. The check is trivial: for every
    case, resolve `schema:` through the harness's own alias rules
    (`test`/`public`/`null` → suppressed, `unicode` → `تست`, `multi` → the v1/v2
    pair, everything else → a literal schema name) and assert the result is either
    suppressed, an alias, or a schema the loaded DB actually has. **A deliberate
    negative must be spelled as one** — the four cases that intend an unknown
    profile all spell it *explicitly in `request.headers`* while carrying a
    perfectly valid `schema:` label: **1010** (`schema: multi` +
    `Accept-Profile: unknown`), **1012** (`schema: multi` +
    **`Content-Profile: unknown`**, the write-side spelling), **1560** and
    **1583** (`schema: headers` + `Accept-Profile: unknown`). That separation —
    a real label, an explicit bogus header — is exactly what makes them
    distinguishable from the 31 cases that encoded the bogus profile *in the
    label itself*, and it is the convention the check should enforce. This is the
    same class as items 25, 27 and 28: **two consecutive passes have now found a
    defect in a field no check reads.**
