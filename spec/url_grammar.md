# URL Grammar (PostgREST v16.0)

Behavior model for the `url_grammar` area: how PostgREST turns a raw HTTP
request line into a domain "resource + action", which query parameters are
reserved by the grammar, how percent-encoding / `+` are handled, and the
errors emitted when the path or method is unsupported.

Version pinned: **PostgREST v16.0**.

> **v16 source layout note.** v16 moved the library sources from
> `src/PostgREST/…` to `src/library/PostgREST/…` (a new `src/executable/` tree
> holds the CLI). Every source anchor below therefore carries the
> `src/library/` prefix; the v14.12 anchors that used `src/PostgREST/` are
> stale paths, not just stale line numbers.

Every claim below carries a source URL with a line anchor. Behaviors that
could not be traced to a concrete source line are listed under "Gaps".

---

## 1. Request -> ApiRequest pipeline

`userApiRequest` is the single entry point that translates a WAI `Request`
into the internal `ApiRequest`. The ordered steps are:

1. `getResource` — resolve the path segments into a `Resource`.
2. `getSchema` — resolve the active schema from profile headers / config.
3. `getAction` — combine resource + HTTP method into an `Action`.
4. `QueryParams.parse` — parse the raw query string.
5. `getRanges` — fold `Range` header + `limit`/`offset` params.
6. `getPayload` — parse the request body.

