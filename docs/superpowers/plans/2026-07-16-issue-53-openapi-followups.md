# Issue #53 OpenAPI Follow-ups (items 2–4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close items 2–4 of GitHub issue #53 — the RPC `preferParams` `$ref` (plus the rest of the shared-parameters block parity), the overloaded-RPC path-item merge, and a per-role privileges cache for the root OpenAPI document.

**Architecture:** All wire-format changes live in `Bier.OpenAPI` (the Swagger 2.0 emitter) and are cited line-by-line to PostgREST v14.12 `src/PostgREST/Response/OpenAPI.hs`. The overload merge is an emitter-assembly rule (PostgREST resolves it during path-map construction, not introspection). The privileges cache is a new tiny GenServer-owned public ETS table per instance whose entries are stamped with a new `generation` ref on the `%Bier.SchemaCache{}` snapshot, so a schema-cache reload invalidates it without any coordination.

**Tech Stack:** Elixir (~> 1.18 floor, 1.20 pinned), ExUnit, Postgrex, `:ets` + `:persistent_term`.

## Global Constraints

- Never edit anything under `spec/` or `test/support/` or `test/conformance/` — frozen conformance ground truth (CLAUDE.md). Unit tests under `test/bier/` are NOT frozen: they were authored alongside `lib/` in PR #47 and may be corrected when the change is justified by a cited PostgREST v14.12 source line. Every such correction in this plan carries its citation.
- All 532 conformance cases must keep passing: run `mix test` (requires a local PostgreSQL; it drops+recreates `bier_test`).
- Wire-parity authority: `https://raw.githubusercontent.com/PostgREST/postgrest/v14.12/src/PostgREST/Response/OpenAPI.hs` (cited below as `OpenAPI.hs#L<n>`).
- Response serialization goes through `Bier.json_library()` — do not call `Jason`/`JSON` directly.
- `mix precommit` (format, hex.audit, compile --warnings-as-errors, credo --strict, docs, test) must pass before the branch is done.
- Execute on a fresh branch off `main` (suggested: `openapi-53-followups`), NOT on `spec-resync-step0`.
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

**Verified-safe against the frozen suite:** no conformance case asserts PATCH/DELETE parameter lists, `preferPost` enum values, the RPC `args` body `required` flag, any `rowFilter.*`/`on_conflict`/`preferParams` definition body, or overloaded functions (the fixtures deliberately avoid overloads). Checked via `grep -rn "preferPost\|preferReturn\|preferParams\|rowFilter\|on_conflict" spec/conformance/cases/` — only case 1661 matches, and it asserts `$ref` strings for GET/POST only.

---

### Task 1: Shared-parameters block parity (`preferParams` `$ref` + Prefer/param definitions)

Issue #53 item 3, extended to the rest of the parameter-definition table that the `spec/openapi.yaml` `gaps` section calls out ("the parameters block requires the full param-definition table"). Six micro-changes, each cited:

| # | Change | PostgREST source |
|---|--------|------------------|
| 1 | Add shared `preferParams` definition, **no `enum` key** (empty-enum suppression: `val "params"` returns `[]` in v14.12, and `enum_ .~ Nothing` when empty) | OpenAPI.hs#L171-188, OpenApiSpec.hs#L1088-1093 |
| 2 | RPC POST parameters become `[args body, {"$ref": "#/parameters/preferParams"}]` | OpenAPI.hs#L219-226 (`makeProcPostParams`) |
| 3 | RPC `args` body param `required` flips `false` → `true` | OpenAPI.hs#L222 (`& required ?~ True`) |
| 4 | `preferPost` enum gains the resolution values: `["return=representation", "return=minimal", "return=none", "resolution=ignore-duplicates", "resolution=merge-duplicates"]` | OpenAPI.hs#L184-186 + L234 (`makePreferParam ["return", "resolution"]`) |
| 5 | Add shared `on_conflict` definition; drop `select` from PATCH and DELETE parameter lists (PATCH = rowFilters ++ [body, preferReturn]; DELETE = rowFilters ++ [preferReturn]) | OpenAPI.hs#L242-248, L336-339 |
| 6 | `rowFilter.*` definitions: drop the `format` key (PostgREST never emits it there), add optional `description` from the column COMMENT | OpenAPI.hs#L299-308 (`makeRowFilter`: `description .~ colDescription c`, only `type_` set) |

