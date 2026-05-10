# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Bier is an early-stage (alpha) Elixir library that aims to serve a RESTful API generated on-the-fly from PostgreSQL DB introspection — heavily inspired by PostgREST. The README is the source of truth for the design intent and includes the two key sequence diagrams (boot flow and request flow). Several pieces called out in the README are intentional placeholders today: DB introspection is stubbed, `Bier.Plugs.ActionController` returns canned responses, `QueryExecutor` and authentication do not yet exist. `Bier.Query.Parser` (`lib/bier/query/parser.ex`) is the seed for slices 2–4 of the multi-agent factory plan.

The whole repository is being driven by the multi-agent factory described in `docs/AGENT_PLAN.md`. Read it before making structural changes — it defines roles (Researcher, Tester, Developer, Reviewer, Auditor), file-ownership boundaries, and CI quality gates. Subagent system prompts live in `.claude/agents/`. `docs/STATUS.md` is the Kanban for slice progress.

## Toolchain

Elixir/OTP versions are pinned in `mise.toml` (Elixir 1.19.5 / OTP 28) and matched in `.github/workflows/ci.yml`. `mix.exs` declares the lower bound at `elixir: "~> 1.18"`.

Postgres is run via `docker-compose.yml` (services `pg14`, `pg15`, `pg16` on host ports 5414/5415/5416). The conformance fixture lives at `priv/repo/conformance_fixtures.sql` and is mounted into each container's init dir.

## Common commands

```sh
mix deps.get          # fetch dependencies
mix compile
mix test              # run the full suite (including doctests)
mix test test/path/to/file_test.exs:LINE   # single test by file:line
mix format            # uses .formatter.exs
mix coveralls.html    # local coverage report (opens cover/excoveralls.html)
```

CI runs these gates per `.github/workflows/ci.yml` (the §8 gates from `docs/AGENT_PLAN.md`); run them locally before pushing to avoid red builds:

```sh
mix deps.unlock --check-unused
mix format --check-formatted
mix hex.audit
mix compile --warnings-as-errors
mix docs --warnings-as-errors
mix credo --strict
mix dialyzer                          # PLTs cached under priv/plts/
mix coveralls.json                    # produces cover/excoveralls.json for the coverage gate
mix test --only conformance           # needs Postgres running (docker compose up -d pg16)
mix test --only property              # property-based tests
bash .githooks/role-guard.sh main     # file-ownership matrix from §4
bash .githooks/changelog-check.sh main # PR must add an entry under [Unreleased]
bash .githooks/spec-lint.sh           # validates spec/conformance/cases/*.yaml
```

The CI matrix for the conformance suite runs on Postgres 14, 15, and 16. `.github/workflows/spec-drift.yml` is a manual-only auditor (per `docs/AGENT_PLAN.md` §3.6); trigger it via `gh workflow run spec-drift.yml`.

Hooks are not active by default — opt in with `git config core.hooksPath .githooks`. Once active: `pre-commit` runs role-guard (glob check + `X-Bier-Role:` trailer audit) plus `mix do format, compile` on staged Elixir files, and `prepare-commit-msg` auto-adds the trailer required by §4.3 (role resolved from `AGENT_ROLE` env or branch prefix).

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

`test/support/` is added to `elixirc_paths` only in `:test` (see `mix.exs`). Put shared fixtures/helpers there. The current unit suite is `test/bier/query/parser_test.exs`. Conformance and property tests live under `test/conformance/` and `test/property/` (created by the Tester in Phase 2). The conformance runner is generative — adding a YAML to `spec/conformance/cases/` auto-creates an ExUnit test, so do not write per-case Elixir test files by hand.
