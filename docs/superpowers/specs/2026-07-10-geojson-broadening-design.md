# geo+json broadening + compact advanced-path JSON — Design

**Issues:** #63 — `[conformance-gap] Broaden application/geo+json: mutations, RPC, and
the embed/advanced read path`; #31 — `[conformance][lib] Embed/advanced path renders
spaced JSON via json_build_object`
**Date:** 2026-07-10
**Status:** Approved (brainstorming)

## Summary

Both issues are symptoms of one root cause: the advanced read path
(embeds/aggregates/spread/computed columns) pre-collapses each row into a scalar
`json_build_object(...)` expression (`Bier.Embed.build_row_object/6`). PostgreSQL
renders `json_build_object` spaced (`"k" : v`), diverging from PostgREST's compact
wire bytes (#31), and a pre-collapsed JSON scalar is not a record `ST_AsGeoJSON`
can consume, which is why `application/geo+json` was left flat-path-only by #62 —
and why the advanced path currently returns a **mislabeled** plain-JSON body under
a geo+json Content-Type (#63 gap 2).

The fix restructures the advanced path to project **named columns into a derived
table** — the same shape #17 used to fix the simple path — and then broadens the
`:geojson` producer to mutations and RPC (#63 gap 1), which becomes safe once every
rendering path can produce a real record.

Delivered as **one PR** closing both issues.

## Success criteria

1. Conformance suite stays at baseline — the ~100 embed/aggregate/spread cases are
   the regression net for the restructure.
2. Embed/aggregate/spread response bodies byte-match PostgREST's compact output
   (locked in by new non-frozen tests asserting exact bytes/Content-Length).
3. geo+json on mutations (`Prefer: return=representation`), RPC, and
   embed/advanced reads matches a live PostgREST v14.12 side-by-side.
4. No response is ever labeled `application/geo+json` with a non-GeoJSON body.

## 1. The SQL restructure (`Bier.Embed` + `Bier.QueryExecutor.build_advanced`)

`Embed.build_row_object/6` becomes a **select-list builder** returning
`{select_items, lateral_joins, state}` instead of one scalar JSON expression:

- **Plain fields / aggregates / computed columns** → `expr AS "out_name"`.
  PostgreSQL permits duplicate aliases in a subquery select list, so duplicate
  output keys keep working (`to_json` emits both, like PostgREST).
- **Non-spread embeds** → remain correlated scalar subqueries, now as named
  columns. Child rows recursively use the same structure:
  - `:many` → `COALESCE((SELECT json_agg(_c) FROM (SELECT <child cols> FROM …
    WHERE … ORDER BY … LIMIT/OFFSET …) _c), '[]'::json)`
  - `:one` → `(SELECT to_json(_c) FROM (SELECT <child cols> … LIMIT 1) _c)`

  `json_agg` over a subquery scan preserves the subquery's order — the simple
  path and PostgREST itself already rely on this.
- **Spread** → `LEFT JOIN LATERAL (SELECT <child cols> …) _bier_spr<N> ON true`,
  with the child's columns pulled up into the parent select list (PostgREST's
  actual SQL shape). A missing to-one row yields SQL NULL columns naturally, so
  the `null_template` COALESCE hack is deleted. To-many spread aggregates each
  key into an array inside the lateral (`json_agg(col) AS "key"`), matching
  PostgREST v12.1 semantics; exact empty-set behavior is verified live during
  implementation.
- The `(obj::jsonb || spread)::json` merge path is **deleted** — the jsonb cast
  was the second spacing source.

`build_advanced` then mirrors `build_simple`'s three-layer shape:

```sql
SELECT <aggregate_body(format)> AS body,
       coalesce(max(_postgrest_t._bier_full_count), 0) AS full_count
FROM (
  SELECT <row_json(format)> AS _bier_row, count(*) OVER() AS _bier_full_count
  FROM (
    SELECT al."id" AS "id",
           (SELECT json_agg(_c) FROM (…) _c) AS "tasks",   -- embed
           _bier_spr1."name", _bier_spr1."rank"            -- spread, pulled up
    FROM "test"."projects" al
    LEFT JOIN LATERAL (SELECT c."name", c."rank" FROM … LIMIT 1) _bier_spr1 ON true
    WHERE … GROUP BY … ORDER BY …
  ) _bier_cols
  LIMIT … OFFSET …
) _postgrest_t
```

The simple and advanced paths converge structurally; the existing `row_json/1`
(`to_json` / `ST_AsGeoJSON(…)::json`) and `aggregate_body/1` (JSON array /
FeatureCollection) format variants apply to both unchanged. The count window
stays above the LIMIT (window functions run before LIMIT/OFFSET), preserving
`Content-Range` semantics.

## 2. Producer broadening + format threading

- **Mutations** (`Bier.Plugs.ActionController.handle/4` for
  POST/PATCH/PUT/DELETE): negotiate against `read_producers(config)` (the
  postgis-gated list) instead of `relation_producers(config)`. `Bier.Mutation`
  threads `format: :geojson` into `QueryExecutor.build_representation` (new
  option, stored in `State.format` as today) so the representation body is a
  FeatureCollection. Location / Content-Range / Preference-Applied handling is
  unchanged; `Bier.Render.render` already passes geojson bodies through.
- **RPC** (`Bier.Rpc`): both `run` negotiation sites offer `:geojson` under the
  same gate. `setof_rel` threads the format into `QueryExecutor.run_function`
  (same builder path as reads). For scalar / composite / setof_record results,
  `result_sql` gains a geojson variant wrapping the result rows in
  `ST_AsGeoJSON(t)` — PostgREST negotiates uniformly and lets SQL raise `22023`
  when no geometry column exists; we mirror that, with exact shapes confirmed
  against live PostgREST.
- **Edge:** empty-payload mutation responses (`respond_empty_set`) under geojson
  return an empty FeatureCollection rather than `[]` — verified live.

## 3. Errors

No new error shapes. A geometry-less relation still fails at execution with
SQLSTATE `22023` ("geometry column is missing") → existing `FallbackController`
mapping to 400. The mislabeled advanced+geojson response ceases to exist rather
than being explicitly rejected.

## 4. Testing & verification

- **Frozen suite:** full `mix test` at baseline (PostGIS is now installed
  locally, so the expected local baseline is 0 failures). `test/**` and `spec/**`
  stay untouched.
- **New non-frozen tests** (established `test/bier/*_test.exs` pattern):
  - byte-exactness / Content-Length assertions for embed, aggregate, and spread
    bodies (#31's acceptance criterion);
  - geojson on mutation representation, RPC, and embed/advanced reads
    (extending `test/bier/geojson_test.exs`).
- **Live PostgREST v14.12 diff:** spin PostgREST up against the fixture DB (the
  bench harness already has the machinery), diff Bier vs PostgREST for embed
  bytes and every new geojson combination; findings recorded in the PR
  description. The comparison script is throwaway (scratchpad), not committed.

## 5. Docs

One line noting that `ST_AsGeoJSON` is emitted unqualified and resolves via the
session `search_path` (matching PostgREST), so a PostGIS installed outside the
search path fails at execution (#63's "related note").

## Out of scope

- Custom media handlers overriding geojson (`Bier.CustomMedia` precedence is
  already handled at the dispatch site).
- New frozen conformance cases — no frozen case exercises these combinations
  (which is how #62 could ship flat-only); ground truth here is the live
  PostgREST diff plus the new non-frozen tests.
