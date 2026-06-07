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
      assert_raise ArgumentError, fn -> JP.parse("$['']") end
    end
  end
end
