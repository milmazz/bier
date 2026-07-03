# OpenAPI Document Generation (#39) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the stub `root_openapi_doc/0` with a real Swagger 2.0 document generated from `Bier.Introspection`, so the 28 conformance cases in 1650–1680 pass.

**Architecture:** A new pure module `Bier.OpenAPI` turns an introspection snapshot (relations + functions + comments + privileges) into a Swagger 2.0 map serialized via `Bier.json_library/0`. Introspection is extended to capture COMMENTs, enum labels, char maxLength, and per-role privileges. The wire format is a thin presentation layer over the introspection model, so a future OpenAPI 3.0 emitter is additive (a separate selling-point follow-up, not in scope here). `ActionController` resolves the request role via `Bier.Auth.resolve/2`, applies `openapi-mode`, and calls `Bier.OpenAPI.build/1`.

**Tech Stack:** Elixir 1.19 / OTP 28, Postgrex, Plug, NimbleOptions (config schema in `lib/bier.ex`), the existing conformance harness (`test/conformance/conformance_test.exs`, `Bier.ConformanceJsonPath`).

---

## Scope & references

- Issue: #39 — 28 cases: **1650, 1651, 1654–1677, 1679, 1680**. (1652/1653 = 406, 1678 = disabled 404, 1681 = HEAD, 1682 = db-root-spec are already handled elsewhere and are NOT in this slice; do not regress them.)
- Behavior model (authoritative, with per-case source lines): `spec/openapi.yaml`.
- Case files: `spec/conformance/cases/16XX_*.yaml`. The `body_jsonpath` assertions ARE the oracle.
- Fixtures (already present, do not modify): `spec/conformance/fixtures.sql` — schema/table/view/column/function COMMENTs (lines 1344–1366), `enum_menagerie_type` (171), `openapi_types` (670), `openapi_defaults` (694), `menagerie` (654), `child_entities`/`grandchild_entities`/`child_entities_view`, `varied_arguments_openapi` (1254), `reset_table` (1280, VOLATILE), `getallusers` (1285, STABLE), `authors_only`, `privileged_hello`.

### The two type-mapping modes (critical — they differ)

1. **schema mode** — used for table-definition column properties and RPC POST-body properties:
   - `json`/`jsonb` → `%{"format" => "json"}` (NO `type` key).
   - arrays → `%{"format" => "<elem>[]", "type" => "array", "items" => <item>}` where `<item>` is `%{"type" => <base>}`, or `%{}` for `json[]`/`jsonb[]`.
   - enum → `%{"type" => "string", "format" => "<schema>.<enumtype>", "enum" => [labels...]}`.
2. **query-param mode** — used for RPC GET query parameters:
   - `json`/`jsonb` → `%{"type" => "string", "format" => "json"}` (note `type: string`).
   - non-variadic arrays → `%{"type" => "string", "format" => "<elem>[]"}` (a string, not an array).
   - VARIADIC array → `%{"type" => "array", "collectionFormat" => "multi", "items" => %{"type" => <base>, "format" => "<elem>"}}`.
   - scalars → same `{type, format}` as schema mode.

Base scalar mapping (shared by both modes), with `format` = verbatim pg type EXCEPT the integer remaps:

| pg type | type | format |
|---|---|---|
| character varying | string | character varying |
| character | string | character (plus `maxLength: n`) |
| text | string | text |
| boolean | boolean | boolean |
| smallint | integer | int32 |
| integer | integer | int32 |
| bigint | integer | int64 |
| numeric | number | numeric |
| real | number | real |
| double precision | number | double precision |
| json | (none) | json |
| jsonb | (none) | jsonb |

Array element base `type` (for `items`): text/character/character varying → string; integer/smallint/bigint → integer; numeric/real/double precision → number; boolean → boolean; json/jsonb → items is `%{}`.

### Comment helpers (shared)

- `split_comment(nil) -> {nil, nil}`; `split_comment(text)`: split on the first `"\n"`. No newline → `{text, nil}`. Else `{head, rest}` where `rest` has leading `\n` stripped and becomes `nil` if empty. Used for: schema → `{info.title, info.description}`; table/view → `{operation.summary, operation.description}`; function → `{operation.summary, operation.description}` and POST-body description = `title <> "\n\n" <> description` (when both present).
- Column property `description` = `[comment, pk_note, fk_note] |> Enum.reject(&is_nil/1) |> Enum.join("\n\n")` (nil if empty), where:
  - `pk_note = "Note:\nThis is a Primary Key.<pk/>"` when the column is a PK member.
  - `fk_note = "Note:\nThis is a Foreign Key to `#{ref_rel}.#{ref_col}`.<fk table='#{ref_rel}' column='#{ref_col}'/>"` for a single-column FK (`length(columns) == 1`).

### Default decoding (case 1669)

`decode_default(nil, _) -> :omit`. Otherwise strip a trailing `::<type>` cast, then:
- boolean type → `"true"`→`true`, `"false"`→`false`.
- integer types (smallint/integer/bigint) → `String.to_integer`.
- numeric/real/double precision → `String.to_float` (handle integer-looking via Float.parse).
- everything else → strip surrounding single quotes, keep as string ("'default'::text" → "default", "'1900-01-01'::date" → "1900-01-01", "'13:00:00'::time without time zone" → "13:00:00").

---

## File Structure

- **Create** `lib/bier/openapi.ex` — `Bier.OpenAPI`: top-level `build/1` assembling the Swagger map (info, externalDocs, paths, definitions, parameters, security). Sub-responsibilities kept as private functions or small sibling modules:
  - **Create** `lib/bier/openapi/types.ex` — `Bier.OpenAPI.Types`: `schema(type, opts)` and `query_param(type, opts)` returning the two mode maps; `default(value, type)`.
- **Modify** `lib/bier/introspection.ex` — add `comment` to `Relation`, add `comment`/`enum_labels`/`max_length` to the column map, add `comment` to the function map; new `schema_comment/2`; new `privileges/3` (per-role table/function access).
- **Modify** `lib/bier.ex` — add `openapi_security_active` to the NimbleOptions schema (~line 263, after `db_root_spec`).
- **Modify** `lib/bier/config.ex` — add `openapi_security_active` struct field + type + default `false`.
- **Modify** `lib/bier/plugs/action_controller.ex` — replace `root_openapi_doc/0` (lines 168–177) with a call into `Bier.OpenAPI.build/1`; resolve the request role; apply `openapi-mode`; pass `openapi_security_active`.
- **Modify** `test/conformance/conformance_test.exs` — remove the `:openapi_doc` pending gate (lines ~24–30) so the 28 cases run.
- **Create** `test/bier/openapi_test.exs` — unit tests for `Bier.OpenAPI`/`Bier.OpenAPI.Types` over hand-built `Relation` structs (fast, DB-free).
- **Create/Modify** `test/bier/introspection_test.exs` — integration tests for the new comment/enum/maxLength/privilege fields against the live fixtures.

