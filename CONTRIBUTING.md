# Contributing to Bier

Thanks for your interest in Bier! This guide collects the project-specific
rules that are easy to trip over; the [README](README.md) covers the
architecture and [`docs/CONFORMANCE_IMPL.md`][conformance-impl] covers the
conformance build in depth.

Everything below assumes a git checkout — several files it refers to
(`mise.toml`, `spec/`, `docs/CONFORMANCE_IMPL.md`) are repository-only and are
not part of the published package or documentation.

[conformance-impl]: https://github.com/milmazz/bier/blob/main/docs/CONFORMANCE_IMPL.md

## Toolchain

Elixir/OTP versions are pinned in `mise.toml` (Elixir 1.20 / OTP 29), matching
CI. `mix.exs` declares the lower bound at `~> 1.18`. With
[mise](https://mise.jdx.dev) installed:

```sh
mise install
mix deps.get
git submodule update --init   # fetch the spec/ conformance submodule
```

A local PostgreSQL (15+) reachable at `localhost:5432` is required for the
test suite. The PostGIS extension must be installed as well — the fixture
chain's `spec/fixtures/04_postgis.sql` depends on it (CI uses the
`postgis/postgis` images). Connection parameters come from the standard `PG*`
environment variables (`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`).

## Running the suite

```sh
mix test                                  # loads the fixture DB, runs everything
mix test test/path/to/file_test.exs:LINE  # a single test
mix test --only area:operators            # one conformance area
```

`mix test` is aliased to `["bier.fixtures.load", "test"]`: it drops and
recreates a local `bier_test` database and runs the `spec/` submodule's
numbered fixture chain (`spec/fixtures/01_roles.sql` through
`07_analyze.sql`) before running, so it is always safe to re-run.

## The golden rule: `test/**` and `spec/**` are frozen

The conformance suite (762 cases in `spec/`, executed by
`test/conformance/conformance_test.exs`) encodes real PostgREST v16.0
behavior, with each case citing its upstream source. It is **ground truth**:

* Fix `lib/` to match the cases — never edit `test/**` or `spec/**`.
* If a case looks wrong, re-check the cited PostgREST source before assuming
  the test is at fault.

`spec/` is a git submodule of
[`milmazz/postgrest-conformance`](https://github.com/milmazz/postgrest-conformance),
so the freeze above is absolute here: there is no in-repo escape hatch for it
at all. Case/behavior changes and fixture edits happen **upstream**, in that
repo, through its own reviewed process — never as part of a bier PR.

## Generated code

`lib/bier/query_parser.ex` is **generated** from its
`lib/bier/query_parser.ex.exs` template. Edit the template, run
`mix gen.parsers`, and commit both the template and the regenerated `.ex`.
Never edit the generated `.ex` directly. Credo analyzes the template
(the file you edit) but skips the generated output.

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
result separately. The test step is a plain `mix test` with no tolerated
baseline: the suite passes today, and any failure fails the job.

## Style

* `mix format` settles formatting arguments; Credo (`.credo.exs`) settles the
  rest. Both run in CI.
* Serialize JSON through `Bier.json_library()`, never by calling a JSON
  module directly, so host applications can swap the encoder.
* New error shapes belong in `Bier.Plugs.FallbackController` as additional
  `call/2` clauses, not inline in the controllers.
* Public modules carry a `@moduledoc` explaining *why* the module exists and
  which PostgREST behavior it mirrors; keep that bar for new code.
