# Conformance case index

Cross-reference of the **668** conformance cases under `spec/conformance/cases/`.
Pinned target: **PostgREST v16.0** (all 668 `source:` URLs).

Each case is one YAML file `NNNN_<slug>.yaml` validated against
[`../case.schema.json`](../case.schema.json). Cases are grouped into 17 feature
areas; each area owns a non-overlapping id band and is backed by one SQL fixture
fragment in [`fixtures/`](fixtures/).

The `schema:` field inside a case is a **fixture-set label, not a filename**:
the frozen harness (`test/support/http_case.ex`) sends any label other than
`null`/`public`/`test` as an `Accept-Profile: <label>` header, so the label must
name a schema the shared conformance server exposes *or* resolve through one of
its aliases / profile lists. Several labels are not schema names on disk —
`unicode` → `تست`, `multi` → the `v1`/`v2` pair — and several are overridden by
an explicit header. See the **Label caveats** section below.

The first `/`-delimited segment of each case's `feature:` field is the
**authoritative** area assignment. The id bands below are derived from what is on
disk now; read the `feature:` prefix if a row ever looks ambiguous.

> **Non-contiguous bands.** Two areas do not occupy a single contiguous range and
> regenerating this file must preserve that rather than collapsing it:
>
> - **auth** uses **11800–11818** on top of its full primary band **1450–1499**
>   (all 50 primary ids are in use). These 19 are the only 5-digit case ids in
>   the tree, and `11800` sorts immediately after `1180` in a *lexical* listing,
>   so they interleave with the filters area's 1180–1199 cases unless ids are
>   sorted **numerically** (`ls | sort -n`, not plain `ls`).
> - **representations** uses **1300–1314 + 1320–1324 + 1330–1333**; the 1315–1319
>   and 1325–1329 gaps are deliberate per-sub-feature spacing (post/patch,
>   delete, put).
>
> The `feature:` prefix remains authoritative — an id's numeric neighbourhood
> never decides its area.

## Area <-> id band <-> fixture fragment

| Area | Cases | Id band | Fixture fragment | `schema:` labels used |
|------|------:|---------|------------------|-----------------------|
| url_grammar | 36 | 1000–1035 | `fixtures/url_grammar.sql` + `fixtures/url_grammar.delta.sql` (case 1029's `test.pgrst_reserved_chars` and case 1035's `test."Server Today"`, both folded) | `multi`, `test`, `unicode`, `ordering` |
| operators | 50 | 1050–1099 | `fixtures/operators.sql` | `operators` |
| select | 50 | 1100–1149 | `fixtures/select.sql` | `test` |
| filters | 50 | 1150–1199 | `fixtures/filters.sql` | `test` |
| ordering | 33 | 1200–1232 | `fixtures/ordering.sql` | `ordering`, `mutations`, `test` |
| **pagination** | **39** | **1250–1288** | `fixtures/pagination.sql` (**no delta** — the v16.0 re-sync added eleven cases and zero fixture objects) | `pagination` |
| representations | 24 | 1300–1314, 1320–1324, 1330–1333 | `fixtures/representations.sql` | `representations` |
| mutations | 48 | 1350–1397 | `fixtures/mutations.sql` | `mutations` |
| rpc | 41 | 1400–1440 | `fixtures/rpc.sql` + `fixtures/rpc.delta.sql` (`test."true"()`, folded) | `rpc`, `test` |
| auth | 69 | 1450–1499 **+ 11800–11818** | `fixtures/auth.sql` | `auth` |
| errors | 27 | 1500–1526 | `fixtures/errors.sql` + `fixtures/errors.delta.sql` (cases 1523/1524's `test.infinite_inserts` + `test.infinite_recursion`, folded) | `test` |
| headers | 35 | 1550–1584 | `fixtures/headers.sql` + `fixtures/headers.delta.sql` (`test.get_vary_header_override()`, folded) | `headers`, `test` |
| content_negotiation | 47 | 1600–1646 | `fixtures/content_negotiation.sql` + `fixtures/content_negotiation.delta.sql` (the vendored media-type domains + handlers, folded) | `test` |
| openapi | 33 | 1650–1682 | `fixtures/openapi.sql` | `openapi`, `openapi_no_schema_comment`, `openapi_variadic` |
| config | 45 | 1700–1744 | `fixtures/config.sql` | `config` |
| observability | 20 | 1750–1769 | `fixtures/observability.sql` | `observability` |
| domain_representations | 21 | 1800–1820 | `fixtures/domain_representations.sql` | `domain_representations` |

Total: **668 cases**, **17 areas**, **17 fixture fragments**
(plus **6** `*.delta.sql` write channels, all currently **comment-only** — each
carries a single `-- Folded into ../fixtures.sql on <date> …` provenance line
and no DDL. Four are dated 2026-08-08; `url_grammar.delta.sql` and
`errors.delta.sql` are dated 2026-08-09. See
[`fixtures/README.md`](fixtures/README.md) for who may write which file).

Each area's `feature:` prefix matches its area name exactly, so the area is
recoverable directly from the case file:

```sh
grep -h '^feature:' spec/conformance/cases/1800_format_single_domain_column.yaml
# feature: domain_representations/read/format_single_column
```

## Label caveats

- **None of `openapi`, `openapi_no_schema_comment`, `openapi_variadic` is a
  schema on disk.** `mix bier.fixtures.load` creates none of them (only
  `openapi_no_comment` exists); the openapi objects live in `test`. The labels
  are inert today because the root path is dispatched before profile resolution
  and the document is built from `hd(db_schemas)`. Re-surfaced independently by
  this pass's machine verification (label `openapi` is carried by **31** cases
  and names no schema, while `conformance_server.ex:171` still lists it in
  `db_schemas`). Flagged as an open finding in
  [`../COVERAGE.md`](../COVERAGE.md) → *Open verification findings*.
