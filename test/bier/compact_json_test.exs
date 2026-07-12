defmodule Bier.CompactJsonTest do
  # Issue #31: the read paths must render PostgREST v14.12's exact wire bytes,
  # live-captured from the real binary (see the spec's §0 whitespace profile):
  # compact row objects separated by `, \n ` (json_agg over a record), embed
  # internals in jsonb style (`": "`, `", "`, keys jsonb-normalized), spread
  # columns compact at the parent level. json_build_object's `"k" : v` and a
  # bare ::jsonb cast both diverge, hence exact-string assertions.
  use ExUnit.Case, async: false

  setup_all do
    opts = Bier.ConformanceServer.base_opts()
    conn_opts = Keyword.take(opts, [:hostname, :port, :database, :username, :password])
    {:ok, conn} = Postgrex.start_link(conn_opts)
    rels = Bier.Introspection.run(conn, ["test"])
    %{conn: conn, rels: rels}
  end

  defp body!(conn, rels, relation, query) do
    {:ok, plan} = Bier.QueryParser.parse_request(query)
    {:ok, sql, params} = Bier.QueryExecutor.build(rels[{"test", relation}], plan, rels)
    %Postgrex.Result{rows: [[body, _count]]} = Postgrex.query!(conn, sql, params)
    body
  end

  test "flat rows separate with comma-newline (simple path)", %{conn: conn, rels: rels} do
    body = body!(conn, rels, "projects", "select=id,name&order=id&limit=2")
    assert body == ~s([{"id":1,"name":"Windows 7"}, \n {"id":2,"name":"Windows 10"}])
  end

  test "to-one embed renders jsonb-style internals", %{conn: conn, rels: rels} do
    body = body!(conn, rels, "projects", "select=id,name,clients(name)&order=id&limit=2")

    assert body ==
             ~s([{"id":1,"name":"Windows 7","clients":{"name": "Microsoft"}}, \n ) <>
               ~s({"id":2,"name":"Windows 10","clients":{"name": "Microsoft"}}])
  end

  test "embed keys are jsonb-normalized (order + spacing)", %{conn: conn, rels: rels} do
    # Select order is name,id — jsonb re-sorts to id,name, exactly as PostgREST.
    body = body!(conn, rels, "projects", "select=id,clients(name,id)&order=id&limit=1")
    assert body == ~s([{"id":1,"clients":{"id": 1, "name": "Microsoft"}}])
  end

  test "to-many embed renders jsonb elements with comma-space", %{conn: conn, rels: rels} do
    body =
      body!(conn, rels, "projects", "select=name,tasks(name)&order=id&limit=1&tasks.order=id")

    assert body ==
             ~s([{"name":"Windows 7","tasks":[{"name": "Design w7"}, {"name": "Code w7"}]}])
  end

  test "empty to-many embed renders []", %{conn: conn, rels: rels} do
    body = body!(conn, rels, "projects", "select=id,tasks(name)&id=eq.5")
    assert body == ~s([{"id":5,"tasks":[]}])
  end

  test "missing to-one embed renders null", %{conn: conn, rels: rels} do
    body = body!(conn, rels, "projects", "select=id,clients(name)&id=eq.5")
    assert body == ~s([{"id":5,"clients":null}])
  end

  test "aggregate with implicit group-by renders compact rows", %{conn: conn, rels: rels} do
    body = body!(conn, rels, "projects", "select=client_id,id.count()&order=client_id")

    assert body ==
             ~s([{"client_id":1,"count":2}, \n {"client_id":2,"count":2}, \n ) <>
               ~s({"client_id":null,"count":1}])
  end

  test "to-one spread renders compact parent-level columns", %{conn: conn, rels: rels} do
    body =
      body!(conn, rels, "projects", "select=id,...clients(client_name:name)&order=id&limit=1")

    assert body == ~s([{"id":1,"client_name":"Microsoft"}])
  end

  test "to-one spread of a missing row renders null columns", %{conn: conn, rels: rels} do
    body = body!(conn, rels, "projects", "select=id,...clients(client_name:name)&id=eq.5")
    assert body == ~s([{"id":5,"client_name":null}])
  end

  test "to-many spread aggregates each column into an array", %{conn: conn, rels: rels} do
    body =
      body!(
        conn,
        rels,
        "projects",
        "select=id,...tasks(task_names:name)&order=id&limit=1&tasks.order=id"
      )

    assert body == ~s([{"id":1,"task_names":["Design w7", "Code w7"]}])
  end
end
