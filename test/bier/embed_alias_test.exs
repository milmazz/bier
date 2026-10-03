defmodule Bier.EmbedAliasTest do
  # An embed's FROM alias is PostgREST's `fromAlias`: `<foreign table>_<depth>`,
  # and no alias at all for a many-to-many embed (#162, cases 1531-1534).
  use ExUnit.Case, async: false

  setup_all do
    opts = Bier.ConformanceServer.base_opts()
    conn_opts = Keyword.take(opts, [:hostname, :port, :database, :username, :password])
    {:ok, conn} = Postgrex.start_link(conn_opts)
    %{rels: Bier.Introspection.run(conn, ["test"])}
  end

  defp build(rels, table, query) do
    {:ok, plan} = Bier.QueryParser.parse_request(query)
    Bier.QueryExecutor.build(rels[{"test", table}], plan, rels)
  end

  test "the alias is the embedded table and its depth, not a sibling counter", %{rels: rels} do
    {:ok, sql, _params} = build(rels, "processes", "select=id,supervisors(id),factories(id)")
    assert sql =~ ~s("factories_1")
    refute sql =~ ~s("factories_2")

    {:ok, sql, _params} = build(rels, "factories", "select=id,processes(process_costs(cost))")
    assert sql =~ ~s("processes_1")
    assert sql =~ ~s("process_costs_2")
  end

  test "a many-to-many embed reads its bare table", %{rels: rels} do
    {:ok, sql, _params} = build(rels, "processes", "select=id,supervisors(id)")
    assert sql =~ ~s("supervisors"."id")
    refute sql =~ ~s("supervisors_1")
  end
end
