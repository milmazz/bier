# REST API Reference

Bier generates a REST API on the fly from PostgreSQL introspection, following
PostgREST's request grammar. This reference documents that grammar — the
`select`/filter/order/pagination query parameters, resource embedding,
mutations, RPC, content negotiation, and error responses — using the brewery
example schema (`docs/tutorials/brewery.sql`, exposed under `db_schemas:
["api"]`) for every example.

All curl examples assume Bier is running at `http://localhost:4040` with the
`api` schema exposed (see [Getting Started](../tutorials/getting-started.md)).
Requests that require the `brewery_member` role are noted explicitly; see
[Authentication](../tutorials/authentication.md).

The brewery schema has these relations:

* `api.styles(id, name, description)`
* `api.breweries(id, name, city, country, founded_year, latitude, longitude)`
* `api.beers(id, brewery_id → breweries, style_id → styles, name, abv, ibu, description)`
* `api.taprooms(id, brewery_id → breweries, name, address, city)`
* `api.check_ins(id, beer_id → beers, drinker, rating, comment, created_at)`
* RPCs: `api.search_beers(term text)`, `api.top_rated_beers(min_rating int default 4)`

## Reading rows & vertical filtering (`select`)

`GET /<relation>` returns every row of a table or view as a JSON array. With
no `select` parameter, every column is returned (`SELECT *`):

```bash
curl "http://localhost:4040/styles"
```

```json
[
  {"id": 1, "name": "IPA", "description": "India Pale Ale — hop-forward and bitter"},
  {"id": 2, "name": "Stout", "description": "Dark, roasted, full-bodied"},
  {"id": 3, "name": "Pilsner", "description": "Crisp pale lager"},
  {"id": 4, "name": "Saison", "description": "Fruity, spicy farmhouse ale"},
  {"id": 5, "name": "Hazy IPA", "description": "Juicy, cloudy New England IPA"}
]
```

### Columns, alias, cast

`select=<col>[,<col>...]` limits the response to the listed columns.
`select=<alias>:<col>` renames a column's JSON key. `select=<col>::<type>`
casts the column to a Postgres type before serialization. Alias and cast
combine as `select=<alias>:<col>::<type>`.

```bash
curl "http://localhost:4040/beers?select=beer:name,abv_text:abv::text&id=eq.1"
```

```json
[{"beer": "Trail Crest IPA", "abv_text": "6.80"}]
```

### JSON paths

`->` navigates into a `json`/`jsonb` column and keeps the JSON type; `->>`
extracts the final step as text. Paths may be aliased and cast, and integer
segments are treated as array indexes. The brewery schema has no `jsonb`
column today, so this is illustrative — for a hypothetical
`beers.metadata jsonb` column:

```bash
curl "http://localhost:4040/beers?select=name,metadata->specs->>ibu_target::int"
```

### Computed columns

A computed column is a SQL function that takes the table's row type and is
selected exactly like a normal column. None of the brewery tables define one
today; the pattern (illustrative) would be:

```sql
create function api.abv_pct(api.beers) returns text
  language sql immutable as $$ select $1.abv::text || '%' $$;
```

```bash
curl "http://localhost:4040/beers?select=name,abv_pct"
```

### Aggregates

`select=count()` returns the row count under the key `"count"`; `select=<col>.<fn>()`
(`count`, `sum`, `avg`, `min`, `max`) aggregates a column, keyed by the
function name unless aliased. Casts and aliases both apply
(`select=cnt:count()::text`). Plain (non-aggregate) fields selected alongside
an aggregate become an implicit `GROUP BY`.

```bash
curl "http://localhost:4040/beers?select=count()"
```

```json
[{"count": 6}]
```

```bash
curl "http://localhost:4040/beers?select=style_id,beer_count:count(),max_ibu:ibu.max()&order=style_id.asc"
```

```json
[
  {"style_id": 1, "beer_count": 1, "max_ibu": 65},
  {"style_id": 2, "beer_count": 1, "max_ibu": 55},
  {"style_id": 3, "beer_count": 1, "max_ibu": 30},
  {"style_id": 4, "beer_count": 1, "max_ibu": 25},
  {"style_id": 5, "beer_count": 2, "max_ibu": 70}
]
```

