# Opt-in OpenAPI 3.0 Emitter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Issue #53 item 1 — an opt-in OpenAPI 3.0.3 root document, selected by a new `openapi_version` config option that defaults to `"2.0"` (the PostgREST-parity Swagger 2.0 document, byte-identical to today's).

**Architecture:** A new `Bier.OpenAPI.V3` module converts the generated Swagger 2.0 map into an OpenAPI 3.0.3 map (`convert/1`). Converting the finished 2.0 document — rather than emitting 3.0 from the internal model in parallel — keeps a single source of truth: every future parity fix to `Bier.OpenAPI.build/1` (e.g. the plan for #53 items 2–3) flows into the 3.0 output for free, and the conversion Swagger 2.0 → OAS 3.0 is a fully mechanical, well-specified mapping. `Bier.Plugs.ActionController.build_openapi_document/2` pipes through the converter when the instance's `openapi_version` is `"3.0"`. PostgREST has never shipped OpenAPI 3.x in core (PostgREST/postgrest#932), so this is a Bier differentiator with no conformance surface: the conformance instance never sets the option and keeps hitting the 2.0 default.

**Tech Stack:** Elixir (~> 1.18 floor), ExUnit, NimbleOptions config schema.

## Global Constraints

- Never edit anything under `spec/`, `test/support/`, or `test/conformance/` — frozen conformance ground truth (CLAUDE.md). New unit tests go under `test/bier/`.
- Default behavior must be bit-for-bit unchanged: `openapi_version` defaults to `"2.0"` and the 2.0 emitter is not touched. All 532 conformance cases must keep passing (`mix test`).
- Response serialization goes through `Bier.json_library()` — never call `Jason`/`JSON` directly.
- `mix precommit` must pass before the branch is done.
- Execute on a fresh branch off `main` (suggested: `openapi-30-emitter`), after the `openapi-53-followups` branch (see `2026-07-16-issue-53-openapi-followups.md`) has merged — the converter tests below assume Task-1-of-that-plan output shapes (e.g. the RPC POST `preferParams` `$ref`, `args` body `required: true`). If executing before that merge, the two call-outs marked "(depends on #53 items 2–3)" in Task 2's tests must be adjusted.
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Conversion rules (Swagger 2.0 → OpenAPI 3.0.3)

The complete mapping the converter implements. Input is exactly what `Bier.OpenAPI.build/1` emits (see `lib/bier/openapi.ex`), so the converter handles precisely these shapes — it is not a general-purpose converter.

| Swagger 2.0 | OpenAPI 3.0.3 |
|---|---|
| `"swagger": "2.0"` | `"openapi": "3.0.3"` |
| `info`, `externalDocs`, `security` | unchanged |
| `schemes` + `host` + `basePath` | `servers: [{"url": url}]` — with a proxy: `"<scheme>://<host><basePath-unless-/>"`; without: `"/"` |
| `definitions` | `components.schemas`, refs rewritten `#/definitions/X` → `#/components/schemas/X` |
| shared `parameters` (non-body) | `components.parameters`: `name`/`in`/`required`/`description` stay; `type`/`format`/`enum`/`default`/`maxLength`/`items` nest under `schema`; `collectionFormat: "multi"` → `style: "form", explode: true` |
| shared `parameters` (body, i.e. `body.<table>`) | `components.requestBodies.body.<table>`: `{description, required, content: {"application/json": {schema}}}` |
| operation `parameters` `$ref` to a non-body shared param | `$ref` rewritten to `#/components/parameters/<key>` |
| operation `parameters` `$ref` to a body shared param | removed from `parameters`; the operation gains `requestBody: {"$ref": "#/components/requestBodies/<key>"}` |
| operation inline body param (the RPC `args`) | removed from `parameters`; inline `requestBody: {required, content: {"application/json": {schema}}}` |
| operation inline non-body params (RPC GET query args) | same nesting rules as shared non-body params |
| response with `schema` | `{description, content: {"application/json": {schema}}}` |
| response without `schema` | unchanged |
| `securityDefinitions` | `components.securitySchemes` (the apiKey shape is identical in 3.0) |

Notes: JSON-typed schemas that carry only `"format"` (no `"type"`) pass through as-is — valid in 3.0. `required` on path items' schemas, `enum` lists, `maxLength`, and `default` values are untouched apart from the parameter-level nesting.

---

### Task 1: `openapi_version` config option

**Files:**
- Modify: `lib/bier.ex` (schema in `Bier.schema/0`, after the `openapi_security_active` entry ~L381-389)
- Modify: `lib/bier/config.ex` (struct defaults ~L92-93, typespec ~L60-61)
- Modify: `test/bier/config_test.exs` (add a describe block)

**Interfaces:**
- Consumes: nothing new.
- Produces: `%Bier.Config{openapi_version: String.t()}` — `"2.0"` (default) or `"3.0"`. Task 3 reads it in `ActionController`.

- [ ] **Step 1: Write the failing test**

Append to `test/bier/config_test.exs` (inside `Bier.ConfigTest`):

```elixir
  describe "openapi_version" do
    test "defaults to 2.0 and accepts 3.0" do
      assert Bier.Config.new!([], Bier.schema()).openapi_version == "2.0"
      assert Bier.Config.new!([openapi_version: "3.0"], Bier.schema()).openapi_version == "3.0"
    end

    test "rejects unknown versions" do
      assert_raise ArgumentError, ~r/openapi_version/, fn ->
        Bier.Config.new!([openapi_version: "3.1"], Bier.schema())
      end
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/bier/config_test.exs`
Expected: FAIL — `%Bier.Config{}` has no `:openapi_version` key (KeyError) and the schema rejects the unknown option.

- [ ] **Step 3: Add the option**

In `lib/bier.ex` `schema/0`, after the `openapi_security_active` entry:

```elixir
      openapi_version: [
        type: {:in, ["2.0", "3.0"]},
        default: env(:openapi_version, "2.0"),
        doc: """
        Version of the generated root OpenAPI document. `"2.0"` (the default)
        is the Swagger 2.0 document PostgREST emits, byte-for-byte; `"3.0"`
        serves an OpenAPI 3.0.3 translation of the same content. Bier-only
        option — PostgREST has no OpenAPI 3.x emitter (postgrest#932). Ignored
        when `db_root_spec` overrides the document.
        """
      ],
```

In `lib/bier/config.ex`: add `openapi_version: "2.0",` to the defaulted struct fields (next to `openapi_mode`) and `openapi_version: String.t(),` to the `@type t` (next to `openapi_mode`).

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/bier/config_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/bier.ex lib/bier/config.ex test/bier/config_test.exs
git commit -m "config: add openapi_version option (2.0 default, 3.0 opt-in)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `Bier.OpenAPI.V3` converter

**Files:**
- Create: `lib/bier/openapi/v3.ex`
- Test: `test/bier/openapi_v3_test.exs` (new)

**Interfaces:**
- Consumes: the map returned by `Bier.OpenAPI.build/1` (Swagger 2.0, string keys).
- Produces: `Bier.OpenAPI.V3.convert(swagger2 :: map()) :: map()` — the OpenAPI 3.0.3 document map. Task 3 calls it from `ActionController`.

- [ ] **Step 1: Write the failing tests**

Create `test/bier/openapi_v3_test.exs`. The input is built through the real 2.0 emitter so the converter is always tested against true shapes:

```elixir
defmodule Bier.OpenAPIV3Test do
  use ExUnit.Case, async: true

  alias Bier.OpenAPI.V3

  defp col(name, type, opts \\ []) do
    %{
      name: name,
      type: type,
      notnull?: Keyword.get(opts, :notnull?, false),
      max_length: Keyword.get(opts, :max_length),
      enum_labels: Keyword.get(opts, :enum_labels),
      default: Keyword.get(opts, :default),
      comment: Keyword.get(opts, :comment)
    }
  end

  defp relation do
    %Bier.Introspection.Relation{
      schema: "test",
      name: "items",
      kind: :table,
      primary_key: ["id"],
      foreign_keys: [],
      comment: "items comment",
      columns: [col("id", "integer", notnull?: true), col("label", "text")]
    }
  end

  defp fun do
    %{
      name: "add",
      comment: "Adds\nTwo numbers",
      volatility: :immutable,
      in_params: [
        %{name: "a", type: "integer", variadic?: false, has_default?: false},
        %{name: "b", type: "integer", variadic?: false, has_default?: true}
      ]
    }
  end

  defp build(opts \\ []) do
    Bier.OpenAPI.build(%{
      relations: [relation()],
      functions: [fun()],
      schema_comment: nil,
      security_active?: Keyword.get(opts, :security_active?, false),
      proxy_uri: Keyword.get(opts, :proxy_uri),
      docs_version: "v14"
    })
  end

  test "top level: openapi version, no swagger/definitions/parameters keys" do
    doc = V3.convert(build())

    assert doc["openapi"] == "3.0.3"
    refute Map.has_key?(doc, "swagger")
    refute Map.has_key?(doc, "definitions")
    refute Map.has_key?(doc, "parameters")
    refute Map.has_key?(doc, "basePath")
    assert doc["info"]["title"] == "PostgREST API"
    assert doc["externalDocs"]["description"] == "PostgREST Documentation"
  end

  test "servers: root url without proxy, full url with proxy" do
    assert V3.convert(build())["servers"] == [%{"url" => "/"}]

    doc = V3.convert(build(proxy_uri: "https://api.example.com:8443/v1"))
    assert doc["servers"] == [%{"url" => "https://api.example.com:8443/v1"}]
    refute Map.has_key?(doc, "host")
    refute Map.has_key?(doc, "schemes")
  end

  test "definitions move to components.schemas with rewritten refs" do
    doc = V3.convert(build())

    schema = doc["components"]["schemas"]["items"]
    assert schema["type"] == "object"
    assert schema["required"] == ["id"]
    assert schema["properties"]["id"]["format"] == "int32"

    get = doc["paths"]["/items"]["get"]

    assert get["responses"]["200"]["content"]["application/json"]["schema"] == %{
             "type" => "array",
             "items" => %{"$ref" => "#/components/schemas/items"}
           }

    # responses without a schema stay plain
    assert get["responses"]["206"] == %{"description" => "Partial Content"}
  end

  test "shared non-body params move to components.parameters with schema nesting" do
    doc = V3.convert(build())
    params = doc["components"]["parameters"]

    assert params["select"] == %{
             "name" => "select",
             "in" => "query",
             "required" => false,
             "description" => "Filtering Columns",
             "schema" => %{"type" => "string"}
           }

    # header param with a default: default nests under schema
    assert params["rangeUnit"]["schema"] == %{"type" => "string", "default" => "items"}

    # Prefer enum nests under schema (depends on #53 items 2-3 for the
    # resolution values; before that merge the enum list is 3 entries)
    assert params["preferPost"]["schema"]["enum"] |> hd() == "return=representation"

    # operation $refs are rewritten
    get = doc["paths"]["/items"]["get"]
    assert %{"$ref" => "#/components/parameters/select"} in get["parameters"]
    refute Enum.any?(get["parameters"], &match?(%{"$ref" => "#/parameters/" <> _}, &1))
  end

  test "table body params become requestBodies; operations reference them" do
    doc = V3.convert(build())

    assert doc["components"]["requestBodies"]["body.items"] == %{
             "description" => "items",
             "required" => false,
             "content" => %{
               "application/json" => %{
                 "schema" => %{"$ref" => "#/components/schemas/items"}
               }
             }
           }

    post = doc["paths"]["/items"]["post"]
    assert post["requestBody"] == %{"$ref" => "#/components/requestBodies/body.items"}
    refute Enum.any?(post["parameters"], &match?(%{"in" => "body"}, &1))
    refute Enum.any?(post["parameters"], &match?(%{"$ref" => "#/components/requestBodies/" <> _}, &1))
  end

  test "rpc: inline args body becomes an inline requestBody; GET params nest schemas" do
    doc = V3.convert(build())
    post = doc["paths"]["/rpc/add"]["post"]

    # (depends on #53 items 2-3: required true + preferParams ref; before that
    # merge, required is false and parameters is empty after body extraction)
    body = post["requestBody"]
    assert body["required"] == true
    schema = body["content"]["application/json"]["schema"]
    assert schema["type"] == "object"
    assert schema["properties"]["a"] == %{"type" => "integer", "format" => "int32"}
    assert schema["required"] == ["a"]

    assert post["parameters"] == [%{"$ref" => "#/components/parameters/preferParams"}]

    get = doc["paths"]["/rpc/add"]["get"]

    assert %{
             "name" => "a",
             "in" => "query",
             "required" => true,
             "schema" => %{"type" => "integer", "format" => "int32"}
           } in get["parameters"]
  end

  test "variadic collectionFormat multi becomes style form + explode" do
    doc =
      Bier.OpenAPI.build(%{
        relations: [],
        functions: [
          %{
            name: "vparam",
            comment: nil,
            volatility: :immutable,
            in_params: [%{name: "v", type: "text[]", variadic?: true, has_default?: false}]
          }
        ],
        schema_comment: nil,
        security_active?: false,
        proxy_uri: nil,
        docs_version: "v14"
      })
      |> V3.convert()

    [param] = doc["paths"]["/rpc/vparam"]["get"]["parameters"]

    assert param["style"] == "form"
    assert param["explode"] == true
    refute Map.has_key?(param, "collectionFormat")
    assert param["schema"] == %{"type" => "array", "items" => %{"type" => "string", "format" => "text"}}
  end

  test "securityDefinitions move to components.securitySchemes; security stays" do
    doc = V3.convert(build(security_active?: true))

    assert doc["security"] == [%{"JWT" => []}]
    refute Map.has_key?(doc, "securityDefinitions")

    assert doc["components"]["securitySchemes"]["JWT"]["type"] == "apiKey"
    assert doc["components"]["securitySchemes"]["JWT"]["in"] == "header"
  end
end
```

Note: `%Bier.Introspection.Relation{}` field names above must match the struct in `lib/bier/introspection.ex` — cross-check the `col_map/2` and relation fixtures in `test/bier/openapi_test.exs` and mirror them exactly (they are the authority on the input shape; adjust the `col/3`/`relation/0` helpers here if the struct differs).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/bier/openapi_v3_test.exs`
Expected: FAIL to compile — `Bier.OpenAPI.V3` does not exist.

- [ ] **Step 3: Implement the converter**

Create `lib/bier/openapi/v3.ex`:

```elixir
defmodule Bier.OpenAPI.V3 do
  @moduledoc """
  Converts the generated Swagger 2.0 root document (`Bier.OpenAPI.build/1`)
  into an OpenAPI 3.0.3 document.

  Opt-in via the `openapi_version: "3.0"` config option; the default remains
  the PostgREST-parity Swagger 2.0 wire format. Converting the finished 2.0
  map (rather than emitting 3.0 from the introspection model in parallel)
  keeps a single wire-format source of truth: parity fixes to the 2.0
  emitter propagate here automatically. PostgREST core has no OpenAPI 3.x
  emitter (PostgREST/postgrest#932), so this output has no conformance
  surface and is shaped by the OpenAPI 3.0.3 spec alone.

  The converter is intentionally NOT general purpose: it handles exactly the
  shapes the 2.0 emitter produces (body params only as `body.*` shared
  definitions or the inline RPC `args`, `application/json` as the implied
  media type, `collectionFormat: "multi"` only on query params).
  """

  @json "application/json"

  # Parameter-object keys that stay at the parameter level in 3.0; everything
  # else (type/format/enum/default/maxLength/items/...) nests under "schema".
  @param_keys ~w(name in required description)

  @doc "Converts a Swagger 2.0 document map into an OpenAPI 3.0.3 one."
  @spec convert(map()) :: map()
  def convert(doc) do
    {bodies, params} = split_shared_params(doc["parameters"] || %{})

    components =
      %{}
      |> put_nonempty("schemas", rewrite_refs(doc["definitions"] || %{}))
      |> put_nonempty("parameters", Map.new(params, fn {k, p} -> {k, convert_param(p)} end))
      |> put_nonempty("requestBodies", Map.new(bodies, fn {k, p} -> {k, convert_body(p)} end))
      |> put_nonempty("securitySchemes", doc["securityDefinitions"])

    body_keys = bodies |> Map.keys() |> MapSet.new()

    %{
      "openapi" => "3.0.3",
      "info" => doc["info"],
      "externalDocs" => doc["externalDocs"],
      "servers" => servers(doc),
      "paths" => convert_paths(doc["paths"] || %{}, body_keys),
      "components" => components
    }
    |> put_nonempty("security", doc["security"])
  end

  defp put_nonempty(map, _k, v) when v in [nil, %{}], do: map
  defp put_nonempty(map, k, v), do: Map.put(map, k, v)

  # ---- servers -------------------------------------------------------------

  # With a proxy the 2.0 doc carries schemes/host/basePath; fold them into one
  # server URL. Without one, the API lives at the document root.
  defp servers(%{"host" => host, "schemes" => [scheme | _]} = doc) do
    base = if doc["basePath"] in [nil, "/"], do: "", else: doc["basePath"]
    [%{"url" => "#{scheme}://#{host}#{base}"}]
  end

  defp servers(_doc), do: [%{"url" => "/"}]

  # ---- shared parameters ---------------------------------------------------

  defp split_shared_params(params) do
    Enum.split_with(params, fn {_k, p} -> p["in"] == "body" end)
  end

  defp convert_body(p) do
    %{
      "required" => p["required"],
      "content" => %{@json => %{"schema" => rewrite_refs(p["schema"])}}
    }
    |> put_nonempty("description", p["description"])
  end

  defp convert_param(p) do
    {kept, schema_keys} = Map.split(p, @param_keys)

    schema =
      case Map.pop(schema_keys, "collectionFormat") do
        {"multi", rest} -> rest
        {nil, rest} -> rest
      end
      |> rewrite_refs()

    kept
    |> Map.put("schema", schema)
    |> then(fn param ->
      if schema_keys["collectionFormat"] == "multi",
        do: Map.merge(param, %{"style" => "form", "explode" => true}),
        else: param
    end)
  end

  # ---- paths ---------------------------------------------------------------

  defp convert_paths(paths, body_keys) do
    Map.new(paths, fn {path, item} ->
      {path, Map.new(item, fn {verb, op} -> {verb, convert_operation(op, body_keys)} end)}
    end)
  end

  defp convert_operation(op, body_keys) do
    {body, params} = extract_body(op["parameters"] || [], body_keys)

    op
    |> Map.put("parameters", Enum.map(params, &convert_op_param/1))
    |> Map.update("responses", %{}, &convert_responses/1)
    |> put_nonempty("requestBody", body)
    |> then(fn converted ->
      if converted["parameters"] == [], do: Map.delete(converted, "parameters"), else: converted
    end)
  end

  # One body param at most per operation (the 2.0 emitter guarantees it):
  # either a $ref to a shared body.<table> definition or the inline RPC args.
  defp extract_body(parameters, body_keys) do
    Enum.reduce(parameters, {nil, []}, fn param, {body, rest} ->
      case param do
        %{"$ref" => "#/parameters/" <> key} ->
          if MapSet.member?(body_keys, key) do
            {%{"$ref" => "#/components/requestBodies/#{key}"}, rest}
          else
            {body, rest ++ [param]}
          end

        %{"in" => "body"} = inline ->
          {%{
             "required" => inline["required"],
             "content" => %{@json => %{"schema" => rewrite_refs(inline["schema"])}}
           }, rest}

        inline ->
          {body, rest ++ [inline]}
      end
    end)
  end

  defp convert_op_param(%{"$ref" => "#/parameters/" <> key}),
    do: %{"$ref" => "#/components/parameters/#{key}"}

  defp convert_op_param(inline), do: convert_param(inline)

  defp convert_responses(responses) do
    Map.new(responses, fn
      {status, %{"schema" => schema} = resp} ->
        {status,
         resp
         |> Map.delete("schema")
         |> Map.put("content", %{@json => %{"schema" => rewrite_refs(schema)}})}

      {status, resp} ->
        {status, resp}
    end)
  end

  # ---- $ref rewriting ------------------------------------------------------

  # Walks any JSON-ish term and repoints definition refs at components.
  defp rewrite_refs(%{} = map) do
    Map.new(map, fn
      {"$ref", "#/definitions/" <> name} -> {"$ref", "#/components/schemas/#{name}"}
      {k, v} -> {k, rewrite_refs(v)}
    end)
  end

  defp rewrite_refs(list) when is_list(list), do: Enum.map(list, &rewrite_refs/1)
  defp rewrite_refs(other), do: other
end
```

- [ ] **Step 4: Run the tests, iterate until green**

Run: `mix test test/bier/openapi_v3_test.exs`
Expected: PASS. Likely first-pass failures to watch for: the `convert_param` `Map.pop`/`then` dance (make sure `collectionFormat` is removed from the nested schema AND drives style/explode), and the `body["required"]` value for RPC args (comes from the 2.0 emitter — `true` after the #53 items 2–3 merge).

Run: `mix test test/bier/openapi_test.exs`
Expected: PASS — the 2.0 emitter is untouched.

- [ ] **Step 5: Commit**

```bash
git add lib/bier/openapi/v3.ex test/bier/openapi_v3_test.exs
git commit -m "openapi: add Swagger 2.0 -> OpenAPI 3.0.3 converter (Bier.OpenAPI.V3)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Serve it from the root endpoint

**Files:**
- Modify: `lib/bier/plugs/action_controller.ex` (`build_openapi_document/2`, ~L185-206)
- Test: `test/bier/openapi_v3_http_test.exs` (new)

**Interfaces:**
- Consumes: `%Bier.Config{openapi_version: "2.0" | "3.0"}` (Task 1); `Bier.OpenAPI.V3.convert/1` (Task 2).
- Produces: `GET /` on an instance configured with `openapi_version: "3.0"` returns the 3.0.3 body; everything else (media negotiation, HEAD, `openapi-mode`, `db-root-spec` precedence, Content-Length) is unchanged.

- [ ] **Step 1: Write the failing test**

Create `test/bier/openapi_v3_http_test.exs`, modeled on the boot pattern used by `test/bier/geojson_http_test.exs` (a real instance against the fixture DB — cross-check that file's setup helper for the connection options and copy its database/credentials wiring exactly; adjust the option names below if they differ):

```elixir
defmodule Bier.OpenAPIV3HttpTest do
  use ExUnit.Case

  # Boots a dedicated instance with openapi_version: "3.0" against the
  # bier_test fixture database and asserts the root serves OpenAPI 3.0.3.
  setup_all do
    name = :openapi_v3_http_test
    port = 47_631

    start_supervised!(
      {Bier,
       name: name,
       router: [port: port, scheme: :http],
       hostname: "localhost",
       username: "postgres",
       database: "bier_test",
       db_schemas: ["test"],
       openapi_version: "3.0"}
    )

    %{url: "http://localhost:#{port}/"}
  end

  test "GET / serves an OpenAPI 3.0.3 document", %{url: url} do
    resp = Req.get!(url, headers: [{"accept", "application/json"}], retry: false)

    assert resp.status == 200
    assert resp.body["openapi"] == "3.0.3"
    refute Map.has_key?(resp.body, "swagger")
    assert resp.body["components"]["schemas"] != %{}
    assert resp.body["servers"] == [%{"url" => "/"}]
  end

  test "content negotiation is unchanged: csv at root is still 406", %{url: url} do
    resp = Req.get!(url, headers: [{"accept", "text/csv"}], retry: false)
    assert resp.status == 406
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/bier/openapi_v3_http_test.exs`
Expected: the boot succeeds (the option exists after Task 1) but the first test FAILS — the body still has `"swagger" => "2.0"` and no `"openapi"` key.

- [ ] **Step 3: Pipe the converter in the controller**

In `lib/bier/plugs/action_controller.ex` `build_openapi_document/2`, wrap the existing `Bier.OpenAPI.build/1` call:

```elixir
    doc =
      Bier.OpenAPI.build(%{
        relations: relations,
        functions: function_inputs(functions),
        schema_comment: cache.schema_comment,
        security_active?: config.openapi_security_active,
        proxy_uri: config.openapi_server_proxy_uri,
        docs_version: "v14"
      })

    # openapi_version: "3.0" serves an OpenAPI 3.0.3 translation of the same
    # content; "2.0" (default) stays the PostgREST-parity Swagger wire format.
    case config.openapi_version do
      "3.0" -> Bier.OpenAPI.V3.convert(doc)
      _ -> doc
    end
```

(Also extend the module's `# ---- root ----` comment block: one line noting the version toggle.)

- [ ] **Step 4: Run the tests**

Run: `mix test test/bier/openapi_v3_http_test.exs`
Expected: PASS.

Run: `mix test --only area:openapi`
Expected: PASS — the conformance instance does not set `openapi_version`, so all 28 cases still receive the 2.0 document.

- [ ] **Step 5: Commit**

```bash
git add lib/bier/plugs/action_controller.ex test/bier/openapi_v3_http_test.exs
git commit -m "openapi: serve OpenAPI 3.0.3 at the root when openapi_version=3.0

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Documentation + final gates

**Files:**
- Modify: `README.md` (configuration/differences section — add `openapi_version` to whichever table/list documents instance options; if a "differences from PostgREST" section exists, note this as a Bier extension)
- Modify: `lib/bier/openapi.ex` (moduledoc: one sentence pointing at `Bier.OpenAPI.V3` for the 3.0 output)

**Interfaces:**
- Consumes: completed Tasks 1–3.
- Produces: docs; a green `mix precommit`.

- [ ] **Step 1: Document the option**

In `lib/bier/openapi.ex`, extend the moduledoc's last paragraph:

```elixir
  Wire-format match to PostgREST v14.12 is the contract; see
  spec/openapi.yaml and spec/conformance/cases/16*.yaml. An opt-in
  OpenAPI 3.0.3 translation of this document is available via the
  `openapi_version: "3.0"` config option (`Bier.OpenAPI.V3`).
```

In `README.md`, locate where config options are documented (search for `openapi_mode` or `openapi-server-proxy-uri`) and add an `openapi_version` entry in the same style, flagged as a Bier extension without a PostgREST equivalent (PostgREST/postgrest#932 has been open since 2017).

- [ ] **Step 2: Run every CI gate**

Run: `mix precommit`
Expected: all gates PASS — `mix docs --warnings-as-errors` is part of it, so the moduledoc edit is checked.

- [ ] **Step 3: Commit and hand off**

```bash
git add README.md lib/bier/openapi.ex
git commit -m "docs: document the openapi_version option

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

Implementation complete for issue #53 item 1. Use superpowers:finishing-a-development-branch. Suggested PR title: "Opt-in OpenAPI 3.0 root document (#53)". Note in the PR body that 3.1 was deliberately deferred (the converter architecture makes it a follow-up: one more `convert/1` variant), and tick item 1's checkbox in #53 on merge.

---

## Self-review notes (kept for the executor)

- **Spec coverage:** issue item 1 asks for an opt-in 3.0/3.1 emitter with a version-selecting config option defaulting to 2.0 — Tasks 1–3 deliver 3.0; 3.1 was explicitly descoped by the operator (2026-07-16) and noted for the PR body.
- **Type consistency:** `V3.convert/1` name and arity match across Tasks 2 and 3; `openapi_version` field name matches across Tasks 1 and 3; test fixture shapes are cross-checked against `test/bier/openapi_test.exs` helpers in both test files' notes.
- **Known execution risks called out inline:** the `%Bier.Introspection.Relation{}` fixture fields (Task 2 Step 1 note) and the HTTP test's DB connection options (Task 3 Step 1 note) must be mirrored from existing test files rather than trusted from this plan.
