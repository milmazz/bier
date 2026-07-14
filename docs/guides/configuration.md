# Configuration

Every setting a `Bier` instance understands — database connection, exposed
schemas, JWT verification, OpenAPI, admin endpoints, and so on — is declared
once, in `Bier.schema/0` (a [NimbleOptions][] schema). That schema is the
single source of truth; everything else described on this page is a
different way of feeding values into it.

This page covers: the three ways to set an option, the full option table,
`PGRST_DB_URI` parsing, standalone/CLI boot, the cross-field validators that
can reject a configuration at boot, and schema-cache reload. Examples use the
brewery setup from the tutorials (`db_schemas: ["api"]`,
`db_anon_role: "web_anon"`).

[NimbleOptions]: https://hexdocs.pm/nimble_options

## The three configuration surfaces

### 1. Keyword options to `Bier.start_link/1`

The primary surface when embedding Bier as a supervised child. Options are
validated by `Bier.Config.new!/2` against `Bier.schema/0`; an invalid value
raises `ArgumentError` at boot.

```elixir
children = [
  {Bier,
   name: MyApp.Bier,
   router: [port: 4040, scheme: :http],
   database: "brewery_dev",
   username: "postgres",
   password: "postgres",
   db_schemas: ["api"],
   db_anon_role: "web_anon"}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

### 2. Application environment

Every key's default in `Bier.schema/0` is sourced from `Application.get_env/3`
under the `:bier` app (via a small `env/2` helper), so anything you would
otherwise pass to `start_link/1` can instead live in `config/*.exs`:

```elixir
# config/config.exs
config :bier,
  hostname: "localhost",
  database: "brewery_dev",
  db_schemas: ["api"],
  db_anon_role: "web_anon"
```

`start_link/1` opts always take precedence over the application-env default
for the same key — the env value only fills in keys you did not pass
explicitly. This surface has no notion of `:name` or `:router`, since those
are inherently per-instance.

### 3. `PGRST_*` environment variables (standalone/CLI only)

This surface exists **only** on the standalone code path: the `bier` escript
and the release's `BIER_STANDALONE=1` boot (see
[Standalone boot](#standalone-boot) below). A host application embedding
`Bier.start_link/1` directly never reads `PGRST_*` — that translation layer
lives entirely in `Bier.CLI.Config`.

`Bier.CLI.Config.load/3` resolves each key from, in order:

1. **flags** — a `%{kebab-key => raw}` override map accepted by the
   `Config.load/3` API itself;
2. **env** — the key's `PGRST_*` variable (or a deprecated alias's own
   `PGRST_*` variable);
3. **file** — the same key (or alias) read from an optional config file;
4. **default** — the key's built-in default.

> #### The shipped `bier` binary never populates `flags` {: .info}
> `flags > env > file > default` is the precedence built into
> `Bier.CLI.Config.load/3`, and `--dump-config`/boot both use it. In
> practice, though, every call site in `Bier.CLI` and `Bier.Application`
> passes an **empty** flags map — the escript has no per-key command-line
> flags today (only `--dump-config`, `-e`/`--example`, `-v`, `-h`, and the
> positional config-file path). So the effective precedence right now is
> **env > file > default**; `flags` is there for programmatic callers of
> `Config.load/3`.

Each spelling (canonical key, then any deprecated alias) is checked as a
*complete* source — its own env var, then its own file key — before moving to
the next spelling. So a canonical file key still beats a deprecated alias's
env var, matching PostgREST's `optWithAlias` behavior.

## Option reference

Types: `atom`, `string`, `string | nil`, `boolean`, `pos_integer` (integer
≥ 1), `[string]` (list of strings), `%{string => string}` / `%{string =>
pos_integer}` (string-keyed maps). A `—` in the `PGRST_*` column means the
option has no PostgREST equivalent and is Bier/library-only (it cannot be
set from the standalone/CLI surface at all).

### Instance & web endpoint

| Option | Type | Default | `PGRST_*` var |
| --- | --- | --- | --- |
| `name` | `atom` | `Bier` | — (library-only; also the registry key and `<name>.Router` module name) |
| `router[:port]` | `pos_integer` | `4040` | `PGRST_SERVER_PORT` (default `3000` for the standalone binary) |
| `router[:scheme]` | `:http \| :https` | `:http` | — (the CLI translation always emits `scheme: :http`; `:https` is only reachable via `start_link/1` opts or app env) |
| `admin_server_port` | `pos_integer \| nil` | `nil` | `PGRST_ADMIN_SERVER_PORT` |
| `server_host` | `string` | `"!4"` | `PGRST_SERVER_HOST` |
| `server_unix_socket` | `string \| nil` | `nil` | `PGRST_SERVER_UNIX_SOCKET` |
| `server_unix_socket_mode` | `string` | `"660"` | `PGRST_SERVER_UNIX_SOCKET_MODE` |

`admin_server_port`, when set, starts a second Bandit listener serving `/live`
and `/ready` (see the [Observability guide](observability.md)); it must
differ from `router[:port]` (see [Validators](#validators)).

### Postgres connection & pool

| Option | Type | Default | `PGRST_*` var |
| --- | --- | --- | --- |
| `hostname` | `string` | `"localhost"` | via `PGRST_DB_URI` (host component) |
| `port` | `pos_integer` | `5432` | via `PGRST_DB_URI` (port component) |
| `database` | `string` | `"bier"` | via `PGRST_DB_URI` (path component) |
| `username` | `string \| nil` | `nil` | via `PGRST_DB_URI` (userinfo) |
| `password` | `string \| nil` | `nil` | via `PGRST_DB_URI` (userinfo) |
| `ssl` | `boolean` | `false` | via `PGRST_DB_URI` (`sslmode=require\|verify-ca\|verify-full` → `true`) |
| `pool_size` | `pos_integer` | `10` | `PGRST_DB_POOL` |
| `db_pool_max_idletime` | `pos_integer \| nil` | `nil` | `PGRST_DB_POOL_MAX_IDLETIME` (alias `db-pool-timeout` / `PGRST_DB_POOL_TIMEOUT`) |

There is no `PGRST_DB_HOST`-style variable — the whole connection is set from
one `PGRST_DB_URI`, exactly as in PostgREST (see the `PGRST_DB_URI` section
below). `db_pool_max_idletime` maps onto DBConnection's `:idle_interval`;
`nil` (the default) defers to the driver default.

### Schema & relation exposure

| Option | Type | Default | `PGRST_*` var |
| --- | --- | --- | --- |
| `db_schemas` | `[string]` | `["public"]` | `PGRST_DB_SCHEMAS` (alias `db-schema` / `PGRST_DB_SCHEMA`) |
| `db_anon_role` | `string \| nil` | `nil` | `PGRST_DB_ANON_ROLE` |
| `db_extra_search_path` | `[string]` | `["public"]` | `PGRST_DB_EXTRA_SEARCH_PATH` |
| `db_max_rows` | `pos_integer \| nil` | `nil` | `PGRST_DB_MAX_ROWS` (alias `max-rows` / `PGRST_MAX_ROWS`) |
| `db_plan_enabled` | `boolean` | `false` | `PGRST_DB_PLAN_ENABLED` |
| `db_tx_end` | `:commit \| :rollback` | `:commit` | `PGRST_DB_TX_END` |
| `db_pre_request` | `string \| nil` | `nil` | `PGRST_DB_PRE_REQUEST` (alias `pre-request` / `PGRST_PRE_REQUEST`) |
| `db_profile_default` | `string \| nil` | `nil` | — (library-only) |
| `db_profile_schemas` | `[string] \| nil` | `nil` | — (library-only) |
| `db_schema_aliases` | `%{string => string}` | `%{}` | — (library-only) |
| `db_max_rows_by_schema` | `%{string => pos_integer}` | `%{}` | — (library-only) |
| `db_safe_update_tables` | `[string]` | `[]` | — (library-only) |

`db_schemas` is ordered; the first entry is the default schema for requests
without an `Accept-Profile`/`Content-Profile` header. `db_tx_end` accepts
PostgREST's `PGRST_DB_TX_END` values `commit`, `commit-allow-override`,
`rollback`, and `rollback-allow-override` on the standalone surface — the
`-allow-override` variants collapse onto their base mode (`:commit` /
`:rollback`) since Bier does not yet support the per-request `Prefer`
override. `db_profile_default`, `db_profile_schemas`, `db_schema_aliases`,
`db_max_rows_by_schema`, and `db_safe_update_tables` are Bier-internal knobs
used by the conformance harness (multi-schema profile routing, per-area row
caps, safe-update emulation) — they have no `PGRST_*` counterpart and cannot
be set from the standalone binary.

> Note: there is no `db_auth_schemas` option. Authentication (JWT
> verification / role resolution) applies uniformly to every schema listed in
> `db_schemas` when `jwt_secret` is configured — schemas are not individually
> opted in or out of auth.

### Schema-cache reload options

| Option | Type | Default | `PGRST_*` var |
| --- | --- | --- | --- |
| `db_channel` | `string` | `"pgrst"` | `PGRST_DB_CHANNEL` |
| `db_channel_enabled` | `boolean` | `true` | `PGRST_DB_CHANNEL_ENABLED` |

See [Schema-cache reload](#schema-cache-reload) below.

### JWT / authentication

| Option | Type | Default | `PGRST_*` var |
| --- | --- | --- | --- |
| `jwt_secret` | `string \| nil` | `nil` | `PGRST_JWT_SECRET` |
| `jwt_aud` | `string \| nil` | `nil` | `PGRST_JWT_AUD` |
| `jwt_secret_is_base64` | `boolean` | `false` | `PGRST_JWT_SECRET_IS_BASE64` (alias `secret-is-base64` / `PGRST_SECRET_IS_BASE64`) |
| `jwt_role_claim_key` | `string` | `".role"` | `PGRST_JWT_ROLE_CLAIM_KEY` (alias `role-claim-key` / `PGRST_ROLE_CLAIM_KEY`) |

Bier verifies **HS256** tokens only (symmetric secret); asymmetric
(RS256/ES256/JWKS) verification is a tracked gap, not yet implemented.
`jwt_role_claim_key` is a JSPath into the decoded claims, e.g. `.role`
(default) or `."https://example.com/roles"[0]`. See
[Validators](#validators) for the constraints on all four.

### CORS, tracing & logging

| Option | Type | Default | `PGRST_*` var |
| --- | --- | --- | --- |
| `server_cors_allowed_origins` | `string \| nil` | `nil` | `PGRST_SERVER_CORS_ALLOWED_ORIGINS` |
| `server_timing_enabled` | `boolean` | `false` | `PGRST_SERVER_TIMING_ENABLED` |
| `server_trace_header` | `string \| nil` | `nil` | `PGRST_SERVER_TRACE_HEADER` |
| `log_level` | `:crit \| :error \| :warn \| :info \| :debug` | `:error` | `PGRST_LOG_LEVEL` |

`server_cors_allowed_origins` is a comma-separated allow-list. See the
[Observability guide](observability.md) for what `server_timing_enabled` and
`server_trace_header` actually add to a response.

### OpenAPI

| Option | Type | Default | `PGRST_*` var |
| --- | --- | --- | --- |
| `openapi_mode` | `"follow-privileges" \| "ignore-privileges" \| "disabled"` | `"follow-privileges"` | `PGRST_OPENAPI_MODE` |
| `db_root_spec` | `string \| nil` | `nil` | `PGRST_DB_ROOT_SPEC` (alias `root-spec` / `PGRST_ROOT_SPEC`) |
| `openapi_server_proxy_uri` | `string \| nil` | `nil` | `PGRST_OPENAPI_SERVER_PROXY_URI` |
| `openapi_security_active` | `boolean` | `false` | `PGRST_OPENAPI_SECURITY_ACTIVE` |

`openapi_mode: "disabled"` makes the root endpoint return `404 PGRST126`
instead of a generated document. `db_root_spec` names a DB function whose
result replaces the generated document entirely.

### App settings (custom GUCs)

| Option | Type | Default | `PGRST_*` var |
| --- | --- | --- | --- |
| `app_settings` | `%{string => string}` | `%{}` | `PGRST_APP_SETTINGS_<NAME>` (one variable per setting) |

Each entry becomes `app.settings.<name>`, a transaction-local GUC set on
every request that runs with the auth context; SQL reads it via
`current_setting('app.settings.<name>')`. On the standalone surface, an
env var `PGRST_APP_SETTINGS_ANTHEM='...'` sets `app.settings.anthem`, and a
config-file line `app.settings.anthem = "..."` sets the same key — the env
var wins on a name collision. Via `start_link/1` opts or app env, pass a
plain map:

```elixir
config :bier, app_settings: %{"anthem" => "Rocky Top"}
```

## `PGRST_DB_URI`

`PGRST_DB_URI` is the only way to set the database connection from the
standalone/CLI surface — there is no per-field `PGRST_DB_HOST` etc. Bier
accepts both libpq forms PostgREST does:

* a **URI**: `postgresql://user:pass@host:5432/dbname?sslmode=require`
  (`postgres://` is also accepted);
* a **keyword/value conninfo string**: `host=... port=... dbname=... user=... password=... sslmode=...`
  (whitespace-separated `key=value` pairs; single-quoted values have their
  quotes stripped — libpq's full quoting/escaping is not modeled).

The default, `postgresql://` (an empty URI), carries no fields, so Bier's own
`hostname`/`port`/`database`/etc. defaults apply unchanged. Of the URI's
query parameters, only `sslmode` maps onto anything Bier exposes:
`require`, `verify-ca`, and `verify-full` all set `ssl: true` (Bier does not
separately model libpq's certificate-verification depth); `disable`,
`allow`, and `prefer` leave `ssl` at its default (`false`) — Postgrex offers
no non-retrying "opportunistic TLS" mode to express `allow`/`prefer`
precisely. A password embedded in the URI (`p%40ss`) is percent-decoded
before use, since `@`/`:` inside a raw password would otherwise be read as
URI delimiters.

```sh
PGRST_DB_URI="postgresql://authenticator:secret@localhost:5432/brewery_dev?sslmode=require"
```

## Standalone boot

Bier is primarily a library embedded via `Bier.start_link/1`, but it can also
run as a **standalone server** — no host application, configured entirely
from `PGRST_*` — for parity testing against a real PostgREST deployment or
for simple drop-in use.

### `BIER_STANDALONE`

`Bier.Application.start/2` (the OTP `mod:` callback) always starts
`Bier.Registry`. It additionally boots one `Bier` instance from the process
environment when `BIER_STANDALONE` is `"1"` or `"true"`:

```sh
BIER_STANDALONE=1 \
PGRST_DB_URI="postgresql://authenticator:secret@localhost:5432/brewery_dev" \
PGRST_DB_SCHEMAS="api" \
PGRST_DB_ANON_ROLE="web_anon" \
_build/prod/rel/bier/bin/bier start
```

Without `BIER_STANDALONE` (the default), `Bier.Application` starts only the
registry, so embedding Bier in a host app via `start_link/1` is unaffected.
A fatal config problem (e.g. a JWT secret shorter than 32 bytes) is printed
to stderr and the VM halts — the standalone boot path runs every value
through `Bier.CLI.Config.validated_start_opts/1`, which is `Bier.Config`'s
full boot-time schema, not the looser rules `--dump-config` tolerates.

### Release

```sh
MIX_ENV=prod mix release
```

builds a self-contained release named `bier` (`_build/prod/rel/bier`,
`releases.bier` in `mix.exs`, `include_executables_for: [:unix]`). Its
`bin/bier start` boots the OTP application; combined with
`BIER_STANDALONE=1` this is the invocation shown above.

### Docker

The repository's `Dockerfile` is a multi-stage build (compile stage on
`hexpm/elixir`, runtime stage on `debian:bookworm-slim`) that produces the
same release and bakes in `ENV BIER_STANDALONE=1` and
`ENV PGRST_SERVER_PORT=3000`, with `ENTRYPOINT ["/app/bin/bier"]` /
`CMD ["start"]`:

```sh
docker build -t bier .

docker run --rm -p 3000:3000 \
  -e PGRST_DB_URI="postgresql://authenticator:secret@db:5432/brewery_dev" \
  -e PGRST_DB_SCHEMAS="api" \
  -e PGRST_DB_ANON_ROLE="web_anon" \
  bier
```

### The `bier` CLI (escript)

`mix escript.build` (via `escript: [main_module: Bier.CLI]` in `mix.exs`)
produces a `./bier` executable — the same `Bier.CLI` core the release's
`bin/bier` and the conformance suite's `kind: cli` cases drive. Its argv
grammar: an optional positional `CONFIG_FILE` path (any argument not
starting with `-`) plus these flags:

| Flag | Effect |
| --- | --- |
| `--dump-config` | Resolve config (flags/env/file/default) and print it as `key = value` lines, sorted, without starting a server |
| `-e`, `--example` | Print an example config file — every implemented key at its default, loadable as-is |
| `-v`, `--version` | Print `bier <version>` |
| `-h`, `--help` | Print usage |
| (none) | Boot: validate and start one `Bier` instance, then block |

`--version`/`--help`/`--example` answer before any config is even read, so a
broken `PGRST_*` value or missing config file never masks them.
`--dump-config` uses the parse layer's more permissive rules (it must be able
to echo whatever was parsed, even a value the boot schema would reject); the
default boot action instead runs `Bier.CLI.Config.validated_start_opts/1`, so
a value `--dump-config` prints happily (e.g. `db-max-rows = 0`) can still be
a fatal boot error.

```sh
PGRST_DB_SCHEMAS=api PGRST_DB_ANON_ROLE=web_anon ./bier --dump-config
./bier --example > bier.conf
./bier bier.conf --dump-config
./bier --help
```

#### Config file format

`Bier.CLI.ConfigFile` parses the PostgREST-compatible subset: one
`key = value` line per setting (kebab-case keys, matching the `PGRST_*`
spellings with `PGRST_` stripped and underscores turned to dashes), `#`
comments (a whole line, or trailing a value), blank lines ignored,
double-quoted strings with `\"` escapes, and bare `true`/`false`/integers
parsed as such — anything else is kept as text.

```text
## brewery.conf
db-uri = "postgresql://authenticator:secret@localhost:5432/brewery_dev"
db-schemas = "api"
db-anon-role = "web_anon"
server-port = 3000
app.settings.anthem = "Rocky Top"
```

Supported `PGRST_*` keys mirror the [Option reference](#option-reference)
table above (plus their deprecated aliases); keys Bier does not implement are
rejected rather than silently accepted or echoed.

## Validators

Beyond per-field type checking (`Bier.schema/0`'s NimbleOptions types),
`Bier.Config.new/2` and `Bier.CLI.Config.load/3` both run the same
cross-field/semantic validators before a config is accepted — so `start_link/1`,
`BIER_STANDALONE`, and the `bier` CLI's boot action all reject identically.

| Validator | Rule | Rejected with |
| --- | --- | --- |
| `jwt_secret` | A configured secret must be **≥ 32 bytes** (`byte_size/1` — octets, not characters) | `"The JWT secret must be at least 32 characters long."` |
| `jwt_aud` | Any string is accepted, unless it contains `:`, in which case it must parse as an absolute URI (a scheme is required; a host is not) | `"jwt-aud should be a string or a valid URI"` |
| `jwt_secret_is_base64` | When `true`, `jwt_secret` must decode as base64 after URL-safe normalization (`-`→`+`, `_`→`/`, `.`→`=`, whitespace stripped) | `"the jwt-secret is not valid base64"` |
| `jwt_role_claim_key` | Must parse as PostgREST's JSPath grammar (bare/quoted keys, `[n]` indices, a trailing `[?(@ op "text")]` filter) | `"failed to parse role-claim-key value (<input>)"` |
| `server_unix_socket_mode` | The longest leading run of octal digits (Haskell `readOct` semantics — so `"599"` reads as `5`, `"800"` has no octal prefix at all) must fall within `0o600`..`0o777`; checked at boot even with no socket configured | `"...needs to be between 600 and 777"` or `"...not an octal"` |
| `openapi_server_proxy_uri` | Must be an absolute `http`/`https` URI with a non-empty host | `"Malformed proxy uri, a correct example: https://example.com:8443/basePath"` |
| `admin_server_port` | When set, must differ from `router[:port]` (`server-port`) | `"admin-server-port cannot be the same as server-port"` |
| `db_channel` | Non-empty, ≤ 63 bytes (the Postgres identifier limit), no null byte | `"db-channel cannot be empty"` / `"...cannot exceed 63 bytes"` / `"...cannot contain null bytes"` |

Every rule above except `db_channel` mirrors a pinned PostgREST conformance
case (`jwt-secret` case 1708, `jwt-aud` 1709, `jwt-role-claim-key` 1711,
`server-unix-socket-mode` 1714/1715, `openapi-server-proxy-uri` 1716,
`admin-server-port` 1717, base64 secret 1718). `db_channel`'s length/null-byte
rule is Bier-only — PostgREST does not validate this key itself; Bier
validates it at boot because `Postgrex.Notifications.listen/3` would
otherwise raise the same violation at connect time, turning a configuration
mistake into a crash loop instead of a clean startup failure.

## Schema-cache reload

Bier introspects the database once, at boot, and serves every request from
that in-memory snapshot (`Bier.SchemaCache`, held in `:persistent_term`).
Two options and one function govern keeping it current after a DDL change:

* `db_channel` (default `"pgrst"`) — the Postgres `NOTIFY`/`LISTEN` channel
  name;
* `db_channel_enabled` (default `true`) — whether the instance opens a
  dedicated `Bier.SchemaCacheListener` connection that `LISTEN`s on that
  channel and reloads on notification. Disabling it saves one DB connection
  per instance.

```sql
NOTIFY pgrst, 'reload schema';
```

reloads the cache without restarting the instance — the same trigger
PostgREST answers via `NOTIFY`/`SIGUSR1`. Programmatically, from Elixir:

```elixir
Bier.reload_schema_cache(MyApp.Bier)
```

does the same thing on demand and works regardless of `db_channel_enabled`.
A failed reload (introspection error) leaves the previous snapshot serving —
the swap only happens after a fully successful load. A `'reload config'`
payload is accepted and logged but is a no-op: Bier's configuration is
supplied by the host application (or by `PGRST_*` on the standalone surface),
not reloadable from inside Postgres.

To reload automatically on every DDL change, install PostgREST's event
trigger against whichever channel `db_channel` names:

```sql
CREATE OR REPLACE FUNCTION public.pgrst_watch() RETURNS event_trigger
  LANGUAGE plpgsql
  AS $$
BEGIN
  NOTIFY pgrst, 'reload schema';
END;
$$;

CREATE EVENT TRIGGER pgrst_watch
  ON ddl_command_end
  EXECUTE PROCEDURE public.pgrst_watch();
```
