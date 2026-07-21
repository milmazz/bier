defmodule Bier.OpenAPIV3Test do
  use ExUnit.Case, async: true

  alias Bier.OpenAPI.V3

  # Mirrors col_map/2 in test/bier/openapi_test.exs, which is the authority on
  # the %Bier.Introspection.Relation{}.columns shape (see the `column()` type
  # in lib/bier/introspection.ex): pk?/composite?/data_rep are unused by
  # Bier.OpenAPI.build/1 but included here to match the real shape exactly.
  defp col(name, type, opts \\ []) do
    %{
      name: name,
      type: type,
      pk?: Keyword.get(opts, :pk?, false),
      notnull?: Keyword.get(opts, :notnull?, false),
      max_length: Keyword.get(opts, :max_length),
      enum_labels: Keyword.get(opts, :enum_labels),
      default: Keyword.get(opts, :default),
      composite?: false,
      data_rep: nil,
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
      server_scheme: :http,
      server_host: "localhost",
      server_port: 3000,
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
    refute Map.has_key?(doc, "produces")
    refute Map.has_key?(doc, "consumes")
    assert doc["info"]["title"] == "PostgREST API"
    assert doc["externalDocs"]["description"] == "PostgREST Documentation"
  end

  test "operation-level produces lists are dropped (2.0-only key)" do
    doc = V3.convert(build())

    root_get = doc["paths"]["/"]["get"]
    assert root_get["summary"] == "OpenAPI description (this document)"
    refute Map.has_key?(root_get, "produces")

    refute Map.has_key?(doc["paths"]["/rpc/add"]["post"], "produces")
    refute Map.has_key?(doc["paths"]["/rpc/add"]["get"], "produces")
  end

  test "servers: server-config url without proxy, proxy url with one" do
    assert V3.convert(build())["servers"] == [%{"url" => "http://localhost:3000"}]

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

    refute Enum.any?(
             post["parameters"],
             &match?(%{"$ref" => "#/components/requestBodies/" <> _}, &1)
           )
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
        server_scheme: :http,
        server_host: "localhost",
        server_port: 3000,
        docs_version: "v14"
      })
      |> V3.convert()

    [param] = doc["paths"]["/rpc/vparam"]["get"]["parameters"]

    assert param["style"] == "form"
    assert param["explode"] == true
    refute Map.has_key?(param, "collectionFormat")

    assert param["schema"] == %{
             "type" => "array",
             "items" => %{"type" => "string", "format" => "text"}
           }
  end

  test "securityDefinitions move to components.securitySchemes; security stays" do
    doc = V3.convert(build(security_active?: true))

    assert doc["security"] == [%{"JWT" => []}]
    refute Map.has_key?(doc, "securityDefinitions")

    assert doc["components"]["securitySchemes"]["JWT"]["type"] == "apiKey"
    assert doc["components"]["securitySchemes"]["JWT"]["in"] == "header"
  end
end