---

## Phase A — `Bier.OpenAPI` builder (pure, unit-tested with hand-built structs)

Phase A builds the whole document against the **extended** `Relation`/column/function shapes. Those struct fields are added first in Task A0 so unit tests can construct inputs without a DB.

### Task A0: Extend the introspection structs (fields only, no queries yet)

**Files:**
- Modify: `lib/bier/introspection.ex:28-81` (the `Relation` module — `column` type, `t` type, `defstruct`)

- [ ] **Step 1: Add the new struct fields**

In `Bier.Introspection.Relation`, extend the `column` type and add `comment` to the relation:

```elixir
@type column :: %{
        name: String.t(),
        type: String.t(),
        pk?: boolean(),
        notnull?: boolean(),
        default: String.t() | nil,
        composite?: boolean(),
        data_rep: data_rep() | nil,
        comment: String.t() | nil,
        enum_labels: [String.t()] | nil,
        max_length: pos_integer() | nil
      }
```

Add `comment: String.t() | nil` to the `Relation.t` type and `comment: nil` to `defstruct`.

- [ ] **Step 2: Default the new column keys where columns are built**

In `run/2`, where each column map is built (the `Enum.map(fn c -> ... end)` block around `lib/bier/introspection.ex:109`), add `comment: c[:comment]`, `enum_labels: c[:enum_labels]`, `max_length: c[:max_length]` so existing callers don't crash. They will be populated for real in Phase B; for now they may be `nil`.

- [ ] **Step 3: Compile**

Run: `mix compile --warnings-as-errors`
Expected: clean compile.

- [ ] **Step 4: Run existing suite (no behavior change yet)**

Run: `mix test test/bier/introspection_test.exs`
Expected: PASS (or, if the file is empty/missing, no failures introduced elsewhere — run `mix test` and confirm still 3 pre-existing geojson failures only).

- [ ] **Step 5: Commit**

```bash
git add lib/bier/introspection.ex
git commit -m "feat(#39): extend introspection structs for openapi (comment/enum/maxLength)"
```

### Task A1: `Bier.OpenAPI.Types` — type mapping

**Files:**
- Create: `lib/bier/openapi/types.ex`
- Test: `test/bier/openapi_test.exs`

- [ ] **Step 1: Write the failing test** (cases 1665, 1666, 1667, 1668)

```elixir
defmodule Bier.OpenAPITest do
  use ExUnit.Case, async: true
  alias Bier.OpenAPI.Types

  describe "schema/2 scalars (1665)" do
    test "varchar/char/text/bool/ints/numbers" do
      assert Types.schema("character varying", []) == %{"type" => "string", "format" => "character varying"}
      assert Types.schema("character", max_length: 1) == %{"type" => "string", "format" => "character", "maxLength" => 1}
      assert Types.schema("text", []) == %{"type" => "string", "format" => "text"}
      assert Types.schema("boolean", []) == %{"type" => "boolean", "format" => "boolean"}
      assert Types.schema("smallint", []) == %{"type" => "integer", "format" => "int32"}
      assert Types.schema("integer", []) == %{"type" => "integer", "format" => "int32"}
      assert Types.schema("bigint", []) == %{"type" => "integer", "format" => "int64"}
      assert Types.schema("numeric", []) == %{"type" => "number", "format" => "numeric"}
      assert Types.schema("real", []) == %{"type" => "number", "format" => "real"}
      assert Types.schema("double precision", []) == %{"type" => "number", "format" => "double precision"}
    end
  end

  describe "schema/2 json + arrays (1666, 1667)" do
    test "json/jsonb have only format" do
      assert Types.schema("json", []) == %{"format" => "json"}
      assert Types.schema("jsonb", []) == %{"format" => "jsonb"}
    end

    test "arrays carry format <elem>[] with typed items" do
      assert Types.schema("text[]", []) == %{"format" => "text[]", "type" => "array", "items" => %{"type" => "string"}}
      assert Types.schema("integer[]", []) == %{"format" => "integer[]", "type" => "array", "items" => %{"type" => "integer"}}
      assert Types.schema("numeric[]", []) == %{"format" => "numeric[]", "type" => "array", "items" => %{"type" => "number"}}
      assert Types.schema("json[]", []) == %{"format" => "json[]", "type" => "array", "items" => %{}}
    end
  end

  describe "schema/2 enum (1668)" do
    test "enum -> type string, format <schema.type>, enum labels" do
      assert Types.schema("test.enum_menagerie_type", enum: ["foo", "bar"]) ==
               %{"type" => "string", "format" => "test.enum_menagerie_type", "enum" => ["foo", "bar"]}
    end
  end

  describe "query_param/2 (1671, 1672)" do
    test "scalars match schema; arrays become string; json -> string" do
      assert Types.query_param("double precision", []) == %{"type" => "number", "format" => "double precision"}
      assert Types.query_param("integer", []) == %{"type" => "integer", "format" => "int32"}
      assert Types.query_param("text[]", []) == %{"type" => "string", "format" => "text[]"}
      assert Types.query_param("json", []) == %{"type" => "string", "format" => "json"}
    end

    test "variadic uses array + collectionFormat multi" do
      assert Types.query_param("text[]", variadic: true) ==
               %{"type" => "array", "collectionFormat" => "multi", "items" => %{"type" => "string", "format" => "text"}}
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/bier/openapi_test.exs`
Expected: FAIL (module `Bier.OpenAPI.Types` undefined).

- [ ] **Step 3: Implement `Bier.OpenAPI.Types`**

