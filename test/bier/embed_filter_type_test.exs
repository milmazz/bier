defmodule Bier.EmbedFilterTypeTest do
  # Regression test for #72: a filter on an embedded resource's non-text
  # column (e.g. `tasks.id=gte.5` embedded under `projects`) must bind the
  # value through the embedded relation's real column type, not fall back to
  # `:text` because the type lookup ran against the wrong (parent) relation.
  use ExUnit.Case, async: false

  setup_all do
    opts = Bier.ConformanceServer.base_opts()
    conn_opts = Keyword.take(opts, [:hostname, :port, :database, :username, :password])
    {:ok, conn} = Postgrex.start_link(conn_opts)
    rels = Bier.Introspection.run(conn, ["test"])
    %{conn: conn, projects: rels[{"test", "projects"}], rels: rels}
  end

  test "filtering an embedded integer column executes and returns the right rows", %{
    conn: conn,
    projects: projects,
    rels: rels
  } do
    # `project_id` exists on `test.tasks` but NOT on `test.projects` (the outer
    # relation) — this is what exposes #72: a coltype lookup against the wrong
    # (parent) relation silently falls back to `:text` instead of erroring
    # (unlike `tasks.id`, which coincidentally also exists, same type, on
    # `test.projects` and would mask the bug).
    {:ok, plan} =
      Bier.QueryParser.parse_request(
        "select=id,name,tasks(id,project_id)&tasks.project_id=gte.3&order=id.asc"
      )

    assert {:ok, sql, params} = Bier.QueryExecutor.build(projects, plan, rels)

    %Postgrex.Result{rows: [[body, _count]]} = Postgrex.query!(conn, sql, params)

    bodies = Bier.json_library().decode!(body)

    for %{"tasks" => tasks} <- bodies do
      assert Enum.all?(tasks, &(&1["project_id"] >= 3))
    end

    assert Enum.any?(bodies, fn %{"tasks" => tasks} -> tasks != [] end)
  end
end
