defmodule Bier.Plugs.AdminRouterTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Bier.Plugs.AdminRouter

  defp call(method, path, name) do
    conn(method, path)
    |> AdminRouter.call(AdminRouter.init(name: name))
  end

  test "GET /live returns 200 regardless of readiness" do
    name = :"live_#{System.unique_integer([:positive])}"
    conn = call(:get, "/live", name)
    assert conn.status == 200
  end

  test "GET /ready returns 503 when the instance is not ready" do
    # No schema cache for this name -> Bier.Health.ready?/1 is false.
    name = :"notready_#{System.unique_integer([:positive])}"
    conn = call(:get, "/ready", name)
    assert conn.status == 503
  end

  test "unknown paths return 404" do
    name = :"unknown_#{System.unique_integer([:positive])}"
    assert call(:get, "/metrics", name).status == 404
    assert call(:post, "/live", name).status == 404
  end
end