- **`multi`** is not a schema either — it stands for the `v1`/`v2` profile pair
  routed by `db_profile_default` / `db_profile_schemas`
  (`test/support/conformance_server.ex:184-185`). All the relations these cases
  target (`parents`, `children`, `get_parents_below`) exist in both `v1` and
  `v2`; case 1024 deliberately targets one that exists only in `v2`.

  > **Where the label is actually resolved matters, and it is not the harness.**
  > `multi` is neither a DB schema nor a `db_schema_aliases` key; it resolves
  > only because **implementation code** carries a hard-coded allowlist of
  > conformance labels — `@profile_aliases ~w(headers multi)` at
  > `lib/bier/plugs/action_controller.ex:479`, consumed at `:504`. Re-verified on
  > disk this pass.
  >
  > **Six cases, not four, actually send the label.** The harness injects
  > `Accept-Profile` with `Map.put_new`, so a case escapes the injection only by
  > spelling out **`Accept-Profile`** itself — spelling out `Content-Profile` is
  > not enough. Of the fourteen `multi` cases, **1005, 1006, 1007, 1008, 1011 and
  > 1012** receive `Accept-Profile: multi`. Three of the six expect success
  > (**1005**/**1008** → 200, **1011** → 201) and so depend on the allowlist.
  > Recorded in [`../COVERAGE.md`](../COVERAGE.md) → *Open verification
  > findings*: a genuine finding, not a bookkeeping note, because 1008's own
  > `notes:` claim "no `Accept-Profile` header" while the harness always sends
  > one. Note this pass's relation check no longer flags the three, because its
  > resolver maps `multi` to `v1`/`v2` itself — a change in the script, not a fix
  > to the tree.
- **`unicode`** aliases the schema `تست` via `db_schema_aliases`
  (`test/support/conformance_server.ex:181`); **`test`**, `public` and `null`
  suppress the `Accept-Profile` header entirely.
- **`headers` is never actually applied on case 1574.** The harness sets
  `Accept-Profile` with `Map.put_new` (`test/support/http_case.ex:69`), so a case
  that spells the header out itself wins over its label. 1574 sends
  `Accept-Profile: SPECIAL "@/\#~_-` explicitly, and relation `names` exists in
  that schema. Fifteen cases override their label this way in total: 1009–1014,
  1017, 1018, 1023, 1024, 1558–1560, 1574 and 1583 — of which twelve spell out
  `Accept-Profile` (the suppressing header) and three only `Content-Profile`
  (1011, 1012, 1559), which does **not** suppress the injection.
- **`ordering` appears under `url_grammar`** (case 1028, the legacy embed
  target-name case, reuses the ordering fixture set), and **`test` appears under
  `rpc`** (case 1440), **under `headers`** (case 1576) and **under `ordering`**
  (cases 1227–1228, the computed-relationship related orders — the
  `computed_designers` / `computed_videogames` functions live in `test` and the
  `ordering` view mirror does not carry them).
- **`mutations` appears under `ordering`** (case 1230, `order=` applied to a
  PATCH's returned representation). The `ordering` schema is a read-only view
  mirror of `test`, so the write goes to the loader-isolated `mutations.no_pk`
  real table; the case's `feature:` prefix (not its label) is what puts it in
  the ordering area.
- **The whole errors area carries `schema: test`**, including cases **1523**
  (`POST /infinite_inserts`) and **1524** (`GET /infinite_recursion`), whose
  objects were folded through `errors.delta.sql`. Both were created in `test`,
  and the loader's area-schema mirroring reproduces them as views in the seven
  mirrored schemas without error — a self-referential view definition is not
  re-planned at `CREATE VIEW` time.

### Fixture-name collision worth knowing: `menagerie` vs `menagerie_empty`

Four **pagination** cases — **1258, 1264, 1266 and 1268** — request
`/menagerie_empty`, a path that appears nowhere upstream. This is deliberate.
Upstream's `menagerie` in `RangeSpec.hs` is the pagination fixture's
single-column **empty** table, but `openapi.sql` contributes a 7-column
type-mapping table of the same name. The consolidated `fixtures.sql` keeps
openapi's as `test.menagerie` and renames the empty one to
`test.menagerie_empty` (`fixtures.sql:75-79`, `:719-722`). All four cases assert
behavior over an **empty** relation (`Content-Range '*/*'`, `*/0`, an offset past
the end), so they were retargeted during the v16.0 pagination re-sync; before
that they pointed at the 7-row type-mapping table and asserted the wrong thing.
Both relations exist in the loaded DB, and each of the four records the collision
in its own `notes:`.

