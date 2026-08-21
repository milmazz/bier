# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Bier is an alpha Elixir library that serves a RESTful API generated on-the-fly from PostgreSQL DB introspection — heavily inspired by PostgREST. The README is the source of truth for the design intent and includes the two key sequence diagrams (boot flow and request flow).

The pipeline is real, not stubbed: `Bier.Introspection` queries `pg_catalog`; `Bier.Plugs.ActionController` resolves the target and runs the read/mutation/RPC path; `Bier.QueryParser` (a generated, dependency-free parser) and `Bier.QueryExecutor` build and run one parameterized JSON query; `Bier.Auth` does HS256 JWT verification + role/GUC setup. Development is driven by a frozen conformance suite derived from PostgREST v16.0 (see `docs/CONFORMANCE_IMPL.md` and `spec/`). Known feature gaps (observability/telemetry, admin/health endpoints, asymmetric JWT) are tracked as GitHub issues.

`spec/` was re-synced from v14.12 to v16.0 in one spec-only pass, which moved the target ahead of `lib/` by 100 failures; `lib/` has since caught up and **all 17 areas are green** — 758 active cases pass (excluded: the 3 `status_text` cases, #42, and case 1771, a deliberate divergence — see "Test layout"). The v16 behavior changes that drove the gap are closed: #93 (`jwt-role-claim-key` → RFC 9535 JSON Path), #94 (`Prefer: timezone`), #95 (embed target names + `url-use-legacy-target-names`) and #96 (`db-schemas` startup validation). When failures reappear, work them down one area at a time with the `bier-conformance` skill.

## Toolchain

Elixir/OTP versions are pinned in `mise.toml` (Elixir 1.20 / OTP 29) and matched in `.github/workflows/elixir.yml`. `mix.exs` declares the lower bound at `elixir: "~> 1.18"`.

## Common commands

```sh
mix deps.get          # fetch dependencies
mix compile
mix test              # loads the fixture DB, then runs the full suite
mix test test/path/to/file_test.exs:LINE   # single test by file:line
mix test --only area:<area>                # one conformance area (e.g. area:operators)
mix format            # uses .formatter.exs
mix gen.parsers       # regenerate the parser module from its *.ex.exs template
mix precommit         # run every CI gate (format/audit/compile/credo/docs/test)
```

`mix test` is aliased to `["bier.fixtures.load", "test"]` (`mix.exs`), so it
drops+recreates a local `bier_test` PostgreSQL database and runs the `spec/`
submodule's numbered fixture chain (`spec/fixtures/01_roles.sql` through
`07_analyze.sql`) before running. A reachable local Postgres is required; see
`docs/CONFORMANCE_IMPL.md` and `spec/HARNESS.md` for the wiring.

Run every CI gate locally before pushing with one command:

```sh
mix precommit
```

It is an alias chaining, in order: `deps.unlock --check-unused`,
`format --check-formatted`, `hex.audit`, `compile --warnings-as-errors`,
`credo --strict`, `docs --warnings-as-errors`, `test`. CI runs the same steps
individually (NOT the alias) so each gate reports separately — keep
`.github/workflows/elixir.yml` that way.

Credo is configured in `.credo.exs` (strict mode). The generated
`query_parser.ex` is excluded, but its `query_parser.ex.exs` template IS
analyzed. No dialyzer step is configured.

## Architecture

### Two-layer supervision (intentional)

There are two distinct supervisors and they do different things:

1. **`Bier.Application`** (`mix.exs` `mod:`) starts only shared, node-wide infrastructure: **`Bier.Registry`** (the unique-keys process registry every instance registers through) and **`Bier.Events.Registry`** (the duplicate-keys pub/sub registry for the SSE events endpoint). It does NOT start an HTTP server.
2. **`Bier`** is itself a `Supervisor` that the host application starts via `Bier.start_link/1` (or as a child spec). Each call creates one *named instance* with its own config, its own Bandit server, and its own dynamically-generated Router module. Multiple instances coexist by passing distinct `:name` options.

Implication: do not put per-instance state in `Bier.Application`. Anything tied to a configured instance belongs under the `Bier` supervisor and should be registered through `Bier.Registry.via/3`.

### Per-instance process naming

`Bier.Registry` is a standard Elixir `Registry` (`keys: :unique`). All instance-scoped processes are registered with `{:via, Registry, {Bier.Registry, key}}` tuples produced by `Bier.Registry.via/3`. The key is either the instance name, or `{name, role}` where role disambiguates (e.g. `DynamicSupervisor`, `Bier.HttpServerStarter`). The supervisor's via-tuple also stashes the validated `Bier.Config` as the registry value, which is how `Bier.Registry.config/1` retrieves it without a GenServer call.

### Boot sequence (current state)

`Bier.start_link/1` → validates opts via `Bier.Config.new!/2` (NimbleOptions schema in `Bier.schema/0`, `lib/bier.ex`; defaults sourced from application env) → the `Bier` supervisor starts its children in order: a per-instance **`Postgrex` pool** (registered via `Bier.Registry.via(name, Postgrex)`), **`Bier.PoolMonitor`**, **`Bier.PrivilegesCache`** (then a conditional **`Bier.JwtCache`** child, started only when a JWT secret and a positive `jwt_cache_max_entries` are configured), a per-instance **`DynamicSupervisor`**, then **`Bier.HttpServerStarter`**. The pool and DynamicSupervisor must come first: `HttpServerStarter.init/1` uses the pool for introspection, and its `handle_continue(:start_webserver, …)` starts Bandit *as a child of the DynamicSupervisor*.

