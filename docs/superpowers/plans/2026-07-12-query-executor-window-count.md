# Query Executor: drop the unconsumed window count Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop emitting `count(*) OVER()` in read queries whose `Prefer: count=` mode never consumes it, so PostgreSQL can use top-N sorts / early-terminating index scans — closing the R2 benchmark gap (Bier p50 2.44 ms vs PostgREST 0.85 ms) without any observable behavior change.

**Architecture:** `Bier.QueryExecutor` builds one SQL statement per read. Today every read carries `count(*) OVER() AS _bier_full_count`, which forces Postgres to materialize the *entire* filtered set through a WindowAgg before `LIMIT` applies. Downstream, that count is only consumed when `count_mode` is `:exact` or `:estimated` (`resolve_count/9`); for `:none` (the default) and `:planned` it is computed and discarded (`Bier.Response.render/7` derives page rows from the JSON body and sets `total = nil`). The fix threads `count_mode` into the SQL builders and emits the window only when needed, replacing the outer `coalesce(max(...), 0)` with a cheap `count(*)` (page rows) so the two-column result contract `[[body, count]]` is unchanged.

**Tech Stack:** Elixir 1.19.5 / OTP 28, Postgrex, local PostgreSQL (conformance `bier_test` DB, bench `bier_bench` DB).

## Evidence (why this is the fix)

`EXPLAIN (ANALYZE)` on `bier_bench` for the R2 request (`GET /items?category=eq.X&order=id.desc&limit=25`, 5,000 rows per category):

- Current shape (window count): Bitmap Heap Scan 5,000 rows → Sort 5,000 rows → WindowAgg → Limit 25. **Execution 8.3 ms.**
- Same query without the window: Index Scan Backward on `items_pkey`, stops after 25 matching rows. **Execution 0.2–0.3 ms** (LIMIT can stay outside the ordered subquery — verified the planner still pushes it down once the window is gone).

R1 (single row by PK) shows parity because its filtered set is 1 row, so the window is free — matching the benchmark report exactly. Writes don't use this path.

## Global Constraints