**Files:**
- Modify: `lib/bier/openapi.ex` (`function_path_item/1` ~L92-121, `rpc_body_param/3` ~L129-140, `relation_path_item/1` PATCH/DELETE branches ~L191-207, `parameters/1` ~L221-317)
- Modify: `test/bier/openapi_test.exs` (PATCH/DELETE `$ref` lists ~L468-485, shared-params test ~L490-499, RPC post-body test ~L620-645)

**Interfaces:**
- Consumes: nothing new — pure change inside `Bier.OpenAPI.build/1`.
- Produces: unchanged signature `Bier.OpenAPI.build(input :: map()) :: map()`; document content changes as listed above. Task 2 edits the same file — do Task 1 first, commit, then Task 2.

- [ ] **Step 1: Write the failing tests**

In `test/bier/openapi_test.exs`:

(a) In the `"post/patch/delete params, responses, tags (1661/1662)"` test, change the PATCH and DELETE expectations to drop `#/parameters/select` (justification: OpenAPI.hs#L336-339 — `patchOp` params are `rs <> ["body." <> tn, "preferReturn"]`, `deletOp` params are `rs <> ["preferReturn"]`; the current `select` entries were never in PostgREST's lists):

```elixir
      assert Enum.map(item["patch"]["parameters"], & &1["$ref"]) == [
               "#/parameters/rowFilter.child_entities.id",
               "#/parameters/rowFilter.child_entities.name",
               "#/parameters/rowFilter.child_entities.parent_id",
               "#/parameters/body.child_entities",
               "#/parameters/preferReturn"
             ]

      assert item["patch"]["responses"]["204"]["description"] == "No Content"

      assert Enum.map(item["delete"]["parameters"], & &1["$ref"]) == [
               "#/parameters/rowFilter.child_entities.id",
               "#/parameters/rowFilter.child_entities.name",
               "#/parameters/rowFilter.child_entities.parent_id",
               "#/parameters/preferReturn"
             ]
```

(b) In the `"parameters block has shared targets and per-column rowFilter (1661)"` test, extend the shared-key list and add shape assertions (replace the test body):

```elixir
    test "parameters block has shared targets and per-column rowFilter (1661)", %{doc: doc} do
      params = doc["parameters"]

      for k <-
            ~w(select order range rangeUnit offset limit preferCount preferPost preferReturn preferParams on_conflict) do
        assert Map.has_key?(params, k), "missing shared parameter #{k}"
      end

      assert Map.has_key?(params, "rowFilter.child_entities.id")
      assert Map.has_key?(params, "body.child_entities")

      # preferParams: empty enum is suppressed — the key is absent entirely
      # (OpenAPI.hs#L171-188 makePreferParam; OpenApiSpec.hs#L1088).
      assert params["preferParams"] == %{
               "name" => "Prefer",
               "in" => "header",
               "type" => "string",
               "required" => false,
               "description" => "Preference"
             }

      # preferPost carries return AND resolution values, in this order
      # (OpenAPI.hs#L184-186, makePreferParam ["return", "resolution"]).
      assert params["preferPost"]["enum"] == [
               "return=representation",
               "return=minimal",
               "return=none",
               "resolution=ignore-duplicates",
               "resolution=merge-duplicates"
             ]

      # on_conflict is unconditionally in the shared block (OpenAPI.hs#L242-248).
      assert params["on_conflict"] == %{
               "name" => "on_conflict",
               "in" => "query",
               "type" => "string",
               "required" => false,
               "description" => "On Conflict"
             }

      # rowFilter has no format key; description comes from the column COMMENT
      # (OpenAPI.hs#L299-308 makeRowFilter).
      assert params["rowFilter.child_entities.id"] == %{
               "name" => "id",
               "in" => "query",
               "type" => "string",
               "required" => false
             }
    end
```

Note: if the `child_entities` fixture struct in this test's `setup` gives the `id` column a comment, the expected map must instead include that `"description"`. Check the `col_map/2` helper at the top of the file — as of today it sets `comment: nil`, so the shape above is right; also add one column-with-comment assertion if a commented column exists in the setup (skip if none does).

(c) In the `"post body schema (1673)"` test, add after the existing `body[...]` assertions:

```elixir
      # PostgREST marks the args body param required (OpenAPI.hs#L222).
      assert body["required"] == true

      # The second POST parameter is the shared preferParams ref
      # (OpenAPI.hs#L219-226 makeProcPostParams).
      assert Enum.at(
               doc["paths"]["/rpc/varied_arguments_openapi"]["post"]["parameters"],
               1
             ) == %{"$ref" => "#/parameters/preferParams"}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/bier/openapi_test.exs`
Expected: FAIL — patch/delete lists still contain `select`; `preferParams`/`on_conflict` missing; `preferPost` enum too short; rowFilter carries `format`; `args` required is `false`; no `$ref` at POST parameters[1].

- [ ] **Step 3: Implement the emitter changes**

In `lib/bier/openapi.ex`:

(a) `function_path_item/1` — append the ref to the POST parameters (OpenAPI.hs#L219-226):

```elixir
    post =
      %{
        "tags" => tags,
        "parameters" => [
          rpc_body_param(fun, summary, description),
          %{"$ref" => "#/parameters/preferParams"}
        ],
        "responses" => %{"200" => %{"description" => "OK"}}
      }
      |> put_optional("summary", summary)
      |> put_optional("description", description)
```

(b) `rpc_body_param/3` — flip required (OpenAPI.hs#L222):

```elixir
    %{"name" => "args", "in" => "body", "required" => true, "schema" => schema}
```

(c) `relation_path_item/1` — drop `select` from PATCH and DELETE (OpenAPI.hs#L336-339):

```elixir
    |> put_method(
      :patch in methods,
      "patch",
      op.(%{
        "parameters" => row_filter_refs(rel) ++ refs(["body.#{rel.name}", "preferReturn"]),
        "responses" => %{"204" => %{"description" => "No Content"}}
      })
    )
    |> put_method(
      :delete in methods,
      "delete",
      op.(%{
        "parameters" => row_filter_refs(rel) ++ refs(["preferReturn"]),
        "responses" => %{"204" => %{"description" => "No Content"}}
      })
    )
```

(d) `parameters/1` shared map — add `preferParams` (no enum: v14.12's `makePreferParam ["params"]` produces an empty value list and the empty enum is suppressed, OpenAPI.hs#L180 + OpenApiSpec.hs#L1088) and `on_conflict` (OpenAPI.hs#L242-248), and extend `preferPost`'s enum (OpenAPI.hs#L184-186):

```elixir
      "preferParams" => %{
        "name" => "Prefer",
        "in" => "header",
        "type" => "string",
        "required" => false,
        "description" => "Preference"
      },
      "on_conflict" => %{
        "name" => "on_conflict",
        "in" => "query",
        "type" => "string",
        "required" => false,
        "description" => "On Conflict"
      },
```

and

```elixir
      "preferPost" => %{
        "name" => "Prefer",
        "in" => "header",
        "type" => "string",
        "required" => false,
        "enum" => [
          "return=representation",
          "return=minimal",
          "return=none",
          "resolution=ignore-duplicates",
          "resolution=merge-duplicates"
        ],
        "description" => "Preference"
      },
```

(e) `parameters/1` row_filters comprehension — drop `format`, add optional description (OpenAPI.hs#L299-308):

```elixir
    row_filters =
      for rel <- input.relations, col <- rel.columns, into: %{} do
        {"rowFilter.#{rel.name}.#{col.name}",
         %{
           "name" => col.name,
           "in" => "query",
           "type" => "string",
           "required" => false
         }
         |> put_optional("description", col.comment)}
      end
```

- [ ] **Step 4: Run the unit tests, then the full suite**

Run: `mix test test/bier/openapi_test.exs`
Expected: PASS.

Run: `mix test --only area:openapi`
Expected: all 28 openapi conformance cases PASS (they assert none of the changed shapes; 1673 asserts `parameters[0]` fields only, 1661 asserts GET/POST refs only).

Run: `mix test`
Expected: full suite PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/bier/openapi.ex test/bier/openapi_test.exs
git commit -m "openapi: align shared parameters block with PostgREST v14.12

Adds the preferParams \$ref on RPC POST (issue #53 item 3) and the rest of
the makeParamDefs parity: preferParams def with suppressed empty enum,
preferPost resolution enum values, on_conflict def, args body required:true,
PATCH/DELETE parameter lists without select, rowFilter description over
format. Each cited to Response/OpenAPI.hs.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Overloaded-RPC path-item merge

Issue #53 item 2. Today `Bier.Plugs.ActionController.function_inputs/1` flat-maps every overload into the builder list and `Bier.OpenAPI.function_paths/1` builds `Map.new(...)` over it, so an arbitrary overload (introspection row order) wins the `/rpc/<fn>` key. PostgREST's rule (verified in v14.12 source): overloads are sorted **ascending by parameter count** at schema-cache build (`SchemaCache.hs#L292-294` `map sort` with the `Routine` `Ord` instance, `Routine.hs#L89-94`), and path assembly is `InsOrdHashMap.fromList` where the **last insert wins** (`OpenAPI.hs#L381-383`), so **the overload with the most parameters supplies the entire path item** — its GET query params, its POST body schema, and its volatility decides whether GET exists. There is no cross-overload parameter merging. (Ties on parameter count fall through to the rest of PostgREST's `Ord` tuple — comment, params, return type — a pathological corner we approximate with a stable sort; noted in a code comment.)

The fix belongs in the emitter (`function_paths/1`), mirroring where PostgREST resolves it; `function_inputs/1` in the controller stays a plain flatten.

**Files:**
- Modify: `lib/bier/openapi.ex` (`function_paths/1`, ~L88-90)
- Modify: `test/bier/openapi_test.exs` (add one describe block; the file's existing `build_fns/1` helper builds a doc from a function-input list)

**Interfaces:**
- Consumes: `input.functions` — list of `%{name, comment, volatility, in_params}` (possibly several entries per name = overloads), exactly what `ActionController.function_inputs/1` already produces.
- Produces: `Bier.OpenAPI.build/1` unchanged signature; one path item per distinct `/rpc/<name>`.

- [ ] **Step 1: Write the failing test**

Append to `test/bier/openapi_test.exs` (inside the top-level module, after the `"rpc path items (1670-1674)"` describe; reuse the file's existing `p/4` and `build_fns/1` helpers):

```elixir
  describe "overloaded rpc functions merge into one path item" do
    # PostgREST sorts a name's overloads ascending by parameter count and the
    # last inserted path item wins, so the most-parameters overload supplies
    # the whole /rpc/<fn> item (SchemaCache.hs#L292, Routine.hs#L89,
    # OpenAPI.hs#L381). Issue #53 item 2.
    test "most-parameters overload wins, regardless of input order" do
      one_arg = %{
        name: "overloaded",
        comment: nil,
        volatility: :volatile,
        in_params: [p("a", "integer", false, false)]
      }

      two_args = %{
        name: "overloaded",
        comment: nil,
        volatility: :immutable,
        in_params: [
          p("a", "integer", false, false),
          p("b", "text", false, false)
        ]
      }

      for fns <- [[one_arg, two_args], [two_args, one_arg]] do
        doc = build_fns(fns)
        item = doc["paths"]["/rpc/overloaded"]

        # exactly one path item, shaped by the two-arg overload:
        # immutable -> GET present, and the POST body lists both args.
        assert Map.has_key?(item, "get")

        body = hd(item["post"]["parameters"])
        assert Map.keys(body["schema"]["properties"]) |> Enum.sort() == ["a", "b"]

        assert Enum.map(item["get"]["parameters"], & &1["name"]) == ["a", "b"]
      end
    end

    test "a volatile winner drops GET even when a stable overload exists" do
      stable_one = %{
        name: "ovl2",
        comment: nil,
        volatility: :stable,
        in_params: [p("a", "integer", false, false)]
      }

      volatile_two = %{
        name: "ovl2",
        comment: nil,
        volatility: :volatile,
        in_params: [
          p("a", "integer", false, false),
          p("b", "text", false, false)
        ]
      }

      item = build_fns([stable_one, volatile_two])["paths"]["/rpc/ovl2"]
      refute Map.has_key?(item, "get")
      assert Map.has_key?(item, "post")
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/bier/openapi_test.exs`
Expected: FAIL — with `[two_args, one_arg]` input order, `Map.new/2` last-wins gives the one-arg overload: the POST body lists only `a`, and (volatile) there is no GET.

- [ ] **Step 3: Implement the merge in the emitter**

In `lib/bier/openapi.ex`, replace `function_paths/1`:

```elixir
  defp function_paths(input) do
    input.functions
    |> Enum.group_by(& &1.name)
    |> Map.new(fn {name, overloads} ->
      {"/rpc/#{name}", function_path_item(winning_overload(overloads))}
    end)
  end

  # PostgREST sorts a name's overloads ascending by parameter count and the
  # last-inserted path item wins, so the most-parameters overload supplies the
  # entire /rpc/<fn> item (SchemaCache.hs decodeFuncs + Routine Ord;
  # OpenAPI.hs makePathItems fromList). Parameter-count ties fall back to
  # input order (stable sort), approximating PostgREST's full Ord tuple.
  defp winning_overload(overloads) do
    overloads |> Enum.sort_by(&length(&1.in_params)) |> List.last()
  end
```

- [ ] **Step 4: Run the tests**

Run: `mix test test/bier/openapi_test.exs`
Expected: PASS.

Run: `mix test`
Expected: full suite PASS (the conformance fixtures contain no overloaded exposed functions — grouping by name is an identity transform for them).

- [ ] **Step 5: Commit**

```bash
git add lib/bier/openapi.ex test/bier/openapi_test.exs
git commit -m "openapi: merge overloaded functions into one /rpc path item

The most-parameters overload supplies the whole path item, mirroring
PostgREST's overload sort + last-insert-wins assembly (issue #53 item 2).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Per-role privileges cache for the root document

Issue #53 item 4. In the default `openapi-mode = follow-privileges`, every `GET /` runs `Bier.Introspection.privileges/3` (two catalog queries) against the pool because the result depends on the request role. Cache it per `{instance, role}`, invalidated by schema-cache reload — which matches PostgREST semantics, since PostgREST's privilege-derived document content also only refreshes when its schema cache reloads, not per request.

Mechanism: add a `generation` field (a `make_ref()`) to `%Bier.SchemaCache{}`, stamped on every introspection load. A new `Bier.PrivilegesCache` GenServer per instance owns a **public** ETS table (tid published once via `:persistent_term`); readers hit the table directly (no mailbox on the hot path) and store entries as `{role, generation, privs}`. A lookup whose generation doesn't match the current snapshot's is a miss — the loader re-queries and overwrites. No flushing, no coordination, no race: two concurrent first-requests for the same role both query and insert idempotently.

**Files:**
- Modify: `lib/bier/schema_cache.ex` (struct/type + `introspect/2`)
- Create: `lib/bier/privileges_cache.ex`
- Modify: `lib/bier.ex` (children list in `init/1`, ~L456-474)
- Modify: `lib/bier/plugs/action_controller.ex` (`build_openapi_document/2` ~L185-206, `filter_by_mode/5` → `/6` ~L208-235)
- Modify: `CLAUDE.md` (boot-sequence child list sentence)
- Test: `test/bier/privileges_cache_test.exs` (new)

**Interfaces:**
- Consumes: `Bier.Introspection.privileges(pg, [schema], role) :: %{relations: map(), functions: map()}` (existing, unchanged); `Bier.SchemaCache.get(name)` (existing).
- Produces:
  - `%Bier.SchemaCache{}` gains `generation :: reference() | nil` (nil only for the never-loaded empty struct).
  - `Bier.PrivilegesCache.start_link(%Bier.Config{}) :: GenServer.on_start()`
  - `Bier.PrivilegesCache.fetch(name :: Bier.name(), role :: String.t(), generation :: reference() | nil, loader :: (-> map())) :: map()`

- [ ] **Step 1: Write the failing test**

Create `test/bier/privileges_cache_test.exs`:

```elixir
defmodule Bier.PrivilegesCacheTest do
  use ExUnit.Case, async: true

  defp unique_name, do: :"priv_cache_#{System.unique_integer([:positive])}"

  defp spy_loader(parent, result) do
    fn ->
      send(parent, :loader_ran)
      result
    end
  end

  test "caches per role within a generation; a new generation invalidates" do
    name = unique_name()
    start_supervised!({Bier.PrivilegesCache, %Bier.Config{name: name}})

    gen1 = make_ref()
    privs = %{relations: %{}, functions: %{}}
    loader = spy_loader(self(), privs)

    assert Bier.PrivilegesCache.fetch(name, "web_anon", gen1, loader) == privs
    assert_received :loader_ran

    assert Bier.PrivilegesCache.fetch(name, "web_anon", gen1, loader) == privs
    refute_received :loader_ran

    # a different role is its own entry
    assert Bier.PrivilegesCache.fetch(name, "admin", gen1, loader) == privs
    assert_received :loader_ran

    # a schema-cache reload stamps a new generation -> first fetch re-runs
    gen2 = make_ref()
    assert Bier.PrivilegesCache.fetch(name, "web_anon", gen2, loader) == privs
    assert_received :loader_ran

    assert Bier.PrivilegesCache.fetch(name, "web_anon", gen2, loader) == privs
    refute_received :loader_ran
  end

  test "an instance without a cache table falls back to the loader every time" do
    name = unique_name()
    loader = spy_loader(self(), %{relations: %{}, functions: %{}})

    Bier.PrivilegesCache.fetch(name, "web_anon", make_ref(), loader)
    assert_received :loader_ran

    Bier.PrivilegesCache.fetch(name, "web_anon", make_ref(), loader)
    assert_received :loader_ran
  end

  test "schema cache snapshots carry a fresh generation ref" do
    # The never-loaded empty struct has no generation.
    assert %Bier.SchemaCache{}.generation == nil
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/bier/privileges_cache_test.exs`
Expected: FAIL to compile — `Bier.PrivilegesCache` does not exist; `%Bier.SchemaCache{}` has no `:generation` key.

- [ ] **Step 3: Implement the cache module and the generation stamp**

Create `lib/bier/privileges_cache.ex`:

```elixir
defmodule Bier.PrivilegesCache do
  @moduledoc """
  Per-instance, per-role cache of `Bier.Introspection.privileges/3` results
  for the root OpenAPI document (`openapi-mode = follow-privileges`).

  Entries are stamped with the `%Bier.SchemaCache{}` snapshot `generation`,
  so a schema-cache reload naturally invalidates the whole cache: the first
  root request per role after a reload misses (generation mismatch),
  re-queries, and overwrites its entry. That matches PostgREST, whose
  privilege-derived document content also refreshes on schema reload rather
  than per request.

  The GenServer owns a **public** ETS table whose tid is published once via
  `:persistent_term` — cache hits are direct ETS reads, never a process
  call. Two concurrent misses for the same role both run the loader and
  insert idempotently; the loader reads live catalog state, so either
  result is valid.
  """

  use GenServer

  @doc false
  def start_link(%Bier.Config{name: name}) do
    GenServer.start_link(__MODULE__, name, name: Bier.Registry.via(name, __MODULE__))
  end

  @doc """
  Returns the cached privileges for `role` under snapshot `generation`,
  running `loader` (and caching its result) on a miss.

  Falls back to a plain `loader.()` call when the instance has no cache
  table (e.g. an instance booted without this child, or direct test calls).
  """
  @spec fetch(Bier.name(), String.t(), reference() | nil, (-> map())) :: map()
  def fetch(name, role, generation, loader) do
    case :persistent_term.get(key(name), nil) do
      nil ->
        loader.()

      tid ->
        case :ets.lookup(tid, role) do
          [{^role, ^generation, privs}] ->
            privs

          _ ->
            privs = loader.()
            :ets.insert(tid, {role, generation, privs})
            privs
        end
    end
  end

  @impl GenServer
  def init(name) do
    tid = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
    # Replaced (global-GC'd) only at instance boot / GenServer restart —
    # never per request. Like the SchemaCache entry, it is not erased when
    # the instance stops.
    :persistent_term.put(key(name), tid)
    {:ok, tid}
  end

  defp key(name), do: {Bier, :privileges_cache, name}
end
```

In `lib/bier/schema_cache.ex`, extend the struct, type, and `introspect/2`:

```elixir
  defstruct relations: %{},
            functions: %{},
            media_handlers: [],
            schema_comment: nil,
            postgis: false,
            generation: nil

  @type t :: %__MODULE__{
          relations: map(),
          functions: map(),
          media_handlers: list(),
          schema_comment: String.t() | nil,
          postgis: boolean(),
          generation: reference() | nil
        }
```

```elixir
  defp introspect(conn, schemas) do
    %__MODULE__{
      relations: Bier.Introspection.run(conn, schemas),
      functions: Bier.Introspection.functions(conn, schemas),
      media_handlers: Bier.Introspection.media_handlers(conn, schemas),
      schema_comment: Bier.Introspection.schema_comment(conn, hd(schemas)),
      postgis: Bier.Introspection.postgis?(conn),
      # Stamps this snapshot for downstream generation-keyed caches
      # (Bier.PrivilegesCache): a reload mints a new ref, invalidating them.
      generation: make_ref()
    }
  end
```

- [ ] **Step 4: Run the unit test**

Run: `mix test test/bier/privileges_cache_test.exs`
Expected: PASS.

- [ ] **Step 5: Wire the child into the instance supervisor and the controller**

In `lib/bier.ex` `init/1`, insert the cache child after `{Bier.PoolMonitor, conf}` and before the `DynamicSupervisor` entry:

```elixir
        # Owns the per-role privileges ETS cache used by the root OpenAPI
        # document (follow-privileges). Started before HttpServerStarter so
        # the table exists before the first request can arrive.
        {Bier.PrivilegesCache, conf},
```

In `lib/bier/plugs/action_controller.ex`, thread the snapshot generation through and fetch via the cache. In `build_openapi_document/2` change the `filter_by_mode` call:

```elixir
    {relations, functions} =
      filter_by_mode(config, role, schema, relations, functions, cache.generation)
```

and change `filter_by_mode/5` to `/6`, with the privileges branch going through the cache (update the function head and the comment above `Only privileges/3 runs per request` in `build_openapi_document`'s doc comment to say the lookup is cached per role and generation):

```elixir
  defp filter_by_mode(config, role, schema, relations, functions, generation) do
    case config.openapi_mode do
      "ignore-privileges" ->
        {relations, functions}

      _follow_privileges when is_nil(role) ->
        {relations, functions}

      _follow_privileges ->
        pg = Registry.via(config.name, Postgrex)

        # Cached per {role, schema-cache generation}: a reload invalidates,
        # so the document tracks DDL/grant changes exactly as fast as the
        # rest of the snapshot does (issue #53 item 4).
        privs =
          Bier.PrivilegesCache.fetch(config.name, role, generation, fn ->
            Bier.Introspection.privileges(pg, [schema], role)
          end)

        rels =
          for r <- relations,
              %{select?: true} = grants <- [privs.relations[{r.schema, r.name}]] do
            %{r | methods: granted_methods(r, grants)}
          end

        fns =
          functions
          |> Enum.filter(fn {{s, n}, _overloads} ->
            match?(%{execute?: true}, privs.functions[{s, n}])
          end)
          |> Map.new()

        {rels, fns}
    end
  end
```

Also update the stale comment block above `build_openapi_document/2` (it currently ends "Only `privileges/3` runs per request, because it depends on the request role.") to:

```elixir
  # ... Only the per-role privileges lookup depends on the request, and it is
  # served from Bier.PrivilegesCache (keyed by role + snapshot generation);
  # the catalog is queried once per role per schema-cache load.
```

In `CLAUDE.md`, update the boot-sequence sentence "the `Bier` supervisor starts three children in order: ..." to name the actual order: the per-instance Postgrex pool, `Bier.PoolMonitor`, `Bier.PrivilegesCache`, the per-instance `DynamicSupervisor`, then `Bier.HttpServerStarter`.

- [ ] **Step 6: Verify against the live suite**

Run: `mix test test/bier/privileges_cache_test.exs test/bier/openapi_test.exs`
Expected: PASS.

Run: `mix test --only area:openapi`
Expected: PASS — cases 1675/1676 (follow-privileges anon/privileged role) and 1677 (ignore-privileges) now exercise the cache path against the shared conformance instance; 1675/1676 use different roles, so each populates its own entry.

Run: `mix test`
Expected: full suite PASS (the schema-cache reload tests assert snapshot swaps; the new `generation` field piggybacks on the same swap).

- [ ] **Step 7: Commit**

```bash
git add lib/bier/privileges_cache.ex lib/bier/schema_cache.ex lib/bier.ex \
        lib/bier/plugs/action_controller.ex test/bier/privileges_cache_test.exs CLAUDE.md
git commit -m "openapi: cache the per-role privileges lookup at the root

GET / in follow-privileges mode no longer runs two catalog queries per
request: results are cached per {instance, role} in a public ETS table and
stamped with the schema-cache snapshot generation, so a reload invalidates
them with zero coordination (issue #53 item 4).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Final gates + follow-up issue draft

**Files:**
- No source changes. Runs the CI gates and drafts (does not create) a follow-up issue.

**Interfaces:**
- Consumes: the completed Tasks 1–3.
- Produces: a green `mix precommit`; a drafted issue body reported to the operator.

- [ ] **Step 1: Run every CI gate**

Run: `mix precommit`
Expected: all gates PASS (format, deps.unlock check, hex.audit, compile --warnings-as-errors, credo --strict, docs, full test suite).

- [ ] **Step 2: Report the drafted follow-up issue to the operator (do NOT `gh issue create` without approval)**

During Task 1's research, three further uncased wire gaps vs PostgREST v14.12 were verified in source but are beyond issue #53's items; present this draft to the user and create it only on their approval:

> **Title:** OpenAPI root document: remaining wire gaps vs PostgREST v14.12
>
> Follow-ups discovered while closing #53 items 2–3 (all verified against `Response/OpenAPI.hs`, none asserted by a conformance case):
>
> - [ ] **Root `"/"` path item.** PostgREST emits a `paths./` entry (GET, tags `["Introspection"]`, summary "OpenAPI description (this document)", produces `[application/openapi+json, application/json]`) — `makeRootPathItem`, OpenAPI.hs#L370-379. Bier omits it.
> - [ ] **RPC operation `produces` list.** Every RPC operation carries `produces: [application/json, application/vnd.pgrst.object+json;nulls=stripped, application/vnd.pgrst.object+json]` — OpenAPI.hs#L360. Bier emits no `produces` on RPC operations.
> - [ ] **Default `host`/`basePath` without a proxy.** `postgrestSpec` always receives scheme/host/port/basePath (from `pickProxy` falling back to server config) — OpenAPI.hs#L393+. Verify what a live 14.12 emits with no `openapi-server-proxy-uri` and align (Bier currently emits neither `host` nor `schemes` in that case).
>
> Source: research for #53; see `docs/superpowers/plans/2026-07-16-issue-53-openapi-followups.md`.

- [ ] **Step 3: Hand off**

Implementation complete for items 2–4 of #53. Use superpowers:finishing-a-development-branch to choose merge/PR. Suggested PR title: "OpenAPI follow-ups: parameters-block parity, overload merge, per-role privileges cache (#53)". The PR closes items 2–4 of #53 (tick its checkboxes on merge); item 1 is covered by `docs/superpowers/plans/2026-07-16-openapi-30-emitter.md`.
