# Conformance case index

Cross-reference of the 532 conformance cases under `spec/conformance/cases/`.
Pinned target: **PostgREST v14.12**.

Each case is one YAML file `NNNN_<slug>.yaml` validated against
[`../case.schema.json`](../case.schema.json). Cases are grouped into 17 feature
areas; each area owns a contiguous, non-overlapping id band and is backed by one
SQL fixture fragment in [`fixtures/`](fixtures/). The `schema:` field inside a
case names the logical fixture set the runner loads from that area's `.sql`
fragment (e.g. `test`, `multi`, `unicode` all live in `url_grammar.sql`).

The first `/`-delimited segment of each case's `feature:` field is the
**authoritative** area assignment. The id bands below are derived from what is on
disk now; read the `feature:` prefix if a row ever looks ambiguous.

## Area <-> id band <-> fixture fragment

| Area | Cases | Id band | Fixture fragment | `schema:` values used |
|------|------:|---------|------------------|-----------------------|
| url_grammar | 28 | 1000–1027 | `fixtures/url_grammar.sql` | `multi`, `test`, `unicode` |
| operators | 50 | 1050–1099 | `fixtures/operators.sql` | `operators` |
| select | 38 | 1100–1137 | `fixtures/select.sql` | `test` |
| filters | 38 | 1150–1187 | `fixtures/filters.sql` | `test` |
| ordering | 23 | 1200–1222 | `fixtures/ordering.sql` | `ordering` |
| pagination | 28 | 1250–1277 | `fixtures/pagination.sql` | `pagination` |
| representations | 18 | 1300–1332 | `fixtures/representations.sql` | `representations` |
| mutations | 46 | 1350–1395 | `fixtures/mutations.sql` | `mutations` |
| rpc | 40 | 1400–1439 | `fixtures/rpc.sql` | `rpc` |
| auth | 45 | 1450–1494 | `fixtures/auth.sql` | `auth` |
| errors | 17 | 1500–1516 | `fixtures/errors.sql` | `test` |
| headers | 25 | 1550–1574 | `fixtures/headers.sql` | `headers` |
| content_negotiation | 39 | 1600–1638 | `fixtures/content_negotiation.sql` | `test` |
| openapi | 33 | 1650–1682 | `fixtures/openapi.sql` | `openapi`, `openapi_no_schema_comment`, `openapi_variadic` |
| config | 31 | 1700–1730 | `fixtures/config.sql` | `config` |
| observability | 18 | 1750–1767 | `fixtures/observability.sql` | `observability` |
| domain_representations | 15 | 1800–1814 | `fixtures/domain_representations.sql` | `domain_representations` |

Total: **532 cases**, **17 areas**, **17 fixture fragments**.

Each area's `feature:` prefix matches its area name exactly, so the area is
recoverable directly from the case file:

```sh
grep -h '^feature:' spec/conformance/cases/1800_format_single_domain_column.yaml
# feature: domain_representations/read/format_single_column
```

## Per-area sub-feature breakdown

The `feature:` field is a slash-delimited path `<area>/<sub-feature>/...`. The
sub-features present per area:

| Area | Id band | Sub-features (`feature:` second segment) |
|------|---------|-------------------------------------------|
| url_grammar | 1000–1027 | method, path, percent-encoding, profile, reserved-params, reserved-characters |
| operators | 1050–1099 | eq, neq, lt/lte/gt/gte, in, is, like/ilike, match/imatch, fts/plfts/wfts/phfts, cs/cd/ov, sl/sr/nxl/nxr/adj, isdistinct, not, quantifier (any/all) |
| select | 1100–1137 | columns, alias, cast, alias-and-cast, json-path, computed-column, embed (incl. one-to-one), computed-relationship, spread, aggregate |
| filters | 1150–1187 | horizontal, logical, not, json, quoting, embed |
| ordering | 1200–1222 | direction, nulls, json_path, computed_column, multi_column, composite, related, embed, error |
| pagination | 1250–1277 | limit_offset, range_header, count, embedded |
| representations | 1300–1332 | post, patch, delete, put |
| mutations | 1350–1395 | insert, update, delete, upsert, columns-param, missing-default, safe-update, safe-delete, max-affected |
| rpc | 1400–1439 | return, setof, args, method, content-negotiation, count, shape, error, overloaded, single-unnamed-param |
| auth | 1450–1494 | anonymous, claims, role, jwt, audience, pre-request, guc, rpc |
| errors | 1500–1516 | sqlstate, pgrst_code, raise, headers |
| headers | 1550–1574 | prefer, profile, location, content-location, guc |
| content_negotiation | 1600–1638 | json, csv, geojson, octet-stream, singular, nulls-stripped, plan, openapi, precedence, error, custom-media-handler (anyelement, override-builtin, any-handler) |
| openapi | 1650–1682 | root, defaults, comments, table, types, rpc, mode, security |
| config | 1700–1730 | dump-config, sources, aliases, validation, coercion, precedence, db-max-rows, db-tx-end, db-extra-search-path, app-settings, server-cors-allowed-origins, cli |
| observability | 1750–1767 | server-timing, trace-header, log-level |
| domain_representations | 1800–1814 | read, write, filter, default |

The **domain_representations** area (added after the audit) exercises
`CREATE DOMAIN ... ` cast-based representations: a JSON/text formatter cast on a
domain shaping the output (read), the inverse parser cast applied to request
bodies (write), domain-typed predicates via the parser cast (filter), and the
fall-through to the base type when no cast is defined (default). Fixture
`fixtures/domain_representations.sql`, all under `schema: domain_representations`.

## Case file shapes

Most cases are HTTP request/response. The **config** and **observability**
areas additionally use a **CLI** request shape (`request.kind: cli`,
`request.flag: "--dump-config"`) asserting on `expect.exit_code`,
`expect.dump_contains`, and `expect.stderr_contains` rather than an HTTP status.
The **auth** area uses `request.jwt` to have the runner mint a signed token. See
`../case.schema.json` for the full field set.

## Looking up a case

```sh
# all cases in an area
grep -l '^feature: domain_representations/' spec/conformance/cases/*.yaml

# the source citation for a case
grep '^source:' spec/conformance/cases/1200_order_by_column_asc.yaml
```
