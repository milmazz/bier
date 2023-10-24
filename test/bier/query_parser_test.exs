defmodule Bier.QueryParserTest do
  use ExUnit.Case, async: true

  import Bier.QueryParser
  doctest Bier.QueryParser

  describe "parse_select/1" do
    test "success: parses the select query string" do
      query_string = "uno:first::text, dos:second, third, forth::text"

      assert {:ok, ~S/first::text AS "uno", second AS "dos", third, forth::text/} =
               parse_select(query_string)

      assert {:ok, "*"} = parse_select("*")
    end

    test "error: should detect bad select input" do
      assert {:error, reason} = parse_select("*,")
      assert reason =~ "expected ASCII character equal to \"*\", followed by end of string"
    end
  end

  describe "parse_filters/1" do
    test "success: parses multiple filters" do
      for operator <- ["like", "ilike"] do
        params = %{age: "gt.13", name: "#{operator}.john*", adult: "is.true"}

        expected_result = [
          {:adult, %{operator: "IS", value: true, negation?: false}},
          {:age, %{operator: ">", value: "13", negation?: false}},
          {:name, %{operator: String.upcase(operator), value: "john%", negation?: false}}
        ]

        assert {:ok, result} = parse_filters(params)
        assert Enum.sort_by(result, &elem(&1, 0), :asc) == expected_result
      end
    end

    test "success: replaces * with % on ilikes" do
      params = %{age: "gt.13", name: "ilike.john*"}

      expected_result = [
        {:age, %{operator: ">", value: "13", negation?: false}},
        {:name, %{operator: "ILIKE", value: "john%", negation?: false}}
      ]

      assert {:ok, result} = parse_filters(params)
      assert Enum.sort_by(result, &elem(&1, 0), :asc) == expected_result
    end

    test "error: detect invalid filters" do
      params = %{age: "gt.13", name: "is.null"}

      assert {:error, :bad_request} == parse_filters(params)
    end
  end

  describe "parse_request_body/1" do
    test "success: checks that all object keys must match" do
      params = [
        %{"task" => "learn how to auth", "done" => true},
        %{"task" => "implement parser", "done" => false}
      ]

      assert {:ok, %{keys: keys, values: values}} = parse_request_body(params)

      expected_keys = MapSet.new(["done", "task"])
      expected_values = MapSet.new([[false, "'implement parser'"], [true, "'learn how to auth'"]])

      assert Map.equal?(MapSet.new(keys), expected_keys)
      assert Map.equal?(MapSet.new(values), expected_values)
    end

    test "error: checks that all object keys must match" do
      params = [
        %{"task" => "learn how to auth"},
        %{"task" => "implement parser", "done" => false}
      ]

      assert parse_request_body(params) == {:error, :mismatch}
    end
  end
end
