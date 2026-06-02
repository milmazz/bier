defmodule Bier.ConformanceAssertionsTest do
  use ExUnit.Case, async: true

  import Bier.ConformanceAssertions

  defp resp(overrides \\ %{}) do
    Map.merge(
      %{
        status: 200,
        headers: %{"content-type" => "application/json; charset=utf-8"},
        body: ~s([{"a":1}])
      },
      overrides
    )
  end

  test "status match passes, mismatch raises" do
    assert_expect(resp(), %{"status" => 200})
    assert_raise ExUnit.AssertionError, fn -> assert_expect(resp(), %{"status" => 404}) end
  end

  test "headers subset match" do
    assert_expect(resp(), %{"headers" => %{"Content-Type" => "application/json; charset=utf-8"}})

    assert_raise ExUnit.AssertionError, fn ->
      assert_expect(resp(), %{"headers" => %{"Content-Type" => "text/csv"}})
    end
  end

  test "headers_present and headers_absent" do
    assert_expect(resp(), %{"headers_present" => ["Content-Type"]})
    assert_expect(resp(), %{"headers_absent" => ["Location"]})

    assert_raise ExUnit.AssertionError, fn ->
      assert_expect(resp(), %{"headers_present" => ["Location"]})
    end

    assert_raise ExUnit.AssertionError, fn ->
      assert_expect(resp(), %{"headers_absent" => ["Content-Type"]})
    end
  end

  test "body_exact deep-compares decoded JSON" do
    assert_expect(resp(), %{"body_exact" => [%{"a" => 1}]})

    assert_raise ExUnit.AssertionError, fn ->
      assert_expect(resp(), %{"body_exact" => [%{"a" => 2}]})
    end
  end

  test "body_contains substring; body_raw exact bytes" do
    assert_expect(resp(), %{"body_contains" => ~s("a":1)})

    assert_expect(resp(%{body: <<1>> <> ~s({"type": "FeatureCollection"})}), %{
      "body_raw" => <<1>> <> ~s({"type": "FeatureCollection"})
    })
  end

  test "unknown assertion key raises (never silently passes)" do
    assert_raise RuntimeError, ~r/unsupported assertion/, fn ->
      assert_expect(resp(), %{"body_nonsense" => 1})
    end
  end

  test "headers_match: regex on header value" do
    r = resp(%{headers: %{"server-timing" => "transaction;dur=12.34"}})

    assert_expect(r, %{"headers_match" => %{"Server-Timing" => "transaction;dur=[0-9]+\\.[0-9]+"}})

    assert_raise ExUnit.AssertionError, fn ->
      assert_expect(r, %{"headers_match" => %{"Server-Timing" => "nope=[0-9]+"}})
    end
  end

  test "headers_no_blank: every header value non-blank" do
    assert_expect(resp(), %{"headers_no_blank" => true})

    assert_raise ExUnit.AssertionError, fn ->
      assert_expect(resp(%{headers: %{"x-blank" => ""}}), %{"headers_no_blank" => true})
    end
  end

  test "headers_absent_in_value: value must not contain substrings" do
    r = resp(%{headers: %{"server-timing" => "jwt;dur=1.0, response;dur=2.0"}})

    assert_expect(r, %{"headers_absent_in_value" => %{"Server-Timing" => ["plan", "transaction"]}})

    assert_raise ExUnit.AssertionError, fn ->
      assert_expect(r, %{"headers_absent_in_value" => %{"Server-Timing" => ["jwt"]}})
    end
  end

  test "body_exact null/empty asserts empty body" do
    assert_expect(resp(%{body: ""}), %{"body_exact" => nil})
    assert_expect(resp(%{body: ""}), %{"body_exact" => ""})
    assert_raise ExUnit.AssertionError, fn -> assert_expect(resp(), %{"body_exact" => nil}) end
  end
end
