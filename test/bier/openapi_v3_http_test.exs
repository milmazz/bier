defmodule Bier.OpenAPIV3HttpTest do
  @moduledoc """
  Boots a dedicated instance with openapi_version: "3.0" against the
  bier_test fixture database and asserts the root serves an OpenAPI 3.0.3
  document (#53 item 3 follow-up: wiring Bier.OpenAPI.V3.convert/1 into the
  root endpoint). Everything else about the root endpoint (negotiation, HEAD,
  openapi-mode, db-root-spec precedence) is unchanged and covered elsewhere.
  """
  use ExUnit.Case, async: false

  alias Bier.TestPorts

  @moduletag :integration

  setup_all do
    port = TestPorts.free_port()
    name = :"openapi_v3_http_#{System.unique_integer([:positive])}"

    opts =
      Bier.ConformanceServer.base_opts()
      |> Keyword.merge(
        name: name,
        router: [port: port, scheme: :http],
        db_schemas: ["test"],
        openapi_version: "3.0"
      )

    {:ok, pid} = Bier.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: Supervisor.stop(pid) end)
    TestPorts.wait_until_listening(port)
    %{url: "http://localhost:#{port}/"}
  end

  test "GET / serves an OpenAPI 3.0.3 document", %{url: url} do
    resp = Req.get!(url, headers: [{"accept", "application/json"}], retry: false)

    assert resp.status == 200
    assert resp.body["openapi"] == "3.0.3"
    refute Map.has_key?(resp.body, "swagger")
    assert map_size(resp.body["components"]["schemas"]) > 0
    assert resp.body["servers"] == [%{"url" => "/"}]
  end

  test "content negotiation is unchanged: csv at root is still 406", %{url: url} do
    resp = Req.get!(url, headers: [{"accept", "text/csv"}], retry: false)
    assert resp.status == 406
  end
end
