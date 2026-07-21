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

  describe "schema/2 normalizes length modifiers" do
    test "char(1) -> base format character with maxLength" do
      assert Types.schema("character(1)", max_length: 1) == %{
               "type" => "string",
               "format" => "character",
               "maxLength" => 1
             }
    end

    test "numeric(10,2) -> numeric" do
      assert Types.schema("numeric(10,2)", []) == %{"type" => "number", "format" => "numeric"}
    end

    test "character varying(255) -> character varying" do
      assert Types.schema("character varying(255)", []) == %{
               "type" => "string",
               "format" => "character varying"
             }
    end

    test "character(1)[] array -> character[] with string items" do
      assert Types.schema("character(1)[]", []) == %{
               "format" => "character[]",
               "type" => "array",
               "items" => %{"type" => "string"}
             }
    end

    test "timestamp(6) without time zone -> timestamp without time zone" do
      assert Types.schema("timestamp(6) without time zone", []) == %{
               "type" => "string",
               "format" => "timestamp without time zone"
             }
    end
  end

  describe "query_param/2 normalizes length modifiers" do
    test "char(1) -> character" do
      assert Types.query_param("character(1)", []) == %{
               "type" => "string",
               "format" => "character"
             }
    end

    test "numeric(10,2) array -> string format numeric[]" do
      assert Types.query_param("numeric(10,2)[]", []) == %{
               "type" => "string",
               "format" => "numeric[]"
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

    test "non-literal defaults (function calls, expressions) are omitted" do
      assert Types.default("nextval('s'::regclass)", "integer") == :omit
      assert Types.default("now()", "numeric") == :omit
      assert Types.default("some_fn()", "boolean") == :omit
    end
  end

  describe "build/1 skeleton" do
    test "swagger + default info + externalDocs (1650/1654/1655)" do
      doc = Bier.OpenAPI.build(build_input(%{}))

      assert doc["swagger"] == "2.0"
      assert doc["info"]["title"] == "PostgREST API"
      assert doc["info"]["description"] == "This is a dynamic API generated by PostgREST"
      assert doc["externalDocs"]["url"] == "https://postgrest.org/en/v14/references/api.html"
      assert doc["externalDocs"]["description"] == "PostgREST Documentation"

      # The document root advertises the rpc trio + text/csv on BOTH
      # produces and consumes (postgrestSpec, OpenAPI.hs#L408-409).
      expected_mimes = [
        "application/json",
        "application/vnd.pgrst.object+json;nulls=stripped",
        "application/vnd.pgrst.object+json",
        "text/csv"
      ]

      assert doc["produces"] == expected_mimes
      assert doc["consumes"] == expected_mimes
    end

    test "schema comment seeds title/description (1656)" do
      doc =
        Bier.OpenAPI.build(
          build_input(%{
            schema_comment: "My API title\nMy API description\nthat spans\nmultiple lines"
          })
        )

      assert doc["info"]["title"] == "My API title"
      assert doc["info"]["description"] == "My API description\nthat spans\nmultiple lines"
    end

    test "single-line schema comment -> title only, no description key" do
      doc = Bier.OpenAPI.build(build_input(%{schema_comment: "Just a title"}))

      assert doc["info"]["title"] == "Just a title"
      refute Map.has_key?(doc["info"], "description")
    end
  end

  describe "build/1 security (1679/1680)" do
    test "absent by default" do
      doc = Bier.OpenAPI.build(build_input(%{}))

      refute Map.has_key?(doc, "security")
      refute Map.has_key?(doc, "securityDefinitions")
    end

    test "present when security_active?" do
      doc = Bier.OpenAPI.build(build_input(%{security_active?: true}))

      assert doc["security"] == [%{"JWT" => []}]
      assert doc["securityDefinitions"]["JWT"]["type"] == "apiKey"
      assert doc["securityDefinitions"]["JWT"]["in"] == "header"
      assert doc["securityDefinitions"]["JWT"]["name"] == "Authorization"

      assert doc["securityDefinitions"]["JWT"]["description"] ==
               "Add the token prepending \"Bearer \" (without quotes) to it"
    end
  end

  describe "definitions (1659/1660/1664)" do
    test "table: properties, pk/fk notes, required, table-comment description" do
      child = %Bier.Introspection.Relation{
        schema: "test",
        name: "child_entities",
        kind: :table,
        primary_key: ["id"],
        foreign_keys: [
          %{
            constraint: "fk",
            columns: ["parent_id"],
            ref_schema: "test",
            ref_relation: "entities",
            ref_columns: ["id"],
            unique?: false
          }
        ],
        columns: [
          col_map("id", "integer",
            pk?: true,
            notnull?: true,
            comment: "child_entities id comment"
          ),
          col_map("name", "text",
            comment: "child_entities name comment. Can be longer than sixty-three characters long"
          ),
          col_map("parent_id", "integer")
        ],
        comment: "child_entities comment"
      }

      d = build_one(child)["definitions"]["child_entities"]
      assert d["type"] == "object"
      assert d["description"] == "child_entities comment"

      assert d["properties"]["id"]["description"] ==
               "child_entities id comment\n\nNote:\nThis is a Primary Key.<pk/>"

      assert d["properties"]["name"]["description"] ==
               "child_entities name comment. Can be longer than sixty-three characters long"

      assert d["properties"]["parent_id"]["description"] ==
               "Note:\nThis is a Foreign Key to `entities.id`.<fk table='entities' column='id'/>"

      assert d["required"] == ["id"]
    end

    test "view: object + comment description + pk/fk notes, NO required key (1664)" do
      view = %Bier.Introspection.Relation{
        schema: "test",
        name: "child_entities_view",
        kind: :view,
        primary_key: ["id"],
        foreign_keys: [
          %{
            constraint: "fk",
            columns: ["parent_id"],
            ref_schema: "test",
            ref_relation: "entities",
            ref_columns: ["id"],
            unique?: false
          }
        ],
        columns: [
          col_map("id", "integer",
            pk?: true,
            notnull?: false,
            comment: "child_entities_view id comment"
          ),
          col_map("parent_id", "integer")
        ],
        comment: "child_entities_view comment"
      }

      d = build_one(view)["definitions"]["child_entities_view"]
      assert d["type"] == "object"
      assert d["description"] == "child_entities_view comment"

      assert d["properties"]["id"]["description"] ==
               "child_entities_view id comment\n\nNote:\nThis is a Primary Key.<pk/>"

      assert d["properties"]["parent_id"]["description"] ==
               "Note:\nThis is a Foreign Key to `entities.id`.<fk table='entities' column='id'/>"

      refute Map.has_key?(d, "required")
    end

    test "commented FK column joins comment and FK note" do
      rel = %Bier.Introspection.Relation{
        schema: "test",
        name: "t",
        kind: :table,
        primary_key: [],
        foreign_keys: [
          %{
            constraint: "fk",
            columns: ["parent_id"],
            ref_schema: "test",
            ref_relation: "entities",
            ref_columns: ["id"],
            unique?: false
          }
        ],
        columns: [col_map("parent_id", "integer", comment: "the parent link")],
        comment: nil
      }

      desc = build_one(rel)["definitions"]["t"]["properties"]["parent_id"]["description"]

      assert desc ==
               "the parent link\n\nNote:\nThis is a Foreign Key to `entities.id`.<fk table='entities' column='id'/>"
    end
  end

  describe "definitions defaults (1669)" do
    test "decoded column defaults" do
      rel = %Bier.Introspection.Relation{
        schema: "test",
        name: "openapi_defaults",
        kind: :table,
        primary_key: [],
        foreign_keys: [],
        comment: nil,
        columns: [
          col_map("text", "text", default: "'default'::text"),
          col_map("boolean", "boolean", default: "false"),
          col_map("integer", "integer", default: "42"),
          col_map("numeric", "numeric", default: "42.2"),
          col_map("date", "date", default: "'1900-01-01'::date"),
          col_map("time", "time without time zone", default: "'13:00:00'::time without time zone")
        ]
      }

      p = build_one(rel)["definitions"]["openapi_defaults"]["properties"]
      assert p["text"]["default"] == "default"
      assert p["boolean"]["default"] == false
      assert p["integer"]["default"] == 42
      assert p["numeric"]["default"] == 42.2
      assert p["date"]["default"] == "1900-01-01"
      assert p["time"]["default"] == "13:00:00"
    end
  end

  describe "table path items (1657/1658/1661/1662/1663)" do
    setup do
      child = %Bier.Introspection.Relation{
        schema: "test",
        name: "child_entities",
        kind: :table,
        primary_key: ["id"],
        foreign_keys: [],
        comment: "child_entities comment",
        columns: [
          col_map("id", "integer"),
          col_map("name", "text"),
          col_map("parent_id", "integer")
        ]
      }

      %{doc: build_one(child)}
    end

    test "get summary (single-line comment), no description, param $refs, responses (1657/1661/1662/1663)",
         %{doc: doc} do
      get = doc["paths"]["/child_entities"]["get"]
      assert get["summary"] == "child_entities comment"
      refute Map.has_key?(get, "description")

      assert Enum.map(get["parameters"], & &1["$ref"]) == [
               "#/parameters/rowFilter.child_entities.id",
               "#/parameters/rowFilter.child_entities.name",
               "#/parameters/rowFilter.child_entities.parent_id",
               "#/parameters/select",
               "#/parameters/order",
               "#/parameters/range",
               "#/parameters/rangeUnit",
               "#/parameters/offset",
               "#/parameters/limit",
               "#/parameters/preferCount"
             ]

      assert get["responses"]["200"]["description"] == "OK"

      assert get["responses"]["200"]["schema"] == %{
               "type" => "array",
               "items" => %{"$ref" => "#/definitions/child_entities"}
             }

      assert get["responses"]["206"]["description"] == "Partial Content"
      assert get["tags"] == ["child_entities"]
    end

    test "post/patch/delete params, responses, tags (1661/1662)", %{doc: doc} do
      item = doc["paths"]["/child_entities"]

      assert Enum.map(item["post"]["parameters"], & &1["$ref"]) ==
               [
                 "#/parameters/body.child_entities",
                 "#/parameters/select",
                 "#/parameters/preferPost"
               ]

      assert item["post"]["responses"]["201"]["description"] == "Created"
      assert item["post"]["tags"] == ["child_entities"]

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

      assert item["delete"]["responses"]["204"]["description"] == "No Content"
    end

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
  end

  describe "multi-line table comment (1658)" do
    test "summary + description split" do
      gc = %Bier.Introspection.Relation{
        schema: "test",
        name: "grandchild_entities",
        kind: :table,
        primary_key: [],
        foreign_keys: [],
        comment:
          "grandchild_entities summary\n\ngrandchild_entities description\nthat spans\nmultiple lines",
        columns: [col_map("id", "integer")]
      }

      get = build_one(gc)["paths"]["/grandchild_entities"]["get"]
      assert get["summary"] == "grandchild_entities summary"
      assert get["description"] == "grandchild_entities description\nthat spans\nmultiple lines"
    end
  end

  describe "view path item is GET-only" do
    test "no post/patch/delete for views" do
      view = %Bier.Introspection.Relation{
        schema: "test",
        name: "av",
        kind: :view,
        primary_key: [],
        foreign_keys: [],
        comment: nil,
        columns: [col_map("id", "integer")]
      }

      item = build_one(view)["paths"]["/av"]
      assert Map.has_key?(item, "get")
      refute Map.has_key?(item, "post")
      refute Map.has_key?(item, "patch")
      refute Map.has_key?(item, "delete")
    end
  end

  describe "rpc path items (1670-1674)" do
    setup do
      fns = [
        %{
          name: "varied_arguments_openapi",
          comment: "An RPC function\nJust a test for RPC function arguments",
          volatility: :immutable,
          in_params: [
            p("double", "double precision", false, false),
            p("text_arr", "text[]", false, false),
            p("integer", "integer", false, true),
            p("json", "json", false, true)
          ]
        },
        %{name: "reset_table", comment: nil, volatility: :volatile, in_params: []},
        %{name: "getallusers", comment: nil, volatility: :stable, in_params: []},
        %{
          name: "variadic_param",
          comment: nil,
          volatility: :immutable,
          in_params: [p_var("v", "text[]")]
        }
      ]

      %{doc: build_fns(fns)}
    end

    test "summary/description + get params (1670/1671)", %{doc: doc} do
      get = doc["paths"]["/rpc/varied_arguments_openapi"]["get"]
      assert get["summary"] == "An RPC function"
      assert get["description"] == "Just a test for RPC function arguments"

      assert Enum.at(get["parameters"], 0) == %{
               "format" => "double precision",
               "in" => "query",
               "name" => "double",
               "required" => true,
               "type" => "number"
             }

      assert Enum.at(get["parameters"], 1) == %{
               "format" => "text[]",
               "in" => "query",
               "name" => "text_arr",
               "required" => true,
               "type" => "string"
             }

      assert Enum.at(get["parameters"], 2) == %{
               "format" => "int32",
               "in" => "query",
               "name" => "integer",
               "required" => false,
               "type" => "integer"
             }

      assert Enum.at(get["parameters"], 3) == %{
               "format" => "json",
               "in" => "query",
               "name" => "json",
               "required" => false,
               "type" => "string"
             }

      assert get["tags"] == ["(rpc) varied_arguments_openapi"]
    end

    test "variadic arg (1672)", %{doc: doc} do
      assert hd(doc["paths"]["/rpc/variadic_param"]["get"]["parameters"]) ==
               %{
                 "collectionFormat" => "multi",
                 "in" => "query",
                 "items" => %{"format" => "text", "type" => "string"},
                 "name" => "v",
                 "required" => false,
                 "type" => "array"
               }
    end

    test "post body schema (1673)", %{doc: doc} do
      body = hd(doc["paths"]["/rpc/varied_arguments_openapi"]["post"]["parameters"])
      assert body["name"] == "args"
      assert body["in"] == "body"
      assert body["schema"]["type"] == "object"

      assert body["schema"]["description"] ==
               "An RPC function\n\nJust a test for RPC function arguments"

      assert body["schema"]["properties"]["double"] == %{
               "format" => "double precision",
               "type" => "number"
             }

      assert body["schema"]["properties"]["text_arr"] == %{
               "format" => "text[]",
               "type" => "array",
               "items" => %{"type" => "string"}
             }

      assert body["schema"]["required"] == ["double", "text_arr"]

      # PostgREST marks the args body param required (OpenAPI.hs#L222).
      assert body["required"] == true

      # The second POST parameter is the shared preferParams ref
      # (OpenAPI.hs#L219-226 makeProcPostParams).
      assert Enum.at(
               doc["paths"]["/rpc/varied_arguments_openapi"]["post"]["parameters"],
               1
             ) == %{"$ref" => "#/parameters/preferParams"}

      assert doc["paths"]["/rpc/varied_arguments_openapi"]["post"]["tags"] == [
               "(rpc) varied_arguments_openapi"
             ]
    end

    test "volatility methods (1674)", %{doc: doc} do
      refute Map.has_key?(doc["paths"]["/rpc/reset_table"], "get")
      assert Map.has_key?(doc["paths"]["/rpc/reset_table"], "post")
      assert Map.has_key?(doc["paths"]["/rpc/getallusers"], "get")
      assert Map.has_key?(doc["paths"]["/rpc/getallusers"], "post")
    end

    test "get and post ops carry the rpc produces list (issue #85)", %{doc: doc} do
      # Every RPC operation advertises json + both singular-object variants
      # (procOp produces, OpenAPI.hs#L360; mime strings MediaType.hs#L72-74).
      expected = [
        "application/json",
        "application/vnd.pgrst.object+json;nulls=stripped",
        "application/vnd.pgrst.object+json"
      ]

      assert doc["paths"]["/rpc/varied_arguments_openapi"]["get"]["produces"] == expected
      assert doc["paths"]["/rpc/varied_arguments_openapi"]["post"]["produces"] == expected
      assert doc["paths"]["/rpc/reset_table"]["post"]["produces"] == expected
    end
  end

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

  describe "build/1 schemes/host/basePath (openapi-server-proxy-uri + server fallback)" do
    # postgrestSpec always emits schemes/host/basePath; with no proxy they
    # come from the server config ("http", server-host, port, "/") and the
    # port is always appended to host (OpenAPI.hs#L393-414, L448-454;
    # swagger2 Host ToJSON). Issue #85 item 3.
    test "absent proxy: server config seeds schemes, escaped host:port, basePath /" do
      doc = build_one_with_proxy(nil)
      assert doc["schemes"] == ["http"]
      # "!4" is a listen-anywhere value: escapeHostName maps it to 0.0.0.0
      # (Network.hs#L46-52).
      assert doc["host"] == "0.0.0.0:4040"
      assert doc["basePath"] == "/"
    end

    test "every listen-anywhere server_host form escapes to 0.0.0.0 (Network.hs#L46-52)" do
      for h <- ~w(* *4 !4 *6 !6) do
        assert build_one_with_server(h, :http, 3000)["host"] == "0.0.0.0:3000"
      end
    end

    test "a concrete server_host passes through, and :https maps the scheme" do
      doc = build_one_with_server("api.internal", :https, 8443)
      assert doc["schemes"] == ["https"]
      assert doc["host"] == "api.internal:8443"
    end

    test "proxy URI seeds schemes, host with explicit port, and basePath" do
      doc = build_one_with_proxy("https://example.com:8443/basePath")
      assert doc["schemes"] == ["https"]
      assert doc["host"] == "example.com:8443"
      assert doc["basePath"] == "/basePath"
    end

    test "scheme-default proxy ports are still appended; empty path maps to /" do
      # pickProxy fills 80/443 for portless URIs and postgrestSpec always
      # renders Host with the port (OpenAPI.hs#L414, L441-446) — the
      # previous omit-default-port behavior was a deviation.
      assert build_one_with_proxy("http://example.com")["host"] == "example.com:80"
      assert build_one_with_proxy("https://example.com")["host"] == "example.com:443"
      assert build_one_with_proxy("http://example.com")["basePath"] == "/"
    end
  end

  describe "root introspection path item" do
    # PostgREST inserts a "/" path item first (makeRootPathItem,
    # OpenAPI.hs#L370-383): GET-only, Introspection tag, and a produces
    # pair of openapi+json / json (toMime, MediaType.hs#L72). Issue #85.
    test "GET-only / entry with Introspection tag and produces pair" do
      doc = build_fns([])

      assert doc["paths"]["/"] == %{
               "get" => %{
                 "tags" => ["Introspection"],
                 "summary" => "OpenAPI description (this document)",
                 "produces" => ["application/openapi+json", "application/json"],
                 "responses" => %{"200" => %{"description" => "OK"}}
               }
             }
    end
  end

  # --- helpers ---
  defp build_input(overrides) do
    Map.merge(
      %{
        relations: [],
        functions: [],
        schema_comment: nil,
        security_active?: false,
        docs_version: "v14",
        server_scheme: :http,
        server_host: "!4",
        server_port: 4040
      },
      overrides
    )
  end

  defp build_one_with_proxy(proxy_uri),
    do: Bier.OpenAPI.build(build_input(%{proxy_uri: proxy_uri}))

  defp build_one_with_server(host, scheme, port),
    do:
      Bier.OpenAPI.build(
        build_input(%{server_host: host, server_scheme: scheme, server_port: port})
      )

  defp p(name, type, variadic?, has_default?),
    do: %{name: name, type: type, variadic?: variadic?, has_default?: has_default?}

  defp p_var(name, type), do: p(name, type, true, false)

  defp build_fns(fns), do: Bier.OpenAPI.build(build_input(%{functions: fns}))

  defp col_map(name, type, opts \\ []) do
    %{
      name: name,
      type: type,
      pk?: Keyword.get(opts, :pk?, false),
      notnull?: Keyword.get(opts, :notnull?, false),
      default: Keyword.get(opts, :default),
      composite?: false,
      data_rep: nil,
      comment: Keyword.get(opts, :comment),
      enum_labels: Keyword.get(opts, :enum_labels),
      max_length: Keyword.get(opts, :max_length)
    }
  end

  defp build_one(rel), do: Bier.OpenAPI.build(build_input(%{relations: [rel]}))
end
