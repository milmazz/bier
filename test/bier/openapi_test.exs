defmodule Bier.OpenAPITest do
  use ExUnit.Case, async: true
  alias Bier.OpenAPI.Types

  describe "schema/2 scalars (1665)" do
    test "varchar/char/text/bool/ints/numbers" do
      assert Types.schema("character varying", []) == %{
               "type" => "string",
               "format" => "character varying"
             }

      assert Types.schema("character", max_length: 1) == %{
               "type" => "string",
               "format" => "character",
               "maxLength" => 1
             }

      assert Types.schema("text", []) == %{"type" => "string", "format" => "text"}
      assert Types.schema("boolean", []) == %{"type" => "boolean", "format" => "boolean"}
      assert Types.schema("smallint", []) == %{"type" => "integer", "format" => "int32"}
      assert Types.schema("integer", []) == %{"type" => "integer", "format" => "int32"}
      assert Types.schema("bigint", []) == %{"type" => "integer", "format" => "int64"}
      assert Types.schema("numeric", []) == %{"type" => "number", "format" => "numeric"}
      assert Types.schema("real", []) == %{"type" => "number", "format" => "real"}

      assert Types.schema("double precision", []) == %{
               "type" => "number",
               "format" => "double precision"
             }
    end
  end

  describe "schema/2 json + arrays (1666, 1667)" do
    test "json/jsonb have only format" do
      assert Types.schema("json", []) == %{"format" => "json"}
      assert Types.schema("jsonb", []) == %{"format" => "jsonb"}
    end

    test "arrays carry format <elem>[] with typed items" do
      assert Types.schema("text[]", []) == %{
               "format" => "text[]",
               "type" => "array",
               "items" => %{"type" => "string"}
             }

      assert Types.schema("integer[]", []) == %{
               "format" => "integer[]",
               "type" => "array",
               "items" => %{"type" => "integer"}
             }

      assert Types.schema("numeric[]", []) == %{
               "format" => "numeric[]",
               "type" => "array",
               "items" => %{"type" => "number"}
             }

      assert Types.schema("json[]", []) == %{
               "format" => "json[]",
               "type" => "array",
               "items" => %{}
             }
    end
  end

  describe "schema/2 enum (1668)" do
    test "enum -> type string, format <schema.type>, enum labels" do
      assert Types.schema("test.enum_menagerie_type", enum: ["foo", "bar"]) ==
               %{
                 "type" => "string",
                 "format" => "test.enum_menagerie_type",
                 "enum" => ["foo", "bar"]
               }
    end
  end

  describe "query_param/2 (1671, 1672)" do
    test "scalars match schema; arrays become string; json -> string" do
      assert Types.query_param("double precision", []) == %{
               "type" => "number",
               "format" => "double precision"
             }

      assert Types.query_param("integer", []) == %{"type" => "integer", "format" => "int32"}
      assert Types.query_param("text[]", []) == %{"type" => "string", "format" => "text[]"}
      assert Types.query_param("json", []) == %{"type" => "string", "format" => "json"}
    end

    test "variadic uses array + collectionFormat multi" do
      assert Types.query_param("text[]", variadic: true) ==
               %{
                 "type" => "array",
                 "collectionFormat" => "multi",
                 "items" => %{"type" => "string", "format" => "text"}
               }
    end

    test "variadic json array omits nil item type" do
      assert Types.query_param("json[]", variadic: true) ==
               %{
                 "type" => "array",
                 "collectionFormat" => "multi",
                 "items" => %{"format" => "json"}
               }
    end
  end

  describe "default/2 (1669)" do
    test "decodes/strips column defaults by type" do
      assert Types.default(nil, "text") == :omit
      assert Types.default("'default'::text", "text") == "default"
      assert Types.default("false", "boolean") == false
      assert Types.default("true", "boolean") == true
      assert Types.default("42", "integer") == 42
      assert Types.default("42.2", "numeric") == 42.2
      assert Types.default("'1900-01-01'::date", "date") == "1900-01-01"

      assert Types.default("'13:00:00'::time without time zone", "time without time zone") ==
               "13:00:00"
    end

    test "integer default that is a sequence call falls back to the raw string (no crash)" do
      assert Types.default("nextval('s'::regclass)", "integer") == "nextval('s'"
    end
  end

  describe "build/1 skeleton" do
    test "swagger + default info + externalDocs (1650/1654/1655)" do
      doc =
        Bier.OpenAPI.build(%{
          relations: [],
          functions: [],
          schema_comment: nil,
          security_active?: false,
          docs_version: "v14"
        })

      assert doc["swagger"] == "2.0"
      assert doc["info"]["title"] == "PostgREST API"
      assert doc["info"]["description"] == "This is a dynamic API generated by PostgREST"
      assert doc["externalDocs"]["url"] == "https://postgrest.org/en/v14/references/api.html"
      assert doc["externalDocs"]["description"] == "PostgREST Documentation"
    end

    test "schema comment seeds title/description (1656)" do
      doc =
        Bier.OpenAPI.build(%{
          relations: [],
          functions: [],
          schema_comment: "My API title\nMy API description\nthat spans\nmultiple lines",
          security_active?: false,
          docs_version: "v14"
        })

      assert doc["info"]["title"] == "My API title"
      assert doc["info"]["description"] == "My API description\nthat spans\nmultiple lines"
    end

    test "single-line schema comment -> title only, no description key" do
      doc =
        Bier.OpenAPI.build(%{
          relations: [],
          functions: [],
          schema_comment: "Just a title",
          security_active?: false,
          docs_version: "v14"
        })

      assert doc["info"]["title"] == "Just a title"
      refute Map.has_key?(doc["info"], "description")
    end
  end

  describe "build/1 security (1679/1680)" do
    test "absent by default" do
      doc =
        Bier.OpenAPI.build(%{
          relations: [],
          functions: [],
          schema_comment: nil,
          security_active?: false,
          docs_version: "v14"
        })

      refute Map.has_key?(doc, "security")
      refute Map.has_key?(doc, "securityDefinitions")
    end

    test "present when security_active?" do
      doc =
        Bier.OpenAPI.build(%{
          relations: [],
          functions: [],
          schema_comment: nil,
          security_active?: true,
          docs_version: "v14"
        })

      assert doc["security"] == [%{"JWT" => []}]
      assert doc["securityDefinitions"]["JWT"]["type"] == "apiKey"
      assert doc["securityDefinitions"]["JWT"]["in"] == "header"
      assert doc["securityDefinitions"]["JWT"]["name"] == "Authorization"

      assert doc["securityDefinitions"]["JWT"]["description"] ==
               "Add the token prepending \"Bearer \" (without quotes) to it"
    end
  end
end
