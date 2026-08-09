# Conformance case index

Cross-reference of the **657** conformance cases under `spec/conformance/cases/`.
Pinned target: **PostgREST v16.0** (all 657 `source:` URLs).

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
| ordering | 33 | 1200–1232 | `fixtures/ordering.sql` | `ordering`, `mutations` |
| pagination | 28 | 1250–1277 | `fixtures/pagination.sql` | `pagination` |
| representations | 24 | 1300–1314, 1320–1324, 1330–1333 | `fixtures/representations.sql` | `representations` |
| mutations | 48 | 1350–1397 | `fixtures/mutations.sql` | `mutations` |
| rpc | 41 | 1400–1440 | `fixtures/rpc.sql` | `rpc`, `test` |
| auth | 69 | 1450–1499 **+ 11800–11818** | `fixtures/auth.sql` | `auth` |
| **errors** | **27** | **1500–1526** | `fixtures/errors.sql` + `fixtures/errors.delta.sql` (cases 1523/1524's `test.infinite_inserts` + `test.infinite_recursion`, folded) | `test` |
| headers | 35 | 1550–1584 | `fixtures/headers.sql` | `headers`, `test` |
| content_negotiation | 47 | 1600–1646 | `fixtures/content_negotiation.sql` | `test` |
| openapi | 33 | 1650–1682 | `fixtures/openapi.sql` | `openapi`, `openapi_no_schema_comment`, `openapi_variadic` |
| config | 45 | 1700–1744 | `fixtures/config.sql` | `config` |
| observability | 20 | 1750–1769 | `fixtures/observability.sql` | `observability` |
| domain_representations | 21 | 1800–1820 | `fixtures/domain_representations.sql` | `domain_representations` |

Total: **657 cases**, **17 areas**, **17 fixture fragments**
(plus **6** `*.delta.sql` write channels, all currently **comment-only** — each
carries a single `-- Folded into ../fixtures.sql on <date> …` provenance line
and no DDL. Four are dated 2026-08-08; `url_grammar.delta.sql` and the new
`errors.delta.sql` are dated **2026-08-09**. See
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
  and the document is built from `hd(db_schemas)`. Flagged as an open finding in
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
  > `lib/bier/plugs/action_controller.ex:479`, consumed at `:504`.
  >
  > **Corrected this pass: six cases, not four, actually send the label.** The
  > harness injects `Accept-Profile` with `Map.put_new`, so a case escapes the
  > injection only by spelling out **`Accept-Profile`** itself — spelling out
  > `Content-Profile` is not enough. Of the fourteen `multi` cases, **1005, 1006,
  > 1007, 1008, 1011 and 1012** receive `Accept-Profile: multi`; the previous
  > revision of this file listed only 1005–1008, having credited 1011/1012's
  > `Content-Profile` with suppressing it. Three of the six expect success
  > (**1005**/**1008** → 200, **1011** → 201) and so depend on the allowlist.
  > Recorded in [`../COVERAGE.md`](../COVERAGE.md) → *Open verification
  > findings*: a genuine finding, not a bookkeeping note, because 1008's own
  > `notes:` claim "no `Accept-Profile` header" while the harness always sends
  > one.
- **`unicode`** aliases the schema `تست` via `db_schema_aliases`
  (`test/support/conformance_server.ex:181`); **`test`**, `public` and `null`
  suppress the `Accept-Profile` header entirely.
- **`headers` is never actually applied on case 1574.** The harness sets
  `Accept-Profile` with `Map.put_new` (`test/support/http_case.ex:69`), so a case
  that spells the header out itself wins over its label. 1574 sends
  `Accept-Profile: SPECIAL "@/\#~_-` explicitly, and relation `names` exists in
  that schema. Fifteen cases override their label this way in total: 1009–1014,
  1017, 1018, 1023, 1024, 1558–1560, 1574 and 1583.
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
- **The whole errors area carries `schema: test`**, including the two new cases
  that write (**1523**, `POST /infinite_inserts`) and read (**1524**,
  `GET /infinite_recursion`) the objects folded through `errors.delta.sql`. Both
  objects were created in `test`, and the loader's area-schema mirroring
  reproduces them as views in the seven mirrored schemas without error — a
  self-referential view definition is not re-planned at `CREATE VIEW` time.

## Cross-area ownership caveat

`Prefer:` coverage is split across three areas by design — `headers` owns the
header semantics, `mutations` owns the table-flavored `max-affected` cases
(1390–1392), and `spec/rpc.yaml` explicitly delegates the RPC flavor of both
`handling` and `max-affected` to the headers area rather than duplicating it.
That delegation currently lands nowhere: **no case in any band exercises
`Prefer: handling` or `Prefer: max-affected` against `/rpc/*`**, and `PGRST128`
("Function must return SETOF or TABLE when max-affected preference is used with
handling=strict") is asserted by no case and modelled by no area file. Recorded
in [`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → headers*; when closing it,
decide the owning band first so the delegation stops being circular.

The same pattern applies to **`PGRST127`** (aggregates rejected inside a to-many
spread). It belongs to `select`; see
[`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → select*.

> Re-checked this pass: `grep -rl 'PGRST127\|PGRST128' spec/` matches exactly
> two files — `COVERAGE.md` and this INDEX, i.e. only the documents recording
> the gap. No case and no area model mentions either code. (The errors re-sync
> did not change this: `spec/errors.yaml` models eight PGRST codes — 000, 001,
> 003, 107, 121, 125, 205, 301 — and neither 127 nor 128 is among them.)

A third split needs the same care. The `in.( … )` **value grammar** is
url_grammar's (its docs page owns the *Reserved characters* section), the `in`
operator's **SQL rendering** is claimed by `operators.yaml:213`, and the
`in.()` **empty set** was raised against `filters`. Two of the three
`in.`-shaped gaps in [`../COVERAGE.md`](../COVERAGE.md) therefore have no
settled owner: decide the band before authoring, and note that `filters`' primary
band 1150–1199 is full (overflow `[10600..10799]`) while url_grammar's
1036+, ordering's 1233+ and errors' 1527+ are free.

## Per-area sub-feature breakdown

The `feature:` field is a slash-delimited path `<area>/<sub-feature>/...`. The
sub-features present per area (second segment, as on disk):

| Area | Id band | Sub-features |
|------|---------|--------------|
| url_grammar | 1000–1035 | method (incl. the OPTIONS `Allow` matrix on a table 1019, a VOLATILE routine 1031, a STABLE routine 1032 and the root path 1033), path (incl. OPTIONS on an unknown relation -> 404, 1034), percent-encoding (incl. `%20` in both a relation and a column name, 1035), profile, reserved-params (`limit` **and** `offset` forbidden on PUT, 1016/1030), reserved-characters |
| operators | 1050–1099 | eq, neq, lt/lte/gt/gte, in, is, like/ilike, match/imatch, fts/plfts/wfts/phfts, cs/cd/ov, sl/sr/nxl/nxr/adj, isdistinct, not, quantifier (any/all) |
| select | 1100–1149 | columns, alias, cast, alias-and-cast, json-path, **composite**, **array**, computed-column, computed-relationship, embed (incl. one-to-one, the v16 alias/legacy-target-name rules and the `table!fk` hint), spread, aggregate |
| filters | 1150–1199 | horizontal, logical, not, json, quoting, embed |
| ordering | 1200–1232 | direction, nulls (incl. alongside limits, 1229), json_path, computed_column, multi_column, composite, related (incl. computed relationships, 1227–1228), embed, mutation_representation (1230, `schema: mutations`), rpc (1231–1232), error |
| pagination | 1250–1277 | limit_offset, range_header, count, embedded |
| representations | 1300–1333 | post, patch, delete, put |
| mutations | 1350–1397 | insert, update, delete, upsert, columns-param, missing-default, safe-update, safe-delete, max-affected |
| rpc | 1400–1440 | return, setof, args, method, content-negotiation, count, shape, error, overloaded, single-unnamed-param, name |
| auth | 1450–1499, 11800–11818 | anonymous, claims, role, role-claim-key, role-switching, jwt, audience, pre-request, guc, rpc |
| **errors** | **1500–1526** | sqlstate (incl. the two new 5xx paths 1523/1524), pgrst_code (incl. the PGRST205 fuzzy-hint pair 1520/1521), raise, headers (incl. the `Proxy-Status` custom-code case 1519), verbosity (incl. the inline-416 case 1522), **envelope** (1525, byte-exact key emission order — new sub-feature), **proxy_status** (1526, absent on the inline 416 — new sub-feature) |
| headers | 1550–1584 | prefer, profile, location, content-location, guc, vary |
| content_negotiation | 1600–1646 | json, csv, geojson, octet-stream, singular, nulls-stripped, plan, openapi, precedence, error, custom-media-handler |
| openapi | 1650–1682 | root, defaults, comments, table, types, rpc, mode, security |
| config | 1700–1744 | dump-config, sources, aliases, validation, coercion, parsing, precedence, db-max-rows, db-tx-end, db-extra-search-path, app-settings, server-cors-allowed-origins, cli, client-error-verbosity, server-reuseport, url-use-legacy-target-names, admin-server-unix-socket |
| observability | 1750–1769 | server-timing, trace-header, log-level |
| domain_representations | 1800–1820 | read, write, filter, default |

### v16.0 additions worth knowing

- **errors** grew its band to **1500–1526** (**27** cases, up from 19) — the only
  area that moved since the previous synthesis, and the newest work in the tree.
  Eight ids are new and they add **two sub-features**:
  - **1519** (`errors/headers/proxy_status_pgrst_custom_code`) — `Proxy-Status`
    carries a `RAISE 'PGRST'`-supplied custom code, not just a PGRST\* or PT
    code (`ErrorSpec.hs#L70`), completing the pair with 1506.
  - **1520–1521** (`errors/pgrst_code/table_not_found_hint` /
    `_no_hint`) — the **PGRST205 fuzzy hint**: `/projectx` is close enough to
    `projects` to earn a `"Perhaps you meant the table 'test.projects'"` hint
    (`ErrorSpec.hs#L80`), `/projxxxx` is not and the hint is `null`
    (`ErrorSpec.hs#L97`). The pair pins both sides of the similarity threshold.
  - **1522** (`errors/verbosity/minimal_range_error`) — `client-error-verbosity:
    minimal` applied to the **inline** 416 body, which is built by
    `Response.hs#L76` rather than by `errorResponseFor`.
  - **1523–1524** (`errors/sqlstate/statement_too_complex` /
    `infinite_recursion`) — the two 5xx SQLSTATE paths: `54001` "stack depth
    limit exceeded" from a self-inserting trigger (`ErrorSpec.hs#L19`) and
    `42P17` "infinite recursion detected in rules for relation" from a view
    defined over itself (`QuerySpec.hs#L1680`). These are the **only** two cases
    in this pass that needed fixture objects — `test.infinite_inserts` (table +
    same-named trigger function + `do_infinite_inserts` trigger) and
    `test.infinite_recursion` (a view `CREATE OR REPLACE`d to select from
    itself), written through `fixtures/errors.delta.sql` and folded into
    `fixtures.sql` on 2026-08-09.
  - **1525** (`errors/envelope/key_emission_order`) — a **byte-exact**
    assertion that the envelope emits `code, details, hint, message` in
    alphabetical order, the wire-level property a `body_exact` mapping cannot
    pin (`test/io/test_settings.py#L299`). It is the only errors case citing the
    `test/io` tree.
  - **1526** (`errors/proxy_status/absent_on_inline_416`) — the negative
    counterpart of 1506/1515/1516/1519: the inline 416 body never passes through
    `errorResponseFor`, so it carries **no** `Proxy-Status`
    (`Response.hs#L65`).
- **url_grammar** grew its band to **1000–1035** (36 cases). Six ids are new and
  two existing cases were rewritten:
  - **1031–1033** complete the OPTIONS `Allow` matrix that 1019 (a writeable
    table) had covered alone: a VOLATILE routine → `OPTIONS,POST`
    (`OptionsSpec.hs#L84`), a STABLE routine → `OPTIONS,GET,HEAD,POST`
    (`#L90`), and the root path → `OPTIONS,GET,HEAD` (`#L103`).
  - **1034** pins OPTIONS on an unknown relation → **404**
    (`OptionsSpec.hs#L22`), i.e. OPTIONS does not bypass relation resolution.
  - **1035** pins `%20` decoding in a *relation* name and a *column* name at
    once (`GET /Server%20Today?select=Just%20A%20Server%20Model&…`,
    `QuerySpec.hs#L1281`), via `test."Server Today"` + its five upstream seed
    rows, folded on 2026-08-09.
  - **1030** is 1016's twin — `offset` on PUT, not just `limit`
    (`UpsertSpec.hs#L302`).
  - **1016** was **re-anchored and rewritten** off `ApiRequest.hs#L178` onto
    `UpsertSpec.hs#L295`, retiring a false "no Feature spec line exists" claim.
  - **1029**'s `notes:` were corrected: the v14.12→v16.0 parser claim
    "byte-identical" was overstated; the parser *body* is unchanged (+8 line
    offset) but the module header is not.
- **select** grew its band to **1100–1149** (50 cases), introducing
  **1142** (`select/embed/hint-table-bang-fk`, `EmbedDisambiguationSpec.hs#L244`);
  **1143–1144** (`select/composite/arrow` and `arrow-text`,
  `JsonOperatorSpec.hs#L150`); **1145–1146** (`select/array/item-arrow` and
  `item-arrow-text`, `JsonOperatorSpec.hs#L158`); **1147–1149**
  (`select/aggregate` casts and group-by across an embed,
  `AggregateFunctionsSpec.hs#L83/#L86/#L92`). 1143 and 1145 go through
  `to_jsonb(col)`, so the terminal-`->` rule on an actual *json/jsonb* column is
  still uncased — see [`../COVERAGE.md`](../COVERAGE.md) → *Known gaps →
  select*.
- **headers** grew its band to **1550–1584** (35 cases): **1582**/**1583** (see
  below) and **1584** (`headers/prefer/timezone`, the two-token
  `Preference-Applied: handling=strict, timezone=…` echo that its sibling 1553
  cannot pin).
- **headers/vary** (1575–1576, 1582–1583) covers the new
  `references/api/vary_header` docs page: the default
  `Vary: Accept, Prefer, Range`, its verbatim replacement through the
  `response.headers` GUC, its presence on every non-error response including
  OPTIONS (1582), and its absence on error responses (1583) — the last two
  derived from App.hs' `toWaiResponse` funnel
  (`src/library/PostgREST/App.hs#L253`), which errors bypass. The third path — a
  CORS *preflight*, answered by the wai-cors middleware before `toWaiResponse` —
  is **not** pinned; it is an open gap against the preflight cases 1702/1703/1742
  in the config band (see [`../COVERAGE.md`](../COVERAGE.md) →
  *Known gaps → headers*).
- **config** grew to **1700–1744 (45 cases)**: `client-error-verbosity`
  (1731–1732), `server-reuseport` (1735), `url-use-legacy-target-names` (1736),
  `admin-server-unix-socket` (1737–1738), `db-schemas` rejecting `pg_catalog` /
  `information_schema` (1733–1734), **1739**
  (`config/parsing/unknown-key-ignored`), **1740–1741** (`coerceBool` from
  numeric and from text strings), **1742–1743** (the CORS default-preflight and
  the hard-coded `Access-Control-Expose-Headers` list — both **HTTP**, not CLI),
  and **1744** (`db-config = false` ignores `ALTER ROLE … SET pgrst.*`).
- **filters** grew its band to **1150–1199** (50 cases) and its primary band is
  now **fully allocated** — `spec/filters.yaml` declares `[10600..10799]` as the
  area's closed overflow range. All nine new ids are `filters/embed/*` and none
  needed a fixture delta: **1191** (`third_level`), **1192–1193** (`inner`),
  **1194/1196–1199** (`null_filtering` + `not.is.null` antijoins), **1195**
  (`or_across_embeds`). **1170** and **1189** were re-anchored rather than
  re-asserted (1189's `source:` moved off `Plan.hs#L855` onto
  `QuerySpec.hs#L1187`).
- **ordering** grew its band to **1200–1232** (33 cases). The six new ids —
  **1227–1228** (`related/computed_relationship[_not_to_one_error]`,
  `RelatedQueriesSpec.hs#L35`/`#L128`), **1229** (`nulls/alongside_limits`,
  `RangeSpec.hs#L226`), **1230** (`mutation_representation/top_level`,
  `UpdateSpec.hs#L443`, `schema: mutations`) and **1231–1232** (`rpc/result`,
  `RangeSpec.hs#L30`) — are **not** v16.0 behavior changes; every one predates
  the pin and had simply never been modelled. They added **no** fixture delta.
- **select/filters/ordering/url_grammar** gained the embed **alias vs. legacy
  target name** rules (1028, 1138–1141, 1188–1190, 1224).
- **auth** grew from 45 to 69 cases; the 19 that did not fit the full 1450–1499
  band went to the 11800–11818 overflow band.

## Case file shapes

Most cases are HTTP request/response (**619**). The **config** area additionally
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
auth 33, observability 20, select 10, openapi 4, **errors 3**. The count moved
114 → 115 this pass, entirely from the errors area (2 → 3, the new case
**1522**). The harness boots a dedicated instance only for the ids listed in
`@variant_case_ids` (`test/support/conformance_server.ex:58-59`, **18** ids:
1467–1473, 1491, 1493, 1654, 1677, 1678, 1680, 1682, 1703, 1758, 1763, 1764)
plus every `kind: cli` case. On any other HTTP case the `config:` block is
**inert** — it documents the upstream configuration the assertion depends on,
but the case still runs against a shared instance. Mechanically, **59** HTTP
cases carry a non-empty `config:` outside `@variant_case_ids`; most simply
restate what the shared instance already provides. The instances where the
declared config *diverges* from the shared instance, and the assertion therefore
depends on it, are case **1742**, the ten select cases **1129–1133, 1139, 1140,
1147–1149**, and — new this pass, declared by `spec/errors.yaml`'s own
`harness_gate` key — the three errors cases **1517, 1518, 1522**, all three of
which need `client-error-verbosity: minimal`. See
[`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → config*.

`preconditions:` is parsed but **never executed** by the harness — treat it as
declarative documentation, never as setup a case may depend on. It is present on
**656** of the 657 cases (case **1330** omits it, which the schema allows).

**3** cases assert `expect.status_text` (**1508, 1510, 1511**) and are tagged
`:pending` / excluded by `test/conformance/conformance_test.exs`, because `Req`
does not expose the HTTP reason phrase. That is the harness's only remaining
deferral; `case.schema.json` itself has no `pending` field. (Earlier revisions of
this file claimed 6 such cases, listing 1509, 1513 and 1514 as well — those three
only *mention* `status_text` in `notes:` or in an expected `hint:` string and
carry no `expect.status_text` key, so they run normally. Re-verified at the
657-case state: still exactly three.)

## Looking up a case

```sh
# all cases in an area
grep -l '^feature: domain_representations/' spec/conformance/cases/*.yaml

# the source citation for a case
grep '^source:' spec/conformance/cases/1200_order_by_column_asc.yaml

# list ids in numeric order (5-digit auth ids sort wrong otherwise)
ls spec/conformance/cases/ | sort -n
```
