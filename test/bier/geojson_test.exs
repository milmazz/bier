defmodule Bier.GeojsonTest do
  # The geo+json producer (conformance cases 1616-1618): postgis detection and
  # the FeatureCollection aggregation built by the executor's :geojson format.
  use ExUnit.Case, async: false

  setup_all do
    opts = Bier.ConformanceServer.base_opts()
    conn_opts = Keyword.take(opts, [:hostname, :port, :database, :username, :password])
    {:ok, conn} = Postgrex.start_link(conn_opts)
    %{conn: conn}
  end

  test "postgis?/1 detects the installed extension", %{conn: conn} do
    assert Bier.Introspection.postgis?(conn)
  end

  test "build/4 with format: :geojson aggregates a FeatureCollection", %{conn: conn} do
    rels = Bier.Introspection.run(conn, ["test"])
    shops = rels[{"test", "shops"}]
    {:ok, plan} = Bier.QueryParser.parse_request("")

    assert {:ok, sql, params} = Bier.QueryExecutor.build(shops, plan, rels, :geojson)
    assert sql =~ "ST_AsGeoJSON"

    %Postgrex.Result{rows: [[body, count]]} = Postgrex.query!(conn, sql, params)
    assert count == 3

    decoded = Bier.json_library().decode!(body)
    assert decoded["type"] == "FeatureCollection"

    assert [%{"type" => "Feature", "geometry" => %{"type" => "Point"}, "properties" => props} | _] =
             decoded["features"]

    assert props == %{"id" => 1, "address" => "1369 Cambridge St"}
  end

  test "build/4 with format: :geojson on a geometry-less relation raises 22023", %{conn: conn} do
    rels = Bier.Introspection.run(conn, ["test"])
    projects = rels[{"test", "projects"}]
    {:ok, plan} = Bier.QueryParser.parse_request("")

    assert {:ok, sql, params} = Bier.QueryExecutor.build(projects, plan, rels, :geojson)

    assert {:error, %Postgrex.Error{postgres: %{pg_code: "22023", message: message}}} =
             Postgrex.query(conn, sql, params)

    assert message == "geometry column is missing"
  end

  test "advanced path: embeds land in Feature properties", %{conn: conn} do
    rels = Bier.Introspection.run(conn, ["geotest"])
    shops = rels[{"geotest", "shops"}]

    {:ok, plan} =
      Bier.QueryParser.parse_request(
        "select=id,address,shop_geom,shop_bles(name)&order=id&shop_bles.order=id"
      )

    assert {:ok, sql, params} = Bier.QueryExecutor.build(shops, plan, rels, :geojson)
    %Postgrex.Result{rows: [[body, count]]} = Postgrex.query!(conn, sql, params)
    assert count == 3

    decoded = Bier.json_library().decode!(body)
    assert decoded["type"] == "FeatureCollection"

    [f1 | _] = decoded["features"]
    assert f1["type"] == "Feature"
    assert f1["geometry"]["type"] == "Point"

    assert f1["properties"] == %{
             "id" => 1,
             "address" => "1369 Cambridge St",
             "shop_bles" => [%{"name" => "battery"}, %{"name" => "car-key"}]
           }
  end

  test "advanced path without a geometry column still raises 22023", %{conn: conn} do
    rels = Bier.Introspection.run(conn, ["geotest"])
    shops = rels[{"geotest", "shops"}]
    # id + embed only: the projected record carries no geometry column.
    {:ok, plan} = Bier.QueryParser.parse_request("select=id,shop_bles(name)")

    assert {:ok, sql, params} = Bier.QueryExecutor.build(shops, plan, rels, :geojson)

    assert {:error, %Postgrex.Error{postgres: %{pg_code: "22023", message: message}}} =
             Postgrex.query(conn, sql, params)

    assert message == "geometry column is missing"
  end
end
