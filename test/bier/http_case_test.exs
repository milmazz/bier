defmodule Bier.HttpCaseTest do
  # async is safe only while tests are read-only against the shared, stateless
  # Bier instance (no DB/server state mutation).
  use Bier.HttpCase, async: true

  alias Bier.ConformanceCase

  test "perform/1 issues the request and returns a normalized response" do
    c = %ConformanceCase{
      id: 0,
      feature: "smoke/get",
      area: "smoke",
      kind: :http,
      request: %{
        "method" => "GET",
        "path" => "/__unknown__",
        "headers" => %{"Accept" => "application/json"}
      },
      schema: "test",
      preconditions: [],
      expect: %{},
      source: nil
    }

    resp = perform(c)
    assert is_integer(resp.status)
    assert is_map(resp.headers)
    assert Enum.all?(Map.keys(resp.headers), &(&1 == String.downcase(&1)))
    assert is_binary(resp.body)
  end
end
