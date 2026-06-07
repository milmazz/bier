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

  # Regression for #11: Req's decompress_body step used to strip Content-Length
  # off the response, so Content-Length assertions saw nil even though Bandit
  # emits it on the wire. `raw: true` / `compressed: false` keep it intact.
  test "perform/1 preserves Content-Length from the server" do
    c = %ConformanceCase{
      id: 0,
      feature: "smoke/content-length",
      area: "smoke",
      kind: :http,
      request: %{"method" => "GET", "path" => "/__unknown__"},
      schema: "test",
      preconditions: [],
      expect: %{},
      source: nil
    }

    resp = perform(c)

    assert content_length = resp.headers["content-length"]
    assert content_length == Integer.to_string(byte_size(resp.body))
  end
end
