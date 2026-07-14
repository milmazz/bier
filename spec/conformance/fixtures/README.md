# Fixture layering and ownership

The conformance database is built by `mix bier.fixtures.load` from four layers
with distinct owners. **Who may write a file matters more than where its
content came from** — this is what prevents the drift that once let the merged
file and the fragments silently diverge.

| File | Owner / writer | Role |
|---|---|---|
| `../fixtures.sql` | Fixture Consolidator (incremental) or reviewed human commit | **Primary artifact.** The authoritative DDL+seed set the frozen case expectations were verified against. Never regenerated wholesale — it embeds merge decisions (superset seeds, collision renames, post-merge additions) that exist nowhere else. |
| `<area>.delta.sql` (created on demand) | one spec-research/fix agent per area | **Write channel.** New objects only — never duplicate DDL that already exists in `fixtures.sql`. The (sequential) Consolidator folds each delta into `fixtures.sql`, verifies the load, then empties the delta. Parallel agents each own their area's delta, so no shared-file races. |
| `../fixtures_local.sql` | **human only** | Environment/harness-support supplement, loaded right after `fixtures.sql` and before area-schema mirroring. Workflow agents must never write it, and conformance cases must never depend on objects that exist only there. |
| `rpc.sql`, `headers.sql` | reviewed human commit only | **Live loader inputs** — not provenance. `lib/mix/tasks/bier.fixtures.load.ex` re-loads them at fixture-load time to build the real `rpc` and `headers` area schemas via text remapping. They carry fragile invariants (see the header of each file) that a careless edit silently breaks. |
| every other `*.sql` here | frozen (historical) | Provenance from the original 2026-06 spec research. **Not authoritative**: `fixtures.sql` has since gained objects and seed decisions these never had. Do not "reconcile" `fixtures.sql` against them and do not extend them — new fixture needs go through `<area>.delta.sql`. |

## Invariants

1. `fixtures.sql` must load standalone into a fresh database (`psql -v
   ON_ERROR_STOP=1`); `fixtures_local.sql` may reference `fixtures.sql`
   objects, never the reverse.
2. Every relation a conformance case references must exist after
   `mix bier.fixtures.load` — the spec workflows' Verify phase machine-checks
   this.
3. `rpc.sql` must keep every object `test`-qualified and contain no string
   literal with the bare token `test` (the loader remaps `\btest\b` → `rpc`).
4. `headers.sql` must keep the literal marker line `-- Multi-schema tables`
   separating its test/private portion from the multi-schema portion, and no
   string literal may contain the bare tokens `test`/`private` (the loader
   splits on the marker and remaps those tokens).
