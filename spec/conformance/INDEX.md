# Conformance case index

Cross-reference of the **628** conformance cases under `spec/conformance/cases/`.
Pinned target: **PostgREST v16.0** (all 628 `source:` URLs).

Each case is one YAML file `NNNN_<slug>.yaml` validated against
[`../case.schema.json`](../case.schema.json). Cases are grouped into 17 feature
areas; each area owns a non-overlapping id band and is backed by one SQL fixture
fragment in [`fixtures/`](fixtures/).

The `schema:` field inside a case is a **fixture-set label, not a filename**:
the frozen harness (`test/support/http_case.ex`) sends any label other than
`null`/`public`/`test` as an `Accept-Profile: <label>` header, so the label must
name a schema the shared conformance server exposes *or* resolve through one of
its aliases / profile lists. Several labels are not schema names on disk —
`unicode` → `تست`, `multi` → the `v1`/`v2` pair — and one (`headers`) is
overridden by an explicit header. See the **Label caveats** section below.

The first `/`-delimited segment of each case's `feature:` field is the
**authoritative** area assignment. The id bands below are derived from what is on
disk now; read the `feature:` prefix if a row ever looks ambiguous.

> **Non-contiguous bands.** Two areas do not occupy a single contiguous range and
> regenerating this file must preserve that rather than collapsing it:
>
> - **auth** uses **11800–11818** on top of its full primary band **1450–1499**
>   (all 50 primary ids are in use). These 19 are the only 5-digit case ids in
>   the tree, and `11800` sorts immediately after `1180` in a *lexical* listing,
>   so they interleave with the filters area's 1180–1190 cases unless ids are
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
| url_grammar | 30 | 1000–1029 | `fixtures/url_grammar.sql` | `multi`, `test`, `unicode`, `ordering` |
| operators | 50 | 1050–1099 | `fixtures/operators.sql` | `operators` |
| select | 50 | 1100–1149 | `fixtures/select.sql` | `test` |
| filters | 41 | 1150–1190 | `fixtures/filters.sql` | `test` |
| ordering | 27 | 1200–1226 | `fixtures/ordering.sql` | `ordering` |
| pagination | 28 | 1250–1277 | `fixtures/pagination.sql` | `pagination` |
| representations | 24 | 1300–1314, 1320–1324, 1330–1333 | `fixtures/representations.sql` | `representations` |
| mutations | 48 | 1350–1397 | `fixtures/mutations.sql` | `mutations` |
| rpc | 41 | 1400–1440 | `fixtures/rpc.sql` | `rpc`, `test` |
| auth | 69 | 1450–1499 **+ 11800–11818** | `fixtures/auth.sql` | `auth` |
| errors | 19 | 1500–1518 | `fixtures/errors.sql` | `test` |
| headers | 35 | 1550–1584 | `fixtures/headers.sql` | `headers`, `test` |
| content_negotiation | 47 | 1600–1646 | `fixtures/content_negotiation.sql` | `test` |
| openapi | 33 | 1650–1682 | `fixtures/openapi.sql` | `openapi`, `openapi_no_schema_comment`, `openapi_variadic` |
| config | 45 | 1700–1744 | `fixtures/config.sql` | `config` |
| observability | 20 | 1750–1769 | `fixtures/observability.sql` | `observability` |
| domain_representations | 21 | 1800–1820 | `fixtures/domain_representations.sql` | `domain_representations` |

Total: **628 cases**, **17 areas**, **17 fixture fragments**
(plus 5 `*.delta.sql` write channels, all currently **comment-only** — each
carries a single `-- Folded into ../fixtures.sql on 2026-08-08 …` provenance
line and no DDL; see [`fixtures/README.md`](fixtures/README.md) for who may
write which file).

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
  [`../COVERAGE.md`](../COVERAGE.md) → *Open verification finding*.
- **`multi`** is not a schema either — it stands for the `v1`/`v2` profile pair
  routed by `db_profile_default` / `db_profile_schemas`
  (`test/support/conformance_server.ex:184-185`, resolved in
  `lib/bier/plugs/action_controller.ex:477-506`). All the relations these cases
  target (`parents`, `children`, `get_parents_below`) exist in both `v1` and
  `v2`; case 1024 deliberately targets one that exists only in `v2`.
