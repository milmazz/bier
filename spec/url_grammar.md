# URL Grammar (PostgREST v14.12)

Behavior model for the `url_grammar` area: how PostgREST turns a raw HTTP
request line into a domain "resource + action", which query parameters are
reserved by the grammar, how percent-encoding / `+` are handled, and the
errors emitted when the path or method is unsupported.

Version pinned: **PostgREST v14.12**.

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

Source: postgrest v14.12 `src/PostgREST/ApiRequest.hs#L79-L103`
(<https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/src/PostgREST/ApiRequest.hs>).

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

Source: postgrest v14.12 `src/PostgREST/ApiRequest.hs#L117-L127`.

### 2.1 Root path `/`

- When OpenAPI is disabled (`OADisabled`), the root returns `OpenAPIDisabled`
  (`PGRST126`, 404).
- With a configured `db-root-spec` routine, the root resolves to that routine.
- Otherwise the root is `ResourceSchema` (serves the OpenAPI document).

Source: postgrest v14.12 `src/PostgREST/ApiRequest.hs#L119-L123`;
`OpenAPIDisabled` rendering at `src/PostgREST/Error.hs#L143,L189,L215`.

---

## 3. Percent-encoding & unicode paths

The path is percent-decoded by WAI into `pathInfo` before `getResource` sees
it, so the table/schema name carried in the path is the decoded UTF-8 string.
A unicode table reached via a fully percent-encoded path (e.g.
`/%D9%85%D9%88%D8%A7%D8%B1%D8%AF`) resolves to the decoded relation name
(`موارد`) in the exposed unicode schema.

