defmodule Bier.ConformanceCaseTest do
  use ExUnit.Case, async: true

  alias Bier.ConformanceCase

  test "load_all/0 parses every YAML case into a struct" do
    cases = ConformanceCase.load_all()
    assert length(cases) > 500
    assert Enum.all?(cases, &match?(%ConformanceCase{}, &1))
    assert Enum.all?(cases, &is_integer(&1.id))
  end

  test "derives area from the feature prefix and defaults kind to :http" do
    c = Enum.find(ConformanceCase.load_all(), &(&1.id == 1067))
    assert c != nil, "fixture case 1067 not found — was it renumbered?"
    assert c.feature == "operators/fts"
    assert c.area == "operators"
    assert c.kind == :http
    assert c.request["method"] == "GET"
    assert c.expect["status"] == 200
  end

  test "marks request.kind == cli cases as :cli" do
    c = Enum.find(ConformanceCase.load_all(), &(&1.id == 1705))
    assert c != nil, "fixture case 1705 not found — was it renumbered?"
    assert c.kind == :cli
    assert c.request["flag"] == "--dump-config"
  end
end
