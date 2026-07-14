# Getting Started

This tutorial builds a small, read-only REST API over a brewery catalog —
styles, breweries, beers, taprooms, and check-ins — using nothing but a
PostgreSQL schema. You will create the database, boot a `Bier` instance
against it two different ways, and make your first requests: listing,
filtering, selecting/renaming columns, ordering, paginating, embedding a
related resource, and calling a database function over HTTP.

## Prerequisites

* PostgreSQL running and reachable (`createdb`/`psql` on your `PATH`).
* Elixir `~> 1.18` (this repository is developed against Elixir 1.20 / OTP
  29 — see `mise.toml` — but any 1.18+ toolchain works for this tutorial).

## Create the database

Bier never creates schema — it only introspects and serves whatever is
already in PostgreSQL. `docs/tutorials/brewery.sql` is a complete,
runnable script: three roles, an `api` schema with five tables and two
functions, grants, and seed data.

```sh
createdb bier_tutorial
psql -d bier_tutorial -f docs/tutorials/brewery.sql
```

Roles are cluster-global, so if you have run this before and the roles
already exist, either ignore the "already exists" notice or drop them
first and re-run:

```sh
dropdb bier_tutorial
psql -d postgres -c "drop role if exists authenticator, web_anon, brewery_member"
```

The script creates three roles, mirroring PostgREST's own convention:

* **`authenticator`** — the only role Bier ever connects to Postgres as.
  It has `noinherit login`, so it can hold no privileges of its own; it
  only switches into one of the roles below for the duration of a
  request.
* **`web_anon`** — what an unauthenticated request runs as. It can
  `select` from every table in `api` and `execute` both functions, but it
  cannot write.
* **`brewery_member`** — an authenticated role that can additionally
  `insert` into `api.check_ins`. Using it requires a JWT, which is the
  subject of the [Authentication](authentication.md) tutorial — this one
  stays anonymous throughout.

## Run Bier

Bier can run two ways: as a **standalone server** configured entirely from
`PGRST_*` environment variables (no Elixir code of your own), or **embedded**
as a supervised child of an Elixir application. Both connect to Postgres as
`authenticator`, exactly like a real deployment — never as a superuser.

### Quick path (Docker or a release)

The repository ships a `Dockerfile` that builds a release with
`BIER_STANDALONE=1` baked in, listening on port `3000` by default:

```sh
docker build -t bier .

docker run --rm -p 3000:3000 \
  -e PGRST_DB_URI="postgresql://authenticator:mysecretpassword@host.docker.internal:5432/bier_tutorial" \
  -e PGRST_DB_SCHEMAS="api" \
  -e PGRST_DB_ANON_ROLE="web_anon" \
  bier
```

(`host.docker.internal` reaches a Postgres running on your host machine from
inside the container; point it at a linked `db` service instead if your
Postgres is also containerized.)

Without Docker, build and run the same release directly:

```sh
MIX_ENV=prod mix release

BIER_STANDALONE=1 \
PGRST_DB_URI="postgresql://authenticator:mysecretpassword@localhost:5432/bier_tutorial" \
PGRST_DB_SCHEMAS="api" \
PGRST_DB_ANON_ROLE="web_anon" \
_build/prod/rel/bier/bin/bier start
```

Either way, `PGRST_DB_URI` carries the connection (including the
`authenticator` credentials), `PGRST_DB_SCHEMAS` picks the schema to expose,
and `PGRST_DB_ANON_ROLE` is the role unauthenticated requests run as. See the
[Configuration guide](../guides/configuration.md#standalone-boot) for every
`PGRST_*` variable and the full standalone-boot story.

### Elixir path

Embedding Bier means adding a `{Bier, ...}` child to a supervision tree, the
same shape whether that is your own application or a throwaway `iex`
session. The options below are the direct Elixir equivalent of the
environment variables above:

```elixir
children = [
  {Bier,
   name: MyApp.Bier,
   router: [port: 4040, scheme: :http],
   database: "bier_tutorial",
   username: "authenticator",
   password: "mysecretpassword",
   db_schemas: ["api"],
   db_anon_role: "web_anon"}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

To try it without writing a project, start it from an `iex` session against
this repository (`mix deps.get` first if you have not already):

```sh
iex -S mix run -e 'Bier.start_link(
  name: Tutorial,
  router: [port: 4040, scheme: :http],
  database: "bier_tutorial",
  username: "authenticator",
  password: "mysecretpassword",
  db_schemas: ["api"],
  db_anon_role: "web_anon"
)'
```

Either form prints a Bandit boot line once the schema has been introspected
and the listener is up — that is your readiness signal:

```
Running Tutorial.Router with Bandit 1.12.0 at 0.0.0.0:4040 (http)
```

The rest of this tutorial assumes Bier is reachable at
`http://localhost:4040`.

