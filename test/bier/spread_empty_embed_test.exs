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

  Dropping the join has to leave the *parameter* accumulator consistent as well
  as the SQL: the subtree binds its filters before it is known to project
  nothing, and `QE.bind/3` never renumbers. The filter cases below are the ones
  that hold that end down.

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

  # `URI.encode/1` rather than `URI.encode_query/1`: the reserved characters a
  # PostgREST query string is built out of — `(`, `)`, `,`, `*`, `.` — must
  # reach the parser literally, and only the spaces inside filter values need
  # escaping.
  defp get(base, path, select, params \\ []) do
    query =
      [{"select", select} | params]
      |> Enum.map_join("&", fn {k, v} -> "#{k}=#{URI.encode(v)}" end)

    Req.get!(base <> path <> "?" <> query, retry: false)
  end

  # test.factories holds exactly these four rows, and they are the parents whose
  # count must survive the spread (`spec/fixtures/02_base.sql:2045-2048`).
  @factories ["Factory A", "Factory B", "Factory C", "Factory D"]

  # The spread spellings this module covers, for the closing sweep.
  @spellings [
    "name,...processes(process_costs())",
    "name,...processes!inner(process_costs())",
    "name,...processes(...process_costs())",
    "name,...processes(...process_costs(processes()))",
    "name,...processes()",
    "name,processes(...process_costs())",
    "factory:name,...processes(name,process_costs())"
  ]

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

    # A spread nested inside a spread collapses inner-first: the innermost
    # `processes()` is `empty: true` at the node, which leaves `...process_costs`
    # merging nothing, which in turn leaves `...processes` merging nothing.
    test "a nested spread that merges nothing collapses at every level", %{base: base} do
      resp = get(base, "/factories", "name,...processes(...process_costs(processes()))")

      assert resp.status == 200
      assert length(resp.body) == 4
      assert Enum.map(resp.body, &Map.keys/1) == List.duplicate(["name"], 4)
    end
  end

  # The dropped subtree has already bound its filters into the parameter
  # accumulator by the time it turns out to project nothing, and `QE.bind/3` is
  # a monotonic counter that never renumbers. Discarding the SQL without
  # discarding those binds hands Postgrex a parameter the statement no longer
  # mentions — or, with a root filter alongside, a statement that references
  # `$2` and never `$1` (`42P18`, raised at Parse).
  describe "filters on a spread that merges nothing (#154, bind accumulator)" do
    test "a filter on the dropped embed does not orphan its bind", %{base: base} do
      resp =
        get(base, "/factories", "name,...processes(process_costs())", [
          {"processes.name", "eq.Process A1"}
        ])

      assert resp.status == 200
      assert length(resp.body) == 4
      assert Enum.map(resp.body, & &1["name"]) |> Enum.sort() == @factories
      assert Enum.map(resp.body, &Map.keys/1) == List.duplicate(["name"], 4)
    end

    test "a root filter alongside it still binds contiguously", %{base: base} do
      resp =
        get(base, "/factories", "name,...processes(process_costs())", [
          {"processes.name", "eq.Process A1"},
          {"name", "neq.Factory A"}
        ])

      assert resp.status == 200

      # The root filter must be the one that survives, and it must still be
      # numbered against the statement it is rendered into.
      assert Enum.map(resp.body, & &1["name"]) |> Enum.sort() ==
               ["Factory B", "Factory C", "Factory D"]
    end

    test "a filter on a nested embed under the dropped spread does not orphan its bind",
         %{base: base} do
      resp =
        get(base, "/factories", "name,...processes(process_costs!inner())", [
          {"processes.process_costs.cost", "gt.100"}
        ])

      assert resp.status == 200
      assert length(resp.body) == 4
    end
  end

  # The two interactions the fix reasons about rather than changes: `!inner`
  # filtering never lived in the LATERAL (it propagates through the parent's
  # `EXISTS`, `inner_join_clauses/6`), and the alias the LATERAL registered was
  # read only by `spread_order_expr/3`, which had no column to name here.
  describe "what dropping the LATERAL must not take with it (#154)" do
    test "!inner still filters the parent through its EXISTS", %{base: base} do
      resp = get(base, "/factories", "name,...processes!inner(process_costs())")

      assert resp.status == 200

      # Factory D has no processes, so the root's EXISTS drops it. Pre-fix this
      # returned 8 rows — the multiplication, minus D.
      assert Enum.map(resp.body, & &1["name"]) |> Enum.sort() ==
               ["Factory A", "Factory B", "Factory C"]
    end

    test "ordering by a spread that merges nothing falls back to a correlated term",
         %{base: base} do
      resp =
        get(base, "/processes", "name,...factories(factory_buildings())", [
          {"order", "factories(name).desc,name.asc"}
        ])

      assert resp.status == 200

      # `spread_col_name/2` finds no `:field` node to name, so the term never
      # reads the (now absent) spread alias and `correlated_order_term/5`
      # answers for it — descending by factory name, so Factory C's four
      # processes come first (`spec/fixtures/02_base.sql:2053-2060`).
      assert Enum.map(resp.body, & &1["name"]) == [
               "Process C1",
               "Process C2",
               "Process XX",
               "Process YY",
               "Process B1",
               "Process B2",
               "Process A1",
               "Process A2"
             ]
    end
  end

  describe "a spread that still projects something (#154 guard)" do
    test "an empty embed alongside a real column merges that column as normal", %{base: base} do
      resp =
        get(base, "/factories", "factory:name,...processes(name,process_costs())", [
          {"processes.order", "name"}
        ])

      assert resp.status == 200
      assert length(resp.body) == 4

      # The short-circuit keys on the spread projecting nothing, NOT on it
      # containing an empty embed: `name` is still merged, and a to-many spread
      # merges it as the aggregated array. `processes.order` pins the array
      # order the way case 11110 does.
      by_factory =
        Map.new(resp.body, fn row -> {row["factory"], row["name"]} end)

      assert by_factory["Factory A"] == ["Process A1", "Process A2"]
      assert by_factory["Factory B"] == ["Process B1", "Process B2"]
      assert by_factory["Factory D"] == []
    end
  end

  test "no spread spelling leaks a raw SQLSTATE or a bind mismatch", %{base: base} do
    for select <- @spellings, params <- [[], [{"processes.name", "eq.Process A1"}]] do
      resp = get(base, "/factories", select, params)

      assert resp.status == 200,
             "select=#{select} #{inspect(params)} returned #{resp.status}: #{inspect(resp.body)}"

      refute is_map(resp.body) and Map.has_key?(resp.body, "code"),
             "select=#{select} #{inspect(params)} errored: #{inspect(resp.body)}"
    end
  end
end