`HttpServerStarter.init/1` runs real introspection via `Bier.SchemaCache.load!/3`, which loads and atomically swaps the snapshot (one `%Bier.SchemaCache{}` struct) in **`:persistent_term`** keyed by `{Bier, :schema_cache, name}` (read on every request through the `Bier.SchemaCache` accessors). A `Bier.SchemaCacheListener` child (gated by `db_channel_enabled`, default true) LISTENs on `db_channel` and atomically re-swaps the snapshot on `NOTIFY … 'reload schema'`; `Bier.reload_schema_cache/1` does the same programmatically. It then calls `Bier.RouterBuilder.build/2` and starts Bandit with `http_options: [compress: false]` (PostgREST never compresses and always emits `Content-Length`; Bandit otherwise strips it).

### Dynamic router generation

`Bier.RouterBuilder.build/2` creates a brand-new module at runtime using `Module.create/3` with quoted `Plug.Router` content, named `<instance_name>.Router` (so two instances must have different `:name` values to avoid module redefinition). It is a thin **catch-all**: a fixed plug pipeline (`:match` → `assign_instance` → `Bier.Plugs.Cors` → `Bier.Plugs.Observability` → `Bier.Plugs.ReadBody` → `:dispatch`) and a single `match _` that forwards every request to `Bier.Plugs.ActionController`. The per-table `get/post/delete` generation is gone — Accept-Profile schema resolution and `/rpc/*` can't be expressed as static routes, so the target `{schema, relation}` is resolved at request time instead.

When changing routing/dispatch semantics, edit the quoted block inside `RouterBuilder` — the generated module is rebuilt every boot, so it is not checked in and grepping for routes won't find them.

### Controllers and the request pipeline

`Bier.Plugs.ActionController.call/2` resolves the target `{schema, relation}` from the path + `Accept-Profile`/`Content-Profile` (default schema = first of `db_schemas`), runs `Bier.Auth.resolve` for schemas that require it (auth is inline here, not a separate plug), then dispatches by path/method:

- root `/` → OpenAPI document (or `db_root_spec`);
- `OPTIONS` → `Allow` header;
- `/rpc/<fn>` → `Bier.Rpc.dispatch`;
- relation `GET`/`HEAD` → `Bier.Negotiation` → `Bier.QueryParser.parse_request` → `Bier.QueryExecutor.run` (one parameterized SQL → JSON) → `Bier.Response`/`Bier.Render`;
- relation `POST`/`PATCH`/`PUT`/`DELETE` → `Bier.Mutation.handle`.

Any non-`Plug.Conn` return value falls through to `Bier.Plugs.FallbackController.call/2`, which maps internal reasons and Postgres `SQLSTATE`s to HTTP statuses and PostgREST's `{code, message, details, hint}` envelope (`PGRST*` codes). New error shapes should be added as additional `FallbackController.call/2` clauses rather than handled inline in `ActionController`.

### The query parser (generated)

`lib/bier/query_parser.ex` is a **generated**, dependency-free module built from its `lib/bier/query_parser.ex.exs` template via `mix gen.parsers` (which runs `mix nimble_parsec.compile`). `nimble_parsec` is a dev/test-only dep (`runtime: false`); the shipped code does not depend on it. Edit the `.ex.exs` template, run `mix gen.parsers`, and commit both the template and the regenerated `.ex` (the `.ex` is what `mix compile` reads — never edit it directly).

### Pluggable JSON

`Bier.json_library/0` returns the configured encoder (defaults to the stdlib `JSON` module, requires Elixir 1.18+). Any new code that serializes responses should go through it rather than calling `Jason`/`JSON` directly, so host apps can override via `config :bier, :json_library, …`.

## Test layout

`test/support/` is added to `elixirc_paths` only in `:test` (see `mix.exs`). Put shared fixtures/helpers there.

The suite is driven by the **conformance cases** in `test/conformance/conformance_test.exs`, which generates one ExUnit test per case in `spec/cases/` (762 cases across 17 areas; 4 are excluded — the 3 `:pending` `status_text` cases, #42, and case 1771 via the `@divergences` map, #122). `@divergences` in that file is the only mechanism for a **deliberate divergence**: the case's id maps to the reasoning, the test is tagged `:pending` and flunks with that reasoning, and the spec YAML stays untouched (it keeps recording what PostgREST really does — `spec/case.schema.json` has no pending key by design). Every entry needs explicit operator sign-off plus a tracking issue, and a compile-time guard fails the build if an entry's case disappears or stops pinning the upstream behavior it diverges from. Each case is tagged `@tag area: :<area>`. The harness under `test/support/` — `Bier.ConformanceServer` (boots one shared instance), `Bier.HttpCase.perform/1` (issues the request via `Req`), and `Bier.ConformanceAssertions` — plus everything under `spec/` is **frozen ground truth**: it encodes real PostgREST v16.0 behavior. Fix `lib/` to match the cases, never edit `test/**` or `spec/**`. See `docs/CONFORMANCE_IMPL.md` for bier's own harness wiring and `spec/HARNESS.md` for the implementer-agnostic format/assertion contract those cases are checked against.

`spec/` is a **git submodule** pinned to a tag of
[`github.com/milmazz/postgrest-conformance`](https://github.com/milmazz/postgrest-conformance)
(currently `v16.0.0-suite.1`) — the freeze above is absolute: it is never
edited inside bier, not even for a typo. The two exceptions the freeze used
to carve out for in-repo `spec/` edits are gone now that `spec/` moved out:
case/behavior changes and fixture edits both happen **upstream**, through
that repo's own reviewed workflows (see its `CONTRIBUTING.md`); the old
human-owned `fixtures_local.sql` supplement is now
`spec/fixtures/03_supplement.sql`, upstream-owned the same way. The only
`spec/`-touching action left in bier is bumping the pin — an explicit,
reviewed commit (`cd spec && git checkout <tag> && cd .. && git add spec`),
never a behavior change smuggled in alongside it.
