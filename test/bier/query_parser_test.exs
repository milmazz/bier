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

  describe "parse_request_body/1" do
    test "checks that all object keys must match" do
      params = [
        %{"task" => "learn how to auth"},
        %{"task" => "implement parser", "done" => false}
      ]

      assert parse_request_body(params) == {:error, :mismatch}
    end
  end
end