```elixir
defmodule Bier.OpenAPI.Types do
  @moduledoc """
  PostgreSQL type -> Swagger 2.0 schema mapping (mirrors PostgREST OpenAPI.hs:59-115).

  Two modes: `schema/2` for column/definition/body properties, `query_param/2`
  for RPC GET query parameters (arrays/json collapse to string).
  """

  # {swagger type | nil, swagger format} for a scalar base type. nil type => json/jsonb.
  defp base("character varying"), do: {"string", "character varying"}
  defp base("character"), do: {"string", "character"}
  defp base("text"), do: {"string", "text"}
  defp base("boolean"), do: {"boolean", "boolean"}
  defp base("smallint"), do: {"integer", "int32"}
  defp base("integer"), do: {"integer", "int32"}
  defp base("bigint"), do: {"integer", "int64"}
  defp base("numeric"), do: {"number", "numeric"}
  defp base("real"), do: {"number", "real"}
  defp base("double precision"), do: {"number", "double precision"}
  defp base("json"), do: {nil, "json"}
  defp base("jsonb"), do: {nil, "jsonb"}
  # Fallback: unknown scalar -> string with verbatim format (matches PostgREST's permissive default).
  defp base(other), do: {"string", other}

  @doc "Schema-mode mapping (definition properties, RPC POST body properties)."
  def schema(type, opts) do
    cond do
      enum = Keyword.get(opts, :enum) ->
        %{"type" => "string", "format" => type, "enum" => enum}

      array_elem = array_element(type) ->
        %{"format" => type, "type" => "array", "items" => array_items(array_elem)}

      true ->
        {t, f} = base(type)
        m = if t, do: %{"type" => t, "format" => f}, else: %{"format" => f}
        maybe_max_length(m, Keyword.get(opts, :max_length))
    end
  end

  @doc "Query-param mode mapping (RPC GET parameters)."
  def query_param(type, opts) do
    cond do
      Keyword.get(opts, :variadic, false) ->
        elem = array_element(type) || type
        {t, f} = base(elem)
        %{"type" => "array", "collectionFormat" => "multi", "items" => %{"type" => t, "format" => f}}

      array_element(type) ->
        %{"type" => "string", "format" => type}

      true ->
        {t, f} = base(type)
        %{"type" => t || "string", "format" => f}
    end
  end

  # "text[]" -> "text"; non-array -> nil.
  defp array_element(type) do
    if String.ends_with?(type, "[]"), do: String.replace_suffix(type, "[]", ""), else: nil
  end

  defp array_items(elem) do
    case base(elem) do
      {nil, _} -> %{}
      {t, _} -> %{"type" => t}
    end
  end

  defp maybe_max_length(m, nil), do: m
  defp maybe_max_length(m, n), do: Map.put(m, "maxLength", n)
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/bier/openapi_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/bier/openapi/types.ex test/bier/openapi_test.exs
git commit -m "feat(#39): OpenAPI.Types PG->Swagger type mapping"
```

### Task A2: Document skeleton + info from schema comment

**Files:**
- Create: `lib/bier/openapi.ex`
- Test: `test/bier/openapi_test.exs`

`build/1` takes an input map. Define its shape once and use it everywhere:

```
%{
  relations: [%Bier.Introspection.Relation{}, ...],   # already privilege-filtered & method-flagged
  functions: [%{name, comment, volatility, in_params: [%{name,type,variadic?,has_default?}], ...}, ...],
  schema_comment: String.t() | nil,
  security_active?: boolean(),
  docs_version: "v14"   # for externalDocs
}
```

- [ ] **Step 1: Write the failing test** (cases 1650/1651/1654/1655/1656)

```elixir
describe "build/1 skeleton" do
  test "swagger + default info + externalDocs (1650/1654/1655)" do
    doc = Bier.OpenAPI.build(%{relations: [], functions: [], schema_comment: nil, security_active?: false, docs_version: "v14"})
    assert doc["swagger"] == "2.0"
    assert doc["info"]["title"] == "PostgREST API"
    assert doc["info"]["description"] == "This is a dynamic API generated by PostgREST"
    assert doc["externalDocs"]["url"] == "https://postgrest.org/en/v14/references/api.html"
    assert doc["externalDocs"]["description"] == "PostgREST Documentation"
  end

  test "schema comment seeds title/description (1656)" do
    doc = Bier.OpenAPI.build(%{relations: [], functions: [], schema_comment: "My API title\nMy API description\nthat spans\nmultiple lines", security_active?: false, docs_version: "v14"})
    assert doc["info"]["title"] == "My API title"
    assert doc["info"]["description"] == "My API description\nthat spans\nmultiple lines"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/bier/openapi_test.exs`
Expected: FAIL (`Bier.OpenAPI.build/1` undefined).

- [ ] **Step 3: Implement skeleton + comment helper**

```elixir
defmodule Bier.OpenAPI do
  @moduledoc """
  Builds the Swagger 2.0 (OpenAPI 2.0) root document from an introspection
  snapshot. Wire-format match to PostgREST v14.12 is the contract; see
  spec/openapi.yaml and spec/conformance/cases/16*.yaml.
  """
  alias Bier.OpenAPI.Types

  @default_title "PostgREST API"
  @default_description "This is a dynamic API generated by PostgREST"

  def build(input) do
    {title, desc} = info(input.schema_comment)

    %{
      "swagger" => "2.0",
      "info" => put_optional(%{"title" => title, "version" => "14.12"}, "description", desc),
      "externalDocs" => %{
        "url" => "https://postgrest.org/en/#{input.docs_version}/references/api.html",
        "description" => "PostgREST Documentation"
      },
      "basePath" => "/",
      "paths" => paths(input),
      "definitions" => definitions(input)
    }
    |> with_security(input.security_active?)
  end

  defp info(nil), do: {@default_title, @default_description}
  defp info(comment), do: split_comment(comment)

  @doc false
  def split_comment(nil), do: {nil, nil}
  def split_comment(text) do
    case String.split(text, "\n", parts: 2) do
      [only] -> {only, nil}
      [head, rest] ->
        rest = rest |> String.replace_leading("\n", "") |> nil_if_empty()
        {head, rest}
    end
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(s), do: s

  defp put_optional(map, _k, nil), do: map
  defp put_optional(map, k, v), do: Map.put(map, k, v)

  # Filled in by later tasks; stubs keep the skeleton test green.
  defp paths(_input), do: %{}
  defp definitions(_input), do: %{}

  defp with_security(doc, false), do: doc
  defp with_security(doc, true) do
    doc
    |> Map.put("security", [%{"JWT" => []}])
    |> Map.put("securityDefinitions", %{
      "JWT" => %{
        "type" => "apiKey",
        "in" => "header",
        "name" => "Authorization",
        "description" => "Add the token prepending \"Bearer \" (without quotes) to it"
      }
    })
  end
end
```