- Never edit `spec/**` or the frozen harness under `test/support/**`; new **additive** unit-test files under `test/bier/` follow existing repo practice (e.g. `test/bier/geojson_test.exs`).
- The full conformance suite (`mix test`, requires local Postgres) must stay green after every task.
- Two-column read-result contract is frozen: every built read query returns one row `[body, full_count]` (`test/bier/geojson_test.exs:25` pattern-matches it).
- Existing public arities must keep working: `Bier.QueryExecutor.build/2..4` callers (`lib/bier/plan.ex:23`, `test/bier/geojson_test.exs:22,42`) must compile and pass unchanged.
- No new dependencies. `mix precommit` (format, hex.audit, compile --warnings-as-errors, credo --strict, docs, test) must pass before push.
- Do not change `bench/http/fixtures.sql` (adding indexes to make the benchmark look better is out of scope — the win must come from Bier's SQL).

## Out of scope (deliberately)

- Prepared-statement caching (`Postgrex` `:cache_statement`): R1 p50 already matches PostgREST without it, and caching by generated SQL text is attacker-influenced cardinality per connection. Revisit only with measurements.
- Regenerating `bench/http/REPORT.md`: the citable 3-round run is executed by the user after this lands.

---

### Task 1: Table-read path — emit the window count only for `:exact`/`:estimated`

**Files:**
- Modify: `lib/bier/query_executor.ex` (`State` struct ~line 26, `run/5` ~line 60, `build/4` ~line 443, `build_simple/3` ~line 530, `build_advanced/3` ~line 577)
- Test: `test/bier/query_executor_count_test.exs` (new)

**Interfaces:**
- Consumes: existing `Bier.QueryParser.parse_request/1`, `Bier.Introspection.run/2`, `Bier.ConformanceServer.base_opts/0` (test-only, `test/support/`).
- Produces: `Bier.QueryExecutor.build(relation, plan, relations \\ %{}, format \\ :json, count_mode \\ :none)` — a 5th optional arg; `%State{}` gains `full_count?: boolean` (default `true` so untouched call sites — `build_representation/4`, `build_function/5` — keep today's SQL until Tasks 2–3). Helpers `window_count_col/1` and `full_count_col/1` (private).

- [ ] **Step 1: Write the failing test**

Create `test/bier/query_executor_count_test.exs`:

```elixir
defmodule Bier.QueryExecutorCountTest do
  # The full-set window count (`count(*) OVER()`) must be emitted only when the
  # `Prefer: count=` mode consumes it (:exact/:estimated). For :none (the
  # default) and :planned it forces Postgres to materialize the whole filtered
  # set through a WindowAgg before LIMIT applies, defeating top-N plans.
  use ExUnit.Case, async: false

  setup_all do
    opts = Bier.ConformanceServer.base_opts()
    conn_opts = Keyword.take(opts, [:hostname, :port, :database, :username, :password])
    {:ok, conn} = Postgrex.start_link(conn_opts)
    rels = Bier.Introspection.run(conn, ["test"])
    %{conn: conn, rels: rels, projects: rels[{"test", "projects"}]}
  end

  test "count=none omits the window count", %{projects: projects, rels: rels} do
    {:ok, plan} = Bier.QueryParser.parse_request("id=gt.0&limit=2")

    assert {:ok, sql, _params} = Bier.QueryExecutor.build(projects, plan, rels, :json, :none)
    refute sql =~ "OVER()"
    assert sql =~ "count(*) AS full_count"
  end

  test "count=planned omits the window count", %{projects: projects, rels: rels} do
    {:ok, plan} = Bier.QueryParser.parse_request("id=gt.0&limit=2")

    assert {:ok, sql, _params} = Bier.QueryExecutor.build(projects, plan, rels, :json, :planned)
    refute sql =~ "OVER()"
  end

  test "count=exact and count=estimated keep the window count", %{projects: projects, rels: rels} do
    {:ok, plan} = Bier.QueryParser.parse_request("id=gt.0&limit=2")

    for mode <- [:exact, :estimated] do
      assert {:ok, sql, _params} = Bier.QueryExecutor.build(projects, plan, rels, :json, mode)
      assert sql =~ "count(*) OVER() AS _bier_full_count"
      assert sql =~ "coalesce(max(_postgrest_t._bier_full_count), 0) AS full_count"
    end
  end

  test "build/4 default (count=none) omits the window count", %{projects: projects, rels: rels} do
    {:ok, plan} = Bier.QueryParser.parse_request("")

    assert {:ok, sql, _params} = Bier.QueryExecutor.build(projects, plan, rels)
    refute sql =~ "OVER()"
  end

  test "the advanced (embed) path honors the count mode", %{projects: projects, rels: rels} do
    {:ok, plan} = Bier.QueryParser.parse_request("select=id,clients(id)&limit=2")

    assert {:ok, none_sql, _} = Bier.QueryExecutor.build(projects, plan, rels, :json, :none)
    refute none_sql =~ "OVER()"

    assert {:ok, exact_sql, _} = Bier.QueryExecutor.build(projects, plan, rels, :json, :exact)
    assert exact_sql =~ "count(*) OVER() AS _bier_full_count"
  end

  test "no-window query executes and returns the same body", %{
    conn: conn,
    projects: projects,
    rels: rels
  } do
    {:ok, plan} = Bier.QueryParser.parse_request("id=gt.0&order=id.asc&limit=2")

    {:ok, none_sql, none_params} = Bier.QueryExecutor.build(projects, plan, rels, :json, :none)
    {:ok, exact_sql, exact_params} = Bier.QueryExecutor.build(projects, plan, rels, :json, :exact)

    %Postgrex.Result{rows: [[none_body, page_count]]} =
      Postgrex.query!(conn, none_sql, none_params)

    %Postgrex.Result{rows: [[exact_body, full_count]]} =
      Postgrex.query!(conn, exact_sql, exact_params)

    assert none_body == exact_body
    assert page_count == 2
    assert full_count >= page_count
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/bier/query_executor_count_test.exs`
Expected: FAIL — `UndefinedFunctionError` for `Bier.QueryExecutor.build/5` on the 5-arg calls, and the `build/4` default test fails its `refute sql =~ "OVER()"` assertion.

- [ ] **Step 3: Implement**

In `lib/bier/query_executor.ex`:

3a. Add the flag to `State` (line ~40, after `format: :json`):

```elixir
              # Output aggregation: :json (a JSON array) or :geojson (a GeoJSON
              # FeatureCollection built with ST_AsGeoJSON).
              format: :json,
              # Whether the query must carry the full (pre-LIMIT) row count via
              # `count(*) OVER()`. Only `Prefer: count=exact|estimated` consume
              # it; emitting it unconditionally forces the whole filtered set
              # through a WindowAgg before LIMIT, defeating top-N plans.
              full_count?: true
```

3b. Extend `build` (line ~443) with a `count_mode` arg:

```elixir
  @doc false
  def build(relation, plan, relations \\ %{}, format \\ :json, count_mode \\ :none)

  def build(%Relation{} = relation, plan, relations, format, count_mode) do
    state = %State{
      relation: relation,
      relations: relations,
      alias_name: relation.name,
      embed_orders: plan[:embed_orders] || %{},
      embed_limits: plan[:embed_limits] || %{},
      embed_offsets: plan[:embed_offsets] || %{},
      format: format,
      full_count?: count_mode in [:exact, :estimated]
    }
    ...
```

(the `try/with` body below is unchanged)

3c. In `run/5` (line ~66), pass the mode through:

```elixir
    with {:ok, sql, params} <-
           Bier.ServerTiming.measure(:plan, fn ->
             build(relation, plan, relations, format, count_mode)
           end) do
```

3d. Make the two shapes conditional. Add two private helpers next to `row_json/1` (~line 565):

```elixir
  defp window_count_col(%State{full_count?: true}),
    do: ", count(*) OVER() AS _bier_full_count"

  defp window_count_col(%State{}), do: ""

  # Without the window, `full_count` degrades to the page-row count — callers
  # on the no-window modes ignore it (Response derives page rows from the body).
  defp full_count_col(%State{full_count?: true}),
    do: "coalesce(max(_postgrest_t._bier_full_count), 0) AS full_count"

  defp full_count_col(%State{}), do: "count(*) AS full_count"
```

In `build_simple/3` replace the `paged`/`sql` construction:

```elixir
    paged =
      "SELECT #{row_json(state.format)} AS _bier_row#{window_count_col(state)} " <>
        "FROM (#{cols}) _bier_cols" <> limit_sql

    sql =
      "SELECT #{aggregate_body(state.format)} AS body, " <>
        "#{full_count_col(state)} " <>
        "FROM (#{paged}) _postgrest_t"
```

In `build_advanced/3` replace the `inner`/`sql` construction:

```elixir
    inner =
      "SELECT #{row_expr} AS __row__#{window_count_col(state)} FROM #{aliased_from}" <>
        where_sql <> group_sql <> having <> order_sql <> limit_sql

    sql =
      "SELECT coalesce(json_agg(_postgrest_t.__row__), '[]')::text AS body, " <>
        "#{full_count_col(state)} " <>
        "FROM (#{inner}) _postgrest_t"
```

Also update the `@moduledoc` shape sketch (lines 7–12) to note the window count is emitted only for `count=exact|estimated`.

- [ ] **Step 4: Run the new test to verify it passes**

Run: `mix test test/bier/query_executor_count_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 5: Run the full suite (conformance is the ground truth)**

Run: `mix test`
Expected: PASS — same count as on `main` (~475 active conformance cases + unit tests), 0 failures. Pay attention to `--only area:pagination`-adjacent cases (counts, Content-Range, 206/416) and the plan media-type cases (1625–1628): they assert status/headers only, not SQL shape, so they must stay green.

- [ ] **Step 6: Format and commit**

```bash
mix format
git add lib/bier/query_executor.ex test/bier/query_executor_count_test.exs
git commit -m "perf(executor): emit count(*) OVER() only for count=exact/estimated

The window count forces the whole filtered set through a WindowAgg before
LIMIT applies (R2 bench: 8.3ms vs 0.3ms for a 25-row page over a 5k-row
category). Prefer: count=none (the default) and count=planned never consume
it: Response derives page rows from the body and planned uses EXPLAIN.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: RPC read path — same conditional for `/rpc/<fn>` GET reads

**Files:**
- Modify: `lib/bier/query_executor.ex` (`run_function/6` ~line 268, `build_function/5` ~line 306)
- Test: `test/bier/query_executor_count_test.exs` (extend)

**Interfaces:**
- Consumes: `%State{full_count?: ...}` and helpers from Task 1.
- Produces: `build_function/6` becomes `@doc false def build_function(fn_def, ret_relation, args, plan, relations, count_mode \\ :none)` (public, test-visible — mirrors the existing `@doc false` `build/5` and `build_count_query/3`). `run_function/6` threads its existing `count_mode` into it. For RPC, `count_for/2` consumes the window for **every** non-`:none` mode, so `full_count?: count_mode != :none`.

- [ ] **Step 1: Write the failing test**

Append to `test/bier/query_executor_count_test.exs`:

```elixir
  test "RPC build honors the count mode", %{projects: projects, rels: rels} do
    {:ok, plan} = Bier.QueryParser.parse_request("limit=5")
    fn_def = %{schema: "test", name: "getallprojects"}

    assert {:ok, none_sql, _} =
             Bier.QueryExecutor.build_function(fn_def, projects, [], plan, rels, :none)

    refute none_sql =~ "OVER()"

    assert {:ok, exact_sql, _} =
             Bier.QueryExecutor.build_function(fn_def, projects, [], plan, rels, :exact)

    assert exact_sql =~ "count(*) OVER() AS _bier_full_count"
  end
```

(`build_function` only quotes the schema/function names into SQL — the test never executes it, so it works regardless of fixture functions.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/bier/query_executor_count_test.exs`
Expected: FAIL — `Bier.QueryExecutor.build_function/6` is undefined (currently a private 5-arg function).

- [ ] **Step 3: Implement**

In `lib/bier/query_executor.ex`:

3a. `run_function/6` (~line 273): pass the mode to the builder:

```elixir
      case Bier.ServerTiming.measure(:plan, fn ->
             build_function(fn_def, ret_relation, args, plan, relations, count_mode)
           end) do
```

3b. Make `build_function` public with the extra arg and set the flag (~line 306):

```elixir
  @doc false
  # RPC reads consume the window count for every non-:none mode (`count_for/2`
  # returns it for :exact/:planned/:estimated alike), so gate on :none only.
  def build_function(fn_def, ret_relation, args, plan, relations, count_mode \\ :none) do
```

and inside the `state = %State{...}` construction add:

```elixir
      from_override: from,
      params: arg_state.params,
      count: arg_state.count,
      full_count?: count_mode != :none
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/bier/query_executor_count_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 5: Run the RPC conformance area, then the full suite**

Run: `mix test --only area:rpc && mix test`
Expected: PASS both (RPC pagination cases with `Prefer: count=exact` exercise the windowed branch; default-count RPC cases exercise the new no-window branch).

- [ ] **Step 6: Format and commit**

```bash
mix format
git add lib/bier/query_executor.ex test/bier/query_executor_count_test.exs
git commit -m "perf(executor): drop the window count from count=none RPC reads

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Mutation representation path — the window there is always dead weight

**Files:**
- Modify: `lib/bier/query_executor.ex` (`build_representation/4` ~line 378)
- Test: `test/bier/query_executor_count_test.exs` (extend)

**Interfaces:**
- Consumes: `%State{full_count?: ...}` from Task 1.
- Produces: no signature change. `build_representation/4` wraps `repr_sql` as `SELECT (SELECT body FROM (repr_sql) _bier_repr) AS body, (SELECT count(*) FROM pgrst_source) AS count, (…) AS meta` — it selects **only** `body` from `repr_sql`, so the inner window column has never been readable. Set `full_count?: false` unconditionally.

- [ ] **Step 1: Write the failing test**

Append to `test/bier/query_executor_count_test.exs`:

```elixir
  test "mutation representation never carries a window count", %{projects: projects, rels: rels} do
    {:ok, plan} = Bier.QueryParser.parse_request("select=id,name")
    source = {"INSERT INTO \"test\".\"projects\" (\"name\") VALUES ($1) RETURNING *", ["x"]}

    assert {:ok, sql, _params} =
             Bier.QueryExecutor.build_representation(projects, plan, rels, source)

    refute sql =~ "OVER()"
    assert sql =~ "(SELECT count(*) FROM pgrst_source) AS count"
  end
```

(Build-only: the SQL is never executed here; the mutation conformance areas execute the real thing in Step 5.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/bier/query_executor_count_test.exs`
Expected: FAIL — `refute sql =~ "OVER()"` (the representation query still embeds `count(*) OVER()` because `State` defaults to `full_count?: true`).

- [ ] **Step 3: Implement**

In `build_representation/4` (~line 381) add the flag to the state construction:

```elixir
    state = %State{
      relation: relation,
      relations: relations,
      alias_name: relation.name,
      embed_orders: plan[:embed_orders] || %{},
      embed_limits: plan[:embed_limits] || %{},
      embed_offsets: plan[:embed_offsets] || %{},
      from_override: cte,
      params: Enum.reverse(source_params),
      count: length(source_params),
      # Only `body` is selected out of the representation subquery; the mutated
      # row count comes from the `(SELECT count(*) FROM pgrst_source)` sibling.
      full_count?: false
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/bier/query_executor_count_test.exs`
Expected: PASS (8 tests).

- [ ] **Step 5: Run the mutation conformance areas, then the full suite**

Run: `mix test --only area:insertions && mix test --only area:updates && mix test --only area:deletions && mix test`
Expected: PASS all (if an area tag above doesn't exist, `mix test` alone is authoritative — check tags with `grep -rh "area:" spec/conformance/cases/*.yaml | sort -u` first).

- [ ] **Step 6: Format and commit**

```bash
mix format
git add lib/bier/query_executor.ex test/bier/query_executor_count_test.exs
git commit -m "perf(executor): drop the dead window count from mutation representations

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: End-to-end verification — CI gates + live R2 latency check

**Files:**
- No source changes. Uses `bench/http/start_bier.exs`, the `bier_bench` DB, and `psql`.

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: evidence (recorded in the PR description) that R2 latency dropped and nothing else moved.

- [ ] **Step 1: Run every CI gate**

Run: `mix precommit`
Expected: all gates PASS (deps.unlock check, format, hex.audit, compile --warnings-as-errors, credo --strict, docs, full test suite).

- [ ] **Step 2: Confirm the new plan shape against the bench DB**

Reload bench fixtures if needed (`createdb bier_bench 2>/dev/null; psql -X -q -v ON_ERROR_STOP=1 -d bier_bench -f bench/http/fixtures.sql`), then EXPLAIN the exact SQL Bier now generates for R2. Print it from the repo (uses the introspection of the live bench DB):

```bash
BENCH_DB_URI="postgres://$(whoami)@localhost:5432/bier_bench" mix run -e '
  {:ok, conn} = Postgrex.start_link(database: "bier_bench")
  rels = Bier.Introspection.run(conn, ["bench"])
  items = rels[{"bench", "items"}]
  {:ok, plan} = Bier.QueryParser.parse_request("category=eq.category-07&order=id.desc&limit=25")
  {:ok, sql, params} = Bier.QueryExecutor.build(items, plan, rels, :json, :none)
  IO.puts(sql)
  {:ok, %{rows: [[_body, _]]}} = Postgrex.query(conn, sql, params)
  {:ok, %{rows: rows}} = Postgrex.query(conn, "EXPLAIN (ANALYZE, COSTS OFF) " <> sql, params)
  Enum.each(rows, fn [l] -> IO.puts(l) end)
'
```

Expected: no `OVER()` in the printed SQL; the plan shows `Index Scan Backward using items_pkey` (or a top-N sort) with **no WindowAgg node** and execution time well under 1 ms (was 8.3 ms).

- [ ] **Step 3: Live HTTP smoke of the R2 endpoint**

Terminal A (from repo root):

```bash
BENCH_DB_URI="postgres://$(whoami)@localhost:5432/bier_bench" BIER_PORT=3001 \
  MIX_ENV=prod mix run --no-halt bench/http/start_bier.exs
```

Terminal B:

```bash
for i in $(seq 1 200); do
  curl -s -o /dev/null -w "%{time_total}\n" \
    "http://127.0.0.1:3001/items?category=eq.category-07&order=id.desc&limit=25"
done | sort -n | awk '{a[NR]=$1} END {print "p50", a[int(NR*0.5)]*1000, "ms; p99", a[int(NR*0.99)]*1000, "ms"}'
# And confirm correctness + headers didn't change:
curl -si "http://127.0.0.1:3001/items?category=eq.category-07&order=id.desc&limit=25" | head -20
curl -si -H "Prefer: count=exact" "http://127.0.0.1:3001/items?category=eq.category-07&limit=25" | grep -i content-range
```

Expected: p50 well under 1 ms (was ~2.4 ms under load; unloaded curl should show <1 ms), body is a 25-element JSON array ordered by `id` descending, `Content-Range: 0-24/*` without the Prefer header and `Content-Range: 0-24/5000` with `count=exact`. (Env var names/ports: check the header of `bench/http/start_bier.exs` and mirror what `bench/http/run.sh` exports around its line 101 if these differ.)

- [ ] **Step 4: Commit nothing — hand back for the citable benchmark run**

The user reruns `bench/http/run.sh` (3-round citable run) and regenerates `REPORT.md`. Do not edit `REPORT.md` by hand (it is generated).