This is every group, since the query is unfiltered and the brewery schema's 6
beers span all 5 styles (`order=` is added for a deterministic group order —
Postgres's own `GROUP BY` order is otherwise unspecified). `count()` and
`max()` are aliased (`beer_count`, `max_ibu`) and combined in the same
`select` alongside the plain `style_id` field driving the `GROUP BY`.
`avg()`/`sum()` on `beers.abv` work the same way — but casting the result to
a parameterized type such as `::numeric(4,2)` currently 400s (see the note
under [Horizontal filtering](#horizontal-filtering)), so the aggregate
example here sticks to `ibu`, whose plain `int` result needs no cast.

> **Note:** PostgREST gates aggregate functions behind the `db-aggregates-enabled`
> config option (default off, 400 `PGRST123` when disabled). Bier does not
> implement that toggle — aggregate functions in `select` are always available.

Aggregates also apply inside an embedded resource, e.g.
`breweries?select=name,beers(abv.avg())` returns each brewery's average beer
ABV nested under `beers`.

## Horizontal filtering

A horizontal filter is a query parameter of the form `<column>=<operator>.<value>`.
Multiple filters (and filters combined with `select`/`order`/pagination
params) are implicitly ANDed together.

```bash
curl "http://localhost:4040/beers?ibu=gte.60"
```

> **Known limitation:** filtering on, or casting (`::type(...)`) to, a
> PostgreSQL type that carries a modifier — `numeric(p,s)`, `varchar(n)`,
> `char(n)` — currently 400s with `PGRST100`. In the brewery schema this
> affects `beers.abv` (`numeric(4,2)`) and `breweries.latitude`/`longitude`
> (`numeric(9,6)`): e.g. `?abv=gte.6` or `?select=abv::numeric(4,2)` both
> fail. Selecting or ordering by these columns is unaffected — only filters
> and parameterized casts trigger it. Tracked as
> [milmazz/bier#71](https://github.com/milmazz/bier/issues/71); the examples
> below use `ibu`/`style_id` instead.

### Operators

| Operator | Meaning | Example |
|---|---|---|
| `eq` | equals | `id=eq.1` |
| `neq` | not equal | `style_id=neq.5` |
| `gt` | greater than | `ibu=gt.50` |
| `gte` | greater than or equal | `ibu=gte.40` |
| `lt` | less than | `ibu=lt.30` |
| `lte` | less than or equal | `ibu=lte.30` |
| `like` | SQL `LIKE`, `*` is the wildcard (rewritten to `%`) | `name=like.*IPA` |
| `ilike` | case-insensitive `like` | `name=ilike.*ipa*` |
| `match` | POSIX regex, case-sensitive (`~`) | `name=match.^Trail` |
| `imatch` | POSIX regex, case-insensitive (`~*`) | `name=imatch.^trail` |
| `in` | value is one of a parenthesized, comma-separated list | `style_id=in.(1,3,5)` |
| `is` | `null`, `not_null`, `true`, `false`, or `unknown` (case-insensitive); no other value is accepted | `style_id=is.null` |
| `isdistinct` | SQL `IS DISTINCT FROM` (null-safe inequality) | `ibu=isdistinct.65` |
| `fts` | full-text search, `@@ to_tsquery(...)` | `description=fts.hazy` |
| `plfts` | full-text search, `@@ plainto_tsquery(...)` | `description=plfts.roasted stout` |
| `phfts` | full-text search, `@@ phraseto_tsquery(...)` (phrase) | `description=phfts.west coast` |
| `wfts` | full-text search, `@@ websearch_to_tsquery(...)` (web-search syntax) | `description=wfts.hazy -stout` |
| `cs` | contains (`@>`), array/range/jsonb | `arr=cs.{2}` |
| `cd` | contained in (`<@`) | `arr=cd.{1,2,4}` |
| `ov` | overlaps (`&&`) | `arr=ov.{2,3}` |
| `sl` | strictly left of (`<<`), range | `range=sl.[9,10]` |
| `sr` | strictly right of (`>>`), range | `range=sr.[3,4]` |
| `nxr` | does not extend right of (`&<`), range | `range=nxr.[4,7]` |
| `nxl` | does not extend left of (`&>`), range | `range=nxl.[4,7]` |
| `adj` | adjacent to (`-|-`), range | `range=adj.(3,10]` |

`fts`/`plfts`/`phfts`/`wfts` take an optional `(<language>)` modifier, e.g.
`description=fts(english).hazy`. `cs`/`cd`/`ov`/`sl`/`sr`/`nxr`/`nxl`/`adj`
operate on array or range-typed columns; the brewery schema has none today, so
those rows use a generic `arr`/`range` placeholder column.

### Negation

Prefix any operator with `not.` to negate it: `<column>=not.<op>.<value>`.

```bash
curl "http://localhost:4040/beers?ibu=not.gt.50"
```

### Quantifiers: `any()` / `all()`

`eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `like`, `ilike`, `match`, and `imatch`
accept an `(any)` or `(all)` modifier, comparing against a Postgres array
literal. Note that Bier includes `neq` in this set (`Bier.QueryExecutor`
groups it with `eq`/`gt`/`gte`/`lt`/`lte` for quantifier handling) —
PostgREST's own grammar excludes `neq` from `any()`/`all()`:

```bash
curl "http://localhost:4040/beers?style_id=eq(any).{1,3,5}"
curl "http://localhost:4040/beers?name=ilike(any).{*ipa*,*stout*}"
```

### Logical trees: `and` / `or`

`and=(cond,cond,...)` / `or=(cond,cond,...)` combine conditions; each
condition is a `field.op.value` filter or a nested `and(...)`/`or(...)`
group. Groups may be negated with a `not.` prefix on the key or inside the
group, and nest arbitrarily. A value containing `(`, `)`, or `,` must be
double-quoted.

```bash
curl "http://localhost:4040/beers?or=(ibu.gte.65,style_id.eq.2)"
curl "http://localhost:4040/beers?and=(or(style_id.eq.1,style_id.eq.5),ibu.gte.40)"
curl "http://localhost:4040/beers?not.or=(style_id.eq.1,style_id.eq.2)"
curl 'http://localhost:4040/styles?or=(description.eq."Dark, roasted, full-bodied",name.eq."Hazy IPA")'
```

### JSON arrow filters

A filter target may traverse a `json`/`jsonb` column the same way `select`
does: `data->foo->>bar=eq.baz`. Illustrative (no brewery column is `jsonb`):

```bash
curl "http://localhost:4040/beers?metadata->specs->>ibu_target=eq.65"
```

### Filters on embedded resources

A filter key may be prefixed with a dotted embed path to filter the embedded
rows. With the default left join, filtering an embed narrows only the
embedded array — parent rows without a match are kept with an empty array (or
`null`) for that key:

```bash
curl "http://localhost:4040/breweries?select=name,beers(name,abv)&beers.name=like.*IPA*"
```

With `!inner` (see [Resource embedding](#resource-embedding)), the same
filter also drops parent rows whose embedding becomes empty:

```bash
curl "http://localhost:4040/breweries?select=name,beers!inner(name,abv)&beers.name=like.*IPA*"
```

Filtering an embed path that is not present in `select` is a 400 with code
`PGRST108`:

```bash
curl "http://localhost:4040/breweries?select=name&beers.name=like.*IPA*"
```

```json
{"code": "PGRST108", "message": "'beers' is not an embedded resource in this request", "details": null, "hint": "Verify that 'beers' is included in the 'select' query parameter."}
```

## Ordering

`order=<col>[.asc|.desc][.nullsfirst|.nullslast]`, comma-separated for
multiple columns. Direction defaults to ascending; when omitted, no `NULLS
FIRST/LAST` clause is emitted (Postgres's own default applies: `NULLS LAST`
for ascending, `NULLS FIRST` for descending).

```bash
curl "http://localhost:4040/beers?order=abv.desc"
curl "http://localhost:4040/beers?order=name.asc.nullsfirst"
curl "http://localhost:4040/beers?order=brewery_id.asc,abv.desc"
```

Embedded resources are ordered independently with `<embed>.order=`:

```bash
curl "http://localhost:4040/breweries?select=name,beers(name,abv)&beers.order=abv.desc"
```

The top-level resource can also be ordered by a column of a **to-one**
(many-to-one / one-to-one) embedded relation with `order=<relation>(<col>).<dir>`:

```bash
curl "http://localhost:4040/beers?select=id,name,breweries(name)&order=breweries(name).asc"
```

Ordering by a relation that is not to-one (e.g. one-to-many) is a 400 with
code `PGRST118`:

```bash
curl "http://localhost:4040/breweries?select=name,beers(name)&order=beers(name).asc"
```

```json
{"code": "PGRST118", "message": "A related order on 'beers' is not possible", "details": "'breweries' and 'beers' do not form a many-to-one or one-to-one relationship", "hint": null}
```

Ordering by a JSON path works the same way `select` does (illustrative, no
brewery column is `jsonb`): `order=metadata->>brewed_on.asc`.

## Pagination

`limit`/`offset` bound the result window; `<embed>.limit`/`<embed>.offset`
apply the same way to an embedded resource, independent of the top-level
window.

```bash
curl "http://localhost:4040/beers?limit=3&offset=3"
```

The `Range`/`Range-Unit` request headers are an alternative to `limit`/
`offset` and override them when both are present. `Range-Unit` defaults to
`items`. `Range: <from>-<to>` is a closed, inclusive window; `Range: <from>-`
is open-ended (offset only, no limit).

```bash
curl -i "http://localhost:4040/beers" -H "Range-Unit: items" -H "Range: 0-2"
```

`Prefer: count=<mode>` controls whether a total row count is computed:

* `none` (default) — no count; `Content-Range` total is `*`, status is always 200.
* `exact` — an exact `COUNT`, reported in `Content-Range`.
* `planned` — the query planner's row estimate (cheap, may be inaccurate).
* `estimated` — the planner estimate when it exceeds `max-rows`, otherwise the exact count.

```bash
curl -i "http://localhost:4040/beers?limit=3" -H "Prefer: count=exact"
```

```http
HTTP/1.1 206 Partial Content
Content-Range: 0-2/6
```

`Content-Range` is `<lower>-<upper>/<total>`, where `<lower>` is the offset
and `<upper>` is `<lower> + returned_row_count - 1`. An empty window renders
the range part as `*`. Status is:

* **200** when no count was requested, or the returned window covers the whole set.
* **206 Partial Content** when a count is known and the window is strictly smaller than it.
* **416 Range Not Satisfiable** for an invalid range (see below).

A negative `limit`, an offside `Range` (`to < from`), or (with a count
requested) an `offset` past the last row all return **416** with code
`PGRST103`:

```bash
curl -i "http://localhost:4040/beers?limit=-1"
```

```json
{"code": "PGRST103", "message": "Requested range not satisfiable", "details": "Limit should be greater than or equal to zero.", "hint": null}
```

## Resource embedding

An embed nests a related resource's rows inside each parent row, resolved
through the relation's foreign keys.

**Many-to-one** (`beers` → its `breweries` parent) embeds a single JSON
object (or `null` when the FK is null):

```bash
curl "http://localhost:4040/beers?select=id,name,breweries(name,city)&id=eq.1"
```

```json
[{"id": 1, "name": "Trail Crest IPA", "breweries": {"name": "Reunion Brewing", "city": "Portland"}}]
```

**One-to-many** (`breweries` → its `beers` children) embeds a JSON array;
breweries with no beers get `[]`, not `null`:

```bash
curl "http://localhost:4040/breweries?select=name,beers(name,abv)"
```

**Many-to-many** (through a junction table) embeds the far-side rows as a
JSON array, e.g. `GET /<a>?select=*,<junction>(<b>(*))`. The brewery schema
has no many-to-many relationship, so this pattern is illustrative only.

### Alias

`<alias>:<relation>(...)` renames the embed's JSON key:

```bash
curl "http://localhost:4040/beers?select=id,brewery:breweries(name)"
```

### `!inner` / `!left`

`<relation>!inner(...)` turns the default left join into an inner join:
source rows whose embedding is empty/null are dropped. `<relation>!left(...)`
is the explicit form of the default.

```bash
curl "http://localhost:4040/beers?select=id,name,styles!inner(name)&styles.name=eq.Stout"
```

### Disambiguation

An embed can target a specific column directly (no ambiguity resolution
needed) by naming the FK column instead of the relation:

```bash
curl "http://localhost:4040/beers?select=id,name,brewery_id(name,city)"
```

When more than one relationship could match — not the case in the brewery
schema, since each table has at most one FK to any given target — use
`<relation>!<fk>(...)` to pick one by constraint name (assuming Postgres's
default `<table>_<column>_fkey` naming, since `brewery.sql` does not name its
constraints explicitly):

```bash
curl "http://localhost:4040/beers?select=id,name,breweries!beers_brewery_id_fkey(name)"
```

An unrecognized hint is a 400 with code `PGRST200`; when the relationship is
genuinely ambiguous, Bier returns **300 Multiple Choices** with code
`PGRST201`, a `details` array enumerating the candidates, and a `hint`
listing the disambiguated targets to retry with.

### Spread

`...` spreads a to-one embed's columns into the parent object instead of
nesting them under a key:

```bash
curl "http://localhost:4040/beers?select=id,name,...breweries(brewery_name:name)&id=eq.1"
```

```json
[{"id": 1, "name": "Trail Crest IPA", "brewery_name": "Reunion Brewing"}]
```

### Filters and order on embeds

Both are covered above: [Filters on embedded resources](#filters-on-embedded-resources)
and the `<embed>.order=` / `order=<relation>(<col>)` forms in
[Ordering](#ordering).

## Mutations

`POST` inserts, `PATCH` updates, `PUT` replaces-or-inserts a single row by
primary key, `DELETE` removes rows. All four accept `?select=` to shape a
`return=representation` body, and (except `DELETE`) `?columns=` to restrict
which JSON payload keys become target columns (others are ignored; an
unknown listed column is 400 `PGRST204`; a blank `?columns=` is 400
`PGRST100`).

Inserting into `check_ins` requires the `brewery_member` role — `web_anon`
has no `INSERT` grant. The examples below assume an authenticated request;
see [Authentication](../tutorials/authentication.md).

> **Note:** `brewery.sql`'s grants are deliberately narrow: `SELECT` on every
> table (both roles) and `INSERT` on `check_ins` (`brewery_member` only) —
> nothing else. The `PATCH`/`PUT`/`DELETE` examples below, and the `POST
> /styles` upsert, need privileges the seed script doesn't grant. Add them
> first (as the table owner) to run these examples against the tutorial
> database, e.g. `grant insert, update on api.styles to brewery_member;`,
> `grant update on api.beers to brewery_member;`, and
> `grant delete on api.check_ins to brewery_member;`.

### POST (insert)

A single JSON object inserts one row; a JSON array inserts many. An empty
object `{}` inserts a row using all column defaults.

```bash
curl -i -X POST "http://localhost:4040/check_ins" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{"beer_id": 3, "drinker": "jess", "rating": 5, "comment": "crisp!"}'
```

With no `Prefer` header (or `Prefer: return=minimal`), a successful insert
returns **201 Created** with an empty body. `Prefer: return=representation`
returns the same status with the inserted row(s) as the body:

```bash
curl -X POST "http://localhost:4040/check_ins" \
  -H "Content-Type: application/json" -H "Authorization: Bearer <token>" \
  -H "Prefer: return=representation" \
  -d '{"beer_id": 3, "drinker": "jess", "rating": 5, "comment": "crisp!"}'
```

```json
[{"id": 6, "beer_id": 3, "drinker": "jess", "rating": 5, "comment": "crisp!", "created_at": "2026-07-13T10:00:00Z"}]
```

`check_ins.created_at` defaults to `now()`, so the timestamp above is
illustrative — running this yourself returns the actual insert time.

`Prefer: return=headers-only` returns an empty body with a `Location` header
pointing at the created row (by primary key) instead — the `Location` header
is emitted **only** for `return=headers-only`, never for a plain insert or
`return=representation`:

```bash
curl -i -X POST "http://localhost:4040/check_ins" \
  -H "Content-Type: application/json" -H "Authorization: Bearer <token>" \
  -H "Prefer: return=headers-only" \
  -d '{"beer_id": 3, "drinker": "jess", "rating": 5}'
```

```http
HTTP/1.1 201 Created
Location: /check_ins?id=eq.6
```

`Prefer: missing=default` (with `?columns=`) fills a payload row's omitted
column with its table DEFAULT instead of `NULL` — useful for bulk inserts
with heterogeneous rows. `check_ins.created_at` defaults to `now()`:

```bash
curl -X POST "http://localhost:4040/check_ins?columns=beer_id,drinker,rating,created_at" \
  -H "Content-Type: application/json" -H "Authorization: Bearer <token>" \
  -H "Prefer: return=representation,missing=default" \
  -d '[{"beer_id": 2, "drinker": "sam", "rating": 4, "created_at": "2020-01-01T00:00:00Z"}, {"beer_id": 3, "drinker": "jo", "rating": 4}]'
```

The second row's `created_at` (omitted) is filled with `now()` instead of `NULL`.

### Upsert via POST

`Prefer: resolution=merge-duplicates` does an `INSERT ... ON CONFLICT DO
UPDATE` (200 if every row already existed and was only updated, 201 if any
row was newly inserted). `Prefer: resolution=ignore-duplicates` does `INSERT
... ON CONFLICT DO NOTHING` (conflicting rows are skipped; only newly
inserted rows are returned). `?on_conflict=<cols>` targets a `UNIQUE`
constraint other than the primary key — here, `styles.name`:

```bash
curl -X POST "http://localhost:4040/styles?on_conflict=name" \
  -H "Content-Type: application/json" -H "Authorization: Bearer <token>" \
  -H "Prefer: return=representation,resolution=merge-duplicates" \
  -d '{"name": "IPA", "description": "Hop-forward and bitter — updated"}'
```

```http
HTTP/1.1 200 OK
```

A table with no primary key silently ignores the `resolution` preference
when no conflict target is available — unless the request also supplies
`?on_conflict=<cols>` naming a `UNIQUE` constraint to upsert on instead
(`Bier.Mutation.preferences/3` honors `resolution` whenever
`relation.primary_key != []` or an explicit `on_conflict` is given).

### PATCH (update)

`PATCH` updates rows matching the request's filters. With no `Prefer`
header, a successful update returns **204 No Content** (even when zero rows
matched); `Prefer: return=representation` returns **200** with the updated
row(s) as an array.

```bash
curl -i -X PATCH "http://localhost:4040/beers?id=eq.1" \
  -H "Content-Type: application/json" -H "Authorization: Bearer <token>" \
  -d '{"description": "Piney, resinous West Coast IPA"}'
```

```http
HTTP/1.1 204 No Content
Content-Range: 0-0/*
```

### PUT (single-row upsert)

`PUT` inserts or replaces exactly one row, addressed by a filter that is
**exactly** the primary key columns with `eq` operators — nothing else.
`limit`/`offset` are not allowed. The payload's primary key values must match
the URL's.

```bash
curl -i -X PUT "http://localhost:4040/styles?id=eq.6" \
  -H "Content-Type: application/json" -H "Authorization: Bearer <token>" \
  -d '{"id": 6, "name": "Barleywine", "description": "Strong, malty ale"}'
```

`id=6` does not yet exist, so this inserts and returns **201 Created**;
re-running the same request replaces the row and returns **200 OK**.
Violations return:

* `limit`/`offset` present — 400 `PGRST114`.
* Filter is not exactly the PK columns with `eq` — 405 `PGRST105`.
* Payload PK differs from the URL PK — 400 `PGRST115`.
* Table has no primary key — 405 `PGRST105`.

### DELETE

```bash
curl -i -X DELETE "http://localhost:4040/check_ins?id=eq.5" \
  -H "Authorization: Bearer <token>" \
  -H "Prefer: return=representation,count=exact"
```

```http
HTTP/1.1 200 OK
Content-Range: */1
```

```json
[{"id": 5, "beer_id": 2, "drinker": "alex", "rating": 3, "comment": "Fine", "created_at": "2026-07-01T12:00:00Z"}]
```

As above, `created_at` defaults to `now()` at seed time — the exact
timestamp will differ when you load `brewery.sql` yourself.

With no `Prefer` header, `DELETE` returns **204 No Content**
(`Content-Range: */*`).

### Guarding a mutation's blast radius

`Prefer: handling=strict, max-affected=<n>` caps how many rows a mutation may
affect; exceeding it rolls back the transaction and returns 400 `PGRST124`.
`handling=lenient` (or omitting `handling`) ignores the cap.

```bash
curl -X PATCH "http://localhost:4040/beers?brewery_id=eq.1" \
  -H "Content-Type: application/json" -H "Authorization: Bearer <token>" \
  -H "Prefer: handling=strict,max-affected=1" \
  -d '{"description": "updated"}'
```

```json
{"code": "PGRST124", "message": "Query result exceeds max-affected preference constraint", "details": "The query affects 2 rows", "hint": null}
```

## RPC

`/rpc/<function>` calls a database function in the exposed schema.
`GET`/`HEAD` bind arguments from the query string and always run read-only
(a `VOLATILE` function called this way raises Postgres `25006`, mapped to
405); `POST` binds arguments from a JSON request body.

```bash
curl "http://localhost:4040/rpc/search_beers?term=IPA"
```

```json
[
  {"id": 1, "brewery_id": 1, "style_id": 1, "name": "Trail Crest IPA", "abv": 6.80, "ibu": 65, "description": "Piney West Coast IPA"},
  {"id": 5, "brewery_id": 3, "style_id": 5, "name": "DIPA v12", "abv": 8.50, "ibu": 70, "description": "Big hazy double IPA"}
]
```

```bash
curl -X POST "http://localhost:4040/rpc/search_beers" \
  -H "Content-Type: application/json" -d '{"term": "stout"}'
```

Arguments with a `DEFAULT` may be omitted — `top_rated_beers(min_rating int
default 4)`:

```bash
curl "http://localhost:4040/rpc/top_rated_beers"
```

```json
[
  {"beer_id": 4, "name": "Export Stout", "avg_rating": 5.00, "check_in_count": 1},
  {"beer_id": 1, "name": "Trail Crest IPA", "avg_rating": 4.50, "check_in_count": 2},
  {"beer_id": 5, "name": "DIPA v12", "avg_rating": 4.00, "check_in_count": 1}
]
```

A `VARIADIC` parameter (none of the brewery functions have one) is supplied
via a JSON array under its name on `POST`, or repeated query params on `GET`;
illustrative: `POST /rpc/tag_beers {"tags": ["hoppy", "juicy"]}` /
`GET /rpc/tag_beers?tags=hoppy&tags=juicy`.

### Return shapes

* A `SETOF <table/view>` function (`search_beers`) or a `TABLE(...)`-returning
  function (`top_rated_beers`) responds with a JSON array of row objects, `[]`
  when empty.
* A scalar-returning function responds with the bare JSON value (not wrapped
  in an array) — e.g. a function returning `int` responds `7`, not `[7]`.
* A function returning a composite type responds with a single JSON object.
* A function returning `void` responds **204 No Content** with no body.

### Shaping the result

`select`, filters, `order`, `limit`/`offset`, and `Prefer: count=` apply
through the full read pipeline — exactly as they do on a table — only for a
function that returns `SETOF <exposed relation>`, like `search_beers`
(`SETOF api.beers`):

```bash
curl "http://localhost:4040/rpc/search_beers?term=IPA&select=id,name&order=id.asc&limit=1"
```

```json
[{"id": 1, "name": "Trail Crest IPA"}]
```

A function returning an anonymous `TABLE(...)` (or with `OUT` parameters),
like `top_rated_beers`, is not backed by an exposed relation — its full
result set is always returned as-is: `select=`, filters, `order`, and
`limit`/`offset` do **not** shape it. `Prefer: count=` still reports the
returned row count in `Content-Range`:

```bash
curl -i "http://localhost:4040/rpc/top_rated_beers" -H "Prefer: count=exact"
```

```http
HTTP/1.1 200 OK
Content-Range: 0-2/3
```

`Accept: text/csv` renders the same result as CSV:

```bash
curl "http://localhost:4040/rpc/top_rated_beers" -H "Accept: text/csv"
```

```
beer_id,name,avg_rating,check_in_count
4,Export Stout,5.00,1
1,Trail Crest IPA,4.50,2
5,DIPA v12,4.00,1
```

An unknown function name or an argument set that matches no overload is a
404 with code `PGRST202`; any method other than `GET`/`HEAD`/`POST` on
`/rpc/<fn>` is a 405 with code `PGRST101`.

## Content negotiation

The `Accept` header picks the response media type; client order wins (the
first acceptable type in the header is used, even if it's not the server's
own preference). No acceptable type is a 406 with code `PGRST107`.

| Media type | Behavior |
|---|---|
| `application/json` (default) | A JSON array of row objects (or a bare value for scalars). |
| `text/csv` | A header row plus data rows, `Content-Type: text/csv; charset=utf-8`. |
| `application/geo+json` | Rows aggregated into a GeoJSON `FeatureCollection`. Offered as a producer only when the `postgis` extension is installed database-wide (`Bier.SchemaCache.postgis?/1`, checked in `Bier.Plugs.ActionController.read_producers/1`) — `brewery.sql` never runs `CREATE EXTENSION postgis;`, so against the tutorial database as shipped, `Accept: application/geo+json` on any relation (including `breweries`) fails 406 with code `PGRST107` (no acceptable media type), the same as any other unsupported `Accept`. If `postgis` *is* installed, the producer becomes available for every relation, but rendering still needs an actual `geometry`/`geography` column — `breweries`' plain `numeric` `latitude`/`longitude` columns don't qualify, so requesting it there would then fail 400 with SQLSTATE `22023` ("geometry column is missing"). |
| `application/vnd.pgrst.object+json` | Coerces the result to a single JSON object instead of a one-element array. Fails 406 `PGRST116` ("Cannot coerce the result to a single JSON object") when the result is not exactly one row. The `+json` suffix is optional. |
| `application/vnd.pgrst.object+json;nulls=stripped` | As above, with every null-valued key omitted from the object. |
| `application/vnd.pgrst.array+json;nulls=stripped` | A JSON array with null-valued keys omitted from each row. |
| `application/vnd.pgrst.plan`, `+json`, or `+text` | The query's `EXPLAIN` plan instead of executing it. Gated by the `db_plan_enabled` config option (default `false`); when disabled, negotiation fails the same as an unsupported type (406 `PGRST107`). |

```bash
curl "http://localhost:4040/breweries?id=eq.1" \
  -H "Accept: application/vnd.pgrst.object+json"
```

```json
{"id": 1, "name": "Reunion Brewing", "city": "Portland", "country": "USA", "founded_year": 2016, "latitude": 45.512230, "longitude": -122.658722}
```

```bash
curl "http://localhost:4040/beers" -H "Accept: text/unknowntype"
```

```json
{"code": "PGRST107", "message": "None of these media types are available: text/unknowntype", "details": null, "hint": null}
```

## Errors

Every error response is a JSON object with exactly four keys — `code`,
`message`, `details`, `hint` — `details`/`hint` are JSON `null`, not omitted,
when there is nothing to report. Every Bier-originated error also carries a
`Proxy-Status: PostgREST; error=<code>` response header.

```json
{"code": "PGRST205", "message": "Could not find the table 'api.nonexistent' in the schema cache", "details": null, "hint": null}
```

### Common codes

| Code | HTTP | Meaning |
|---|---|---|
| `PGRST100` | 400 | Malformed `select`/`order`/filter/logic-tree query parameter. |
| `PGRST101` | 405 | Unsupported HTTP method on `/rpc/<fn>`. |
| `PGRST102` | 400 | Empty/invalid JSON body, non-uniform bulk-insert keys, or ragged CSV. |
| `PGRST103` | 416 | Requested range not satisfiable (negative `limit`, offside `Range`, out-of-bounds `offset`). |
| `PGRST105` | 405 | `PUT` filter is not exactly the primary key columns with `eq`, or the table has no primary key. |
| `PGRST106` | 406 | Invalid `Accept-Profile`/`Content-Profile` schema. |
| `PGRST107` | 406 | No acceptable media type for the `Accept` header. |
| `PGRST108` | 400 | A filter/order references an embed path not present in `select`. |
| `PGRST114` | 400 | `limit`/`offset` supplied on `PUT`. |
| `PGRST115` | 400 | `PUT` payload primary key does not match the URL's. |
| `PGRST116` | 406 | Singular request (`vnd.pgrst.object+json`) resolved to other than exactly one row. |
| `PGRST117` | 405 | Unsupported HTTP method on a relation. |
| `PGRST118` | 400 | A related `order=` targets a relation that is not many-to-one/one-to-one. |
| `PGRST122` | 400 | `Prefer: handling=strict` rejected an unrecognized/invalid preference. |
| `PGRST124` | 400 | A mutation exceeded `Prefer: max-affected=<n>`. |
| `PGRST125` | 404 | Invalid path in the request URL. |
| `PGRST200` | 400 | No relationship found for an embed (unknown/wrong hint). |
| `PGRST201` | 300 | Ambiguous embed — more than one relationship matched. |
| `PGRST202` | 404 | Unknown RPC function or no overload matches the supplied arguments. |
| `PGRST204` | 400 | `?columns=`/payload references a column absent from the relation. |
| `PGRST205` | 404 | Unknown table/view. |
| `PGRST300` | 500 | No `jwt_secret` is configured but a JWT was presented — a server misconfiguration, not a bad token. |
| `PGRST301`–`PGRST303` | 401 | JWT verification failures (missing/malformed/expired token, audience mismatch) — see [Authentication](../tutorials/authentication.md). Note: the no-`jwt_secret`-configured case is also reported as `PGRST301` on some code paths, and like `PGRST300` above, as a **500** rather than 401 (`Bier.Plugs.FallbackController`). |

Postgres errors raised from within a query or function pass through with
their raw 5-character `SQLSTATE` as `code`. A few notable mappings: unique
violations (`23505`) and foreign-key violations (`23503`) both return 409;
`insufficient_privilege` (`42501`) returns 401 for the anonymous role or 403
for an authenticated one; calling a `VOLATILE` function via `GET`/`HEAD`
(`25006`, read-only transaction) returns 405.
