# Contributing to Bier

Thanks for your interest in Bier! This guide collects the project-specific
rules that are easy to trip over; the [README](README.md) covers the
architecture and the [docs/CONFORMANCE_IMPL.md](docs/CONFORMANCE_IMPL.md)
document covers the conformance build in depth.

## Toolchain

Elixir/OTP versions are pinned in [`mise.toml`](mise.toml) (Elixir 1.19.5 /
OTP 28). With [mise](https://mise.jdx.dev) installed:

```sh
mise install
mix deps.get
```

A local PostgreSQL (15+) reachable at `localhost:5432` is required for the
test suite. Connection parameters come from the standard `PG*` environment
variables (`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`).

## Running the suite

```sh
mix test                                  # loads the fixture DB, runs everything
mix test test/path/to/file_test.exs:LINE  # a single test
mix test --only area:operators            # one conformance area
```

`mix test` is aliased to `["bier.fixtures.load", "test"]`: it drops and
recreates a local `bier_test` database and loads
`spec/conformance/fixtures.sql` before running, so it is always safe to re-run.

## The golden rule: `test/**` and `spec/**` are frozen

The conformance suite (532 cases in `spec/`, executed by
`test/conformance/conformance_test.exs`) encodes real PostgREST v14.12
behavior, with each case citing its upstream source. It is **ground truth**:

* Fix `lib/` to match the cases — never edit `test/**` or `spec/**`.
* If a case looks wrong, re-check the cited PostgREST source before assuming
  the test is at fault.

## Generated code

`lib/bier/query_parser.ex` and `lib/bier/query_parser/nimble.ex` are
**generated** from their `*.ex.exs` templates. Edit the template, run
`mix gen.parsers`, and commit both the template and the regenerated `.ex`.
Never edit the generated `.ex` files directly. Credo analyzes the templates
(the files you edit) but skips the generated output.

## Before you push

Run all of CI's gates with one command:

```sh
mix precommit
```

It is an alias (see `mix.exs`) for the individual gates, in order:

```sh
mix deps.unlock --check-unused
mix format --check-formatted
mix hex.audit
mix compile --warnings-as-errors
mix credo --strict
mix docs --warnings-as-errors
mix test
```

CI runs the same steps individually (not the alias) so each gate reports its
result separately.

CI tolerates a documented baseline of known environment/harness test failures
(see `.github/workflows/elixir.yml`); it fails only when the failure count
*increases*. If your change fixes some of those failures, lower the baseline
in the workflow to lock in the gain.

## Style

* `mix format` settles formatting arguments; Credo (`.credo.exs`) settles the
  rest. Both run in CI.
* Serialize JSON through `Bier.json_library()`, never by calling a JSON
  module directly, so host applications can swap the encoder.
* New error shapes belong in `Bier.Plugs.FallbackController` as additional
  `call/2` clauses, not inline in the controllers.
* Public modules carry a `@moduledoc` explaining *why* the module exists and
  which PostgREST behavior it mirrors; keep that bar for new code.
