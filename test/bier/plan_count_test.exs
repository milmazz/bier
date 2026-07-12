defmodule Bier.PlanCountTest do
  # The application/vnd.pgrst.plan media type (Bier.Plan.explain/5) must EXPLAIN
  # the exact query shape the real request would run. A `Prefer: count=exact`
  # (or count=estimated) request runs the full-set window count
  # (`count(*) OVER()`), so the plan for that same request must show it too —
  # otherwise the plan understates the query's cost. An EXPLAIN (FORMAT TEXT)
  # of a query containing `count(*) OVER()` always reports a `WindowAgg` node,
  # so its presence/absence in the plan text is a reliable proxy.
  use ExUnit.Case, async: true

  setup do
    %{base: Bier.ConformanceServer.base_url()}
  end

  test "plan reflects Prefer: count=exact with a WindowAgg node", %{base: base} do
    resp =
      Req.get!(base <> "/projects?limit=1",
        headers: [{"accept", "application/vnd.pgrst.plan+text"}, {"prefer", "count=exact"}],
        retry: false
      )

    assert resp.status == 200
    assert resp.body =~ "WindowAgg"
  end

  test "plan without a count preference omits the WindowAgg node", %{base: base} do
    resp =
      Req.get!(base <> "/projects?limit=1",
        headers: [{"accept", "application/vnd.pgrst.plan+text"}],
        retry: false
      )

    assert resp.status == 200
    refute resp.body =~ "WindowAgg"
  end
end
