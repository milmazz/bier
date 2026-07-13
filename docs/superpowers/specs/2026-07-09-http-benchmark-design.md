# HTTP benchmark harness: Bier vs PostgREST — design

**Date:** 2026-07-09
**Status:** Approved (pending final read-through)
**Goal:** Before tagging 0.1.0, produce defensible, rerunnable numbers answering:
for the same database, same data, and same request shapes, what throughput and
latency does Bier deliver versus PostgREST — and what is the ratio?

## Scope

- **In:** end-to-end HTTP benchmarks of simple reads and mutations, anonymous
  (no JWT), both servers native on macOS against a local native Postgres.
- **Out (explicitly):** auth/JWT overhead, `/rpc/` calls, embedded-resource
  reads, large-page reads, `count=exact`, Docker/Linux topologies, CI
  integration. Any of these can be added later as new scenarios without
  changing the harness shape.

## Servers under test

Both servers run natively on the benchmark Mac (no Docker — the macOS VM layer
would distort latency), against the same native Postgres instance.

### PostgREST

- **Version pinned to v14.12**, the exact version the conformance suite in
  `spec/` is frozen against. This keeps the performance claim aligned with the
  behavioral-parity claim.
- Obtained as the official macOS binary from the GitHub release page,
  downloaded once by the run script into `bench/http/bin/` (gitignored).
  Homebrew is not used: its formula version drifts and cannot be pinned to
  v14.12.
- Configured via a committed `bench/http/postgrest.conf`.

### Bier

- Compiled with `MIX_ENV=prod` and started via
  `MIX_ENV=prod mix run --no-halt bench/http/start_bier.exs`. Bier is a
  library, so the runner script is the standalone entry point: it calls
  `Bier.start_link/1` with the benchmark config.
- No release packaging: once compiled for prod, `mix run` and a release execute
  the same BEAM code; the release adds no benchmark value here.

### Config parity (held equal on both servers)

| Knob | Value |
|------|-------|
| Postgres instance | same local server, DB `bier_bench` |
| DB pool size | 10 |
| Exposed schemas | `bench` only |
| Anonymous role | `bench_anon` (no JWT secret configured) |
| Logging | effectively off: PostgREST `log-level = "crit"`, Bier `Logger` level `:warning` |
| HTTP | HTTP/1.1 with keep-alive, no TLS |
| Compression | off on both (Bier never compresses, matching PostgREST) |

## Benchmark database

A new fixtures file, `bench/http/fixtures.sql`, loaded by the run script into
a dedicated `bier_bench` database (drop + recreate on every run, same pattern
as `mix bier.fixtures.load`). It is independent of the frozen conformance
fixtures in `spec/` — those stay untouched.

- **`bench.items`** — read target, ~100,000 rows: `id` int PK (identity),
  `name` text, `value` numeric, `inserted_at` timestamptz, `active` boolean,
  `category` text drawn from ~20 distinct values with a b-tree index.
  Seeded deterministically in SQL (`generate_series`), no random seed drift
  between runs.
- **`bench.events`** — write target: `id` int PK (identity), `payload` text,
  `occurred_at` timestamptz. Truncated and reseeded to a fixed baseline
  (10,000 rows) between every measurement round so both servers face
  identical table state and size.
- **`bench_anon`** role: `USAGE` on schema `bench`, `SELECT` on `items`,
  `SELECT/INSERT/UPDATE` on `events`. Both servers use it as the anonymous
  role.

## Scenarios

Four k6 scenarios, matching the agreed read + mutation scope:

| ID | Request | Notes |
|----|---------|-------|
| R1 | `GET /items?id=eq.<random 1..100000>` | single row by PK; the headline per-request-overhead number |
| R2 | `GET /items?category=eq.<random of 20>&order=id.desc&limit=25` | filtered + ordered page; exercises SQL generation and a 25-row JSON body |
| M1 | `POST /events` (JSON body, `Prefer: return=minimal`) | insert path |
| M2 | `PATCH /events?id=eq.<random 1..10000>` (JSON body) | update-by-PK path |

Randomization uses k6's seeded PRNG so both servers see the same request
distribution.

## Methodology

This section is what makes the numbers defensible; the report reproduces it.

1. **Two stages per scenario per server:**
   - **Ceiling stage (closed loop):** k6 ramping-VUs finds each server's
     maximum sustained RPS. Reported as "max throughput".
   - **Latency stage (open loop):** k6 `constant-arrival-rate` at a fixed
     rate set to a fraction of the *slower* server's ceiling for that
     scenario (computed automatically from the ceiling stage): **70%** for
     full runs, **40%** for `--smoke` (short windows give a cold-started
     server no time to absorb a 70% burst — smoke validates the pipeline,
     not the numbers). The fraction is overridable via `RATE_FRACTION` and
     recorded in `meta.json` and the report. Both servers are measured at
     the *same* arrival rate, so p50/p90/p99 are comparable and immune to
     coordinated omission.