Note: `String.replace_leading/3` only strips one delimiter occurrence per call cycle — verify against 1658 which has a single leading `\n` after the summary. (`"summary\ndesc..."` → split parts:2 → rest = `"desc..."`, no leading `\n`; the `\n\n` stripping case is 1656 where rest begins `"My API description"` already — confirm with the test above; if a case needs multiple leading newlines stripped use `String.trim_leading(rest, "\n")`.)

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/bier/openapi_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/bier/openapi.ex test/bier/openapi_test.exs
git commit -m "feat(#39): OpenAPI document skeleton (swagger/info/externalDocs/security)"
```

### Task A3: Table definitions (`definitions.<rel>`)

**Files:**
- Modify: `lib/bier/openapi.ex` (`definitions/1`)
- Test: `test/bier/openapi_test.exs`

- [ ] **Step 1: Write the failing test** (cases 1659, 1660, 1664, 1669)

Build a `Relation` fixture in the test mirroring `child_entities` (id pk+comment, name comment, parent_id FK to entities.id) and `child_entities_view`, plus an `openapi_defaults` relation. Assert:

```elixir
test "definitions: properties, descriptions, pk/fk notes, required, defaults" do
  child = %Bier.Introspection.Relation{
    schema: "test", name: "child_entities", kind: :table,
    primary_key: ["id"],
    foreign_keys: [%{constraint: "fk", columns: ["parent_id"], ref_schema: "test", ref_relation: "entities", ref_columns: ["id"], unique?: false}],
    columns: [
      %{name: "id", type: "integer", pk?: true, notnull?: true, default: nil, composite?: false, data_rep: nil, comment: "child_entities id comment", enum_labels: nil, max_length: nil},
      %{name: "name", type: "text", pk?: false, notnull?: false, default: nil, composite?: false, data_rep: nil, comment: "child_entities name comment. Can be longer than sixty-three characters long", enum_labels: nil, max_length: nil},
      %{name: "parent_id", type: "integer", pk?: false, notnull?: false, default: nil, composite?: false, data_rep: nil, comment: nil, enum_labels: nil, max_length: nil}
    ],
    comment: "child_entities comment"
  }
  doc = Bier.OpenAPI.build(%{relations: [child], functions: [], schema_comment: nil, security_active?: false, docs_version: "v14"})
  d = doc["definitions"]["child_entities"]
  assert d["type"] == "object"
  assert d["properties"]["id"]["description"] == "child_entities id comment\n\nNote:\nThis is a Primary Key.<pk/>"
  assert d["properties"]["name"]["description"] == "child_entities name comment. Can be longer than sixty-three characters long"
  assert d["properties"]["parent_id"]["description"] == "Note:\nThis is a Foreign Key to `entities.id`.<fk table='entities' column='id'/>"
  assert hd(d["required"]) == "id"
end
```

Add a view variant asserting `definitions.child_entities_view.description == "child_entities_view comment"` and `Map.has_key?(d, "required") == false`, and an `openapi_defaults` variant asserting decoded defaults (text→"default", boolean→false, integer→42, numeric→42.2, date→"1900-01-01", time→"13:00:00") per case 1669.

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/bier/openapi_test.exs`
Expected: FAIL (definitions empty).

- [ ] **Step 3: Implement `definitions/1`, property builder, notes, defaults**

```elixir
defp definitions(input) do
  Map.new(input.relations, fn rel -> {rel.name, definition(rel)} end)
end

defp definition(rel) do
  props = Map.new(rel.columns, fn col -> {col.name, property(col, rel)} end)
  required = for c <- rel.columns, c.notnull?, do: c.name

  %{"type" => "object", "properties" => props}
  |> put_optional("description", rel.comment)
  |> put_required(required)
end

defp put_required(map, []), do: map
defp put_required(map, required), do: Map.put(map, "required", required)

defp property(col, rel) do
  opts =
    []
    |> maybe_kw(:max_length, col.max_length)
    |> maybe_kw(:enum, col.enum_labels)

  col.type
  |> Types.schema(opts)
  |> put_description(column_description(col, rel))
  |> put_default(Types.default(col.default, col.type))
end

defp maybe_kw(kw, _k, nil), do: kw
defp maybe_kw(kw, k, v), do: Keyword.put(kw, k, v)

defp put_description(map, nil), do: map
defp put_description(map, d), do: Map.put(map, "description", d)

defp put_default(map, :omit), do: map
defp put_default(map, v), do: Map.put(map, "default", v)

defp column_description(col, rel) do
  [col.comment, pk_note(col), fk_note(col, rel)]
  |> Enum.reject(&is_nil/1)
  |> case do
    [] -> nil
    parts -> Enum.join(parts, "\n\n")
  end
end

defp pk_note(%{pk?: true}), do: "Note:\nThis is a Primary Key.<pk/>"
defp pk_note(_), do: nil

defp fk_note(col, rel) do
  case Enum.find(rel.foreign_keys, fn fk -> fk.columns == [col.name] end) do
    %{ref_relation: t, ref_columns: [c]} ->
      "Note:\nThis is a Foreign Key to `#{t}.#{c}`.<fk table='#{t}' column='#{c}'/>"
    _ -> nil
  end
end
```

Add `Types.default/2` to `Bier.OpenAPI.Types` (the decoder from the "Default decoding" section). Returns `:omit` for nil:

```elixir
def default(nil, _type), do: :omit
def default(raw, type) do
  stripped = strip_cast(raw)
  cond do
    type in ["boolean"] -> stripped == "true"
    type in ["smallint", "integer", "bigint"] -> String.to_integer(stripped)
    type in ["numeric", "real", "double precision"] -> parse_number(stripped)
    true -> unquote_sql(stripped)
  end
end

defp strip_cast(s), do: s |> String.split("::", parts: 2) |> hd()
defp unquote_sql(s) do
  s |> String.trim() |> String.trim_leading("'") |> String.trim_trailing("'")
end
defp parse_number(s) do
  case Float.parse(s) do
    {f, ""} -> if f == Float.round(f) and not String.contains?(s, "."), do: trunc(f), else: f
    _ -> s
  end
end
```

Note `strip_cast` runs before `unquote_sql` for the string branch (e.g. `'default'::text` → `'default'` → `default`).

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/bier/openapi_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/bier/openapi.ex lib/bier/openapi/types.ex test/bier/openapi_test.exs
git commit -m "feat(#39): OpenAPI table definitions (properties, pk/fk notes, defaults)"
```

### Task A4: Table path items + shared parameters

**Files:**
- Modify: `lib/bier/openapi.ex` (`paths/1`, `parameters/1`)
- Test: `test/bier/openapi_test.exs`