## Cross-area ownership caveat

`Prefer:` coverage is split across areas by design — `headers` owns the header
semantics, `mutations` owns the table-flavored `max-affected` cases
(1390–1392), and `spec/rpc.yaml` explicitly delegates the RPC flavor of both
`handling` and `max-affected` to the headers area rather than duplicating it.
That delegation currently lands nowhere: **no case in any band exercises
`Prefer: handling` or `Prefer: max-affected` against `/rpc/*`**, and `PGRST128`
("Function must return SETOF or TABLE when max-affected preference is used with
handling=strict") is asserted by no case and modelled by no area file.

The pagination re-sync made this a **three-way** split rather than resolving it:
new cases **1286** (`count=exact` echoed as `Preference-Applied` on a plain read)
and **1288** (`count=none, handling=strict` → 400 PGRST122) put `Prefer`
assertions in the *pagination* band too. They are correctly placed — the
preference they exercise is `count`, which pagination owns — but 1288 is now the
tree's second table-flavored `handling=strict` assertion, sitting outside the
area that models `handling`. Recorded in
[`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → headers*; when closing the RPC
gap, decide the owning band first so the delegation stops being circular.

The same pattern applies to **`PGRST127`** (aggregates rejected inside a to-many
spread). It belongs to `select`; see
[`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → select*.

> Re-checked this pass: `grep -rl 'PGRST127\|PGRST128' spec/` matches exactly
> two files — `COVERAGE.md` and this INDEX, i.e. only the documents recording
> the gap. No case and no area model mentions either code.

A third split needs the same care. The `in.( … )` **value grammar** is
url_grammar's (its docs page owns the *Reserved characters* section), the `in`
operator's **SQL rendering** is claimed by `operators.yaml:213`, and the
`in.()` **empty set** was raised against `filters`. Two of the three
`in.`-shaped gaps in [`../COVERAGE.md`](../COVERAGE.md) therefore have no
settled owner: decide the band before authoring, and note that `filters`' primary
band 1150–1199 is full (overflow `[10600..10799]`) while url_grammar's 1036+,
ordering's 1233+, errors' 1527+ and pagination's 1289+ are free.

## Per-area sub-feature breakdown

The `feature:` field is a slash-delimited path `<area>/<sub-feature>/...`. The
sub-features present per area (second segment, as on disk):

| Area | Id band | Sub-features |
|------|---------|--------------|
| url_grammar | 1000–1035 | method (incl. the OPTIONS `Allow` matrix on a table 1019, a VOLATILE routine 1031, a STABLE routine 1032 and the root path 1033), path (incl. OPTIONS on an unknown relation -> 404, 1034), percent-encoding (incl. `%20` in both a relation and a column name, 1035), profile, reserved-params (`limit` **and** `offset` forbidden on PUT, 1016/1030), reserved-characters |
| operators | 1050–1099 | eq, neq, lt/lte/gt/gte, in, is, like/ilike, match/imatch, fts/plfts/wfts/phfts, cs/cd/ov, sl/sr/nxl/nxr/adj, isdistinct, not, quantifier (any/all) |
| select | 1100–1149 | columns, alias, cast, alias-and-cast, json-path, composite, array, computed-column, computed-relationship, embed (incl. one-to-one, the v16 alias/legacy-target-name rules and the `table!fk` hint), spread, aggregate |
| filters | 1150–1199 | horizontal, logical, not, json, quoting, embed |
| ordering | 1200–1232 | direction, nulls (incl. alongside limits, 1229), json_path, computed_column, multi_column, composite, related (incl. computed relationships, 1227–1228), embed, mutation_representation (1230, `schema: mutations`), rpc (1231–1232), error |
| **pagination** | **1250–1288** | limit_offset (incl. HEAD 1277 and the POST-`/rpc/`-with-query-params flavor 1281), range_header (incl. past-the-last-item with count 1278, open-ended non-zero offset 1279, the GET-`/rpc/` flavor 1280, the **method scoping** pair 1284/1285 and the **intersection-not-override** case 1287), count (incl. `count=planned` on an RPC yielding no total 1283, `Preference-Applied` echoed 1286, and `count=none` rejected under `handling=strict` 1288), embedded (**limit only** — `.offset` has no case; see [`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → pagination*), content_range (1282, the empty-window envelope on an RPC) |
| representations | 1300–1333 | post, patch, delete, put |
| mutations | 1350–1397 | insert, update, delete, upsert, columns-param, missing-default, safe-update, safe-delete, max-affected |
| rpc | 1400–1440 | return, setof, args, method, content-negotiation, count, shape, error, overloaded, single-unnamed-param, name |
| auth | 1450–1499, 11800–11818 | anonymous, claims, role, role-claim-key, role-switching, jwt, audience, pre-request, guc, rpc |
| errors | 1500–1526 | sqlstate (incl. the two 5xx paths 1523/1524), pgrst_code (incl. the PGRST205 fuzzy-hint pair 1520/1521), raise, headers (incl. the `Proxy-Status` custom-code case 1519), verbosity (incl. the inline-416 case 1522), envelope (1525, byte-exact key emission order), proxy_status (1526, absent on the inline 416) |
| headers | 1550–1584 | prefer, profile, location, content-location, guc, vary |
| content_negotiation | 1600–1646 | json, csv, geojson, octet-stream, singular, nulls-stripped, plan, openapi, precedence, error, custom-media-handler |
| openapi | 1650–1682 | root, defaults, comments, table, types, rpc, mode, security |
| config | 1700–1744 | dump-config, sources, aliases, validation, coercion, parsing, precedence, db-max-rows, db-tx-end, db-extra-search-path, app-settings, server-cors-allowed-origins, cli, client-error-verbosity, server-reuseport, url-use-legacy-target-names, admin-server-unix-socket |
| observability | 1750–1769 | server-timing, trace-header, log-level |
| domain_representations | 1800–1820 | read, write, filter, default |

### v16.0 additions worth knowing

- **pagination** grew its band to **1250–1288** (**39** cases, up from 28) — the
  only area that moved since the previous synthesis, and the newest work in the
  tree. Eleven ids are new, **eight existing cases were rewritten**, and the pass
  is unusual in that it also **corrected a modelled rule** rather than only
  adding coverage:
  - **1287** (`range_header/intersects_limit`) is the pass's headline. The model
    previously claimed "Range headers override limit/offset query params",
    citing the upstream it-block titled *"headers override get parameters"*
    (`RangeSpec.hs#L194`, case 1261). `getRanges` does **not** override — it
    computes `headerAndLimitRange = rangeIntersection headerRange limitRange`
    (`ApiRequest.hs#L185`). Upstream's shape (`?limit=3` + `Range: 0-1`) is the
    one case where intersection and override agree, so no existing case could
    catch the error. 1287 (`?limit=2` + `Range: 0-5` → 2 rows, not 6) is the
    discriminating shape, and **1261's `notes:` were rewritten** to say so — its
    filename still reads `..._overrides_params.yaml`.
  - **1284**/**1285** (`range_header/get_only_head`, `get_only_rpc_post`) pin the
    header's **method scoping**: `headerRange = if method == "GET" then
    rangeRequested hdrs else allRange` (`ApiRequest.hs#L183`, under a comment
    citing RFC 9110), with `method` the raw request method, so HEAD is *not*
    folded into GET. limit/offset query params are not method-scoped and still
    apply (1277, 1281) — the contrast is the point.
  - **1280–1283**, **1285** carry pagination onto `/rpc/` paths for the first
    time (`pagination_count.rst#L61`, "This also works on views and table
    functions"): the Range header on a GET `/rpc/` (1280), limit/offset on a
    **POST** `/rpc/` whose args are in the JSON body (1281), the `*/*`
    empty-window envelope with `Content-Length: 2` (1282, a new `content_range`
    sub-feature) and `count=planned` on an RPC producing **no total at all**
    (1283, the PAG-024 degradation).
  - **1286**/**1288** are `Prefer` assertions: `count=exact` echoed as
    `Preference-Applied` on a plain **read** (upstream only asserts it on
    mutations), and `count=none` — which is *not* a `PreferCount` constructor —
    rejected with 400 PGRST122 under `handling=strict`. Cases **1267** and
    **1268** gained `headers_absent: ["Preference-Applied"]` for the same reason.
  - **1278**/**1279** finish the Range-header edge set: the 416 route on a
    *non-empty* collection (`Range: 100-199` + `count=exact` → `*/15`) and the
    open-ended non-zero offset `Range: 10-`, whose `source:` is
    `pagination_count.rst#L52` — **the tree's only case anchored at the
    documentation** rather than at the test suite or the source.
  - **1258, 1264, 1266, 1268** were retargeted from `/menagerie` to
    `/menagerie_empty` (see *Fixture-name collision* above), and **1268**/**1269**
    had their `source:` anchors moved from the enclosing `context` line onto the
    actual assertion (`RangeSpec.hs#L160`→`#L163`, `#L152`→`#L153`).
  - **1275**'s `notes:` were substantially expanded to record that Bier's
    conformance server sets no `db-max-rows`, so `count=estimated` reports
    `max(exactTotal, plannerEstimate)` rather than the exact total; the case is
    safe only because the planner estimate happens to equal the exact count.
  - The pass added **no fixture object** and no `pagination.delta.sql`.
- **errors** holds its band at **1500–1526** (27 cases) with two sub-features
  added in the previous pass — **envelope** (1525, byte-exact key emission order,
  the only errors case citing the `test/io` tree) and **proxy_status** (1526,
  absent on the inline 416) — plus **1519** (`Proxy-Status` on a
  `RAISE 'PGRST'` custom code), **1520–1521** (the PGRST205 fuzzy-hint threshold
  pair), **1522** (`client-error-verbosity: minimal` on the inline 416) and
  **1523–1524** (the 54001 and 42P17 5xx SQLSTATE paths, the two cases that
  needed `errors.delta.sql`).
- **url_grammar** holds its band at **1000–1035** (36 cases): **1031–1033**
  complete the OPTIONS `Allow` matrix, **1034** pins OPTIONS on an unknown
  relation → 404, **1035** pins `%20` decoding in a relation *and* a column name
  (via `test."Server Today"`, folded 2026-08-09), **1030** is 1016's `offset`
  twin, **1016** was re-anchored onto `UpsertSpec.hs#L295`, and **1029**'s
  "byte-identical parser" note was corrected.
- **select** holds **1100–1149** (50 cases), introducing
  **1142** (`select/embed/hint-table-bang-fk`); **1143–1144** and **1145–1146**
  (composite- and array-column `->`/`->>`); **1147–1149** (aggregate casts and
  group-by across an embed). 1143 and 1145 go through `to_jsonb(col)`, so the
  terminal-`->` rule on an actual *json/jsonb* column is still uncased — see
  [`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → select*.
- **headers** holds **1550–1584** (35 cases): **1582**/**1583** (the `Vary`
  funnel and its absence on errors) and **1584** (the two-token
  `Preference-Applied` echo that 1553 cannot pin). **headers/vary**
  (1575–1576, 1582–1583) covers the new `references/api/vary_header` docs page;
  the CORS-*preflight* leg is **not** pinned and is an open gap against the
  preflight cases 1702/1703/1742 in the config band.
- **config** holds **1700–1744 (45 cases)**: `client-error-verbosity`
  (1731–1732), `server-reuseport` (1735), `url-use-legacy-target-names` (1736),
  `admin-server-unix-socket` (1737–1738), `db-schemas` rejecting `pg_catalog` /
  `information_schema` (1733–1734), **1739** (`parsing/unknown-key-ignored`),
  **1740–1741** (`coerceBool`), **1742–1743** (the CORS default-preflight and the
  hard-coded `Access-Control-Expose-Headers` list — both **HTTP**, not CLI), and
  **1744** (`db-config = false`).
- **filters** holds **1150–1199** (50 cases) and its primary band is **fully
  allocated** — `spec/filters.yaml` declares `[10600..10799]` as the area's
  closed overflow range. All nine of its newest ids are `filters/embed/*` and
  none needed a fixture delta.
- **ordering** holds **1200–1232** (33 cases); its six newest ids — 1227–1228,
  1229, 1230, 1231–1232 — are **not** v16.0 behavior changes; every one predates
  the pin and had simply never been modelled. They added **no** fixture delta.
- **select/filters/ordering/url_grammar** gained the embed **alias vs. legacy
  target name** rules (1028, 1138–1141, 1188–1190, 1224).
- **auth** grew from 45 to 69 cases; the 19 that did not fit the full 1450–1499
  band went to the 11800–11818 overflow band.

## Case file shapes

Most cases are HTTP request/response (**630**). The **config** area additionally
uses a **CLI** shape (`request.kind: cli`, `request.flag: "--dump-config"`)
asserting on `expect.exit_code`, `expect.dump_contains`,
`expect.dump_reparse_stable`, and `expect.stderr_contains` rather than an HTTP
status — **38** cases, ids **1705–1741 plus 1744**. Note the CLI ids are *not*
one contiguous run: **1742 and 1743 are HTTP** CORS cases sitting inside the
config band, so `1705–1744` is the band, not the CLI set.

The **auth** area uses `request.jwt` to have the runner mint a signed token —
**32** cases do (1460–1464, 1468–1474, 1496–1499, 11800–11808, 11810–11812,
11815–11818); case 11809 is the exception, carrying a literal `Authorization`
header because it needs a token signed with a secret the harness deliberately
does not know.

Any case may carry a `config:` block — **115** do (111 non-empty; 1705, 1719,
1727 and 1743 carry an empty `config: {}`), spread over six areas: config 45,
auth 33, observability 20, select 10, openapi 4, errors 3. **The count did not
move this pass**: the pagination re-sync added eleven cases and not one of them
declares a `config:` block, which is why its assertions are safe on the shared
instance. The harness boots a dedicated instance only for the ids listed in
`@variant_case_ids` (`test/support/conformance_server.ex:58-59`, **18** ids:
1467–1473, 1491, 1493, 1654, 1677, 1678, 1680, 1682, 1703, 1758, 1763, 1764)
plus every `kind: cli` case. On any other HTTP case the `config:` block is
**inert** — it documents the upstream configuration the assertion depends on,
but the case still runs against a shared instance. Mechanically, **59** HTTP
cases carry a non-empty `config:` outside `@variant_case_ids`; most simply
restate what the shared instance already provides. The instances where the
declared config *diverges* from the shared instance, and the assertion therefore
depends on it, are case **1742**, the ten select cases **1129–1133, 1139, 1140,
1147–1149**, and the three errors cases **1517, 1518, 1522** (which
`spec/errors.yaml`'s own `harness_gate:` key names explicitly). See
[`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → config*.

`preconditions:` is parsed but **never executed** by the harness — treat it as
declarative documentation, never as setup a case may depend on. It is present on
**667** of the 668 cases (case **1330** omits it, which the schema allows). The
sharpest illustration is in this area: pagination cases **1272, 1274 and 1275**
declare `preconditions: ["ANALYZE …"]` for planner-estimate expectations and pass
only because `mix bier.fixtures.load` happens to run a database-wide `ANALYZE`
afterwards. `spec/pagination.yaml` records this for the harness owner rather than
working around it.

**3** cases assert `expect.status_text` (**1508, 1510, 1511**) and are tagged
`:pending` / excluded by `test/conformance/conformance_test.exs`, because `Req`
does not expose the HTTP reason phrase. That is the harness's only remaining
deferral; `case.schema.json` itself has no `pending` field. (Earlier revisions of
this file claimed 6 such cases, listing 1509, 1513 and 1514 as well — those three
only *mention* `status_text` in `notes:` or in an expected `hint:` string and
carry no `expect.status_text` key, so they run normally. Re-verified at the
668-case state: still exactly three.)

## Looking up a case

```sh
# all cases in an area
grep -l '^feature: domain_representations/' spec/conformance/cases/*.yaml

# the source citation for a case
grep '^source:' spec/conformance/cases/1200_order_by_column_asc.yaml

# list ids in numeric order (5-digit auth ids sort wrong otherwise)
ls spec/conformance/cases/ | sort -n
```