Source: postgrest v16.0 `src/library/PostgREST/ApiRequest.hs#L76-L100`
(<https://raw.githubusercontent.com/PostgREST/postgrest/v16.0/src/library/PostgREST/ApiRequest.hs#L76>).

The step order is byte-for-byte the same as v14.12; only the file path and the
line numbers moved (v14.12 had it at `src/PostgREST/ApiRequest.hs#L79-L103`).

---

## 2. Path -> resource resolution

`getResource` maps the WAI `pathInfo` (the path split on `/`, percent-decoded)
to exactly three resource shapes, and rejects everything else:

| Path segments        | Resource                        |
| -------------------- | ------------------------------- |
| `[]` (root `/`)      | `ResourceSchema` (OpenAPI root) or a configured root routine; `OpenAPIDisabled` if disabled |
| `[table]`            | `ResourceRelation table`        |
| `["rpc", pName]`     | `ResourceRoutine pName`         |
| anything else        | `Left InvalidResourcePath`      |

So `/items` is a relation, `/rpc/fn` is a routine, and any path with more
than one non-rpc segment (e.g. `/first/second/third`, `/invalid/nested/paths`)
is `InvalidResourcePath`.

Source: postgrest v16.0 `src/library/PostgREST/ApiRequest.hs#L118-L128`.

### 2.1 Root path `/`

- When OpenAPI is disabled (`OADisabled`), the root returns `OpenAPIDisabled`
  (`PGRST126`, 404).
- With a configured `db-root-spec` routine, the root resolves to that routine.
- Otherwise the root is `ResourceSchema` (serves the OpenAPI document).

Source: postgrest v16.0 `src/library/PostgREST/ApiRequest.hs#L120-L124`;
`OpenAPIDisabled` status/code/message at `src/library/PostgREST/Error.hs#L124`
(`HTTP.status404`), `#L170` (`"PGRST126"`), `#L196`
(`"Root endpoint metadata is disabled"`); behavior test
`test/spec/Feature/OpenApi/DisabledOpenApiSpec.hs#L17-L23`.

---

## 3. Percent-encoding & unicode paths

The path is percent-decoded by WAI into `pathInfo` before `getResource` sees
it, so the table/schema name carried in the path is the decoded UTF-8 string.
A unicode table reached via a fully percent-encoded path (e.g.
`/%D9%85%D9%88%D8%A7%D8%B1%D8%AF`) resolves to the decoded relation name
(`موارد`) in the exposed unicode schema.

Source (behavior test): postgrest v16.0
`test/spec/Feature/Query/UnicodeSpec.hs#L18` (the read
`get "/%D9%85%D9%88%D8%A7%D8%B1%D8%AF"`), with the exposed schema set inline at
`test/spec/Feature/Query/UnicodeSpec.hs#L15`
(`baseCfg { configDbSchemas = fromList ["تست"] }`). In v14.12 the same config
lived in a named `testUnicodeCfg` in `SpecHelper.hs`; v16 removed that helper
and inlines the config per-spec, so `SpecHelper.hs#L181` is no longer a valid
anchor. Table DDL unchanged at `test/spec/fixtures/schema.sql#L10` (schema) and
`#L187` (table).

Docs: `docs/references/api/url_grammar.rst#L21-L36` ("Unicode support") and
`#L38-L47` (table/column names with spaces via `%20`).

---

## 4. Method -> action resolution

`getAction` is a total function over `(Resource, method)`. Allowed
combinations:

### Relation (`/table`)

| Method  | Action                                    |
| ------- | ----------------------------------------- |
| HEAD    | `ActRelationRead` (head=True)             |
| GET     | `ActRelationRead`                         |
| POST    | `ActRelationMut MutationCreate`           |
| PUT     | `ActRelationMut MutationSingleUpsert`     |
| PATCH   | `ActRelationMut MutationUpdate`           |
| DELETE  | `ActRelationMut MutationDelete`           |
| OPTIONS | `ActRelationInfo`                         |

### Routine (`/rpc/fn`)

| Method  | Action / Error                            |
| ------- | ----------------------------------------- |
| HEAD    | `ActRoutine (InvRead True)`               |
| GET     | `ActRoutine (InvRead False)`              |
| POST    | `ActRoutine Inv`                          |
| OPTIONS | `ActRoutineInfo`                          |
| other   | `Left (InvalidRpcMethod method)`          |

So `DELETE`/`PATCH`/`PUT` on `/rpc/fn` fail with `InvalidRpcMethod`
(`PGRST101`, **405**).

### Schema root

| Method  | Action            |
| ------- | ----------------- |
| HEAD/GET| `ActSchemaRead`   |
| OPTIONS | `ActSchemaInfo`   |

Any other `(resource, method)` falls through to
`Left (UnsupportedMethod method)` (`PGRST117`, **405**).

Source: postgrest v16.0 `src/library/PostgREST/ApiRequest.hs#L130-L151`
(unchanged from v14.12 apart from the file move).

---

## 5. Schema (profile) negotiation

`getSchema` picks the active schema:

- **Read methods** (GET/HEAD/OPTIONS, i.e. the `_` fall-through) use the
  `Accept-Profile` header.
- **Write methods** (POST/PATCH/PUT/DELETE) use the `Content-Profile` header.
- If the chosen profile is not in `db-schemas`, fail with
  `UnacceptableSchema` (`PGRST106`, **406**), hint listing exposed schemas.
- If no profile header is present, use the first configured schema as default.
  `iNegotiatedByProfile` is `True` when more than one schema is exposed.

The response echoes the resolved schema in the `Content-Profile` header (only
when `iNegotiatedByProfile` is set).

Source: postgrest v16.0 `src/library/PostgREST/ApiRequest.hs#L156-L173`;
`Content-Profile` emission at `src/library/PostgREST/Response.hs#L258-L260`;
behavior tests `test/spec/Feature/Query/MultipleSchemaSpec.hs#L24-L82`
(reads: default v1 at L24-L44, `Accept-Profile: v2` at L46-L66, unknown table
per-schema at L68-L75, unknown profile at L77-L82) and `#L141-L159`
(writes via `Content-Profile`: v2 insert at L141-L150, unknown profile at
L152-L159).

> v16 note: `MultipleSchemaSpec` now sets its own config inline
> (`configDbSchemas = fromList ["v1", "v2", "SPECIAL \"@/\\#~_-"]`,
> `#L21`) instead of pulling a named helper config, which shifted every
> `it`-block in the file by +2 lines. The assertions themselves are identical
> to v14.12.

---

## 6. Reserved query parameters

`QueryParams.parse` treats some query-string keys as reserved grammar, not as
column filters:

- **Reserved (root-only)**: `select`, `columns`, `on_conflict`.
- **Reserved + embeddable** (matched by their *last* dot-separated word, so
  `embed.order` counts): `order`, `limit`, `offset`, `and`, `or`.

A key is a filter iff it is neither reserved nor ends in a reserved-embeddable
word. `select` defaults to `*` when absent.

Source: postgrest v16.0
`src/library/PostgREST/ApiRequest/QueryParams.hs#L167-L174`
(`endingIn` at L167-L169, `isFilter` at L172, `reserved` at L173,
`reservedEmbeddable` at L174); `select` default at `#L146`; the
`offset` -> `limit` key rewrite at `#L152` and `#L176`.

The whole reserved-parameter block is byte-identical to v14.12 — only the file
path and line numbers moved.

### 6.1 Canonical query string

The canonical form sorts params alphabetically by key and renders a missing
value as `=` (empty). E.g. `a=1&c=3&b=2&d` canonicalizes to `a=1&b=2&c=3&d=`.

Source (doctest): postgrest v16.0
`src/library/PostgREST/ApiRequest/QueryParams.hs#L104-L107`; implementation at
`#L161-L165`.

### 6.2 `+` and percent decoding in the query string

The query string is parsed with `parseQueryReplacePlus True`, so a literal `+`
in a value decodes to a space, and `%20` also decodes to a space. Both forms
are equivalent in filter values.

Source: postgrest v16.0
`src/library/PostgREST/ApiRequest/QueryParams.hs#L157`; behavior tests using
`%20` spaces in values `test/spec/Feature/Query/QuerySpec.hs#L203-L213`
(`plfts.The%20Fat%20Rats` at L203, `wfts.The%20Fat%20Rats` at L208,
`wfts.fun%20and%20possible` at L213).

### 6.3 Reserved-character quoting in filter values

PostgREST's query grammar reserves `,` `.` `:` `*` `(` `)` as structural
characters (list separators, the `op.value` dot, range/cast colons, the
`like`/`ilike` glob star, and the `in.( … )` parentheses). A filter value — or
a column *identifier* — that itself contains one of these reserved characters
must be wrapped in double quotes so the grammar reads the character as data,
not structure. In a URL the double quote is percent-encoded as `%22`, e.g.

```
/w_or_wo_comma_names?name=in.(%22Hebdon, John%22,%22Williams, Mary%22)
```

Inside a single `in.( … )` list, quoted and unquoted entries may be mixed —
only the entries carrying a reserved character need the `%22` quoting (e.g.
`in.(David White,%22Hebdon, John%22)`). The same rule applies to `not.in.( … )`.

**v16 change:** the documented reserved-character set gained `*`. v14.12's docs
listed ``, . : ()``; v16 lists ``, . : * ( )``. The parser itself did not change
(`QueryParams.hs` is byte-identical between the pins) — `*` is reserved because
`like`/`ilike` translate a `*` in the value into the SQL `%` wildcard, so a
literal `*` in a value or identifier must be quoted to survive.

Source (docs): postgrest v16.0
`docs/references/api/url_grammar.rst#L54` (the reserved-character list, changed
from v14.12's same line). Source (the `*` -> `%` translation):
`src/library/PostgREST/Query/SqlFragment.hs#L415` (`star c = if c == '*' then '%' else c`).

Source (behavior tests): postgrest v16.0
`test/spec/Feature/Query/QuerySpec.hs#L1300-L1321`
(`describe "values with quotes in IN and NOT IN"` at L1300; only-quoted values
at L1302/L1305, `not.in` at L1308, mixed quoted/unquoted at L1313, a value
containing `(`/`)` at L1319). The dual of this rule for quoted *identifiers*
(columns named `*id*`, `:arr->ow::cast`, `(inside,parens)`, `a.dotted.column`,
`  col  w  space  `) is exercised at
`test/spec/Feature/Query/QuerySpec.hs#L1290-L1293`; the fixture table is
`test/spec/fixtures/schema.sql#L1821-L1827` with data at
`test/spec/fixtures/data.sql#L571-L576`.

Backslash escaping inside `in.( … )` (`\"` for a literal double quote, `\\` for
a literal backslash) is documented at
`docs/references/api/url_grammar.rst#L68-L74` and tested at
`test/spec/Feature/Query/QuerySpec.hs#L1323-L1340`; see Gaps — no case is
emitted because the required rows are absent from the consolidated fixture.

---

## 7. Row resolution via horizontal filters

There is no row "id in the path"; a single row is addressed by a horizontal
filter on the query string, e.g. `/items?id=eq.5`. Filters with the `NoOpExpr`
shape (no `op.` prefix) on RPC become function params; otherwise they become
column predicates. The root-table subset (`qsFiltersRoot`) is what
UPDATE/DELETE use.

Source: postgrest v16.0
`src/library/PostgREST/ApiRequest/QueryParams.hs#L129-L143`
(the `hasOp`/`hasRootFilter` partition); behavior test
`test/spec/Feature/Query/QuerySpec.hs#L40-L46` (`it "matches with equality"` at
L40, `get "/items?id=eq.5"` at L41, body `[{"id":5}]` at L42, headers
`Content-Range: 0-0/*` / `Content-Length: 10` at L43-L46).

---

## 8. Range / limit interaction (grammar-level)

`getRanges` folds the `Range` request header with the `limit`/`offset` query
params. Grammar-relevant rules:

- The `Range` header is honored **only for GET** (ignored for other methods).
- `limit`/`offset` query params are **not allowed for PUT**: a PUT with a
  non-default top-level range fails with `PutLimitNotAllowedError`
  (`PGRST114`, **400**, message
  `"limit/offset querystring parameters are not allowed for PUT"`).
- `limit=0` is a special "limit zero" range; an otherwise-empty range is
  invalid (`InvalidRange`, `PGRST103`, **416**).

Source: postgrest v16.0 `src/library/PostgREST/ApiRequest.hs#L175-L191`
(GET-only `Range` at L183, PUT rejection at L178, limit-zero at L188-L190);
error codes/statuses `src/library/PostgREST/Error.hs#L107` (416),
`#L111` (400), `#L147` (`PGRST103`), `#L158` (`PGRST114`), `#L185` (message).

---

## 9. Error envelope (this area)

All grammar errors use the standard PostgREST error body
`{code, message, details, hint}` and set `Proxy-Status: PostgREST; error=<code>`.

| Error                | Code     | Status | Message                                      |
| -------------------- | -------- | ------ | -------------------------------------------- |
| InvalidResourcePath  | PGRST125 | 404    | Invalid path specified in request URL        |
| UnsupportedMethod    | PGRST117 | 405    | Unsupported HTTP method: `<method>`          |
| InvalidRpcMethod     | PGRST101 | 405    | Cannot use the `<method>` method on RPC      |
| UnacceptableSchema   | PGRST106 | 406    | Invalid schema: `<schema>`                   |
| PutLimitNotAllowed   | PGRST114 | 400    | limit/offset querystring parameters are not allowed for PUT |
| OpenAPIDisabled      | PGRST126 | 404    | Root endpoint metadata is disabled           |
| QueryParamError      | PGRST100 | 400    | (parser message)                             |

Source (postgrest v16.0 `src/library/PostgREST/Error.hs`):

| Error | status | code | message |
| ----- | ------ | ---- | ------- |
| InvalidResourcePath | `#L123` | `#L169` | `#L195` |
| UnsupportedMethod   | `#L116` | `#L161` | `#L188` |
| InvalidRpcMethod    | `#L106` | `#L145` | `#L176` |
| UnacceptableSchema  | `#L115` | `#L150` | `#L180` (hint `#L222`) |
| PutLimitNotAllowed  | `#L111` | `#L158` | `#L185` |
| OpenAPIDisabled     | `#L124` | `#L170` | `#L196` |
| QueryParamError     | `#L112` | `#L144` | `#L175` (details `#L201`) |

**v16 refactor (no wire change at defaults).** v14.12 built the error response
from a `PgrstError` typeclass whose `headers` prepended `proxyStatusHeader`; v16
splits that into `ErrorBody` + `ErrorHeaders` and emits `Proxy-Status`
unconditionally from `errorResponseFor` (`src/library/PostgREST/Error.hs#L86`
builds the header, `#L88` puts it on every error response). The error data types
moved to a new module `src/library/PostgREST/Error/Types.hs#L29-L60`.

v16 also adds `client-error-verbosity`: with the default `verbose` the body
keeps all four keys, with `minimal` it drops `details` and `hint`
(`src/library/PostgREST/Error.hs#L64-L78`, default `Verbose` at
`src/library/PostgREST/Config.hs#L338`). All cases in this area assume the
default, so the envelope shape is unchanged.

Proxy-status behavior test: `test/spec/Feature/Query/ErrorSpec.hs#L32-L40`
(`context "includes the proxy-status header on the response"` at L32,
`get "/invalid/nested/paths"` at L34, `Proxy-Status: PostgREST; error=PGRST125`
at L38).

---

## 10. Embed target names in query-parameter keys (v16 deprecation)

A reserved-embeddable key may carry a dot-separated **embed path** prefix
(`tasks.order=…`, `tasks.limit=1`), and a filter key may too
(`tasks.name=like.Code*`). When the embedded resource is *aliased* in `select`
(`select=the_tasks:tasks(id,name)`), v14.12 resolved such a prefix against the
underlying relation name. v16 deprecates that:

- Default (`url-use-legacy-target-names = true`): the request still succeeds,
  and the response carries a `Warning` header
  `299 PostgREST<version> "Embedded resource was referenced by relation name
  even though it has an alias. This is deprecated and will stop working in a
  future release. Update `<relName>` to `<alias>` in query string filters,
  orders or limits."` (one `` `name` to `alias` `` pair per offending node,
  comma-separated).
- With `url-use-legacy-target-names = false`: the same request is a **400
  `PGRST108`** with `message` `'tasks' is not an embedded resource in this
  request`, `details` `Target names are not allowed in filters if they have an
  alias`, and `hint` `Change 'tasks' to 'the_tasks' in filters, orders or
  limits.`

Source: config key + default `True` at
`src/library/PostgREST/Config.hs#L324` (dumped at `#L205`, declared at `#L118`);
warning collection at `src/library/PostgREST/Plan.hs#L151-L168`
(`readPlanWarning` matching `relAlias = Just alias, relIsLegacyTargetNameMatch = True`
at `#L167`); message/hint text and gating at
`src/library/PostgREST/App.hs#L212-L218`; `Warning` header construction at
`src/library/PostgREST/App.hs#L264-L270`; the `PGRST108` code at
`src/library/PostgREST/Error.hs#L152` with this variant's `details` at `#L214`
and `hint` at `#L220`, and the error constructor carrying the alias pair at
`src/library/PostgREST/Error/Types.hs#L46`.

Behavior tests: default/legacy path with the `Warning` header at
`test/spec/Feature/Query/QuerySpec.hs#L1183-L1187`; the
`url-use-legacy-target-names = false` variant at
`test/spec/Feature/Query/QuerySpec.hs#L1695-L1720`. Note the sibling change at
`#L1159-L1162`: the plain "ordering embeded entities with alias" test now uses
the alias (`the_tasks.order=name.asc`) rather than the relation name.

---

## Gaps

- **OpenAPIDisabled (PGRST126)** and the **db-root-spec routine** root path
  depend on PostgREST runtime config (`server-root-spec`,
  `openapi-mode=disabled`) rather than the schema fixture, so no black-box
  conformance case is emitted here. Source for behavior is
  `test/spec/Feature/OpenApi/DisabledOpenApiSpec.hs#L17-L23` and
  `src/library/PostgREST/ApiRequest.hs#L120-L124`. Recorded as a gap because
  the conformance runner has no config-injection mechanism for arbitrary new
  case ids (see the next item).
- **`url-use-legacy-target-names = false`** (the 400 `PGRST108` with the
  `Change 'tasks' to 'the_tasks'` hint,
  `test/spec/Feature/Query/QuerySpec.hs#L1709-L1720`) needs a per-case config
  override. The frozen harness only applies a case's `config:` block for ids in
  its hardcoded `@variant_case_ids` list
  (`test/support/conformance_server.ex`), which a spec agent may not extend, so
  only the **default** (legacy-enabled, `Warning`-header) side is emitted as a
  case (1028).
- **`PutLimitNotAllowedError` (PGRST114)** is traced in source
  (`src/library/PostgREST/ApiRequest.hs#L178`) but there is still no dedicated
  Feature spec line exercising it via PUT + `limit` in v16.0; case 1016 is
  emitted from the source contract and flagged here as test-anchor-pending.
- **Reserved-character quoting of a filter *value* containing a dot**
  (§6.3): the v16.0 Feature specs exercise the comma, paren and quote/backslash
  cases directly (`w_or_wo_comma_names`, `QuerySpec.hs#L1300-L1341`) but there
  is no `it`-block asserting a `%22`-quoted filter *value* that contains a
  literal dot — the dot-containing reserved-char test is about a quoted *column
  name* (`QuerySpec.hs#L1290-L1293`, now covered by case 1029). Rather than
  invent a row+assertion, the dotted-value case is omitted.
- **Backslash / escaped-double-quote values inside `in.( … )`**
  (`QuerySpec.hs#L1323-L1340`, docs `url_grammar.rst#L68-L74`) need the rows
  `'"'`, `'Double"Quote"McGraw"'`, `'\'` and `'/\Slash/\Beast/\'` in
  `w_or_wo_comma_names` (`test/spec/fixtures/data.sql#L348-L351`). The consolidated `bier_test`
  fixture seeds only the six comma/paren names, and this area's write channel
  may not edit `fixtures.sql`; adding them via the delta would duplicate an
  existing table's seed rather than add a new object. Omitted, recorded here.
- **Canonical query-string ordering** (§6.1) is a doctest, not an
  HTTP-observable response field, so it has no black-box case (it surfaces
  only via the `Vary`/cache key internals, not asserted in Feature specs).
- **`pg_catalog` / `information_schema` rejected in `db-schemas`** is new in
  v16 (docs `docs/references/api/schemas.rst#L8-L11`) but is a **startup
  validation** behavior, not a URL-grammar one; it belongs to the `config`
  area's CLI cases and is not emitted here.
- **Default `Vary: Accept, Prefer, Range` response header** is new in v16
  (`src/library/PostgREST/App.hs#L253,L259`, test
  `test/spec/Feature/HttpHeaderSpec.hs#L26-L34`). It is emitted on *every*
  response, not only profile-negotiated ones, so it belongs to the `headers`
  area rather than to profile negotiation here.
