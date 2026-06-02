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
end