## Your first requests

### List beers

With no filter, `select` still limits the response to the columns you name:

```bash
curl "http://localhost:4040/beers?select=name,abv"
```

```json
[
  {"name": "Trail Crest IPA", "abv": 6.80},
  {"name": "Fog Line", "abv": 6.20},
  {"name": "Table Pils", "abv": 4.80},
  {"name": "Export Stout", "abv": 7.50},
  {"name": "DIPA v12", "abv": 8.50},
  {"name": "Desert Saison", "abv": 5.90}
]
```

### Order and limit: the three strongest beers

`order=<col>.desc` sorts descending; `limit` caps the row count:

```bash
curl "http://localhost:4040/beers?select=name,abv&order=abv.desc&limit=3"
```

```json
[
  {"name": "DIPA v12", "abv": 8.50},
  {"name": "Export Stout", "abv": 7.50},
  {"name": "Trail Crest IPA", "abv": 6.80}
]
```

### Filter: only the bitter ones

A horizontal filter is `<column>=<operator>.<value>`. `gte` is greater-than-
or-equal; the full operator table is in the
[API reference](../guides/api-reference.md#horizontal-filtering).

> `abv` (`numeric(4,2)`) can't be filtered yet — Bier 400s when filtering on
> (or casting to) a parameterized type like `numeric(p,s)`, a known
> limitation tracked in
> [milmazz/bier#71](https://github.com/milmazz/bier/issues/71). This example
> filters on `ibu` (a plain `int`) instead.

```bash
curl "http://localhost:4040/beers?ibu=gte.40&select=name,ibu"
```

```json
[
  {"name": "Trail Crest IPA", "ibu": 65},
  {"name": "Fog Line", "ibu": 40},
  {"name": "Export Stout", "ibu": 55},
  {"name": "DIPA v12", "ibu": 70}
]
```

### Select and rename columns

`select=<alias>:<col>` renames a column's JSON key without changing what is
queried:

```bash
curl "http://localhost:4040/beers?select=beer:name,abv&limit=2"
```

```json
[
  {"beer": "Trail Crest IPA", "abv": 6.80},
  {"beer": "Fog Line", "abv": 6.20}
]
```

### Embed the brewery

A foreign key lets you pull in the related row as nested JSON, with no join
to write yourself — `beers.brewery_id` references `breweries.id`, so naming
`breweries(...)` inside `select` embeds it:

```bash
curl "http://localhost:4040/beers?select=name,breweries(name,city)&limit=2"
```

```json
[
  {"name": "Trail Crest IPA", "breweries": {"city": "Portland", "name": "Reunion Brewing"}},
  {"name": "Fog Line", "breweries": {"city": "Portland", "name": "Reunion Brewing"}}
]
```

### Paginate: `limit`/`offset`

```bash
curl "http://localhost:4040/beers?limit=3&offset=3&select=name"
```

```json
[
  {"name": "Export Stout"},
  {"name": "DIPA v12"},
  {"name": "Desert Saison"}
]
```

### Paginate: `Range` and an exact count

The `Range`/`Range-Unit` headers are an alternative to `limit`/`offset`, and
`Prefer: count=exact` asks Bier to compute the total row count and report it
in `Content-Range`:

```bash
curl -i "http://localhost:4040/beers?select=name" \
  -H "Range-Unit: items" -H "Range: 0-2" -H "Prefer: count=exact"
```

```http
HTTP/1.1 206 Partial Content
Content-Range: 0-2/6
```

```json
[
  {"name": "Trail Crest IPA"},
  {"name": "Fog Line"},
  {"name": "Table Pils"}
]
```

`0-2/6` reads as "rows 0 through 2 of 6 total" — the response is a **206
Partial Content** because the requested window is strictly smaller than the
full set.

### Call a function: `GET /rpc/search_beers`

Every function in an exposed schema is callable at `/rpc/<function>`;
scalar arguments become query parameters. `api.search_beers(term text)`
does an `ilike` search over name and description:

```bash
curl "http://localhost:4040/rpc/search_beers?term=IPA&select=name"
```

```json
[
  {"name": "Trail Crest IPA"},
  {"name": "DIPA v12"}
]
```

## Recap and next steps

You loaded a real PostgreSQL schema, ran Bier against it two different ways
— standalone via `PGRST_*` environment variables, and embedded via a
`{Bier, ...}` child spec — and drove it with plain HTTP: no controllers,
routes, or serializers were written for any of this.

From here:

* [API reference](../guides/api-reference.md) covers the full query
  grammar — every filter operator, aggregates, JSON paths, computed
  columns, mutations, and content negotiation — using this same brewery
  schema.
* [Authentication](authentication.md) picks up where this tutorial left
  off: minting a JWT for `brewery_member` so a client can post check-ins,
  which `web_anon` cannot do.
