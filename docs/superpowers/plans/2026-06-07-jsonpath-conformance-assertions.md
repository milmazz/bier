# JSONPath body assertions (#38) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the conformance harness evaluate `expect.body_jsonpath` so the non-openapi cases that use it run instead of being excluded.

**Architecture:** A tiny, dependency-free JSONPath-subset resolver (`Bier.ConformanceJsonPath`) navigates the decoded response body; a new `body_jsonpath` clause in `Bier.ConformanceAssertions` layers the `equals`/`present`/`absent`/`exists` matcher on top. The conformance generator stops tagging non-openapi `body_jsonpath` cases `:pending`; openapi cases stay excluded under a new `:openapi_doc` reason (they need the generated document, #39) so CI stays green.

**Tech Stack:** Elixir, ExUnit, `yaml_elixir` (case loading), `Bier.json_library/0` (JSON decode). No new dependency.

See the design: `docs/superpowers/specs/2026-06-07-jsonpath-conformance-assertions-design.md`.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `test/support/conformance_json_path.ex` (create) | `Bier.ConformanceJsonPath`: `parse/1`, `resolve/2`, `fetch/2`. Pure, no deps. |
| `test/bier/conformance_json_path_test.exs` (create) | Unit tests for parse/resolve/fetch. |
| `test/support/conformance_assertions.ex` (modify) | Add the `body_jsonpath` check clause. |
| `test/bier/conformance_assertions_test.exs` (modify) | Matcher tests for `body_jsonpath`. |
| `test/conformance/conformance_test.exs` (modify) | Swap the broad `:jsonpath` pending arm for a narrow `:openapi_doc` arm. |

All changes are test-only. No `lib/` or `mix.exs` changes.

---

## Task 1: `Bier.ConformanceJsonPath.parse/1`

**Files:**
- Create: `test/support/conformance_json_path.ex`
- Test: `test/bier/conformance_json_path_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/bier/conformance_json_path_test.exs`:

```elixir
defmodule Bier.ConformanceJsonPathTest do
  use ExUnit.Case, async: true

  alias Bier.ConformanceJsonPath, as: JP

  describe "parse/1" do
    test "root only" do
      assert JP.parse("$") == []
    end

    test "dot members" do
      assert JP.parse("$.code") == [{:key, "code"}]
      assert JP.parse("$.info.title") == [{:key, "info"}, {:key, "title"}]
      assert JP.parse("$.a_json") == [{:key, "a_json"}]
    end

    test "bracket string keys (slash, dollar, digits)" do
      assert JP.parse("$.paths['/child_entities']") ==
               [{:key, "paths"}, {:key, "/child_entities"}]

      assert JP.parse("$.x['$ref']") == [{:key, "x"}, {:key, "$ref"}]
      assert JP.parse("$.responses['200']") == [{:key, "responses"}, {:key, "200"}]
    end

    test "array indices" do
      assert JP.parse("$[0].Plan") == [{:index, 0}, {:key, "Plan"}]
      assert JP.parse("$.tags[0]") == [{:key, "tags"}, {:index, 0}]
    end

    test "mixed chain" do
      assert JP.parse("$.paths['/child_entities'].get.responses['200'].description") ==
               [
                 {:key, "paths"},
                 {:key, "/child_entities"},
                 {:key, "get"},
                 {:key, "responses"},
                 {:key, "200"},
                 {:key, "description"}
               ]
    end

    test "malformed paths raise ArgumentError" do
      assert_raise ArgumentError, fn -> JP.parse("code") end
      assert_raise ArgumentError, fn -> JP.parse("$.") end
      assert_raise ArgumentError, fn -> JP.parse("$['unterminated") end
      assert_raise ArgumentError, fn -> JP.parse("$[]") end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/conformance_json_path_test.exs`
Expected: FAIL — `Bier.ConformanceJsonPath.parse/1 is undefined (module ... is not available)`.

- [ ] **Step 3: Write minimal implementation**

Create `test/support/conformance_json_path.ex`:

```elixir
defmodule Bier.ConformanceJsonPath do
  @moduledoc """
  A deterministic, single-match JSONPath subset for the conformance harness's
  `expect.body_jsonpath` assertions.

  Supports exactly the grammar the conformance cases use — root `$`, dot member
  `.key`, bracket string key `['key']` (keys may contain `/`, `$`, digits), and
  array index `[n]`. It deliberately does NOT support filters (`?()`), recursive
  descent (`..`), wildcards (`[*]`/`.*`), or slices; such syntax raises rather
  than being silently ignored. Inputs are trusted (our own checked-in spec
  files), so the parser fails fast on a malformed path to surface authoring
  typos at the assertion site.
  """

  @type segment :: {:key, String.t()} | {:index, non_neg_integer()}

  @doc """
  Parse a path string into a list of segments. Raises `ArgumentError` on a
  malformed path. `"$"` parses to `[]` (the whole document).
  """
  @spec parse(String.t()) :: [segment()]
  def parse("$" <> rest), do: parse_segments(rest, [], "$" <> rest)
  def parse(path), do: raise(ArgumentError, "JSONPath must start with $: #{inspect(path)}")

  defp parse_segments("", acc, _orig), do: Enum.reverse(acc)

  # .identifier
  defp parse_segments("." <> rest, acc, orig) do
    {ident, rest} = take_ident(rest, "")
    if ident == "", do: bad(orig)
    parse_segments(rest, [{:key, ident} | acc], orig)
  end

  # ['quoted string']  (must be tried before the bare-"[" clause below)
  defp parse_segments("['" <> rest, acc, orig) do
    case take_until_quote(rest, "") do
      {key, "]" <> rest2} -> parse_segments(rest2, [{:key, key} | acc], orig)
      _ -> bad(orig)
    end
  end

  # [integer]
  defp parse_segments("[" <> rest, acc, orig) do
    case take_digits(rest, "") do
      {"", _} -> bad(orig)
      {digits, "]" <> rest2} -> parse_segments(rest2, [{:index, String.to_integer(digits)} | acc], orig)
      _ -> bad(orig)
    end
  end

  defp parse_segments(_other, _acc, orig), do: bad(orig)

  defp take_ident(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_,
       do: take_ident(rest, acc <> <<c>>)

  defp take_ident(rest, acc), do: {acc, rest}

  defp take_digits(<<c, rest::binary>>, acc) when c in ?0..?9,
    do: take_digits(rest, acc <> <<c>>)

  defp take_digits(rest, acc), do: {acc, rest}

  # Read until the closing single quote. No escaping is needed for the corpus;
  # an unterminated quote returns :unterminated, which the caller turns into a
  # parse error.
  defp take_until_quote("'" <> rest, acc), do: {acc, rest}
  defp take_until_quote(<<c, rest::binary>>, acc), do: take_until_quote(rest, acc <> <<c>>)
  defp take_until_quote("", _acc), do: :unterminated

  defp bad(orig), do: raise(ArgumentError, "malformed JSONPath: #{inspect(orig)}")
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/bier/conformance_json_path_test.exs`
Expected: PASS (the `parse/1` describe block; `resolve`/`fetch` not tested yet).

- [ ] **Step 5: Commit**

```bash
git add test/support/conformance_json_path.ex test/bier/conformance_json_path_test.exs
git commit -m "feat(#38): JSONPath subset parser for the conformance harness"
```

---

## Task 2: `resolve/2` and `fetch/2`

**Files:**
- Modify: `test/support/conformance_json_path.ex`
- Test: `test/bier/conformance_json_path_test.exs`

- [ ] **Step 1: Write the failing test**

Append these describe blocks inside `Bier.ConformanceJsonPathTest` (before the final `end`):

```elixir
  describe "resolve/2" do
    @doc_term %{
      "swagger" => "2.0",
      "info" => %{"title" => "API"},
      "details" => nil,
      "paths" => %{"/x" => %{"get" => %{"tags" => ["a", "b"]}}},
      "list" => [%{"Plan" => 1}]
    }

    test "whole document for empty segments" do
      assert JP.resolve([], @doc_term) == {:ok, @doc_term}
    end

    test "nested key hit" do
      assert JP.resolve([{:key, "info"}, {:key, "title"}], @doc_term) == {:ok, "API"}
    end

    test "key present with null value is a hit (not missing)" do
      assert JP.resolve([{:key, "details"}], @doc_term) == {:ok, nil}
    end

    test "bracket-keyed path and array index" do
      assert JP.resolve(
               [{:key, "paths"}, {:key, "/x"}, {:key, "get"}, {:key, "tags"}, {:index, 1}],
               @doc_term
             ) == {:ok, "b"}

      assert JP.resolve([{:index, 0}, {:key, "Plan"}], @doc_term["list"]) == {:ok, 1}
    end

    test "missing key, out-of-range index, and type mismatch are :missing" do
      assert JP.resolve([{:key, "nope"}], @doc_term) == :missing
      assert JP.resolve([{:key, "list"}, {:index, 9}], @doc_term) == :missing
      assert JP.resolve([{:key, "swagger"}, {:key, "x"}], @doc_term) == :missing
    end
  end

  describe "fetch/2" do
    test "parses then resolves" do
      term = %{"a" => %{"b" => [10, 20]}}
      assert JP.fetch(term, "$.a.b[1]") == {:ok, 20}
      assert JP.fetch(term, "$.a.c") == :missing
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/conformance_json_path_test.exs`
Expected: FAIL — `Bier.ConformanceJsonPath.resolve/2 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Append to `Bier.ConformanceJsonPath` (before the final `end` of the module):

```elixir
  @doc "Resolve parsed `segments` against a decoded JSON term."
  @spec resolve([segment()], term()) :: {:ok, term()} | :missing
  def resolve([], term), do: {:ok, term}

  def resolve([{:key, k} | rest], term) when is_map(term) do
    case Map.fetch(term, k) do
      {:ok, value} -> resolve(rest, value)
      :error -> :missing
    end
  end

  def resolve([{:index, i} | rest], term) when is_list(term) and i < length(term),
    do: resolve(rest, Enum.at(term, i))

  def resolve(_segments, _term), do: :missing

  @doc "Parse `path` and resolve it against `term`."
  @spec fetch(term(), String.t()) :: {:ok, term()} | :missing
  def fetch(term, path), do: path |> parse() |> resolve(term)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/bier/conformance_json_path_test.exs`
Expected: PASS (all parse/resolve/fetch tests).

- [ ] **Step 5: Commit**

```bash
git add test/support/conformance_json_path.ex test/bier/conformance_json_path_test.exs
git commit -m "feat(#38): resolve/fetch for the JSONPath subset"
```

---

## Task 3: `body_jsonpath` matcher in `ConformanceAssertions`

**Files:**
- Modify: `test/support/conformance_assertions.ex`
- Test: `test/bier/conformance_assertions_test.exs:101` (add tests before the final `end`)

- [ ] **Step 1: Write the failing test**

Add these tests to `Bier.ConformanceAssertionsTest` (before the final `end`). They reuse the existing `resp/1` helper:

```elixir
  test "body_jsonpath equals (incl. null), present, exists, absent" do
    body =
      ~s({"code":"PGRST106","details":null,"swagger":"2.0",) <>
        ~s("paths":{"/x":{"get":{"tags":["t0"]}}}})

    r = resp(%{body: body})

    assert_expect(r, %{
      "body_jsonpath" => [
        %{"path" => "$.code", "equals" => "PGRST106"},
        %{"path" => "$.details", "equals" => nil},
        %{"path" => "$.paths['/x'].get.tags[0]", "equals" => "t0"},
        %{"path" => "$.swagger", "present" => true},
        %{"path" => "$.swagger", "exists" => true},
        %{"path" => "$.paths['/missing']", "absent" => true}
      ]
    })
  end

  test "body_jsonpath equals mismatch fails" do
    r = resp(%{body: ~s({"code":"PGRST106"})})

    assert_raise ExUnit.AssertionError, fn ->
      assert_expect(r, %{"body_jsonpath" => [%{"path" => "$.code", "equals" => "OTHER"}]})
    end
  end

  test "body_jsonpath absent fails when the node is present" do
    r = resp(%{body: ~s({"a":1})})

    assert_raise ExUnit.AssertionError, fn ->
      assert_expect(r, %{"body_jsonpath" => [%{"path" => "$.a", "absent" => true}]})
    end
  end

  test "body_jsonpath present fails when the node is missing" do
    r = resp(%{body: ~s({"a":1})})

    assert_raise ExUnit.AssertionError, fn ->
      assert_expect(r, %{"body_jsonpath" => [%{"path" => "$.b", "present" => true}]})
    end
  end

  test "body_jsonpath unknown predicate raises (never silently passes)" do
    r = resp(%{body: ~s({"a":1})})

    assert_raise RuntimeError, ~r/unsupported body_jsonpath predicate/, fn ->
      assert_expect(r, %{"body_jsonpath" => [%{"path" => "$.a", "bogus" => true}]})
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/bier/conformance_assertions_test.exs`
Expected: FAIL — the catch-all clause raises `unsupported assertion key: "body_jsonpath"`.

- [ ] **Step 3: Write minimal implementation**

In `test/support/conformance_assertions.ex`, add these clauses immediately **before** the catch-all `defp check(key, _val, _resp)` (line 101):

```elixir
  defp check("body_jsonpath", entries, resp) when is_list(entries) do
    decoded = decode_json(resp.body)
    Enum.each(entries, &check_jsonpath_entry(&1, decoded))
  end
```

And add these private helpers (anywhere among the other `defp`s, e.g. just above `decode_json/1`):

```elixir
  defp check_jsonpath_entry(%{"path" => path} = entry, decoded) do
    result = Bier.ConformanceJsonPath.fetch(decoded, path)

    cond do
      Map.has_key?(entry, "equals") ->
        expected = Map.fetch!(entry, "equals")

        assert result == {:ok, expected},
               "body_jsonpath #{path} equals mismatch:\n" <>
                 "  expected: #{inspect(expected)}\n  got:      #{inspect(result)}"

      Map.get(entry, "present") == true or Map.get(entry, "exists") == true ->
        assert match?({:ok, _}, result),
               "body_jsonpath #{path} expected to be present, got: #{inspect(result)}"

      Map.get(entry, "absent") == true ->
        assert result == :missing,
               "body_jsonpath #{path} expected to be absent, got: #{inspect(result)}"

      true ->
        raise "unsupported body_jsonpath predicate in entry: #{inspect(entry)}"
    end
  end

  defp check_jsonpath_entry(entry, _decoded) do
    raise "body_jsonpath entry missing \"path\": #{inspect(entry)}"
  end
```

> Note: `equals` uses plain `==` on `{:ok, value}`, matching the house semantics of `body_exact`/`body_json`. `equals: null` therefore means "present and equal to null" (`{:ok, nil}`), distinct from `absent`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/bier/conformance_assertions_test.exs`
Expected: PASS (all existing tests plus the five new `body_jsonpath` tests).

- [ ] **Step 5: Commit**

```bash
git add test/support/conformance_assertions.ex test/bier/conformance_assertions_test.exs
git commit -m "feat(#38): body_jsonpath matcher (equals/present/absent/exists)"
```

---

## Task 4: Enable non-openapi cases; gate openapi under `:openapi_doc`

**Files:**
- Modify: `test/conformance/conformance_test.exs:6-23`

Rationale: removing the `:jsonpath` pending arm entirely would turn the 28 openapi cases red (the OpenAPI document is still a stub until #39). Instead, enable the 11 non-openapi `body_jsonpath` cases and keep the openapi ones excluded under a new, honest reason `:openapi_doc` that points at #39 — CI stays green and nothing is dishonestly hidden.

- [ ] **Step 1: Update the moduledoc and the `pending_reason` cond**

In `test/conformance/conformance_test.exs`, replace the moduledoc reason sentence and the `pending_reason` cond.

Change the moduledoc line that lists reasons (lines 6-9) to include the new reason:

```elixir
  Cases the current harness cannot evaluate are tagged :pending and
  excluded (see pending_reason): :cli (no CLI), :jwt (needs JWT signing),
  :openapi_doc (openapi body_jsonpath cases need the generated OpenAPI
  document, #39), :status_text (req does not expose the HTTP reason phrase).
```

Replace the `pending_reason` cond (currently lines 16-23):

```elixir
    pending_reason =
      cond do
        c.kind == :cli ->
          :cli

        Map.has_key?(c.request, "jwt") ->
          :jwt

        # body_jsonpath now evaluates (see Bier.ConformanceJsonPath), EXCEPT the
        # openapi-area cases, which assert the generated OpenAPI document that is
        # still a stub until #39. Keep those excluded under an honest reason.
        Map.has_key?(c.expect, "body_jsonpath") and c.area == "openapi" ->
          :openapi_doc

        Map.has_key?(c.expect, "status_text") ->
          :status_text

        true ->
          nil
      end
```

- [ ] **Step 2: Run the full conformance suite**

Run: `mix test test/conformance/conformance_test.exs`
Expected: the 11 non-openapi `body_jsonpath` cases now execute (no longer excluded). The 28 openapi cases remain excluded (now reason `:openapi_doc`). The pre-existing unrelated failures (1467 RS256, 1616–1618 geojson) still fail; that is expected.

- [ ] **Step 3: Triage the newly-enabled cases**

Run and inspect just the newly-enabled cases:

Run: `mix test test/conformance/conformance_test.exs 2>&1 | grep -E "test (1010|1012|1016|1356|1358|1393|1501|1502|1619|1625|1703) "`

Expected: most/all pass. For any that **fail**, determine the cause:
- If the failure is a genuine unimplemented `lib/` behavior (out of scope for #38, which only adds the evaluator), do NOT fix `lib/` here. Tag that one case `:pending` with a precise reason and open/ξreference a tracking issue, so CI stays green and the gap is recorded. Add a clause to the cond, e.g.:

```elixir
        # <case id>: <behavior> not implemented yet — see issue #<n>.
        c.id == <case_id> ->
          :<reason>
```

- If the failure is a bug in this task's evaluator/matcher, fix the evaluator/matcher (return to Task 1–3) — never weaken a test to make it pass.

Record the outcome (which of the 11 are green, which are deferred and why) in the commit message.

- [ ] **Step 4: Run the whole suite and the CI gates**

Run:
```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```
Expected: `mix test` finishes with only the pre-existing unrelated failures (1467, 1616–1618) — no new failures. `format` and `compile` clean.

- [ ] **Step 5: Commit**

```bash
git add test/conformance/conformance_test.exs
git commit -m "test(#38): evaluate non-openapi body_jsonpath; gate openapi on #39"
```

---

## Self-Review

- **Spec coverage:** §3 components → Tasks 1–2 (`ConformanceJsonPath`), Task 3 (matcher), Task 4 (generator). §4 grammar/segments → Task 1 tests + impl. §4 resolve semantics (`:missing` for miss/range/type) → Task 2 tests. §5 matcher table (equals/present/exists/absent, unknown raises) → Task 3 tests. §6 error handling (malformed raises, unknown predicate raises, non-JSON flunks) → Tasks 1 & 3. §7 test plan → Tasks 1–4. §1 "28 openapi stay red pending #39, not re-hidden" → Task 4 `:openapi_doc` gating (refined from the spec's "remove the arm" to keep CI green; same spirit — reason now points explicitly at #39).
- **Placeholder scan:** none — every code step shows full code; Task 4 Step 3's `<case_id>`/`<n>` are intentional fill-ins only used if a real lib gap surfaces, with explicit instructions.
- **Type consistency:** `segment` = `{:key, String.t()} | {:index, non_neg_integer()}` used uniformly; `parse/1`→`resolve/2`→`fetch/2` signatures consistent across Tasks 1–3; matcher calls `Bier.ConformanceJsonPath.fetch/2` exactly as defined.

## Notes for the implementer

- This worktree (`worktree-jsonpath-conformance-assertions`) is isolated from the telemetry PR (#37). Run `mix deps.get` if `deps/` is absent.
- `test/support/**` is compiled only in `:test` (see `mix.exs` `elixirc_paths`), so the new module is available to tests but never shipped.
- Do not add a JSONPath dependency or `nimble_parsec` (see the design's §2 rationale).