- **`unicode`** aliases the schema `تست` via `db_schema_aliases`
  (`test/support/conformance_server.ex:181`); **`test`**, `public` and `null`
  suppress the `Accept-Profile` header entirely.
- **`headers` is never actually applied on case 1574.** The harness sets
  `Accept-Profile` with `Map.put_new` (`test/support/http_case.ex:69`), so a case
  that spells the header out itself wins over its label. 1574 sends
  `Accept-Profile: SPECIAL "@/\#~_-` explicitly, and relation `names` exists in
  that schema.
- **`ordering` appears under `url_grammar`** (case 1028, the legacy embed
  target-name case, reuses the ordering fixture set), and **`test` appears under
  `rpc`** (case 1440) and **under `headers`** (case 1576).

## Cross-area ownership caveat

`Prefer:` coverage is split across three areas by design — `headers` owns the
header semantics, `mutations` owns the table-flavored `max-affected` cases
(1390–1392), and `spec/rpc.yaml` explicitly delegates the RPC flavor of both
`handling` and `max-affected` to the headers area rather than duplicating it.
That delegation currently lands nowhere: **no case in any band exercises
`Prefer: handling` or `Prefer: max-affected` against `/rpc/*`**, and `PGRST128`
("Function must return SETOF or TABLE when max-affected preference is used with
handling=strict") appears nowhere in the tree. Recorded in
[`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → headers*; when closing it,
decide the owning band first so the delegation stops being circular.

The same pattern applies to **`PGRST127`** (aggregates rejected inside a to-many
spread): it appears nowhere in any band or area model. It belongs to `select`;
see [`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → select*.

## Per-area sub-feature breakdown

The `feature:` field is a slash-delimited path `<area>/<sub-feature>/...`. The
sub-features present per area (second segment, as on disk):

| Area | Id band | Sub-features |
|------|---------|--------------|
| url_grammar | 1000–1029 | method, path, percent-encoding, profile, reserved-params, reserved-characters |
| operators | 1050–1099 | eq, neq, lt/lte/gt/gte, in, is, like/ilike, match/imatch, fts/plfts/wfts/phfts, cs/cd/ov, sl/sr/nxl/nxr/adj, isdistinct, not, quantifier (any/all) |
| select | 1100–1149 | columns, alias, cast, alias-and-cast, json-path, **composite**, **array**, computed-column, computed-relationship, embed (incl. one-to-one, the v16 alias/legacy-target-name rules and the `table!fk` hint), spread, aggregate |
| filters | 1150–1190 | horizontal, logical, not, json, quoting, embed |
| ordering | 1200–1226 | direction, nulls, json_path, computed_column, multi_column, composite, related, embed, error |
| pagination | 1250–1277 | limit_offset, range_header, count, embedded |
| representations | 1300–1333 | post, patch, delete, put |
| mutations | 1350–1397 | insert, update, delete, upsert, columns-param, missing-default, safe-update, safe-delete, max-affected |
| rpc | 1400–1440 | return, setof, args, method, content-negotiation, count, shape, error, overloaded, single-unnamed-param, name |
| auth | 1450–1499, 11800–11818 | anonymous, claims, role, role-claim-key, role-switching, jwt, audience, pre-request, guc, rpc |
| errors | 1500–1518 | sqlstate, pgrst_code, raise, headers, verbosity |
| headers | 1550–1584 | prefer, profile, location, content-location, guc, vary |
| content_negotiation | 1600–1646 | json, csv, geojson, octet-stream, singular, nulls-stripped, plan, openapi, precedence, error, custom-media-handler |
| openapi | 1650–1682 | root, defaults, comments, table, types, rpc, mode, security |
| config | 1700–1744 | dump-config, sources, aliases, validation, coercion, parsing, precedence, db-max-rows, db-tx-end, db-extra-search-path, app-settings, server-cors-allowed-origins, cli, client-error-verbosity, server-reuseport, url-use-legacy-target-names, admin-server-unix-socket |
| observability | 1750–1769 | server-timing, trace-header, log-level |
| domain_representations | 1800–1820 | read, write, filter, default |

### v16.0 additions worth knowing

- **select** grew its band to **1100–1149** (50 cases, up from 42). Eight ids are
  new since the last synthesis, and they introduce two new sub-features:
  **1142** (`select/embed/hint-table-bang-fk`, disambiguation via `table!fk`,
  `EmbedDisambiguationSpec.hs#L244`); **1143–1144** (`select/composite/arrow` and
  `arrow-text` — `num->i` / `num->>i` on a *composite* column,
  `JsonOperatorSpec.hs#L150`); **1145–1146** (`select/array/item-arrow` and
  `item-arrow-text` — `numbers->0`, `numbers_mult->1->>2` on `int[]`/`int[][]`,
  `JsonOperatorSpec.hs#L158`); **1147–1149** (`select/aggregate` — cast of the
  aggregated column, alias + input cast + result cast, and group-by across an
  embed, `AggregateFunctionsSpec.hs#L83/#L86/#L92`). 1143 and 1145 go through
  `to_jsonb(col)`, so the terminal-`->` rule on an actual *json/jsonb* column is
  still uncased — see [`../COVERAGE.md`](../COVERAGE.md) → *Known gaps →
  select*.
- **headers** grew its band to **1550–1584** (35 cases). Three ids are new in
  this pass: **1582** and **1583** (see below) and **1584**
  (`headers/prefer/timezone`, the two-token `Preference-Applied:
  handling=strict, timezone=…` echo that its sibling 1553 cannot pin).
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
- **config** grew to **1700–1744 (45 cases)**. v16 keys added earlier in the
  pass: `client-error-verbosity` (1731–1732), `server-reuseport` (1735),
  `url-use-legacy-target-names` (1736), `admin-server-unix-socket` (1737–1738),
  plus `db-schemas` rejecting `pg_catalog` / `information_schema` (1733–1734).
  Six ids are newer still: **1739** (`config/parsing/unknown-key-ignored`, a new
  sub-feature), **1740–1741** (`coerceBool` from numeric and from text strings),
  **1742–1743** (the CORS default-preflight and the hard-coded
  `Access-Control-Expose-Headers` list — both **HTTP**, not CLI), and **1744**
  (`db-config = false` ignores `ALTER ROLE … SET pgrst.*`).
- **select/filters/ordering/url_grammar** gained the embed **alias vs. legacy
  target name** rules (1028, 1138–1141, 1188–1190, 1224).
- **auth** grew from 45 to 69 cases; the 19 that did not fit the full 1450–1499
  band went to the 11800–11818 overflow band.

## Case file shapes

Most cases are HTTP request/response (**590**). The **config** area additionally
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

Any case may carry a `config:` block — **114** do (110 non-empty; 1705, 1719,
1727 and 1743 carry an empty `config: {}`) — but the harness boots a dedicated
instance only for the ids listed in `@variant_case_ids`
(`test/support/conformance_server.ex:58-59`, **18** ids: 1467–1473, 1491, 1493,
1654, 1677, 1678, 1680, 1682, 1703, 1758, 1763, 1764) plus every `kind: cli`
case. On any other HTTP case the `config:` block is **inert** — it documents the
upstream configuration the assertion depends on, but the case still runs against
a shared instance. The live instances of that mismatch are case **1742** and the
ten select cases **1129–1133, 1139, 1140, 1147–1149**; see
[`../COVERAGE.md`](../COVERAGE.md) → *Known gaps → config*.

`preconditions:` is parsed but **never executed** by the harness — treat it as
declarative documentation, never as setup a case may depend on. It is present on
627 of the 628 cases (case **1330** omits it, which the schema allows).

**3** cases assert `expect.status_text` (**1508, 1510, 1511**) and are tagged
`:pending` / excluded by `test/conformance/conformance_test.exs`, because `Req`
does not expose the HTTP reason phrase. That is the harness's only remaining
deferral; `case.schema.json` itself has no `pending` field. (Earlier revisions of
this file claimed 6 such cases, listing 1509, 1513 and 1514 as well — those three
only *mention* `status_text` in `notes:` or in an expected `hint:` string and
carry no `expect.status_text` key, so they run normally.)

## Looking up a case

```sh
# all cases in an area
grep -l '^feature: domain_representations/' spec/conformance/cases/*.yaml

# the source citation for a case
grep '^source:' spec/conformance/cases/1200_order_by_column_asc.yaml

# list ids in numeric order (5-digit auth ids sort wrong otherwise)
ls spec/conformance/cases/ | sort -n
```
