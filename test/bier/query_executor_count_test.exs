defmodule Bier.QueryExecutorCountTest do
  # The full-set window count (`count(*) OVER()`) must be emitted only when the
  # `Prefer: count=` mode consumes it (:exact/:estimated). For :none (the
  # default) and :planned it forces Postgres to materialize the whole filtered
  # set through a WindowAgg before LIMIT applies, defeating top-N plans.
  use ExUnit.Case, async: false

  setup_all do
    opts = Bier.ConformanceServer.base_opts()
    conn_opts = Keyword.take(opts, [:hostname, :port, :database, :username, :password])
    {:ok, conn} = Postgrex.start_link(conn_opts)
    rels = Bier.Introspection.run(conn, ["test"])
    %{conn: conn, rels: rels, projects: rels[{"test", "projects"}]}
  end

  test "count=none omits the window count", %{projects: projects, rels: rels} do
    {:ok, plan} = Bier.QueryParser.parse_request("id=gt.0&limit=2")

    assert {:ok, sql, _params} = Bier.QueryExecutor.build(projects, plan, rels, :json, :none)
    refute sql =~ "OVER()"
    assert sql =~ "count(*) AS full_count"
  end

  test "count=planned omits the window count", %{projects: projects, rels: rels} do
    {:ok, plan} = Bier.QueryParser.parse_request("id=gt.0&limit=2")

    assert {:ok, sql, _params} = Bier.QueryExecutor.build(projects, plan, rels, :json, :planned)
    refute sql =~ "OVER()"
  end

  test "count=exact and count=estimated keep the window count", %{projects: projects, rels: rels} do
    {:ok, plan} = Bier.QueryParser.parse_request("id=gt.0&limit=2")

    for mode <- [:exact, :estimated] do
      assert {:ok, sql, _params} = Bier.QueryExecutor.build(projects, plan, rels, :json, mode)
      assert sql =~ "count(*) OVER() AS _bier_full_count"
      assert sql =~ "coalesce(max(_postgrest_t._bier_full_count), 0) AS full_count"
    end
  end

  test "build/4 default (count=none) omits the window count", %{projects: projects, rels: rels} do
    {:ok, plan} = Bier.QueryParser.parse_request("")

    assert {:ok, sql, _params} = Bier.QueryExecutor.build(projects, plan, rels)
    refute sql =~ "OVER()"
  end

  test "the advanced (embed) path honors the count mode", %{projects: projects, rels: rels} do
    {:ok, plan} = Bier.QueryParser.parse_request("select=id,clients(id)&limit=2")

    assert {:ok, none_sql, _} = Bier.QueryExecutor.build(projects, plan, rels, :json, :none)
    refute none_sql =~ "OVER()"

    assert {:ok, exact_sql, _} = Bier.QueryExecutor.build(projects, plan, rels, :json, :exact)
    assert exact_sql =~ "count(*) OVER() AS _bier_full_count"
  end

  test "no-window query executes and returns the same body", %{
    conn: conn,
    projects: projects,
    rels: rels
  } do
    {:ok, plan} = Bier.QueryParser.parse_request("id=gt.0&order=id.asc&limit=2")

    {:ok, none_sql, none_params} = Bier.QueryExecutor.build(projects, plan, rels, :json, :none)
    {:ok, exact_sql, exact_params} = Bier.QueryExecutor.build(projects, plan, rels, :json, :exact)

    %Postgrex.Result{rows: [[none_body, page_count]]} =
      Postgrex.query!(conn, none_sql, none_params)

    %Postgrex.Result{rows: [[exact_body, full_count]]} =
      Postgrex.query!(conn, exact_sql, exact_params)

    assert none_body == exact_body
    assert page_count == 2
    assert full_count >= page_count
  end

  test "RPC build honors the count mode", %{projects: projects, rels: rels} do
    {:ok, plan} = Bier.QueryParser.parse_request("limit=5")
    fn_def = %{schema: "test", name: "getallprojects"}

    assert {:ok, none_sql, _} =
             Bier.QueryExecutor.build_function(fn_def, projects, [], plan, rels, :none)

    refute none_sql =~ "OVER()"

    assert {:ok, exact_sql, _} =
             Bier.QueryExecutor.build_function(fn_def, projects, [], plan, rels, :exact)

    assert exact_sql =~ "count(*) OVER() AS _bier_full_count"
  end

  test "mutation representation never carries a window count", %{projects: projects, rels: rels} do
    {:ok, plan} = Bier.QueryParser.parse_request("select=id,name")
    source = {"INSERT INTO \"test\".\"projects\" (\"name\") VALUES ($1) RETURNING *", ["x"]}

    assert {:ok, sql, _params} =
             Bier.QueryExecutor.build_representation(projects, plan, rels, source)

    refute sql =~ "OVER()"
    assert sql =~ "(SELECT count(*) FROM pgrst_source) AS count"
  end
end