Source (behavior test): postgrest v14.12
`test/spec/Feature/Query/UnicodeSpec.hs#L16-L19`
(read returns the unicode table's rows).

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

Source: postgrest v14.12 `src/PostgREST/ApiRequest.hs#L129-L152`.

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

The response echoes the resolved schema in the `Content-Profile` header.

Source: postgrest v14.12 `src/PostgREST/ApiRequest.hs#L155-L172`;
behavior tests `test/spec/Feature/Query/MultipleSchemaSpec.hs#L22-L80,L116-L157`.

---

## 6. Reserved query parameters

`QueryParams.parse` treats some query-string keys as reserved grammar, not as
column filters:

- **Reserved (root-only)**: `select`, `columns`, `on_conflict`.
- **Reserved + embeddable** (matched by their *last* dot-separated word, so
  `embed.order` counts): `order`, `limit`, `offset`, `and`, `or`.

A key is a filter iff it is neither reserved nor ends in a reserved-embeddable
word. `select` defaults to `*` when absent.

Source: postgrest v14.12
`src/PostgREST/ApiRequest/QueryParams.hs#L137-L168`.

### 6.1 Canonical query string

The canonical form sorts params alphabetically by key and renders a missing
value as `=` (empty). E.g. `a=1&c=3&b=2&d` canonicalizes to `a=1&b=2&c=3&d=`.

Source (doctest): postgrest v14.12
`src/PostgREST/ApiRequest/QueryParams.hs#L97-L99,L153-L157`.

### 6.2 `+` and percent decoding in the query string

The query string is parsed with `parseQueryReplacePlus True`, so a literal `+`
in a value decodes to a space, and `%20` also decodes to a space. Both forms
are equivalent in filter values.

Source: postgrest v14.12
`src/PostgREST/ApiRequest/QueryParams.hs#L149`; behavior test using `%20`
spaces in values `test/spec/Feature/Query/QuerySpec.hs#L198-L208`.

### 6.3 Reserved-character quoting in filter values

PostgREST's query grammar reserves `,` `.` `:` `(` `)` as structural
characters (list separators, the `op.value` dot, range/cast colons, and the
`in.( … )` parentheses). A filter value that itself contains one of these
reserved characters must be wrapped in double quotes so the grammar reads the
character as data, not structure. In a URL the double quote is percent-encoded
as `%22`, e.g.

```
/w_or_wo_comma_names?name=in.(%22Hebdon, John%22,%22Williams, Mary%22)
```

Inside a single `in.( … )` list, quoted and unquoted entries may be mixed —
only the entries carrying a reserved character need the `%22` quoting (e.g.
`in.(David White,%22Hebdon, John%22)`). The same rule applies to `not.in.( … )`.

Source (behavior test): postgrest v14.12
`test/spec/Feature/Query/QuerySpec.hs#L1288-L1307`
(`describe "values with quotes in IN and NOT IN"` at L1288; only-quoted values
at L1290/L1293, `not.in` at L1296, mixed quoted/unquoted at L1301). The dual of
this rule for quoted *identifiers* (a column whose name contains reserved
characters) is exercised at
`test/spec/Feature/Query/QuerySpec.hs#L1278-L1279`.

---

## 7. Row resolution via horizontal filters

There is no row "id in the path"; a single row is addressed by a horizontal
filter on the query string, e.g. `/items?id=eq.5`. Filters with the `NoOpExpr`
shape (no `op.` prefix) on RPC become function params; otherwise they become
column predicates. The root-table subset (`qsFiltersRoot`) is what
UPDATE/DELETE use.

Source: postgrest v14.12
`src/PostgREST/ApiRequest/QueryParams.hs#L121-L135`; behavior test
`test/spec/Feature/Query/QuerySpec.hs#L35-L41` (`it "matches with equality"` at
L35, `get "/items?id=eq.5"` at L36, body `[{"id":5}]` at L37, headers
`Content-Range: 0-0/*`/`Content-Length: 10` at L38-L41). (A prior review claimed
this was at ~L60, but L60 is the unrelated `/items?id=in.(1,3,5)` test; the
`eq.5` case is at L35-L41 in v14.12.)

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

Source: postgrest v14.12 `src/PostgREST/ApiRequest.hs#L174-L191`;
error codes/statuses `src/PostgREST/Error.hs#L126,L130,L166,L177,L197,L204`.

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

Source: postgrest v14.12 `src/PostgREST/Error.hs#L120-L241`;
proxy-status header behavior `test/spec/Feature/Query/ErrorSpec.hs#L32-L40`.

---

## Gaps

- **OpenAPIDisabled (PGRST126)** and the **db-root-spec routine** root path
  depend on PostgREST runtime config (`server-root-spec`,
  `openapi-mode=disabled`) rather than the schema fixture, so no black-box
  conformance case is emitted here. Source for behavior is
  `test/spec/Feature/OpenApi/DisabledOpenApiSpec.hs#L15-L20` and
  `src/PostgREST/ApiRequest.hs#L119-L123`. Recorded as a gap because the
  conformance runner has no config-injection mechanism specified yet.
- **`PutLimitNotAllowedError` (PGRST114)** is traced in source
  (`src/PostgREST/ApiRequest.hs#L177`) but I did not locate a dedicated
  Feature spec line exercising it via PUT + `limit`; emitted as a case from
  the source contract and flagged here as test-anchor-pending.
- **Reserved-character quoting of a filter *value* containing a dot** (§6.3):
  the v14.12 Feature specs exercise the comma case directly
  (`w_or_wo_comma_names`, `QuerySpec.hs#L1288-L1307`) but I found no Feature-spec
  `it`-block asserting a `%22`-quoted filter *value* that contains a literal dot
  — the dot-containing reserved-char tests are about quoted *column names*
  (`QuerySpec.hs#L1278-L1279`), not values. Rather than invent a row+assertion,
  the dotted-value case is omitted here and recorded as a gap.
- **Canonical query-string ordering** (§6.1) is a doctest, not an
  HTTP-observable response field, so it has no black-box case (it surfaces
  only via the `Vary`/cache key internals, not asserted in Feature specs).
