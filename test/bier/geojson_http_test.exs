defmodule Bier.GeojsonHttpTest do
  @moduledoc """
  End-to-end geo+json negotiation on mutations and RPC (#63), against a
  dedicated instance exposing the geotest schema. base_opts carries
  db_tx_end: :rollback, so mutations never persist — no cleanup needed.
  """
  use ExUnit.Case, async: false

  alias Bier.TestPorts

  @moduletag :integration

  setup_all do
    port = TestPorts.free_port()
    name = :"geojson_http_#{System.unique_integer([:positive])}"

    opts =
      Bier.ConformanceServer.base_opts()
      |> Keyword.merge(
        name: name,
        router: [port: port, scheme: :http],
        db_schemas: ["geotest"]
      )

    {:ok, pid} = Bier.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: Supervisor.stop(pid) end)
    TestPorts.wait_until_listening(port)
    %{base: "http://localhost:#{port}"}
  end

  defp request!(base, method, path, headers, body \\ nil) do
    Req.request!(
      method: method,
      url: base <> path,
      headers: headers,
      body: body,
      retry: false,
      decode_body: false
    )
  end

  defp decode!(body), do: Bier.json_library().decode!(body)

  test "POST return=representation renders a FeatureCollection", %{base: base} do
    resp =
      request!(
        base,
        :post,
        "/shops",
        [
          {"accept", "application/geo+json"},
          {"content-type", "application/json"},
          {"prefer", "return=representation"}
        ],
        ~s|{"id": 4, "address": "New Shop", "shop_geom": "SRID=4326;POINT(-71.0 42.0)"}|
      )

    assert resp.status == 201
    assert ["application/geo+json; charset=utf-8"] = resp.headers["content-type"]

    decoded = decode!(resp.body)
    assert decoded["type"] == "FeatureCollection"

    assert [
             %{
               "type" => "Feature",
               "geometry" => %{"type" => "Point"},
               "properties" => %{"id" => 4, "address" => "New Shop"}
             }
           ] = decoded["features"]
  end

  test "DELETE return=representation renders the deleted Feature", %{base: base} do
    resp =
      request!(base, :delete, "/shops?id=eq.3", [
        {"accept", "application/geo+json"},
        {"prefer", "return=representation"}
      ])

    assert resp.status == 200
    decoded = decode!(resp.body)
    assert [%{"properties" => %{"id" => 3}}] = decoded["features"]
  end

  test "mutation on a geometry-less table fails 400/22023", %{base: base} do
    resp =
      request!(
        base,
        :post,
        "/plain",
        [
          {"accept", "application/geo+json"},
          {"content-type", "application/json"},
          {"prefer", "return=representation"}
        ],
        ~s({"id": 2, "label": "x"})
      )

    assert resp.status == 400
    assert %{"code" => "22023", "message" => "geometry column is missing"} = decode!(resp.body)
  end

  test "empty-payload POST renders an empty FeatureCollection", %{base: base} do
    resp =
      request!(
        base,
        :post,
        "/shops",
        [
          {"accept", "application/geo+json"},
          {"content-type", "application/json"},
          {"prefer", "return=representation"}
        ],
        "[]"
      )

    assert resp.status == 201
    # Exact bytes: PostgREST's geo+json wrapper is SQL json_build_object output,
    # which is spaced — the empty-set short-circuit must match those bytes.
    # (Live-verified against PostgREST 14.12 in the diff task.)
    assert resp.body == ~s({"type" : "FeatureCollection", "features" : []})
  end

  test "RPC returning SETOF <relation> renders a FeatureCollection", %{base: base} do
    resp = request!(base, :get, "/rpc/get_shops", [{"accept", "application/geo+json"}])

    assert resp.status == 200
    assert ["application/geo+json; charset=utf-8"] = resp.headers["content-type"]

    decoded = decode!(resp.body)
    assert decoded["type"] == "FeatureCollection"
    assert length(decoded["features"]) == 3
    assert %{"geometry" => %{"type" => "Point"}} = hd(decoded["features"])
  end

  test "RPC setof-relation with embeds renders embeds in properties", %{base: base} do
    resp =
      request!(
        base,
        :get,
        "/rpc/get_shops?select=id,address,shop_geom,shop_bles(name)&shop_bles.order=id",
        [{"accept", "application/geo+json"}]
      )

    assert resp.status == 200
    decoded = decode!(resp.body)

    assert %{"properties" => %{"id" => 1, "shop_bles" => [_, _]}} = hd(decoded["features"])
  end

  test "scalar-geometry RPC renders a single-Feature collection", %{base: base} do
    resp = request!(base, :get, "/rpc/get_shop_geom?id=1", [{"accept", "application/geo+json"}])

    assert resp.status == 200
    decoded = decode!(resp.body)
    assert decoded["type"] == "FeatureCollection"
    assert [%{"type" => "Feature", "geometry" => %{"type" => "Point"}}] = decoded["features"]
  end
end
