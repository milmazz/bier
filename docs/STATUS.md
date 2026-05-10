# Bier status board

> Owned by the Orchestrator. Single source of truth for slice progress.
> Format defined in `docs/AGENT_PLAN.md` §6.

## Phasing

| Phase | State       | Notes |
| ----- | ----------- | ----- |
| 0     | in progress | Factory bootstrap (this PR). |
| 1     | not started | Researcher populates `spec/`. Blocked on Phase 0 merge. |
| 2     | not started | Tester writes the suite. Blocked on Phase 1. |
| 3     | not started | Developers turn the suite green slice-by-slice. |
| 4     | not started | Side-by-side conformance against pinned PostgREST. |
| 5     | not started | Release; Spec-Drift Auditor available for re-pinning. |

PostgREST version pinned for parity: `v12.2.0` (default in `.github/workflows/spec-drift.yml`).

## Slice board

The 17 slices defined in `docs/AGENT_PLAN.md` §6. `tests passing` is "n / total"
once the conformance suite exists; until then it reads "—".

| #  | slice                  | agent       | branch                  | tests passing | blocked on        | PR  |
| -- | ---------------------- | ----------- | ----------------------- | ------------- | ----------------- | --- |
| 1  | db_introspection       | _unassigned_ | feat/db-introspection   | —             | spec/, test/      | —   |
| 2  | query_parser_select    | _unassigned_ | feat/query-select       | —             | spec/, test/      | —   |
| 3  | query_parser_filters   | _unassigned_ | feat/query-filters      | —             | spec/, test/      | —   |
| 4  | query_parser_order     | _unassigned_ | feat/query-order        | —             | spec/, test/      | —   |
| 5  | query_parser_embed     | _unassigned_ | feat/query-embed        | —             | slices 1, 2       | —   |
| 6  | sql_builder            | _unassigned_ | feat/sql-builder        | —             | slices 2–5        | —   |
| 7  | executor               | _unassigned_ | feat/executor           | —             | slice 6           | —   |
| 8  | router                 | _unassigned_ | feat/router             | —             | slice 1           | —   |
| 9  | mutations              | _unassigned_ | feat/mutations          | —             | slices 6, 7, 8    | —   |
| 10 | rpc                    | _unassigned_ | feat/rpc                | —             | slices 1, 7, 8    | —   |
| 11 | auth_jwt               | _unassigned_ | feat/auth-jwt           | —             | slice 8           | —   |
| 12 | content_negotiation    | _unassigned_ | feat/content-negotiation| —             | slice 8           | —   |
| 13 | pagination_headers     | _unassigned_ | feat/pagination         | —             | slices 6, 7, 8    | —   |
| 14 | errors                 | _unassigned_ | feat/errors             | —             | slice 8           | —   |
| 15 | openapi                | _unassigned_ | feat/openapi            | —             | slice 1           | —   |
| 16 | config                 | _unassigned_ | feat/config             | —             | —                 | —   |
| 17 | observability          | _unassigned_ | feat/observability      | —             | slice 8           | —   |

Independent slices runnable in parallel from day one of Phase 3: 1, 2, 3, 4, 16.
Then 5; then 6; then 7/8; then the rest.

## Coverage gate

`MIN_COVERAGE` in `.github/workflows/ci.yml` (`coverage-gate` job) is `0` for
Phase 0 — the gate is plumbed but not enforced. Ratchet up per slice as
testable code lands; a per-slice exit criterion is line coverage ≥ 85%
on touched modules (`docs/AGENT_PLAN.md` §8 #9).

## Pending agent definitions

Subagent system prompts live in `.claude/agents/`:

- `researcher.md`
- `tester.md`
- `developer.md`
- `reviewer.md`
- `auditor.md`

Each follows the `docs/AGENT_PLAN.md` §11 skeleton.