2. **Windows:** 10 s warmup (discarded) + 60 s measurement per stage. The
   ceiling stage runs warmup and measurement as separate k6 runs. The
   latency stage runs them as **one continuous k6 arrival stream** (a
   tagged warmup phase flowing directly into the measured phase, only the
   measured phase reported): an idle gap between separate k6 processes was
   observed to stall PostgREST's GHC idle GC and collapse the following
   window (a fresh server sustained the same rate cleanly), so the gap must
   not exist — removed symmetrically for both servers. The warmup phase
   **ramps linearly from 10% to 100%** of the shared rate: a cold server
   hit with the full rate at t=0 measures boot transients rather than
   steady state and can queue-spiral before it warms up. Additionally,
   every `bench.events` reset is followed by `ANALYZE` — `TRUNCATE` leaves
   stale planner stats, and a mis-planned first burst of UPDATEs was
   observed to saturate a cold server's pool. The measured phase uses its
   own pre-allocated VU pool, so its first requests may arrive on fresh TCP
   connections — identical for both servers by construction; server-side
   warmth (caches, pools, GC state) carries over regardless.
3. **Rounds:** the ceiling stage runs **once** per scenario per server (it
   calibrates the shared arrival rate; its number is reported but not
   averaged). The latency stage runs **3 interleaved rounds** per server
   with counterbalanced boot order (A/B, B/A, A/B) so neither server
   systematically gets a round's cooler first slot, averaging out thermal
   and background-load drift. The report shows the median across rounds
   with min–max spread.
4. **Parity probe (pre-flight):** before any measurement, the script issues
   one probe request per scenario to both servers and asserts the response
   bodies are equivalent (JSON-equal) and statuses identical. Benchmarking
   unequal work is worse than not benchmarking.
5. **Environment checks (pre-flight):** Postgres reachable; both servers pass
   a health probe; k6, `psql`, and the pinned PostgREST binary present. The
   report records hardware model, macOS version, Elixir/OTP, PostgreSQL
   version, PostgREST version, and date.
6. **Mutation hygiene:** `bench.events` is reset to the same baseline before
   every stage, for both servers. For the ceiling stage it is additionally
   reset between the warmup run and the measured run (self-paced warmups
   insert different amounts per server). The latency stage needs no
   mid-stream reset: both servers receive the same shared arrival rate with
   a zero-drop guarantee, so warmup insert counts — and therefore table
   state at the measured window's start — are equal by construction.

### Abort conditions

The run aborts loudly (non-zero exit, no report written) if:

- either server fails its health probe,
- the parity probe diverges,
- any measurement stage records a non-2xx response,
- any latency stage drops iterations or misses the shared arrival rate by
  more than 5% — k6 sheds load when its VU pool saturates, which silently
  degrades the open-loop stage into a closed-loop one; that voids the
  "both servers measured at the same arrival rate" guarantee. If this guard
  fires, raise the VU pool (or lower the 70% fraction) rather than removing
  the guard, and record the change here.

## Harness layout

```
bench/http/
  run.sh            # the one command: prereqs → DB load → rounds → report
  fixtures.sql      # bench schema + seed data + bench_anon role
  start_bier.exs    # Bier runner for MIX_ENV=prod mix run --no-halt
  postgrest.conf    # pinned PostgREST configuration
  scenarios.js      # k6 script; scenario + stage selected via env vars
  report.exs        # folds k6 JSON summaries → REPORT.md
  bin/              # downloaded postgrest binary (gitignored)
  results/          # raw k6 JSON summaries (gitignored)
  REPORT.md         # committed, generated; style follows bench/REPORT.md
```

- `run.sh --smoke` runs the full pipeline with 5-second windows and 1 round —
  an under-two-minute end-to-end validation of the harness itself.
- `run.sh` (full) is expected to take roughly 50–60 minutes:
  ceiling stages 4 scenarios × 2 servers × ~70 s, plus latency stages
  4 scenarios × 2 servers × 3 rounds × ~70 s, plus DB resets.

## Report

`bench/http/REPORT.md`, generated by `report.exs` from the raw k6 JSON,
committed to the repo. Contents:

1. **Environment block** — hardware, OS, versions, date.
2. **One table per scenario** — max RPS (ceiling), p50/p90/p99 latency at the
   shared fixed arrival rate, error counts (must be 0), and the
   Bier:PostgREST ratio for each metric.
3. **Methodology recap** — condensed from this spec, so the report stands
   alone and future releases (0.2.0, …) can be re-measured identically.

The report states its conclusion plainly: whichever server is faster, by how
much, per scenario — no marketing framing. If PostgREST wins a scenario, the
report says so.

## Error handling summary

- Prereq failures → actionable message (e.g. "k6 not found: brew install k6").
- Server boot failures → dump the server's captured stdout/stderr tail.
- Mid-run failures → partial results left in `results/` for inspection;
  REPORT.md is only written from a complete, error-free run.

## Testing the harness

- `--smoke` mode (above) is the harness's own integration test.
- `report.exs` is pure (JSON in → markdown out) and can be sanity-checked
  against a saved fixture summary if it grows logic worth guarding.
