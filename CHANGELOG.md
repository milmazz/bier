# Changelog

All notable changes to **bier** are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

In addition to the standard sections (`Added`, `Changed`, `Deprecated`,
`Removed`, `Fixed`, `Security`), Bier uses two project-specific sections:

- **`Spec`** — changes that originate in `spec/` (Researcher).
- **`Tests`** — changes confined to the test suite (Tester).

Every PR must add at least one bullet under `## [Unreleased]` (enforced by
the `changelog` job in `.github/workflows/ci.yml`). Use the
`changelog:skip` PR label for chore / internal-doc-only / CI-only PRs that
genuinely have no user-visible effect; the Reviewer agent rejects
unjustified skips.

## [Unreleased]

### Added

- Phase 0 factory bootstrap: new dependencies (`postgrex`, `ecto_sql`,
  `jose`, `joken`, `stream_data`, `excoveralls`, `credo`, `dialyxir`,
  `yaml_elixir`, `jason`), `docker-compose.yml` covering Postgres
  14/15/16, `priv/repo/conformance_fixtures.sql` placeholder,
  `.github/workflows/ci.yml` implementing every §8 quality gate,
  `.github/workflows/spec-drift.yml` (manual-only per §3.6),
  `.github/CODEOWNERS`, `.github/ISSUE_TEMPLATE/spec-gap.md`,
  role-guard / changelog-check / spec-lint scripts under `.githooks/`,
  `.credo.exs` (strict mode minus `TagTODO`/`TagFIXME`),
  `docs/STATUS.md` Kanban skeleton, and subagent system prompts under
  `.claude/agents/`.

### Changed

- Renamed `Bier.QueryParser` to `Bier.Query.Parser` and moved the source
  to `lib/bier/query/parser.ex` to seed the new layout for slices 2–4.
  The test file moves to `test/bier/query/parser_test.exs`. No
  behavioral changes.
- Updated `CLAUDE.md` to reflect the new toolchain (credo, dialyzer,
  coveralls), the docker-compose Postgres setup, and the multi-agent
  factory entry points.

### Spec

- _none_

### Tests

- _none_

### Removed

- `.github/workflows/elixir.yml` — replaced by the multi-job
  `.github/workflows/ci.yml`.
