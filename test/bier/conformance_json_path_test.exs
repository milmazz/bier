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
end
