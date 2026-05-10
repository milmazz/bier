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
- `.githooks/prepare-commit-msg`: auto-adds the `X-Bier-Role:` trailer
  required by §4.3 (role resolved from `AGENT_ROLE` env or canonical
  branch prefix).
- `.github/labels.yml`: documents the seven PR labels the role-guard
  reads (`role:researcher` … `role:auditor`, plus `changelog:skip`)
  for bulk creation by the Orchestrator.

### Changed

- Renamed `Bier.QueryParser` to `Bier.Query.Parser` and moved the source
  to `lib/bier/query/parser.ex` to seed the new layout for slices 2–4.
  The test file moves to `test/bier/query/parser_test.exs`. No
  behavioral changes.
- Updated `CLAUDE.md` to reflect the new toolchain (credo, dialyzer,
  coveralls), the docker-compose Postgres setup, and the multi-agent
  factory entry points.
- `.githooks/role-guard.sh`: rewritten to align with the merged Option
  0 spec (§4.1, §4.3). Role resolution now follows the priority order
  PR label (`PR_LABELS` env, set by CI from
  `github.event.pull_request.labels`) → branch prefix → `X-Bier-Role:`
  commit trailer, with `AGENT_ROLE` retained as a local override when
  `PR_LABELS` is empty. Branch prefixes match the §4.1 canonical set
  (`research/`, `test/`, `dev/<slice>/`, `review/`, `audit/`,
  `chore/`). New trailer audit step requires at least one commit on
  the branch to carry `X-Bier-Role: <role>`.
- `.github/workflows/ci.yml`: the `role-guard` job now passes
  `PR_LABELS` (joined from `github.event.pull_request.labels.*.name`)
  to the script.
- `.github/CODEOWNERS`: header rewritten to make the
  review-routing-only role explicit; enforcement is the role-guard CI.
- `.claude/agents/{researcher,tester,developer,reviewer,auditor}.md`:
  each subagent now declares its canonical branch prefix, commit
  trailer, and `role:<role>` PR label per §11.

### Spec

- _none_

### Tests

- _none_

### Fixed

- `ci.yml`: removed the workflow-level `MIX_ENV: test` that prevented
  `mix docs` (lint job) and `mix dialyzer` from finding their tasks
  (`ex_doc` and `dialyxir` are `only: :dev`). `mix test` and
  `coveralls.*` continue to auto-elevate to `:test`.
- `ci.yml`: routed the `conformance` and `property` jobs through
  `.githooks/mix-test-tagged.sh`, which tolerates the Elixir 1.19
  "no test was executed" exit code 1 produced by `mix test --only
  <tag>` when no tests carry that tag yet (Phase 0 / 1 reality).

### Removed

- `.github/workflows/elixir.yml` — replaced by the multi-job
  `.github/workflows/ci.yml`.
