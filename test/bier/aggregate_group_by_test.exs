defmodule Bier.AggregateGroupByTest do
  @moduledoc """
  The implicit `GROUP BY` must cover every column the select list actually
  projects, not just the ones spelled as plain fields (#145, from the #137
  review).

  `Bier.Embed.group_by/4` used to derive its terms from the select *nodes*,
  filtered to `%{kind: :field}`, while the columns themselves are produced by
  `build_row_select/7`. Two node kinds project columns without being `:field` —
  a `*` (which expands to the relation's whole column list) and a non-spread
  JSON embed (which projects a correlated subquery referencing the source-side
  join columns) — so pairing either with an aggregate emitted no `GROUP BY` for
  them and leaked a raw PostgreSQL `42803` to the client.

  The suite never caught it: no conformance case pairs an aggregate with `*` or
  with a plain embed. Contrary to the original report, a plain field alongside
  does NOT mask it — `id.sum(),clients(name),name` fails just as `*,id.sum()`
  does, because the missing terms are the embed's and the star's, not the
  field's.

  Not async: binds a real port and runs DB introspection at boot.
  """
  use ExUnit.Case, async: false

  alias Bier.TestPorts

  @moduletag :integration

  setup_all do
    port = TestPorts.free_port()
    name = :"agg_group_by_it_#{System.unique_integer([:positive])}"

    # Merged rather than prepended so `pool_size` overrides the shared opts'
    # 10 instead of duplicating the key: these are a handful of small reads,
    # and every extra instance's pool competes for the same `max_connections`.
    opts =
      Keyword.merge(Bier.ConformanceServer.base_opts(),
        name: name,
        router: [port: port, scheme: :http],
        db_aggregates_enabled: true,
        pool_size: 2
      )

    start_supervised!({Bier, opts})
    TestPorts.wait_until_listening(port)

    %{base: "http://localhost:#{port}"}
  end

  defp get(base, select) do
    Req.get!(base <> "/projects?select=" <> URI.encode(select), retry: false)
  end

  # `sum` per group, sorted so the assertion does not depend on physical order.
  defp sums(body), do: body |> Enum.map(& &1["sum"]) |> Enum.sort()

  describe "aggregate alongside a non-spread JSON embed (#145)" do
    test "groups by the source-side join column instead of leaking 42803", %{base: base} do
      resp = get(base, "id.sum(),clients(name)")

      assert resp.status == 200

      # projects.client_id has three distinct values (1, 2, NULL), so three
      # groups; the sums total the 15 that an ungrouped `id.sum()` returns.
      assert sums(resp.body) == [3, 5, 7]
      assert Enum.sum(sums(resp.body)) == 15

      names = resp.body |> Enum.map(&get_in(&1, ["clients", "name"])) |> Enum.sort()
      assert names == [nil, "Apple", "Microsoft"]
    end

    test "a plain field alongside does not change the grouping", %{base: base} do
      resp = get(base, "id.sum(),clients(name),name")

      assert resp.status == 200
      assert Enum.sum(sums(resp.body)) == 15
    end
  end

  describe "aggregate alongside `*` (#145)" do
    test "groups by every expanded column instead of leaking 42803", %{base: base} do
      resp = get(base, "*,id.sum()")

      assert resp.status == 200

      # Grouping by the full column list makes every row its own group, so each
      # row's sum is its own id and the star's columns are all still present.
      assert Enum.sum(sums(resp.body)) == 15

      for row <- resp.body do
        assert row["sum"] == row["id"]
        assert Map.has_key?(row, "name")
        assert Map.has_key?(row, "client_id")
      end
    end

    test "a plain field alongside `*` still groups", %{base: base} do
      resp = get(base, "*,id.sum(),name")

      assert resp.status == 200
      assert Enum.sum(sums(resp.body)) == 15
    end
  end

  describe "the other relationship shapes an embed can take (#145)" do
    test "many-to-many, whose subquery correlates through the junction", %{base: base} do
      resp =
        Req.get!(base <> "/users?select=" <> URI.encode("id.sum(),tasks(name)"), retry: false)

      assert resp.status == 200
      assert Enum.all?(resp.body, &is_list(&1["tasks"]))
    end

    test "a computed relationship groups by the whole source row", %{base: base} do
      # The subquery passes the source row itself to the function
      # (`test.computed_designers(videogames)`), so the grouping term is the row,
      # not a column: pre-fix this failed with `ungrouped column "videogames.*"`.
      resp =
        Req.get!(base <> "/videogames?select=" <> URI.encode("id.sum(),computed_designers(name)"),
          retry: false
        )

      assert resp.status == 200
      assert Enum.all?(resp.body, &Map.has_key?(&1, "computed_designers"))
    end
  end

  describe "shapes that already worked stay unchanged" do
    test "aggregate with a plain field", %{base: base} do
      resp = get(base, "id.sum(),name")

      assert resp.status == 200
      assert Enum.sum(sums(resp.body)) == 15
      assert length(resp.body) == 5
    end

    test "aggregate alone collapses to a single ungrouped row", %{base: base} do
      resp = get(base, "id.sum()")

      assert resp.status == 200
      assert resp.body == [%{"sum" => 15}]
    end
  end

  test "no aggregate shape leaks a raw SQLSTATE to the client", %{base: base} do
    for select <- [
          "id.sum(),clients(name)",
          "*,id.sum()",
          "*,id.sum(),name",
          "id.sum(),clients(name),name",
          "id.sum(),name",
          "id.sum()"
        ] do
      resp = get(base, select)

      refute match?(%{"code" => "42803"}, resp.body),
             "select=#{select} leaked a raw 42803: #{inspect(resp.body)}"

      assert resp.status == 200, "select=#{select} returned #{resp.status}"
    end
  end
end