Cases 1657, 1658, 1661, 1662, 1663. Method emission for this slice: GET always; POST/PATCH/DELETE when `rel.kind == :table` (privilege gating is applied upstream in Phase B/C by trimming the relation's allowed methods — see Task C2; for unit tests assume tables are fully writable, matching the anonymous-writable `child_entities` fixture). Views emit GET only.

- [ ] **Step 1: Write the failing test**

```elixir
test "table path item: summary/desc, parameter $refs, responses, schema (1657/1658/1661/1662/1663)" do
  child = %Bier.Introspection.Relation{schema: "test", name: "child_entities", kind: :table,
    primary_key: ["id"], foreign_keys: [],
    columns: [c("id","integer"), c("name","text"), c("parent_id","integer")],
    comment: "child_entities comment"}
  doc = Bier.OpenAPI.build(%{relations: [child], functions: [], schema_comment: nil, security_active?: false, docs_version: "v14"})
  get = doc["paths"]["/child_entities"]["get"]
  assert get["summary"] == "child_entities comment"
  refute Map.has_key?(get, "description")
  refs = Enum.map(get["parameters"], & &1["$ref"])
  assert refs == [
    "#/parameters/rowFilter.child_entities.id",
    "#/parameters/rowFilter.child_entities.name",
    "#/parameters/rowFilter.child_entities.parent_id",
    "#/parameters/select", "#/parameters/order", "#/parameters/range",
    "#/parameters/rangeUnit", "#/parameters/offset", "#/parameters/limit",
    "#/parameters/preferCount"
  ]
  assert get["responses"]["200"]["description"] == "OK"
  assert get["responses"]["200"]["schema"] == %{"type" => "array", "items" => %{"$ref" => "#/definitions/child_entities"}}
  assert get["responses"]["206"]["description"] == "Partial Content"
  post = doc["paths"]["/child_entities"]["post"]
  assert Enum.map(post["parameters"], & &1["$ref"]) == ["#/parameters/body.child_entities", "#/parameters/select", "#/parameters/preferPost"]
  assert post["responses"]["201"]["description"] == "Created"
  assert doc["paths"]["/child_entities"]["patch"]["responses"]["204"]["description"] == "No Content"
  assert doc["paths"]["/child_entities"]["delete"]["responses"]["204"]["description"] == "No Content"
  # tags (1676/1677)
  assert post["tags"] == ["child_entities"]
end
```

Add a `c/2` helper in the test building a full column map with nil comment/enum/max_length.

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/bier/openapi_test.exs`
Expected: FAIL (paths empty).

- [ ] **Step 3: Implement `paths/1` for relations + `parameters/1`**

```elixir
defp paths(input) do
  rel_paths = Map.new(input.relations, fn rel -> {"/" <> rel.name, relation_path_item(rel)} end)
  Map.merge(rel_paths, function_paths(input))   # function_paths/1 added in Task A5; stub returns %{} until then
end

defp relation_path_item(rel) do
  {summary, description} = split_comment(rel.comment)
  base_op = fn extra ->
    %{"tags" => [rel.name]} |> put_optional("summary", summary) |> put_optional("description", description) |> Map.merge(extra)
  end

  get = base_op.(%{
    "parameters" => row_filter_refs(rel) ++ refs(~w(select order range rangeUnit offset limit preferCount)),
    "responses" => %{
      "200" => %{"description" => "OK", "schema" => %{"type" => "array", "items" => %{"$ref" => "#/definitions/#{rel.name}"}}},
      "206" => %{"description" => "Partial Content"}
    }
  })

  item = %{"get" => get}

  if rel.kind == :table do
    item
    |> Map.put("post", base_op.(%{"parameters" => refs(["body.#{rel.name}", "select", "preferPost"]), "responses" => %{"201" => %{"description" => "Created"}}}))
    |> Map.put("patch", base_op.(%{"parameters" => row_filter_refs(rel) ++ refs(["body.#{rel.name}", "select", "preferReturn"]), "responses" => %{"204" => %{"description" => "No Content"}}}))
    |> Map.put("delete", base_op.(%{"parameters" => row_filter_refs(rel) ++ refs(["select", "preferReturn"]), "responses" => %{"204" => %{"description" => "No Content"}}}))
  else
    item
  end
end

defp row_filter_refs(rel), do: Enum.map(rel.columns, fn c -> %{"$ref" => "#/parameters/rowFilter.#{rel.name}.#{c.name}"} end)
defp refs(names), do: Enum.map(names, fn n -> %{"$ref" => "#/parameters/#{n}"} end)
```

Also add a `parameters/1` to `build/1`'s top-level map so the `$ref`s resolve to real definitions (only the refs are conformance-asserted, but the doc must be self-consistent). Add `"parameters" => parameters(input)` to the `build/1` map and:

```elixir
defp parameters(input) do
  shared = %{
    "select" => %{"name" => "select", "in" => "query", "type" => "string", "required" => false, "description" => "Filtering Columns"},
    "order" => %{"name" => "order", "in" => "query", "type" => "string", "required" => false, "description" => "Ordering"},
    "range" => %{"name" => "Range", "in" => "header", "type" => "string", "required" => false, "description" => "Limiting and Pagination"},
    "rangeUnit" => %{"name" => "Range-Unit", "in" => "header", "type" => "string", "required" => false, "default" => "items", "description" => "Limiting and Pagination"},
    "offset" => %{"name" => "offset", "in" => "query", "type" => "string", "required" => false, "description" => "Limiting and Pagination"},
    "limit" => %{"name" => "limit", "in" => "query", "type" => "string", "required" => false, "description" => "Limiting and Pagination"},
    "preferCount" => %{"name" => "Prefer", "in" => "header", "type" => "string", "required" => false, "enum" => ["count=none"], "description" => "Preference"},
    "preferPost" => %{"name" => "Prefer", "in" => "header", "type" => "string", "required" => false, "enum" => ["return=representation", "return=minimal", "return=none"], "description" => "Preference"},
    "preferReturn" => %{"name" => "Prefer", "in" => "header", "type" => "string", "required" => false, "enum" => ["return=representation", "return=minimal", "return=none"], "description" => "Preference"}
  }
  row_filters = for rel <- input.relations, col <- rel.columns, into: %{} do
    {"rowFilter.#{rel.name}.#{col.name}", %{"name" => col.name, "in" => "query", "type" => "string", "required" => false, "format" => col.type}}
  end
  bodies = for rel <- input.relations, rel.kind == :table, into: %{} do
    {"body.#{rel.name}", %{"name" => rel.name, "description" => rel.name, "required" => false, "in" => "body", "schema" => %{"$ref" => "#/definitions/#{rel.name}"}}}
  end
  shared |> Map.merge(row_filters) |> Map.merge(bodies)
end
```

(Stub `function_paths/1` to `%{}` now; Task A5 implements it.)

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/bier/openapi_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/bier/openapi.ex test/bier/openapi_test.exs
git commit -m "feat(#39): OpenAPI table path items + shared parameters"
```

### Task A5: RPC path items (`/rpc/<fn>`)

**Files:**
- Modify: `lib/bier/openapi.ex` (`function_paths/1`)
- Test: `test/bier/openapi_test.exs`

Cases 1670, 1671, 1672, 1673, 1674. The function input shape (built in Phase B from `Bier.Introspection.functions/2`, which already has `volatility` and `in_params`):

```
%{name: "varied_arguments_openapi", comment: "An RPC function\nJust a test...",
  volatility: :immutable | :stable | :volatile,
  in_params: [%{name: "double", type: "double precision", variadic?: false, has_default?: false}, ...]}
```

- [ ] **Step 1: Write the failing test**

```elixir
test "rpc path item: summary/desc, get params, post body, volatility (1670-1674)" do
  fns = [
    %{name: "varied_arguments_openapi", comment: "An RPC function\nJust a test for RPC function arguments",
      volatility: :immutable,
      in_params: [
        p("double", "double precision", false, false),
        p("text_arr", "text[]", false, false),
        p("integer", "integer", false, true),
        p("json", "json", false, true)
      ]},
    %{name: "reset_table", comment: nil, volatility: :volatile, in_params: []},
    %{name: "getallusers", comment: nil, volatility: :stable, in_params: []},
    %{name: "variadic_param", comment: nil, volatility: :immutable, in_params: [p_var("v", "text[]")]}
  ]
  doc = Bier.OpenAPI.build(%{relations: [], functions: fns, schema_comment: nil, security_active?: false, docs_version: "v14"})
  get = doc["paths"]["/rpc/varied_arguments_openapi"]["get"]
  assert get["summary"] == "An RPC function"
  assert get["description"] == "Just a test for RPC function arguments"
  assert Enum.at(get["parameters"], 0) == %{"format" => "double precision", "in" => "query", "name" => "double", "required" => true, "type" => "number"}
  assert Enum.at(get["parameters"], 1) == %{"format" => "text[]", "in" => "query", "name" => "text_arr", "required" => true, "type" => "string"}
  assert Enum.at(get["parameters"], 2) == %{"format" => "int32", "in" => "query", "name" => "integer", "required" => false, "type" => "integer"}
  assert Enum.at(get["parameters"], 3) == %{"format" => "json", "in" => "query", "name" => "json", "required" => false, "type" => "string"}
  # variadic (1672)
  assert doc["paths"]["/rpc/variadic_param"]["get"]["parameters"] |> hd() ==
    %{"collectionFormat" => "multi", "in" => "query", "items" => %{"format" => "text", "type" => "string"}, "name" => "v", "required" => false, "type" => "array"}
  # post body (1673)
  body = doc["paths"]["/rpc/varied_arguments_openapi"]["post"]["parameters"] |> hd()
  assert body["schema"]["type"] == "object"
  assert body["schema"]["description"] == "An RPC function\n\nJust a test for RPC function arguments"
  assert body["schema"]["properties"]["double"] == %{"format" => "double precision", "type" => "number"}
  assert body["schema"]["properties"]["text_arr"] == %{"format" => "text[]", "type" => "array", "items" => %{"type" => "string"}}
  assert hd(body["schema"]["required"]) == "double"
  assert body["schema"]["properties"]["text_arr"] # present
  # volatility methods (1674)
  refute Map.has_key?(doc["paths"]["/rpc/reset_table"], "get")
  assert Map.has_key?(doc["paths"]["/rpc/reset_table"], "post")
  assert Map.has_key?(doc["paths"]["/rpc/getallusers"], "get")
  assert Map.has_key?(doc["paths"]["/rpc/getallusers"], "post")
  # tags (1676)
  assert doc["paths"]["/rpc/varied_arguments_openapi"]["post"]["tags"] == ["(rpc) varied_arguments_openapi"]
end
```

Add test helpers `p/4` (`%{name:, type:, variadic?: false, has_default:}`) and `p_var/2` (variadic? true).

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/bier/openapi_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implement `function_paths/1`**

```elixir
defp function_paths(input) do
  Map.new(input.functions, fn fun -> {"/rpc/#{fun.name}", function_path_item(fun)} end)
end

defp function_path_item(fun) do
  {summary, description} = split_comment(fun.comment)
  tags = ["(rpc) #{fun.name}"]

  post = %{"tags" => tags, "parameters" => [rpc_body_param(fun, summary, description)], "responses" => %{"200" => %{"description" => "OK"}}}
         |> put_optional("summary", summary) |> put_optional("description", description)

  item = %{"post" => post}

  if fun.volatility == :volatile do
    item
  else
    get = %{"tags" => tags, "parameters" => Enum.map(fun.in_params, &rpc_query_param/1), "responses" => %{"200" => %{"description" => "OK"}}}
          |> put_optional("summary", summary) |> put_optional("description", description)
    Map.put(item, "get", get)
  end
end

defp rpc_query_param(p) do
  Types.query_param(p.type, variadic: p.variadic?)
  |> Map.merge(%{"name" => p.name, "in" => "query", "required" => not p.has_default?})
end

defp rpc_body_param(fun, summary, description) do
  props = Map.new(fun.in_params, fn p -> {p.name, Types.schema(p.type, [])} end)
  required = for p <- fun.in_params, not p.has_default?, do: p.name
  desc = [summary, description] |> Enum.reject(&is_nil/1) |> Enum.join("\n\n") |> nil_if_empty()

  schema = %{"type" => "object", "properties" => props}
           |> put_optional("description", desc)
           |> put_required(required)

  %{"name" => "args", "in" => "body", "required" => false, "schema" => schema}
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/bier/openapi_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/bier/openapi.ex test/bier/openapi_test.exs
git commit -m "feat(#39): OpenAPI RPC path items (get params, post body, volatility)"
```

---

## Phase B — Introspection: populate comments, enum, maxLength, privileges

### Task B1: Comments + enum labels + maxLength in `run/2`, plus `schema_comment/2`

**Files:**
- Modify: `lib/bier/introspection.ex` (the columns query in `run/2`; add `schema_comment/2`; add `comment` to functions in `functions/2`)
- Test: `test/bier/introspection_test.exs` (integration, live DB)

- [ ] **Step 1: Write the failing integration test**

Use the existing conformance DB harness to get a connection over the `test` schema (follow the pattern already used in `test/bier/introspection_test.exs` if present, or `test/support/*` conformance helpers). Assert against fixtures:

```elixir
test "captures column comments, enum labels, char maxLength" do
  rels = Bier.Introspection.run(conn, ["test"])
  child = rels[{"test", "child_entities"}]
  id = Enum.find(child.columns, &(&1.name == "id"))
  assert id.comment == "child_entities id comment"
  menagerie = rels[{"test", "menagerie"}]
  enum_col = Enum.find(menagerie.columns, &(&1.name == "enum"))
  assert enum_col.enum_labels == ["foo", "bar"]
  assert enum_col.type == "test.enum_menagerie_type"
  types = rels[{"test", "openapi_types"}]
  a_char = Enum.find(types.columns, &(&1.name == "a_character"))
  assert a_char.max_length == 1
  assert child.comment == "child_entities comment"
end

test "schema_comment/2 returns the test schema COMMENT" do
  assert Bier.Introspection.schema_comment(conn, "test") =~ "My API title"
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/bier/introspection_test.exs`
Expected: FAIL (fields nil / function missing).

- [ ] **Step 3: Extend the SQL**

In the columns query inside `run/2`, add to the SELECT/`json_build` (joining `pg_attribute a`, `pg_class c`, `pg_type t`):
- `col_description(c.oid, a.attnum) AS comment`
- enum labels: `CASE WHEN t.typtype = 'e' THEN (SELECT array_agg(e.enumlabel ORDER BY e.enumsortorder) FROM pg_enum e WHERE e.enumtypid = t.oid) END AS enum_labels`
- the type rendering must yield the **schema-qualified enum name** for enum columns (`format_type` already yields `test.enum_menagerie_type` for a non-pg_catalog type — verify; if it yields a bare name, build `quote_ident`-free `n.nspname || '.' || t.typname` for `typtype='e'`).
- maxLength for char(n): `information_schema`-style `CASE WHEN t.typname IN ('bpchar','varchar') AND a.atttypmod > 4 THEN a.atttypmod - 4 END AS max_length` (atttypmod-4 is the declared length; `character(1)` → typmod 5 → 1; only emit for `bpchar` where a fixed length is meaningful for `maxLength` — confirm 1665 wants maxLength only on `a_character` (char(1)), not on `a_character_varying`).

For relation comment: add `obj_description(c.oid, 'pg_class') AS comment` to the relations query (or a join) and set `comment:` on the `Relation` struct in the grouping step.

Add `schema_comment/2`:

```elixir
@spec schema_comment(conn :: term(), schema :: String.t()) :: String.t() | nil
def schema_comment(conn, schema) do
  sql = "SELECT obj_description(oid, 'pg_namespace') FROM pg_namespace WHERE nspname = $1"
  case Postgrex.query!(conn, sql, [schema]).rows do
    [[comment]] -> comment
    _ -> nil
  end
end
```

In `functions/2`, add `obj_description(p.oid, 'pg_proc') AS comment` to the SELECT and `comment: ...` to the function map built in `build_function/1`. Also ensure each `in_param` carries `variadic?` (from `proargmodes = 'v'`) and `has_default?` (compare arg position against `pronargdefaults`: the last `pronargdefaults` input args have defaults).

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/bier/introspection_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/bier/introspection.ex test/bier/introspection_test.exs
git commit -m "feat(#39): introspect comments, enum labels, char maxLength, fn comments"
```

### Task B2: Per-role privileges (`Bier.Introspection.privileges/3`)

**Files:**
- Modify: `lib/bier/introspection.ex` (new `privileges/3`)
- Test: `test/bier/introspection_test.exs`

Cases 1675/1676/1677 need to know, for the request role, which relations are SELECT/INSERT/UPDATE/DELETE-able and which functions are EXECUTE-able. Compute it in SQL (Postgres resolves role membership):

- [ ] **Step 1: Write the failing test**

```elixir
test "privileges/3 reflects role grants" do
  anon = Bier.Introspection.privileges(conn, ["test"], "postgrest_test_anonymous")
  refute anon.relations[{"test", "authors_only"}].select?
  author = Bier.Introspection.privileges(conn, ["test"], "postgrest_test_author")
  assert author.relations[{"test", "authors_only"}].select?
  refute anon.functions[{"test", "privileged_hello"}].execute?
  assert author.functions[{"test", "privileged_hello"}].execute?
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/bier/introspection_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implement `privileges/3`**

```elixir
@spec privileges(term(), [String.t()], String.t()) :: %{relations: map(), functions: map()}
def privileges(conn, schemas, role) do
  rel_sql = """
  SELECT n.nspname, c.relname,
         has_table_privilege($1, c.oid, 'SELECT'),
         has_table_privilege($1, c.oid, 'INSERT'),
         has_table_privilege($1, c.oid, 'UPDATE'),
         has_table_privilege($1, c.oid, 'DELETE')
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = ANY($2) AND c.relkind = ANY(ARRAY['r','v','m','f','p'])
  """
  relations =
    for [s, r, sel, ins, upd, del] <- Postgrex.query!(conn, rel_sql, [role, schemas]).rows, into: %{} do
      {{s, r}, %{select?: sel, insert?: ins, update?: upd, delete?: del}}
    end

  fn_sql = """
  SELECT n.nspname, p.proname, has_function_privilege($1, p.oid, 'EXECUTE')
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = ANY($2)
  """
  functions =
    for [s, f, exec] <- Postgrex.query!(conn, fn_sql, [role, schemas]).rows, into: %{} do
      {{s, f}, %{execute?: exec}}
    end

  %{relations: relations, functions: functions}
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/bier/introspection_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/bier/introspection.ex test/bier/introspection_test.exs
git commit -m "feat(#39): introspect per-role table/function privileges"
```

---

## Phase C — Config + wiring + conformance acceptance

### Task C1: `openapi_security_active` config key

**Files:**
- Modify: `lib/bier.ex` (~line 263, after `db_root_spec`)
- Modify: `lib/bier/config.ex` (struct field + type, ~lines 47/68/71)

- [ ] **Step 1: Add the schema option** in `lib/bier.ex`:

```elixir
openapi_security_active: [
  type: :boolean,
  default: env(:openapi_security_active, false),
  doc: """
  When true the root OpenAPI document includes `security` and a `JWT` apiKey
  `securityDefinitions` entry (PostgREST openapi-security-active).
  """
],
```

- [ ] **Step 2: Add to `Bier.Config`** — `openapi_security_active: boolean()` in the type, `:openapi_security_active` in the struct keys, default `false`.

- [ ] **Step 3: Compile**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add lib/bier.ex lib/bier/config.ex
git commit -m "feat(#39): add openapi_security_active config option"
```

### Task C2: Wire `ActionController` root → `Bier.OpenAPI.build/1`

**Files:**
- Modify: `lib/bier/plugs/action_controller.ex` (replace `root_openapi_doc/0` at lines 168–177 and its caller at line 134)

The root handler must, for the generated-doc path (not `db-root-spec`, not `disabled`):
1. Resolve the request role: `{:ok, ctx} = Bier.Auth.resolve(conn, config)` and use `ctx.role` (falls back to `db_anon_role` inside Auth). On `{:error, _}` for a bad token, surface the existing auth error (reuse the controller's current auth error mapping).
2. Gather introspection for the exposed schemas. **Reuse the per-instance schema cache** the controller already has access to (the same relations/functions the router was built from — find how `assigns`/the instance exposes `db_structure`; if only the keyed relations map is available, convert to a list). Functions come from the instance's introspected function map (confirm where it is cached; if not cached, call `Bier.Introspection.functions/2` over the instance conn).
3. Apply `openapi-mode`:
   - `ignore-privileges`: include all relations/functions; tables keep all mutating methods.
   - `follow-privileges`: call `Bier.Introspection.privileges/3` with `ctx.role`; **drop** relations whose `select?` is false and functions whose `execute?` is false; for surviving tables, drop POST/PATCH/DELETE when insert?/update?/delete? is false. (Implement method-trimming by passing an allowed-methods set into the builder OR by pre-trimming; simplest: extend the relation list element with a `:methods` field consumed by `relation_path_item/1`. If you add `:methods`, update Task A4's `relation_path_item/1` to gate on it and update the A4 unit test to pass `methods: [:get, :post, :patch, :delete]`.)
4. Build input and serialize:

```elixir
input = %{
  relations: relations,
  functions: functions,
  schema_comment: Bier.Introspection.schema_comment(conn, primary_schema),
  security_active?: config.openapi_security_active,
  docs_version: "v14"
}
doc = Bier.OpenAPI.build(input)
root_doc_body(conn, Bier.json_library().encode!(doc))
```

- [ ] **Step 1: Implement the wiring** (replace `root_openapi_doc/0` body and update the caller at line 134). Keep the existing `disabled` (PGRST126) and `db-root-spec` branches intact.

- [ ] **Step 2: Compile + smoke test**

Run: `mix compile --warnings-as-errors`
Then exercise the root manually via an existing controller/server test, or proceed to Task C3 which is the real acceptance.

- [ ] **Step 3: Commit**

```bash
git add lib/bier/plugs/action_controller.ex lib/bier/openapi.ex test/bier/openapi_test.exs
git commit -m "feat(#39): serve generated OpenAPI doc at root with openapi-mode"
```

### Task C3: Flip the conformance gate and make all 28 green

**Files:**
- Modify: `test/conformance/conformance_test.exs` (remove the `:openapi_doc` pending branch, lines ~24–30)

- [ ] **Step 1: Remove the pending gate**

Delete the clause:

```elixir
Map.has_key?(c.expect, "body_jsonpath") and c.area == "openapi" ->
  :openapi_doc
```

and the now-stale comment above it. Update the moduledoc `pending_reason` list (lines ~5–7) to drop `:openapi_doc`.

- [ ] **Step 2: Run the openapi area**

Run: `mix test test/conformance/conformance_test.exs`
Expected: the 28 openapi cases (1650/1651/1654–1677/1679/1680) now execute. Iterate on any failures against `spec/openapi.yaml` + the case file. Common gotchas to check against real fixtures:
- enum format must be schema-qualified (`test.enum_menagerie_type`).
- `varied_arguments_openapi` param **index** ordering (case 1671 asserts params [0], [6], [15], [16]) — the in-param order must match `proargnames` order; OUT params excluded.
- `has_default?` derivation (`pronargdefaults` applies to the trailing input args).
- 1676 sends a real JWT (role `postgrest_test_author`, secret `reallyreallyreallyreallyverysafe`) — ensure the instance's `jwt_secret` matches the conformance fixture config so `Bier.Auth.resolve/2` yields that role.

- [ ] **Step 3: Run the full suite — confirm no regressions**

Run: `mix test`
Expected: only the 3 pre-existing geojson failures (1616–1618) remain; all 28 openapi cases pass; previously-passing cases unchanged.

- [ ] **Step 4: CI gates**

Run:
```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix docs --warnings-as-errors
mix deps.unlock --check-unused
```
Expected: all clean (run `mix format` first if needed).

- [ ] **Step 5: Commit**

```bash
git add test/conformance/conformance_test.exs
git commit -m "test(#39): enable openapi conformance cases (1650-1680)"
```

---

## Self-Review checklist (done while writing)

- **Spec coverage:** every `spec/openapi.yaml` entry maps to a task — root/info/externalDocs (A2), db-root-spec (out of scope, untouched), comments schema/table/column/fn (A2/A3/A4/A5 + B1), table params/responses/definition (A3/A4), type mapping/enum/defaults (A1/A3), rpc get/post/volatility (A5), openapi-mode follow/ignore/disabled (C2; disabled pre-existing), security (A2 builder + C1 config). 28 cases enumerated and gated in C3.
- **Two type modes** captured explicitly (A1) — the most error-prone divergence (arrays/json differ between definition properties and RPC GET params).
- **Type consistency:** `build/1` input shape fixed once (Task A2) and reused (A3/A4/A5/C2); `Relation`/column field names match Task A0; `Types.schema/2`+`query_param/2`+`default/2` signatures consistent across A1/A3/A5.
- **Open verification items flagged inline** (not placeholders — concrete checks): `format_type` enum qualification & `atttypmod` maxLength (B1), param index ordering & `has_default?` (B1/C3), JWT secret alignment for 1676 (C3), where the instance caches functions/relations for the root handler (C2).

## Follow-up (out of scope, worth filing after merge)

File an issue: **"Emit OpenAPI 3.0/3.1 as an opt-in (selling point over PostgREST)."** The `Bier.OpenAPI` builder derives the document from the introspection model with the Swagger-2.0 wire shape isolated in `build/1`; a 3.0 emitter is an additive sibling selected by config or `Accept`, reusing `Bier.OpenAPI.Types` semantics. PostgREST has never shipped 3.0 in core (issue #932, open since 2017), so this is a genuine differentiator.
