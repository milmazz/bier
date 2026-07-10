# geo+json broadening (#63) + compact advanced-path JSON (#31) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the advanced read path (embeds/aggregates/spread) to project named columns into a derived table so it renders PostgREST's compact JSON bytes (#31) and supports `ST_AsGeoJSON` (#63 advanced path), then offer the `:geojson` producer on mutations and RPC (#63 gap 1).

**Architecture:** `Bier.Embed.build_row_object/6` becomes `build_row_select/6`, returning `{cols, laterals, state}` where `cols` are `{expr, out_name}` pairs and `laterals` are `LEFT JOIN LATERAL` clauses (spread only). `Bier.QueryExecutor.build_advanced` adopts `build_simple`'s three-layer shape (inner named projection → paged `row_json(format)` + count window → `aggregate_body(format)`), making the existing `:geojson` format work on both paths. Mutations and RPC then negotiate against the postgis-gated producer list and thread `format:` into the SQL builders.

**Tech Stack:** Elixir 1.20 / OTP 29, Postgrex, PostGIS, PostgREST 14.12 binary (`bench/http/bin/postgrest`) for live verification.

**Spec:** `docs/superpowers/specs/2026-07-10-geojson-broadening-design.md`

## Global Constraints

- Never edit `test/conformance/**`, `test/support/**`, or `spec/**` (frozen ground truth). New tests go in `test/bier/*_test.exs`.
- `mix test` must stay at baseline: **0 failures** locally (PostGIS is installed).
- All user values reach SQL as bound parameters or single-quote-escaped literals; identifiers via `QueryExecutor.quote_ident/1`.
- Output aliases go through `quote_ident` (PostgreSQL truncates identifiers at 63 bytes — same constraint PostgREST has; acceptable).
- Branch: `geojson-broadening-31-63` (already created). Commit after every green step.
- Working dir: `/Users/milmazz/Dev/elixir-lang/bier`. Run single files with `mix test test/bier/<file>.exs` (the `mix test` alias reloads fixtures first — that is expected and needed after Task 2's fixture change).

---

### Task 1: Compact restructure of the advanced path (#31)

**Files:**
- Test (create): `test/bier/compact_json_test.exs`
- Modify: `lib/bier/embed.ex` (row builder, embed rendering, spread, delete `spread_expr/4`, `null_template/2`, `json_pair/2`)
- Modify: `lib/bier/query_executor.ex:572-625` (`build_advanced/3`), comment at `lib/bier/query_executor.ex:553-561` (`row_json/1`)

**Interfaces:**
- Consumes: existing `Embed` helpers (`field_expr/3`, `star_col_expr/3`, `from_clause/4`, `build_embed_where/6`, `build_order_advanced/6`, `pop_embed_*`), `QueryExecutor` (`row_json/1`, `aggregate_body/1`, `quote_ident/1`).
- Produces: `Bier.Embed.build_row_select(nodes, relation, al, embed_filters, state, qe) :: {[{expr :: String.t(), out_name :: String.t()}], [lateral :: String.t()], state}` and `Bier.Embed.render_cols([{expr, name}]) :: String.t()`. Task 2–4 rely on `build_advanced` honoring `state.format` (`:json` | `:geojson`).

- [ ] **Step 1: Write the failing byte-exactness tests**

Create `test/bier/compact_json_test.exs`:

```elixir
defmodule Bier.CompactJsonTest do
  # Issue #31: the read paths must render PostgREST v14.12's exact wire bytes,
  # live-captured from the real binary (see the spec's §0 whitespace profile):
  # compact row objects separated by `, \n ` (json_agg over a record), embed
  # internals in jsonb style (`": "`, `", "`, keys jsonb-normalized), spread
  # columns compact at the parent level. json_build_object's `"k" : v` and a
  # bare ::jsonb cast both diverge, hence exact-string assertions.
  use ExUnit.Case, async: false

  setup_all do
    opts = Bier.ConformanceServer.base_opts()
    conn_opts = Keyword.take(opts, [:hostname, :port, :database, :username, :password])
    {:ok, conn} = Postgrex.start_link(conn_opts)
    rels = Bier.Introspection.run(conn, ["test"])
    %{conn: conn, rels: rels}
  end

  defp body!(conn, rels, relation, query) do
    {:ok, plan} = Bier.QueryParser.parse_request(query)
    {:ok, sql, params} = Bier.QueryExecutor.build(rels[{"test", relation}], plan, rels)
    %Postgrex.Result{rows: [[body, _count]]} = Postgrex.query!(conn, sql, params)
    body
  end

  test "flat rows separate with comma-newline (simple path)", %{conn: conn, rels: rels} do
    body = body!(conn, rels, "projects", "select=id,name&order=id&limit=2")
    assert body == ~s([{"id":1,"name":"Windows 7"}, \n {"id":2,"name":"Windows 10"}])
  end

  test "to-one embed renders jsonb-style internals", %{conn: conn, rels: rels} do
    body = body!(conn, rels, "projects", "select=id,name,clients(name)&order=id&limit=2")

    assert body ==
             ~s([{"id":1,"name":"Windows 7","clients":{"name": "Microsoft"}}, \n ) <>
               ~s({"id":2,"name":"Windows 10","clients":{"name": "Microsoft"}}])
  end

  test "embed keys are jsonb-normalized (order + spacing)", %{conn: conn, rels: rels} do
    # Select order is name,id — jsonb re-sorts to id,name, exactly as PostgREST.
    body = body!(conn, rels, "projects", "select=id,clients(name,id)&order=id&limit=1")
    assert body == ~s([{"id":1,"clients":{"id": 1, "name": "Microsoft"}}])
  end

  test "to-many embed renders jsonb elements with comma-space", %{conn: conn, rels: rels} do
    body =
      body!(conn, rels, "projects", "select=name,tasks(name)&order=id&limit=1&tasks.order=id")

    assert body ==
             ~s([{"name":"Windows 7","tasks":[{"name": "Design w7"}, {"name": "Code w7"}]}])
  end

  test "empty to-many embed renders []", %{conn: conn, rels: rels} do
    body = body!(conn, rels, "projects", "select=id,tasks(name)&id=eq.5")
    assert body == ~s([{"id":5,"tasks":[]}])
  end

  test "missing to-one embed renders null", %{conn: conn, rels: rels} do
    body = body!(conn, rels, "projects", "select=id,clients(name)&id=eq.5")
    assert body == ~s([{"id":5,"clients":null}])
  end

  test "aggregate with implicit group-by renders compact rows", %{conn: conn, rels: rels} do
    body = body!(conn, rels, "projects", "select=client_id,id.count()&order=client_id")

    assert body ==
             ~s([{"client_id":1,"count":2}, \n {"client_id":2,"count":2}, \n ) <>
               ~s({"client_id":null,"count":1}])
  end

  test "to-one spread renders compact parent-level columns", %{conn: conn, rels: rels} do
    body = body!(conn, rels, "projects", "select=id,...clients(client_name:name)&order=id&limit=1")
    assert body == ~s([{"id":1,"client_name":"Microsoft"}])
  end

  test "to-one spread of a missing row renders null columns", %{conn: conn, rels: rels} do
    body = body!(conn, rels, "projects", "select=id,...clients(client_name:name)&id=eq.5")
    assert body == ~s([{"id":5,"client_name":null}])
  end

  test "to-many spread aggregates each column into an array", %{conn: conn, rels: rels} do
    body =
      body!(
        conn,
        rels,
        "projects",
        "select=id,...tasks(task_names:name)&order=id&limit=1&tasks.order=id"
      )

    assert body == ~s([{"id":1,"task_names":["Design w7", "Code w7"]}])
  end
end
```

- [ ] **Step 2: Run the new file to verify it fails on spacing**

Run: `mix test test/bier/compact_json_test.exs`
Expected: **all 11 tests FAIL** — advanced-path bodies contain json_build_object's `" : "` spacing, and the flat/simple-path test is missing the `, \n ` row separator. If any test fails for a different reason (parse error, SQL error), stop and fix the test, not `lib/`.

- [ ] **Step 3: Rewrite the row builder in `lib/bier/embed.ex`**

Replace `build_row_object/6` (lines 28–59) with:

```elixir
  @doc """
  Build the named select list for a single row of `relation` (aliased as `al`),
  given the select `nodes`. Returns `{cols, laterals, state}`: `cols` is a list
  of `{expr, out_name}` pairs (rendered with `render_cols/1`), `laterals` is a
  list of ` LEFT JOIN LATERAL (...) ON true` clauses contributed by spread
  embeds. Rendering the row with `to_json(<derived table>)` (instead of
  `json_build_object`) matches PostgREST's compact wire bytes — see issue #31.
  `embed_filters` maps embed paths to filter nodes. `qe` is the executor module
  (passed to avoid a compile cycle).
  """
  def build_row_select(nodes, %Relation{} = relation, al, embed_filters, state, qe) do
    {entries, state} =
      Enum.flat_map_reduce(nodes, state, fn node, st ->
        build_node(node, relation, al, embed_filters, st, qe)
      end)

    Enum.reduce(entries, {[], [], state}, fn
      {:spread_cols, spread_cols, lateral}, {cols, lats, st} ->
        {cols ++ spread_cols, lats ++ [lateral], st}

      {_expr, _name} = col, {cols, lats, st} ->
        {cols ++ [col], lats, st}
    end)
  end

  @doc false
  # Render `{expr, out_name}` pairs as a SQL select list.
  def render_cols(cols) do
    Enum.map_join(cols, ", ", fn {expr, name} -> "#{expr} AS #{QE.quote_ident(name)}" end)
  end
```

Convert the node builders from `json_pair` strings to `{expr, name}` tuples:

- `star_pairs/2` becomes:

```elixir
  defp star_pairs(relation, al) do
    Enum.map(relation.columns, fn c ->
      {star_col_expr(relation, al, c.name), c.name}
    end)
  end
```

- the `:field` clause: `{[{expr, name}], state}` (expr/name computed exactly as today, just swapping the pair order into a tuple).
- the `:agg` clause: `{[{inner, name}], state}`.
- the `empty: true` embed clause: unchanged (`{[], state}`).

- [ ] **Step 4: Rewrite `build_embed/7` (embeds + spread) in `lib/bier/embed.ex`**

Replace the body from the child-object build down (keep the segment/filter/order routing at the top unchanged). The child now renders as a named projection; `:one` wraps with `to_json`, `:many` with `json_agg` over the derived table; spread becomes a LATERAL join with pulled-up columns:

```elixir
    {child_cols, child_laterals, state} =
      build_row_select(e.select, target, child_alias, deeper_filters, child_scope, qe)

    state = struct!(state, saved)

    {where_sql, state} =
      build_embed_where(join, own_filters, child_alias, src_alias, state, qe)

    {order_sql, state} =
      build_order_advanced(own_order, e.select, target, child_alias, state, qe)

    page_sql = paginate_sql(own_limit, own_offset)

    from = from_clause(target, child_alias, rel, src_alias)
    lateral_sql = Enum.join(child_laterals, "")
    child_select = child_select_list(child_cols)

    if e.spread do
      spread_entry(kind, child_cols, child_select, from, lateral_sql, where_sql, order_sql, page_sql, state)
    else
      # Embed internals go through jsonb (to_jsonb / json_agg(to_jsonb(…))):
      # PostgREST renders embedded objects jsonb-style — `": "` spacing and
      # jsonb key normalization — while parent rows stay compact. Live-verified
      # against PostgREST 14.12 (spec §0).
      sub =
        case kind do
          :one ->
            inner =
              "SELECT #{child_select} FROM #{from}#{lateral_sql}#{where_sql}#{order_sql} LIMIT 1"

            "(SELECT to_jsonb(_bier_c) FROM (#{inner}) _bier_c)"

          :many ->
            inner =
              "SELECT #{child_select} FROM #{from}#{lateral_sql}#{where_sql}#{order_sql}#{page_sql}"

            "COALESCE((SELECT json_agg(to_jsonb(_bier_c)) FROM (#{inner}) _bier_c), '[]'::json)"
        end

      {[{sub, out_name}], state}
    end
  end

  # A child select that projects no columns (e.g. every node is an empty
  # embed) still renders `{}` rows, as json_build_object() did.
  defp child_select_list([]), do: "'{}'::json AS _bier_empty_row"
  defp child_select_list(cols), do: render_cols(cols)
```

Note: when `child_cols == []`, `:one` renders `to_json(_bier_c)` over the single `_bier_empty_row` column — that would wrap as `{"_bier_empty_row":{}}`, which is wrong. Guard the `:one`/`:many` wrappers:

```elixir
          :one when child_cols == [] ->
            inner = "SELECT 1 FROM #{from}#{where_sql}#{order_sql} LIMIT 1"
            "(SELECT '{}'::json FROM (#{inner}) _bier_c)"

          :many when child_cols == [] ->
            inner = "SELECT 1 FROM #{from}#{where_sql}#{order_sql}#{page_sql}"
            "COALESCE((SELECT json_agg('{}'::json) FROM (#{inner}) _bier_c), '[]'::json)"
```

(Place these clauses before the general `:one`/`:many` clauses; a `case ... do` on `{kind, child_cols}` is the cleanest shape — implementer's choice, behavior as above.)

Add the spread builder (replaces `spread_expr/4` and `null_template/2`, which are **deleted**):

```elixir
  # Spread merges the embedded resource's columns into the parent row.
  # PostgREST implements this by pulling the child's columns up through a
  # LEFT JOIN LATERAL, so a missing to-one row contributes NULL columns (the
  # keys stay present, value null) with no COALESCE template needed. A to-many
  # spread aggregates each child column into a JSON array under its key
  # (PostgREST v12.1 semantics).
  defp spread_entry(kind, child_cols, child_select, from, lateral_sql, where_sql, order_sql, page_sql, state) do
    seq = state.embed_seq + 1
    state = %{state | embed_seq: seq}
    spr = QE.quote_ident("_bier_spr#{seq}")

    lateral =
      case kind do
        :one ->
          inner =
            "SELECT #{child_select} FROM #{from}#{lateral_sql}#{where_sql}#{order_sql} LIMIT 1"

          " LEFT JOIN LATERAL (#{inner}) #{spr} ON true"

        :many ->
          inner =
            "SELECT #{child_select} FROM #{from}#{lateral_sql}#{where_sql}#{order_sql}#{page_sql}"

          aggs =
            Enum.map_join(child_cols, ", ", fn {_expr, name} ->
              q = QE.quote_ident(name)
              "COALESCE(json_agg(_bier_s.#{q}), '[]'::json) AS #{q}"
            end)

          " LEFT JOIN LATERAL (SELECT #{aggs} FROM (#{inner}) _bier_s) #{spr} ON true"
      end

    cols = Enum.map(child_cols, fn {_expr, name} -> {"#{spr}.#{QE.quote_ident(name)}", name} end)
    {[{:spread_cols, cols, lateral}], state}
  end
```

Delete `spread_expr/4`, `null_template/2`, and `json_pair/2` (grep first: `json_pair` must have no remaining callers).

- [ ] **Step 5: Rewrite `build_advanced/3` in `lib/bier/query_executor.ex`**

Replace lines 572–625 with the three-layer shape (mirrors `build_simple`; the WHERE/order/group plumbing is unchanged, only the projection and wrapping change):

```elixir
  defp build_advanced(relation, plan, state) do
    al = state.alias_name
    aliased_from = "#{from_source(relation, state)} #{quote_ident(al)}"

    # A top-level filter whose column names a selected embed is a null-filter on
    # that embedded resource (semi/anti-join), not a real column filter.
    {null_embed_filters, column_filters} = split_embed_null_filters(plan.filters, plan.select)

    {cols, laterals, state} =
      Embed.build_row_select(
        plan.select,
        relation,
        al,
        plan.embed_filters || %{},
        state,
        __MODULE__
      )

    {where_sql, state} = build_where_aliased(column_filters, al, state)

    {inner_where, state} =
      Embed.inner_join_where(
        plan.select,
        relation,
        al,
        plan.embed_filters || %{},
        state,
        __MODULE__
      )

    {null_where, state} =
      Embed.null_filter_where(null_embed_filters, plan.select, relation, al, state, __MODULE__)

    where_sql = combine_where(where_sql, inner_where)
    where_sql = combine_where(where_sql, null_where)

    {group_sql, having} = Embed.group_by(plan.select, al)

    {order_sql, state} =
      Embed.build_order_advanced(plan.order, plan.select, relation, al, state, __MODULE__)

    {limit_sql, state} = build_limit(plan, state)

    # Project the named select list (embeds as correlated jsonb columns, spread
    # via LATERAL) into a derived table and thread the ROW RECORD through the
    # paged layer — json_agg over a record renders PostgREST's exact bytes
    # (compact rows, `, \n ` separators), and ST_AsGeoJSON consumes the same
    # record (issue #63). json_build_object would space `"k" : v` (issue #31).
    # Same shape as build_simple: order inside, count window + LIMIT/OFFSET one
    # level up.
    {select_list, row_expr} =
      case cols do
        [] -> {"1 AS _bier_dummy", "'{}'::json"}
        _ -> {Embed.render_cols(cols), row_json(state.format)}
      end

    inner =
      "SELECT #{select_list} FROM #{aliased_from}#{Enum.join(laterals, "")}" <>
        where_sql <> group_sql <> having <> order_sql

    paged =
      "SELECT #{row_expr} AS _bier_row, count(*) OVER() AS _bier_full_count " <>
        "FROM (#{inner}) _bier_cols" <> limit_sql

    sql =
      "SELECT #{aggregate_body(state.format)} AS body, " <>
        "coalesce(max(_postgrest_t._bier_full_count), 0) AS full_count " <>
        "FROM (#{paged}) _postgrest_t"

    {:ok, sql, Enum.reverse(state.params)}
  end
```

**Also change `row_json/1` itself** (`lib/bier/query_executor.ex:560-561`), which both paths share:

```elixir
  defp row_json(:geojson), do: "ST_AsGeoJSON(_bier_cols)::json"
  defp row_json(_format), do: "_bier_cols"
```

The `:json` case projects the bare **record** (not `to_json(_bier_cols)`): the outer `json_agg` then renders each row compactly AND separates rows with `, \n ` exactly like PostgREST (which aggregates its derived table directly). This intentionally also fixes the **simple** path, which until now aggregated a pre-rendered json value and silently dropped PostgREST's newline separator on every multi-row response. Update the big comment above `build_simple`'s `cols` binding (`lib/bier/query_executor.ex:531-537`) accordingly, and replace the now-stale final sentence of the `row_json` comment ("Only this flat path supports it…") with "Both the simple and advanced paths render through this expression; the advanced path's derived table carries embeds as jsonb columns, which ST_AsGeoJSON places into `properties`."

Do NOT try to strip or normalize `json_agg`'s whitespace anywhere — its native rendering IS PostgREST's wire format (PostgREST runs the same aggregate). In particular `aggregate_body/1` stays exactly as it is.

- [ ] **Step 6: Run the byte tests**

Run: `mix test test/bier/compact_json_test.exs`
Expected: **11 tests, 0 failures**.

- [ ] **Step 7: Run the full suite (conformance is the regression net)**

Run: `mix test`
Expected: **0 failures** (532-case suite; ~475 active). If embed/aggregate/spread cases fail, debug the generated SQL by printing it from the failing case's query via `Bier.QueryExecutor.build/4` in `iex -S mix`. Known risk areas: m2m junction FROM + LATERAL ordering (`FROM j, t LEFT JOIN LATERAL … ON true` — the lateral may only reference `t`, which is all spread needs), GROUP BY + ORDER BY staying in the inner query, and related-order correlated subqueries (inner query, `al` in scope).

- [ ] **Step 8: Run format + credo**

Run: `mix format && mix credo --strict`
Expected: clean. (`lib/bier/embed.ex` is analyzed; the generated parser is excluded but this file is not.)

- [ ] **Step 9: Commit**

```bash
git add lib/bier/embed.ex lib/bier/query_executor.ex test/bier/compact_json_test.exs
git commit -m "fix(#31): render advanced-path rows via named projection + to_json

json_build_object spaces \`\"k\" : v\` and the spread ::jsonb merge spaces
\`\"k\": v\`; both diverged from PostgREST's compact wire bytes. The advanced
path now projects a named select list into a derived table (spread via
LEFT JOIN LATERAL, matching PostgREST's SQL shape) and renders rows with
to_json, byte-compatible with PostgREST and consumable by ST_AsGeoJSON.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `geotest` fixtures + advanced-path geojson read coverage

**Files:**
- Modify: `lib/mix/tasks/bier.fixtures.load.ex:105-121` (`load_postgis_fixtures/2`)
- Modify: `test/bier/geojson_test.exs` (add advanced-path tests)
- Modify: `lib/bier/plugs/action_controller.ex:568-572` (stale `read_producers` comment only)

**Interfaces:**
- Consumes: Task 1's `build_advanced` honoring `state.format`.
- Produces: `geotest` schema — `geotest.shops(id int PK, address text, shop_geom geometry)`, `geotest.shop_bles(id int PK, name text, coords geometry, shop_id int FK→shops)`, `geotest.plain(id int PK, label text)` (no geometry), `geotest.get_shops() RETURNS SETOF geotest.shops`, `geotest.get_shop_geom(id int) RETURNS geometry`. Tasks 3–5 build HTTP tests and the live diff on these exact names.

- [ ] **Step 1: Extend the PostGIS fixture block**

In `load_postgis_fixtures/2`, append to the existing SQL string (after the `GRANT SELECT ON TABLE test.shops …` line):

```sql
    -- Isolated schema for geo+json feature tests (mutations/RPC/embeds).
    -- Deliberately NOT in the shared conformance instance's db_schemas, so
    -- the frozen suite (incl. the openapi document cases) never sees it.
    CREATE SCHEMA geotest;
    CREATE TABLE geotest.shops (
        id        int primary key,
        address   text,
        shop_geom geometry(POINT, 4326)
    );
    INSERT INTO geotest.shops SELECT * FROM test.shops;
    CREATE TABLE geotest.shop_bles (
        id      int primary key,
        name    text,
        coords  geometry(POINT, 4326),
        shop_id int REFERENCES geotest.shops(id)
    );
    INSERT INTO geotest.shop_bles (id, name, coords, shop_id) VALUES
      (1, 'battery',    'SRID=4326;POINT(-71.10044 42.373695)', 1),
      (2, 'car-key',    'SRID=4326;POINT(-71.10543 42.366432)', 1),
      (3, 'headphones', 'SRID=4326;POINT(-71.081924 42.36437)', 2);
    CREATE TABLE geotest.plain (id int primary key, label text);
    INSERT INTO geotest.plain VALUES (1, 'no-geometry');
    CREATE FUNCTION geotest.get_shops() RETURNS SETOF geotest.shops
      LANGUAGE sql STABLE AS 'SELECT * FROM geotest.shops ORDER BY id';
    CREATE FUNCTION geotest.get_shop_geom(id int) RETURNS geometry
      LANGUAGE sql STABLE
      AS 'SELECT shop_geom FROM geotest.shops WHERE shops.id = get_shop_geom.id';
    GRANT USAGE ON SCHEMA geotest TO postgrest_test_anonymous;
    GRANT ALL ON ALL TABLES IN SCHEMA geotest TO postgrest_test_anonymous;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA geotest TO postgrest_test_anonymous;
```

(The anonymous grants are for Task 5's live PostgREST run, which switches to `postgrest_test_anonymous`; Bier's test instances connect as the DB superuser.)

- [ ] **Step 2: Reload fixtures and confirm the schema exists**

Run: `mix bier.fixtures.load && psql -d bier_test -tAc "SELECT count(*) FROM geotest.shop_bles"`
Expected: `3`

- [ ] **Step 3: Add advanced-path geojson tests**

Append to `test/bier/geojson_test.exs` (inside the module):

```elixir
  test "advanced path: embeds land in Feature properties", %{conn: conn} do
    rels = Bier.Introspection.run(conn, ["geotest"])
    shops = rels[{"geotest", "shops"}]

    {:ok, plan} =
      Bier.QueryParser.parse_request(
        "select=id,address,shop_geom,shop_bles(name)&order=id&shop_bles.order=id"
      )

    assert {:ok, sql, params} = Bier.QueryExecutor.build(shops, plan, rels, :geojson)
    %Postgrex.Result{rows: [[body, count]]} = Postgrex.query!(conn, sql, params)
    assert count == 3

    decoded = Bier.json_library().decode!(body)
    assert decoded["type"] == "FeatureCollection"

    [f1 | _] = decoded["features"]
    assert f1["type"] == "Feature"
    assert f1["geometry"]["type"] == "Point"

    assert f1["properties"] == %{
             "id" => 1,
             "address" => "1369 Cambridge St",
             "shop_bles" => [%{"name" => "battery"}, %{"name" => "car-key"}]
           }
  end

  test "advanced path without a geometry column still raises 22023", %{conn: conn} do
    rels = Bier.Introspection.run(conn, ["geotest"])
    shops = rels[{"geotest", "shops"}]
    # id + embed only: the projected record carries no geometry column.
    {:ok, plan} = Bier.QueryParser.parse_request("select=id,shop_bles(name)")

    assert {:ok, sql, params} = Bier.QueryExecutor.build(shops, plan, rels, :geojson)

    assert {:error, %Postgrex.Error{postgres: %{pg_code: "22023", message: message}}} =
             Postgrex.query(conn, sql, params)

    assert message == "geometry column is missing"
  end
```

- [ ] **Step 4: Run the geojson tests, then the full suite**

Run: `mix test test/bier/geojson_test.exs`
Expected: PASS (the two new tests plus the three existing ones).
Run: `mix test`
Expected: 0 failures (the new schema must not disturb the shared instance — it is not in its `db_schemas`).

- [ ] **Step 5: Fix the stale comment in `action_controller.ex`**

At `lib/bier/plugs/action_controller.ex:568-572`, the `read_producers` comment says "Relation reads additionally offer…". Leave the code; update the comment to say "Relation reads (and, since #63, mutations) additionally offer `application/geo+json` when the postgis extension is installed…" — Task 3 makes that true; doing the comment here keeps Task 3's diff purely behavioral. Alternatively fold this edit into Task 3 — implementer's choice, but don't ship a wrong comment past Task 3.

- [ ] **Step 6: Commit**

```bash
git add lib/mix/tasks/bier.fixtures.load.ex test/bier/geojson_test.exs lib/bier/plugs/action_controller.ex
git commit -m "feat(#63): geotest fixtures + advanced-path geo+json read coverage

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Offer geo+json on mutations

**Files:**
- Modify: `lib/bier/media_type.ex` (add `executor_format/1`)
- Modify: `lib/bier/plugs/action_controller.ex` (mutation negotiation → `read_producers/1`; make `read_producers/1` public `@doc false`; replace private `format/1` with `MediaType.executor_format/1`)
- Modify: `lib/bier/query_executor.ex:378` (`build_representation/4` → `/5` with `opts`)
- Modify: `lib/bier/mutation.ex` (thread format; geojson empty-set body)
- Test (create): `test/bier/geojson_http_test.exs`

**Interfaces:**
- Consumes: Task 2's `geotest` schema; Task 1's format-aware `build_advanced`.
- Produces: `Bier.MediaType.executor_format(%MediaType{}) :: :json | :geojson`; public `Bier.Plugs.ActionController.read_producers(config)` (Task 4 uses both); `QueryExecutor.build_representation(relation, plan, relations, {sql, params}, opts \\ [])` accepting `format:`.

- [ ] **Step 1: Write the failing HTTP tests**

Create `test/bier/geojson_http_test.exs`:

```elixir
defmodule Bier.GeojsonHttpTest do
  @moduledoc """
  End-to-end geo+json negotiation on mutations and RPC (#63), against a
  dedicated instance exposing the geotest schema. base_opts carries
  db_tx_end: :rollback, so mutations never persist — no cleanup needed.
  """
  use ExUnit.Case, async: false

  alias Bier.TestPorts

  @moduletag :integration

  setup_all do
    port = TestPorts.free_port()
    name = :"geojson_http_#{System.unique_integer([:positive])}"

    opts =
      Bier.ConformanceServer.base_opts()
      |> Keyword.merge(
        name: name,
        router: [port: port, scheme: :http],
        db_schemas: ["geotest"]
      )

    {:ok, pid} = Bier.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: Supervisor.stop(pid) end)
    TestPorts.wait_until_listening(port)
    %{base: "http://localhost:#{port}"}
  end

  defp request!(base, method, path, headers, body \\ nil) do
    Req.request!(
      method: method,
      url: base <> path,
      headers: headers,
      body: body,
      retry: false,
      decode_body: false
    )
  end

  defp decode!(body), do: Bier.json_library().decode!(body)

  test "POST return=representation renders a FeatureCollection", %{base: base} do
    resp =
      request!(
        base,
        :post,
        "/shops",
        [
          {"accept", "application/geo+json"},
          {"content-type", "application/json"},
          {"prefer", "return=representation"}
        ],
        ~s({"id": 4, "address": "New Shop", "shop_geom": "SRID=4326;POINT(-71.0 42.0)"})
      )

    assert resp.status == 201
    assert ["application/geo+json; charset=utf-8"] = resp.headers["content-type"]

    decoded = decode!(resp.body)
    assert decoded["type"] == "FeatureCollection"

    assert [
             %{
               "type" => "Feature",
               "geometry" => %{"type" => "Point"},
               "properties" => %{"id" => 4, "address" => "New Shop"}
             }
           ] = decoded["features"]
  end

  test "DELETE return=representation renders the deleted Feature", %{base: base} do
    resp =
      request!(base, :delete, "/shops?id=eq.3", [
        {"accept", "application/geo+json"},
        {"prefer", "return=representation"}
      ])

    assert resp.status == 200
    decoded = decode!(resp.body)
    assert [%{"properties" => %{"id" => 3}}] = decoded["features"]
  end

  test "mutation on a geometry-less table fails 400/22023", %{base: base} do
    resp =
      request!(
        base,
        :post,
        "/plain",
        [
          {"accept", "application/geo+json"},
          {"content-type", "application/json"},
          {"prefer", "return=representation"}
        ],
        ~s({"id": 2, "label": "x"})
      )

    assert resp.status == 400
    assert %{"code" => "22023", "message" => "geometry column is missing"} = decode!(resp.body)
  end

  test "empty-payload POST renders an empty FeatureCollection", %{base: base} do
    resp =
      request!(
        base,
        :post,
        "/shops",
        [
          {"accept", "application/geo+json"},
          {"content-type", "application/json"},
          {"prefer", "return=representation"}
        ],
        "[]"
      )

    assert resp.status == 201
    # Exact bytes: PostgREST's geo+json wrapper is SQL json_build_object output,
    # which is spaced — the empty-set short-circuit must match those bytes.
    # (Live-verified against PostgREST 14.12 in the diff task.)
    assert resp.body == ~s({"type" : "FeatureCollection", "features" : []})
  end
end
```

- [ ] **Step 2: Run to verify the failures are 406s**

Run: `mix test test/bier/geojson_http_test.exs`
Expected: FAIL — the mutation tests get **406** (`PGRST107`) because mutations don't offer `:geojson` yet. (If `Bier.start_link` or the fixture schema errors instead, fix that first.)

- [ ] **Step 3: Implement**

1. `lib/bier/media_type.ex` — add:

```elixir
  @doc """
  The query-executor output format for a negotiated media type: `:geojson`
  for `application/geo+json` (rows aggregated into a FeatureCollection via
  ST_AsGeoJSON), `:json` for everything else.
  """
  def executor_format(%__MODULE__{symbol: :geojson}), do: :geojson
  def executor_format(_media), do: :json
```

2. `lib/bier/plugs/action_controller.ex`:
   - mutation clause (`handle/4` for POST/PATCH/PUT/DELETE, line ~372): `Negotiation.resolve(conn, read_producers(config))`.
   - `read_producers/1` (line ~573): change `defp` to `@doc false def` (Task 4's RPC call site).
   - delete the private `format/1` (lines 412–416); in `handle_get/4` pass `format: MediaType.executor_format(media)`.

3. `lib/bier/query_executor.ex` — `build_representation/4` (line 378) gains a trailing `opts \\ []`; in its `%State{}` set `format: Keyword.get(opts, :format, :json)`.

4. `lib/bier/mutation.ex`:
   - in `run/4` (line ~198): `QueryExecutor.build_representation(write.relation, write.plan, relations, {sql, params}, format: MediaType.executor_format(write.media))`.
   - `respond_empty_set/4` (line ~345): body becomes `empty_set_body(media)`; add:

```elixir
  # PostgREST renders geo+json bodies in SQL via json_build_object, whose
  # spaced output is part of the wire format; the empty-set short-circuit
  # must emit the same bytes (verified against live PostgREST 14.12).
  defp empty_set_body(%MediaType{symbol: :geojson}),
    do: ~s({"type" : "FeatureCollection", "features" : []})

  defp empty_set_body(_media), do: "[]"
```

- [ ] **Step 4: Run the HTTP tests, then the full suite**

Run: `mix test test/bier/geojson_http_test.exs`
Expected: PASS (4 tests).
Run: `mix test`
Expected: 0 failures — in particular the mutation-area conformance cases (negotiation list changed for mutations: adding a gated `:geojson` producer must not change any existing negotiation outcome, since `:geojson` is appended last and never matches `*/*`).

- [ ] **Step 5: Commit**

```bash
git add lib/bier/media_type.ex lib/bier/plugs/action_controller.ex lib/bier/query_executor.ex lib/bier/mutation.ex test/bier/geojson_http_test.exs
git commit -m "feat(#63): offer application/geo+json on mutations

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Offer geo+json on RPC

**Files:**
- Modify: `lib/bier/rpc.ex` (both negotiation sites, `result_sql/3` geojson variant, count guard)
- Modify: `lib/bier/query_executor.ex` (`run_function/6` reads `:format` opt)
- Test: extend `test/bier/geojson_http_test.exs`

**Interfaces:**
- Consumes: Task 3's `MediaType.executor_format/1` and public `ActionController.read_producers/1`; Task 2's `geotest.get_shops/0` + `geotest.get_shop_geom/1`.
- Produces: nothing new for later tasks.

- [ ] **Step 1: Write the failing tests**

Append to `test/bier/geojson_http_test.exs`:

```elixir
  test "RPC returning SETOF <relation> renders a FeatureCollection", %{base: base} do
    resp = request!(base, :get, "/rpc/get_shops", [{"accept", "application/geo+json"}])

    assert resp.status == 200
    assert ["application/geo+json; charset=utf-8"] = resp.headers["content-type"]

    decoded = decode!(resp.body)
    assert decoded["type"] == "FeatureCollection"
    assert length(decoded["features"]) == 3
    assert %{"geometry" => %{"type" => "Point"}} = hd(decoded["features"])
  end

  test "RPC setof-relation with embeds renders embeds in properties", %{base: base} do
    resp =
      request!(
        base,
        :get,
        "/rpc/get_shops?select=id,address,shop_geom,shop_bles(name)&shop_bles.order=id",
        [{"accept", "application/geo+json"}]
      )

    assert resp.status == 200
    decoded = decode!(resp.body)

    assert %{"properties" => %{"id" => 1, "shop_bles" => [_, _]}} = hd(decoded["features"])
  end

  test "scalar-geometry RPC renders a single-Feature collection", %{base: base} do
    resp = request!(base, :get, "/rpc/get_shop_geom?id=1", [{"accept", "application/geo+json"}])

    assert resp.status == 200
    decoded = decode!(resp.body)
    assert decoded["type"] == "FeatureCollection"
    assert [%{"type" => "Feature", "geometry" => %{"type" => "Point"}}] = decoded["features"]
  end
```

- [ ] **Step 2: Run to verify 406 failures**

Run: `mix test test/bier/geojson_http_test.exs`
Expected: the 3 new tests FAIL with status 406.

- [ ] **Step 3: Implement**

1. `lib/bier/query_executor.ex` — `run_function/6`: read `format = Keyword.get(opts, :format, :json)` and set it in the `%State{}` built inside `build_function/5` (thread it as an argument, mirroring how `relations` flows).

2. `lib/bier/rpc.ex`:
   - `:setof_rel` clause (line ~275): negotiate against `ActionController.read_producers(config)`; pass `format: MediaType.executor_format(media)` in the `run_function` opts (alias `Bier.MediaType` if not already).
   - generic clause (line ~305): `producers = ActionController.read_producers(config) ++ [:octet]`.
   - `result_sql/3`: add a geojson clause **above** the fallback clause (line 334), keeping the `:octet` clause first:

```elixir
  # geo+json: aggregate the result rows into a FeatureCollection via
  # ST_AsGeoJSON over the row record; a result without a geometry column
  # raises 22023 at execution, mirroring PostgREST.
  defp result_sql(fn_def, from, %MediaType{symbol: :geojson}) do
    inner =
      case fn_def.ret_kind do
        kind when kind in [:setof_record, :composite] -> "SELECT * FROM #{from}"
        _scalar -> "SELECT #{from} AS _v"
      end

    "SELECT json_build_object('type', 'FeatureCollection', 'features', " <>
      "coalesce(json_agg(ST_AsGeoJSON(t)::json), '[]'))::text FROM (#{inner}) t"
  end
```

   - `render_result/5` setof clause (line ~360): the body may now be a FeatureCollection object, which `Response.row_count/1` cannot decode as an array — guard the count:

```elixir
    count =
      if count_mode == :none or media.symbol == :geojson,
        do: 0,
        else: Response.row_count(body)
```

     (A `count=` preference combined with geo+json on a non-setof_rel RPC is out of conformance scope; the guard just prevents a decode crash. Note this in a comment.)
   - scalar/composite geojson results flow through the existing generic `render_result/5` (content-type from media) unchanged.

- [ ] **Step 4: Run the file, then the full suite**

Run: `mix test test/bier/geojson_http_test.exs`
Expected: PASS (7 tests).
Run: `mix test`
Expected: 0 failures (RPC-area cases unaffected: `:geojson` appended after the defaults, `:octet` still offered).

- [ ] **Step 5: Commit**

```bash
git add lib/bier/rpc.ex lib/bier/query_executor.ex test/bier/geojson_http_test.exs
git commit -m "feat(#63): offer application/geo+json on RPC

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Live PostgREST 14.12 diff

**Files:**
- Create (scratchpad, NOT committed): `<scratchpad>/postgrest.conf`, `<scratchpad>/live_diff.exs`, `<scratchpad>/DIFF_NOTES.md`
- Possibly modify: `lib/` + test literals, per findings

**Interfaces:**
- Consumes: everything above; `bench/http/bin/postgrest` (verified: `PostgREST 14.12`); the `bier_test` DB with Task 2 fixtures.
- Produces: `DIFF_NOTES.md` findings for the PR body (Task 6).

- [ ] **Step 1: Write the PostgREST config**

`<scratchpad>/postgrest.conf` (substitute the real OS user for `$USER`):

```
db-uri = "postgres://$USER@localhost:5432/bier_test"
db-schemas = "test, geotest"
db-anon-role = "postgrest_test_anonymous"
db-tx-end = "rollback"
server-port = 3009
```

Start it: `bench/http/bin/postgrest <scratchpad>/postgrest.conf` (run in background). Verify: `curl -s localhost:3009/projects?limit=1` returns JSON.

- [ ] **Step 2: Write and run the diff script**

`<scratchpad>/live_diff.exs` — boots a Bier instance on port 3010 with `db_schemas: ["test", "geotest"]`, `db_tx_end: :rollback` (reuse `Bier.ConformanceServer.base_opts()` merged accordingly), then for each case below issues the identical request to both ports and byte-compares status, `content-type`, and body (report mismatches; don't halt). Run with `mix run <scratchpad>/live_diff.exs`.

Diff matrix (geotest requests carry `Accept-Profile: geotest` for reads / `Content-Profile: geotest` for writes+rpc):

| # | Request | Checks |
|---|---------|--------|
| 1 | `GET /projects?select=id,name,clients(name)&order=id&limit=2` | #31 to-one bytes |
| 2 | `GET /projects?select=name,tasks(name)&order=id&limit=1&tasks.order=id` | #31 to-many bytes |
| 3 | `GET /projects?select=id,...clients(client_name:name)&order=id&limit=1` and `…&id=eq.5` | #31 spread bytes + null cols |
| 4 | `GET /projects?select=client_id,id.count()&order=client_id` | #31 aggregate bytes |
| 5 | `GET /projects?select=id,...tasks(task_names:name)&order=id&limit=1` | to-many spread array semantics (uncased in the frozen suite) |
| 6 | `GET /shops?select=id,address,shop_geom,shop_bles(name)&order=id&shop_bles.order=id` + `Accept: application/geo+json` | advanced geojson read bytes |
| 7 | `POST /shops` repr + geojson (body as in Task 3 test) | mutation geojson bytes/status/Location |
| 8 | `POST /shops` body `[]` repr + geojson | empty FeatureCollection bytes |
| 9 | `PATCH /shops?id=eq.1` repr + geojson, `DELETE /shops?id=eq.3` repr + geojson | mutation geojson |
| 10 | `GET /rpc/get_shops` + geojson; `POST /rpc/get_shops` (body `{}`) + geojson | setof_rel RPC |
| 11 | `GET /rpc/get_shop_geom?id=1` + geojson | scalar RPC geojson shape |
| 12 | `GET /projects` + geojson (via `test` profile — no geometry) and `POST /plain` repr + geojson | 22023 error envelope |

- [ ] **Step 3: Resolve divergences**

For every mismatch: decide whether it's a Bier bug (fix in `lib/`, update the unit-test literals from Tasks 1–4 to the PostgREST bytes) or an intentional/unreachable divergence (record it). Re-run the diff until it reports only recorded divergences. Likely candidates called out in the design: empty-FeatureCollection bytes (Task 3's literal), to-many spread empty/`[]` semantics (`COALESCE` choice in Task 1), scalar-RPC geojson shape (Task 4's `result_sql`).

- [ ] **Step 4: Record findings**

Write `<scratchpad>/DIFF_NOTES.md`: the matrix with ✓/✗ per case and a paragraph per resolved or accepted divergence. This feeds the PR body verbatim.

- [ ] **Step 5: Run the full suite once more and commit any lib/test adjustments**

Run: `mix test` → 0 failures.

```bash
git add -A lib test/bier
git commit -m "fix(#63,#31): align geo+json and compact-JSON bytes with live PostgREST 14.12

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

(Skip the commit if the diff produced no changes.)

Stop PostgREST (`kill` the background process).

---

### Task 6: Docs, precommit, PR

**Files:**
- Modify: `README.md` and/or the docs page that documents media types (locate with `grep -rn "geo+json" README.md docs/ --include="*.md" -l`; update wherever geo+json's flat-only limitation is stated)
- Modify: `CHANGELOG.md` if present

**Interfaces:** none new.

- [ ] **Step 1: Update docs**

Wherever geo+json support is described, state: it is offered on relation reads, mutations with `Prefer: return=representation`, and RPC when PostGIS is installed; and add the note: "`ST_AsGeoJSON` is emitted unqualified and resolves via the session `search_path` (matching PostgREST) — a PostGIS installed outside the search path fails at execution." Remove any "flat path only" wording. Add a CHANGELOG entry under Unreleased if the file exists.

- [ ] **Step 2: Run the full CI gate locally**

Run: `mix precommit`
Expected: every step green (`deps.unlock --check-unused`, `format --check-formatted`, `hex.audit`, `compile --warnings-as-errors`, `credo --strict`, `docs --warnings-as-errors`, `test`).

- [ ] **Step 3: Commit docs and push**

```bash
git add -A
git commit -m "docs(#63): document broadened geo+json support + search_path note

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push -u origin geojson-broadening-31-63
```

- [ ] **Step 4: Open the PR**

`gh pr create` with title `feat(#63,#31): broaden application/geo+json + compact advanced-path JSON`. Body: summary of the restructure and producer broadening; the live-diff findings table from `DIFF_NOTES.md`; `Closes #63`, `Closes #31`; the standard footer:

```
🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

---

## Self-review notes

- **Spec coverage:** §1 restructure → Task 1; §2 mutations/RPC/threading → Tasks 3–4; §2 edge (empty set) → Task 3 step 3.4 + Task 5 case 8; §3 errors → Task 2/3 tests (22023); §4 testing → Tasks 1–5; §5 docs → Task 6. Success criteria 1–4 all have verifying steps.
- **Known judgment calls encoded here:** to-many spread uses `COALESCE(json_agg(…), '[]')` per key (live-verified in Task 5 case 5); empty-set geojson body uses PostgREST's spaced SQL bytes (live-verified case 8); empty projections (`select=rel()`) keep rendering `{}` rows.
- **Type consistency:** `build_row_select` returns `{cols, laterals, state}` — used identically in Task 1 (embed.ex + query_executor.ex). `executor_format/1` defined in Task 3, consumed in Tasks 3–4. `read_producers/1` made public in Task 3, consumed in Task 4.
