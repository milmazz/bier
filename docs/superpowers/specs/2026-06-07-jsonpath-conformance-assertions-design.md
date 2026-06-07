# JSONPath body assertions for the conformance harness (#38) — Design

> Status: draft (design). Implementation plan to follow via writing-plans.
> Scope: GitHub issue #38. Test-harness only (`test/support/**` + the generator).
> Unblocks `expect.body_jsonpath` (39 cases currently tagged `:pending`).

## 1. Goal

Let the conformance suite evaluate the `expect.body_jsonpath` assertion vocabulary
so the 39 cases that use it can run instead of being excluded. Today
`test/conformance/conformance_test.exs` tags any case with
`expect.body_jsonpath` as `@tag :pending` (reason `:jsonpath`) because the
harness has no JSONPath evaluator — making `:jsonpath` the single biggest driver
of the conformance gap (39 of 80 pending cases).

This delivers the **evaluator + matcher only**. Of the 39 cases:

- **11 are non-openapi** (url_grammar, mutations, errors, content_negotiation,
  config) and should flip to green on this work alone — *provided* the underlying
  responses are already correct (to be confirmed during implementation; a real
  red here is a useful lib-bug signal, not a defect of this harness work).
- **28 are openapi** (`1650–1680`). This work lets them be *asserted*, but they
  remain red until the OpenAPI document is generated (#39). The evaluator is a
  prerequisite for #39 paying off; the two compose.

## 2. Why not a JSONPath dependency (settled during brainstorming)

The need splits in two, and a library only covers the trivial half:

1. **Path navigation** over the decoded body — a 4-rule, deterministic,
   single-match subset (see §4). Confirmed across all 39 cases: **zero** filters
   (`?()`), recursive descent (`..`), wildcards (`[*]`/`.*`), or slices.
2. **The matcher** — `equals` (deep JSON equality vs a YAML-decoded value,
   including nested objects), plus `present` / `absent` / `exists`. **No JSONPath
   library provides this**; we build it regardless.

The Elixir JSONPath landscape (researched 2026-06-07):

| Library | Latest | Released | Notes |
| --- | --- | --- | --- |
| `exjsonpath` | 0.9.0 | Mar 2020 | unmaintained; pre-RFC-9535 |
| `warpath` | 0.6.3 | Sep 2022 | unmaintained; pre-RFC-9535 |
| `json_path` | 0.3 | Jun 2026 | RFC-9535 compliant but days-old, pre-1.0 |

A dependency would save ~40 lines of trivial path-walking while adding a
stale-or-volatile transitive dep, requiring validation of our bracket edge cases
(`['$ref']`, `['/child_entities']`, `['200']`) that pre-RFC parsers often get
wrong, and *still* leaving us to hand-roll the matcher. For this codebase the
library is the higher long-term-maintenance option. **Decision: a small,
purpose-built resolver (Option A), behind a clean `fetch/2` seam so a library
could be swapped in later if requirements ever grow filters/wildcards.**

### Note on security / input handling

This code is **test-only** and every input is **trusted and local**: `path`
strings come from our checked-in `spec/conformance/cases/*.yaml`; it navigates an
in-memory decoded JSON term and builds **no SQL, query, or shell**. There is no
injection surface here (the untrusted HTTP query string is a *different*
subsystem, `Bier.QueryParser`, already defended by parameterized SQL). We still
parse the path into a structured form up front — not for security, but so a
malformed path **fails fast with a clear error** (catching our own YAML typos)
instead of silently mis-navigating.

`nimble_parsec` is **not** used: the grammar is four productions (a ~20-line hand
tokenizer is clearer at this altitude), and the repo deliberately keeps
`nimble_parsec` `only: :dev, runtime: false` (it only *generates* the
dependency-free `QueryParser`). Test-only code stays dependency-free.

## 3. Architecture

```
expect.body_jsonpath: [ { path: "...", equals|present|absent|exists: ... }, ... ]
        │
        ▼  check("body_jsonpath", entries, resp)        (conformance_assertions.ex)
        │     │ decode body once  (Bier.json_library)
        │     ▼
        │   ConformanceJsonPath.fetch(decoded, path)     (conformance_json_path.ex)
        │     parse(path) → [segment]  →  resolve(segments, decoded)
        │     ▼
        │   {:ok, value} | :missing
        ▼
   predicate check (equals == / present|exists / absent)  → pass | flunk
```

### Components (all test-only)

| File | Responsibility |
| --- | --- |
| `test/support/conformance_json_path.ex` (new) | `Bier.ConformanceJsonPath`: `parse/1` (string → segment list, raises on malformed), `resolve/2` (segments × term → `{:ok, value} \| :missing`), and `fetch/2` (string × term → same) as the public seam. Pure; no deps. |
| `test/support/conformance_assertions.ex` (edit) | Add a `check("body_jsonpath", entries, resp)` clause before the catch-all raise. Reuses `decode_json/1`. |
| `test/conformance/conformance_test.exs` (edit) | Remove the `Map.has_key?(c.expect, "body_jsonpath") -> :jsonpath` arm of `pending_reason` so these cases run. |

No `lib/` or `mix.exs` changes (no new dependency).

## 4. The JSONPath subset

### Grammar (exactly what the 39 cases use)

```
path     = "$" *segment
segment  = "." ident            ; dot member
         | "[" "'" str "'" "]"  ; bracket string key
         | "[" int "]"          ; array index
ident    = (ALPHA / "_") *(ALPHA / DIGIT / "_")
str      = *(any char except "'")     ; e.g. "/child_entities", "$ref", "200"
int      = 1*DIGIT
```

A bracket key (`['200']`) is a **string map key**; a bare bracket integer
(`[0]`) is an **array index** — the parse distinguishes them, so `responses['200']`
and `tags[0]` resolve correctly. No escaping inside `'...'` is required (no
embedded quotes occur in the corpus); the parser reads to the next `'`.

### Segment representation

```elixir
@type segment :: {:key, String.t()} | {:index, non_neg_integer()}

parse("$.paths['/child_entities'].get.responses['200'].description")
#=> [{:key, "paths"}, {:key, "/child_entities"}, {:key, "get"},
#    {:key, "responses"}, {:key, "200"}, {:key, "description"}]
```

`$` alone parses to `[]` and resolves to the whole body (not used by any case,
but well-defined).

### resolve/2 semantics

Walk the decoded term left to right:

- `{:key, k}` — if the current node is a map with key `k`, descend; else `:missing`.
- `{:index, i}` — if the current node is a list with `i < length`, descend
  (`Enum.at/2`); else `:missing`.
- Type mismatch (key on a list, index on a map) — `:missing`.

Returns `{:ok, value}` after the last segment, or `:missing` if any step fails.
`:missing` is a first-class result, never an exception — it is exactly what the
`absent`/`present` predicates test.

## 5. Matcher (`check("body_jsonpath", entries, resp)`)

`entries` is the list of `%{"path" => p, <predicate> => v}` maps. Decode the body
once via `decode_json/1`, then for each entry resolve `fetch(decoded, p)` and
apply its single predicate:

| Predicate | Passes when |
| --- | --- |
| `equals: V` | `fetch == {:ok, actual}` **and** `actual == V` |
| `present: true` | `fetch == {:ok, _}` |
| `exists: true` | `fetch == {:ok, _}` (synonym of `present`) |
| `absent: true` | `fetch == :missing` |

- **`equals` uses plain `==` on decoded terms**, identical to the existing
  `body_exact`/`body_json` checks — same house semantics, including for nested
  objects/arrays (`{format: "json[]", type: "array", items: {type: "string"}}`).
  Expected values are YAML-decoded (string keys, scalars, lists, maps), matching
  the JSON-decoded actual. (If int/float skew between the YAML and JSON decoders
  ever surfaces, normalize then — not anticipated for the current corpus.)
- A failing entry produces a clear `flunk` naming the **path**, the **expected**
  predicate/value, and the **actual** (`{:ok, value}` or `missing`).

## 6. Error handling

- **Malformed path** (e.g. unterminated `['…`, stray chars) — `parse/1` raises
  `ArgumentError` naming the offending path. Surfaces a spec-authoring typo at
  the assertion site rather than mis-navigating.
- **Unknown predicate key** (anything other than `equals`/`present`/`exists`/
  `absent` in an entry) — raises, consistent with the module's existing
  "unsupported assertion key" rule: a case never passes by ignoring an assertion.
- **Body not valid JSON** — reuses `decode_json/1`, which `flunk`s with the body.
- **Entry without a `path`** — raises (malformed case).

## 7. Test plan (TDD)

Unit tests for `Bier.ConformanceJsonPath` (no HTTP, pure):

- `parse/1`: dot keys, bracket string keys (`/`, `$ref`, `200`), array indices,
  mixed chains; `$`-only; malformed inputs raise.
- `resolve/2` & `fetch/2`: hit (`{:ok, v}`), miss on absent key, miss on
  out-of-range index, miss on type mismatch, nested objects/arrays, whole-body
  for `$`.

Matcher tests for `assert_expect` with `body_jsonpath`: each predicate passing
and failing against a fixture map; unknown-predicate raises; non-JSON body
flunks. Then remove the `:jsonpath` pending arm and run the suite: the 11
non-openapi cases are expected green (or surface real lib bugs to file); the 28
openapi cases stay red pending #39 and are noted, not re-hidden.

## 8. Out of scope / relationships

- **OpenAPI document generation (#39)** — the 28 openapi cases depend on it; this
  work only makes them assertable.
- **JSONPath features beyond the subset** (filters, recursion, wildcards,
  slices) — not implemented; the `fetch/2` seam allows swapping in a library if a
  future case ever needs them. `parse/1` raises on such syntax rather than
  silently ignoring it.
- No changes to `lib/`, no runtime dependency, no `mix.exs` change.

## 9. Branch note

Work proceeds in the `worktree-jsonpath-conformance-assertions` worktree
(branch off `main`), isolated from the in-flight telemetry PR (#37). All writes
are `test/support/**` and the conformance generator — within the test harness.
