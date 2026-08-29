defmodule Bier.SpreadEmptyEmbedTest do
  @moduledoc """
  A spread whose projection contributes no columns has two answers, not one,
  and which one you get turns on how the emptiness is spelled.

  **Nested empty SPREAD — one row per parent (#154).** `...processes()` and
  `...processes(...process_costs())` both resolve to a projection of no
  columns. `Bier.Embed.spread_entry/8`'s `:many` branch builds its LATERAL by
  folding `child_cols` into a list of `json_agg(…)` aggregates; that list is
  what makes the subquery an aggregate query, and an aggregate query over zero
  rows still returns exactly one row — which is what keeps the
  `LEFT JOIN LATERAL` from changing the parent's cardinality. When `child_cols`
  is empty the aggregate list renders as `""`, and `SELECT  FROM (…)` is legal
  SQL that is no longer an aggregate query: the LATERAL would return one row
  per child and multiply the parent rows while contributing no keys. Dropping
  the join is the fix, and cases 11138/11140 pin the result.

  **Nested empty EMBED — 400 (case 11139).** `...processes(process_costs())` is
  *not* the same statement. Upstream's `relSelectToSpread` (`Plan.hs:716`)
  emits one `SpreadSelectField` named after every embedded relation in its
  `JsonEmbed` branch unconditionally — it never consults the `rsEmptyEmbed`
  flag the non-spread path computes — so the projection names a column the
  subquery does not project and PostgreSQL raises `42703`. Its `Spread` branch
  (`L718`) instead splices a nested spread's own field list, which is why the
  spelling above stays a 200.

  That second half is what this file used to get wrong. It was written for
  #154 with no conformance case covering the nested-empty spelling, and it
  said so: *"what upstream returns for it is unverified, and that question
  belongs in postgrest-conformance, not here."* Suite.5 answered it — 11139 is
  a 400, read off a live run of the pinned v16.0 binary — so every assertion
  here that expected a 200 from an empty embed has been inverted.

  What the conformance cases do not cover, and this file therefore still owns:

  * The **parameter accumulator** under a dropped LATERAL. The subtree binds
    its filters before it is known to project nothing, and `QE.bind/3` is a
    monotonic counter that never renumbers. Discarding the SQL without
    discarding those binds hands Postgrex a parameter the statement no longer
    mentions — or, with a root filter alongside, a statement that references
    `$2` and never `$1` (`42P18`, raised at Parse).
  * The two interactions the drop reasons about rather than changes: `!inner`
    filtering never lived in the LATERAL (it propagates through the parent's
    `EXISTS`, `inner_join_clauses/6`), and the alias the LATERAL registered was
    read only by `spread_order_expr/3`, which has no column to name here.
  * The **sibling 42703 spellings** 11139's own notes name but do not issue —
    `!inner`, an extra real column alongside the empty embed, the to-one
    direction, and the phantom propagating up through a nested spread.

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

  # Spellings whose projection resolves to no columns through nested empty
  # SPREADS. These drop the LATERAL and answer 200 (cases 11138/11140).
  @merging_spellings [
    "name,...processes()",
    "name,...processes(...process_costs())",
    "name,...processes!inner(...process_costs())",
    "name,processes(...process_costs())"
  ]

  # Spellings carrying a nested empty EMBED, each with the deterministic
  # `<source>_<relation>_<depth>` aggregate alias PostgreSQL quotes back
  # (`Plan.hs:541`). Case 11139 issues the first; the rest are the siblings its
  # notes name.
  @phantom_spellings [
    {"/factories", "name,...processes(process_costs())",
     "column factories_processes_1.process_costs does not exist"},
    {"/factories", "name,...processes!inner(process_costs())",
     "column factories_processes_1.process_costs does not exist"},
    {"/factories", "factory:name,...processes(name,process_costs())",
     "column factories_processes_1.process_costs does not exist"},
    {"/factories", "name,...processes(process_costs!inner())",
     "column factories_processes_1.process_costs does not exist"},
    {"/factories", "name,...processes(...process_costs(processes()))",
     "column processes_process_costs_2.processes does not exist"},
    {"/processes", "name,...factories(factory_buildings())",
     "column processes_factories_1.factory_buildings does not exist"}
  ]

  describe "a to-many spread whose projection resolves to nothing (#154)" do
    test "contributes no keys and leaves the parent row count alone", %{base: base} do
      resp = get(base, "/factories", "name,...processes(...process_costs())")

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
      resp = get(base, "/processes", "name,...factories(...factory_buildings())")

      assert resp.status == 200

      # test.processes is eight rows (`spec/fixtures/02_base.sql:2053-2060`),
      # each with a to-one factory that merges no columns.
      assert length(resp.body) == 8
      assert Enum.map(resp.body, &Map.keys/1) == List.duplicate(["name"], 8)
    end
  end

  describe "filters on a spread that merges nothing (#154, bind accumulator)" do
    test "a filter on the dropped embed does not orphan its bind", %{base: base} do
      resp =
        get(base, "/factories", "name,...processes(...process_costs())", [
          {"processes.name", "eq.Process A1"}
        ])

      assert resp.status == 200
      assert length(resp.body) == 4
      assert Enum.map(resp.body, & &1["name"]) |> Enum.sort() == @factories
      assert Enum.map(resp.body, &Map.keys/1) == List.duplicate(["name"], 4)
    end

    test "a root filter alongside it still binds contiguously", %{base: base} do
      resp =
        get(base, "/factories", "name,...processes(...process_costs())", [
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
        get(base, "/factories", "name,...processes(...process_costs!inner())", [
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
      resp = get(base, "/factories", "name,...processes!inner(...process_costs())")

      assert resp.status == 200

      # Factory D has no processes, so the root's EXISTS drops it. Pre-fix this
      # returned 8 rows — the multiplication, minus D.
      assert Enum.map(resp.body, & &1["name"]) |> Enum.sort() ==
               ["Factory A", "Factory B", "Factory C"]
    end

    test "ordering by a spread that merges nothing falls back to a correlated term",
         %{base: base} do
      resp =
        get(base, "/processes", "name,...factories(...factory_buildings())", [
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
    test "a real column alongside an empty spread merges as normal", %{base: base} do
      resp =
        get(base, "/factories", "factory:name,...processes(name,...process_costs())", [
          {"processes.order", "name"}
        ])

      assert resp.status == 200
      assert length(resp.body) == 4

      # The short-circuit keys on the spread projecting nothing, NOT on it
      # containing an empty child: `name` is still merged, and a to-many spread
      # merges it as the aggregated array. `processes.order` pins the array
      # order the way case 11110 does.
      by_factory =
        Map.new(resp.body, fn row -> {row["factory"], row["name"]} end)

      assert by_factory["Factory A"] == ["Process A1", "Process A2"]
      assert by_factory["Factory B"] == ["Process B1", "Process B2"]
      assert by_factory["Factory D"] == []
    end
  end

  # Case 11139 issues exactly one of these. The rest are the spellings its
  # notes assert give "the same message with their own aliases" — the claim is
  # cheap to state upstream and worth holding down here, since each one is a
  # different path into `relSelectToSpread`.
  describe "a nested empty embed inside a spread is a 42703 (case 11139)" do
    for {path, select, message} <- @phantom_spellings do
      test "#{path}?select=#{select}", %{base: base} do
        resp = get(base, unquote(path), unquote(select))

        assert resp.status == 400

        assert resp.body == %{
                 "code" => "42703",
                 "details" => nil,
                 "hint" => nil,
                 "message" => unquote(message)
               }
      end
    end

    # The phantom is not swallowed by a filter that would otherwise prune the
    # subtree: the projection names the missing column whatever the WHERE says,
    # and the bind accumulator must still hand Postgrex a coherent statement —
    # a 42P18 here would surface as a bind mismatch, not as 42703.
    test "a filter on the empty embed does not mask it", %{base: base} do
      resp =
        get(base, "/factories", "name,...processes(process_costs())", [
          {"processes.name", "eq.Process A1"},
          {"name", "neq.Factory A"}
        ])

      assert resp.status == 400
      assert resp.body["code"] == "42703"
      assert resp.body["message"] == "column factories_processes_1.process_costs does not exist"
    end
  end

  test "no merging spelling leaks a raw SQLSTATE or a bind mismatch", %{base: base} do
    for select <- @merging_spellings, params <- [[], [{"processes.name", "eq.Process A1"}]] do
      resp = get(base, "/factories", select, params)

      assert resp.status == 200,
             "select=#{select} #{inspect(params)} returned #{resp.status}: #{inspect(resp.body)}"

      refute is_map(resp.body) and Map.has_key?(resp.body, "code"),
             "select=#{select} #{inspect(params)} errored: #{inspect(resp.body)}"
    end
  end
end
