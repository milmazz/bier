defmodule Bier.SpreadEmptyEmbedTest do
  @moduledoc """
  A to-many spread whose projection contributes no columns must still yield one
  row per parent (#154, from the #147 review).

  `Bier.Embed.spread_entry/8`'s `:many` branch builds its LATERAL by folding
  `child_cols` into a list of `json_agg(…)` aggregates. That list is what makes
  the subquery an aggregate query, and an aggregate query over zero rows still
  returns exactly one row — which is what keeps the `LEFT JOIN LATERAL` from
  changing the parent's cardinality.

  `child_cols` can be empty. The empty-projection short-circuit in
  `build_node/7` matches `%{kind: :embed, empty: true}`, which the parser sets
  only for a *literally* empty parens list (`...processes()`, case 11138). A
  spread whose projection consists entirely of empty embeds —
  `...processes(process_costs())` — is `empty: false` at the outer node, so it
  descends into `build_embed/8` and every child contributes zero entries. The
  aggregate list renders as `""`, and `SELECT  FROM (…)` is legal SQL that is no
  longer an aggregate query: the LATERAL returns one row per child and
  multiplies the parent rows while contributing no keys.

  Case 11138 pins one row per parent for the `...rel()` spelling, and a spread
  that merges no columns is the same statement about the output, so that is the
  behavior asserted here. No conformance case covers the nested-empty spelling —
  what upstream returns for it is unverified, and that question belongs in
  postgrest-conformance, not here.

  Not async: binds a real port and runs DB introspection at boot.
  """
  use ExUnit.Case, async: false

  alias Bier.TestPorts

  @moduletag :integration

  setup_all do
    port = TestPorts.free_port()
    name = :"spread_empty_embed_it_#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge(Bier.ConformanceServer.base_opts(),
        name: name,
        router: [port: port, scheme: :http],
        pool_size: 2
      )

    start_supervised!({Bier, opts})
    TestPorts.wait_until_listening(port)

    %{base: "http://localhost:#{port}"}
  end

  defp get(base, path, select) do
    Req.get!(base <> path <> "?select=" <> URI.encode(select), retry: false)
  end

  # test.factories holds exactly these four rows, and they are the parents whose
  # count must survive the spread (`spec/fixtures/02_base.sql:2045-2048`).
  @factories ["Factory A", "Factory B", "Factory C", "Factory D"]

  describe "a to-many spread whose projection is all empty embeds (#154)" do
    test "contributes no keys and leaves the parent row count alone", %{base: base} do
      resp = get(base, "/factories", "name,...processes(process_costs())")

      assert resp.status == 200

      # Pre-fix this returned 9 rows: one per process for the three factories
      # that have any (2 + 2 + 4), plus the NULL-extended row for Factory D,
      # which has none (`spec/fixtures/02_base.sql:2053-2060`).
      assert length(resp.body) == 4
      assert Enum.map(resp.body, & &1["name"]) |> Enum.sort() == @factories

      # A spread that merges no columns contributes no keys, exactly as the
      # empty spread `...processes()` does in case 11138.
      assert Enum.map(resp.body, &Map.keys/1) == List.duplicate(["name"], 4)
    end

    # The to-one branch never multiplied — its `LIMIT 1` capped the LATERAL at
    # one row whatever the projection was — but the fix drops that join too, so
    # this pins the equivalence rather than a change.
    test "the to-one spelling is unchanged by dropping its LATERAL", %{base: base} do
      resp = get(base, "/processes", "name,...factories(factory_buildings())")

      assert resp.status == 200

      # test.processes is eight rows (`spec/fixtures/02_base.sql:2053-2060`),
      # each with a to-one factory that merges no columns.
      assert length(resp.body) == 8
      assert Enum.map(resp.body, &Map.keys/1) == List.duplicate(["name"], 8)
    end
  end

  describe "a spread that still projects something (#154 guard)" do
    test "an empty embed alongside a real column merges that column as normal", %{base: base} do
      resp = get(base, "/factories", "factory:name,...processes(name,process_costs())")

      assert resp.status == 200
      assert length(resp.body) == 4

      # The short-circuit keys on the spread projecting nothing, NOT on it
      # containing an empty embed: `name` is still merged, and a to-many spread
      # merges it as the aggregated array.
      by_factory =
        Map.new(resp.body, fn row -> {row["factory"], row["name"]} end)

      assert by_factory["Factory A"] == ["Process A1", "Process A2"]
      assert by_factory["Factory B"] == ["Process B1", "Process B2"]
      assert by_factory["Factory D"] == []
    end
  end
end
