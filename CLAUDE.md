# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Bier is an early-stage (alpha) Elixir library that aims to serve a RESTful API generated on-the-fly from PostgreSQL DB introspection — heavily inspired by PostgREST. The README is the source of truth for the design intent and includes the two key sequence diagrams (boot flow and request flow). Several pieces called out in the README are intentional placeholders today: DB introspection is stubbed, `Bier.Plugs.ActionController` returns canned responses, and `QueryParser` / `QueryExecutor` (and authentication) do not yet exist.

## Toolchain

- Elixir/OTP versions are pinned in `mise.toml` (Elixir 1.19.5 / OTP 28). `mix.exs` declares `elixir: "~> 1.18"`.
- Note: `.github/workflows/elixir.yml` still pins Elixir 1.15.2 / OTP 26.0 — the CI matrix is older than the local toolchain.

## Common commands

```sh
mix deps.get          # fetch dependencies
mix compile
mix test              # run the full suite
mix test test/path/to/file_test.exs:LINE   # single test by file:line
mix format            # uses .formatter.exs
```

There is no lint/dialyzer/credo step configured.

## Architecture

### Two-layer supervision (intentional)

There are two distinct supervisors and they do different things:

1. **`Bier.Application`** (`mix.exs` `mod:`) starts only **`Bier.Registry`** — a process registry shared across all Bier instances in the BEAM node. It does NOT start an HTTP server.
2. **`Bier`** is itself a `Supervisor` that the host application starts via `Bier.start_link/1` (or as a child spec). Each call creates one *named instance* with its own config, its own Bandit server, and its own dynamically-generated Router module. Multiple instances coexist by passing distinct `:name` options.

Implication: do not put per-instance state in `Bier.Application`. Anything tied to a configured instance belongs under the `Bier` supervisor and should be registered through `Bier.Registry.via/3`.

### Per-instance process naming

`Bier.Registry` is a standard Elixir `Registry` (`keys: :unique`). All instance-scoped processes are registered with `{:via, Registry, {Bier.Registry, key}}` tuples produced by `Bier.Registry.via/3`. The key is either the instance name, or `{name, role}` where role disambiguates (e.g. `DynamicSupervisor`, `Bier.HttpServerStarter`). The supervisor's via-tuple also stashes the validated `Bier.Config` as the registry value, which is how `Bier.Registry.config/1` retrieves it without a GenServer call.

### Boot sequence (current state)

`Bier.start_link/1` → validates opts via `Bier.Config.new!/2` (NimbleOptions schema in `lib/bier.ex`) → starts `Bier.HttpServerStarter` and a per-instance `DynamicSupervisor`. `HttpServerStarter.init/1` runs (today: fakes) DB introspection, then calls `Bier.RouterBuilder.build/2`, then `handle_continue(:start_webserver, …)` starts Bandit as a child of that DynamicSupervisor with the freshly built plug.

### Dynamic router generation

`Bier.RouterBuilder.build/2` creates a brand-new module at runtime using `Module.create/3` with quoted `Plug.Router` content. The module is named `<instance_name>.Router` (e.g. `Bier.Router` for the default instance — so two instances must have different `:name` values to avoid module redefinition). For each entry in `db_structure` it emits `get/post/delete` routes pointing to `Bier.Plugs.ActionController` with `init_opts` set to the action atom (`:index | :post | :delete`) and `assigns` carrying `supervisor_name`, `schema`, and `table_name`. Anything that doesn't match falls through to `Bier.Plugs.FallbackController` with `:not_found`.

When changing routing/dispatch semantics, edit the quoted block inside `RouterBuilder` — the generated module is rebuilt every boot, so it is not checked in and grepping for routes won't find them.

### Controllers

`Bier.Plugs.ActionController.call/2` dispatches by the `init_opts` action atom and lets a non-`Plug.Conn` return value fall through to `FallbackController.call/2`, which pattern-matches on shapes like `{:error, :bad_request}`, `{:error, :mismatch}`, `%{code: :insufficient_privilege}`, and `%{code: :foreign_key_violation}`. New error shapes should be added as additional `FallbackController.call/2` clauses rather than handled inline in the action.

### Pluggable JSON

`Bier.json_library/0` returns the configured encoder (defaults to the stdlib `JSON` module, requires Elixir 1.18+). Any new code that serializes responses should go through it rather than calling `Jason`/`JSON` directly, so host apps can override via `config :bier, :json_library, …`.

## Test layout

`test/support/` is added to `elixirc_paths` only in `:test` (see `mix.exs`). Put shared fixtures/helpers there. The current suite is essentially empty (`test/bier_test.exs`).
