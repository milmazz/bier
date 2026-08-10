defmodule Bier.RenderFidelityTest do
  @moduledoc """
  `Bier.Render` used to decode the executor's JSON body into Elixir terms and
  re-encode it for the singular and nulls-stripped media types (#109). Two
  things did not survive that round trip:

    * **key order** — Elixir maps are unordered, so keys came back sorted
      instead of in `SELECT` order;
    * **numeric text** — `numeric` arrives as exact decimal text from
      PostgreSQL, was decoded to a float and re-rendered shortest-round-trip,
      so `45.512230` became `45.51223`.

  Both are wire-visible and both contradict the byte-fidelity property the
  project holds itself to; `Content-Length` differed between two
  representations of the same row for no reason other than the re-encode.
  Upstream builds these bodies in SQL — `json_agg(_postgrest_t)->0` and
  `json_strip_nulls(...)` (`Query/SqlFragment.hs`: `asJsonSingleF`, `asJsonF`,
  `addNullsToSnip`) — and therefore preserves both.

  No frozen case pins either property for these media types (the singular cases
  select a single column, and `spec/content_negotiation.yaml` models plurality,
  `Content-Type` and the `nulls=stripped` semantics but says nothing about key
  order or numeric text), so this is the Bier-side regression test. The schema
  is created and dropped by the test — `spec/**` is untouched.

  The table mirrors the issue's reproduction: a column order that differs from
  alphabetical order, `numeric(9,6)` values with significant trailing zeros, and
  a null column for the stripping cases.
  """
  use ExUnit.Case, async: false

  alias Bier.TestPorts

  @moduletag :integration

  @schema "bier_render_fx"

  # Exactly what PostgreSQL renders for row 1 through `json_agg`: definition key
  # order, numeric trailing zeros intact.
  @row ~s({"id":1,"name":"Reunion Brewing","city":"Portland","latitude":45.512230,) <>
         ~s("longitude":-122.658722,"note":null})

  @row_stripped ~s({"id":1,"name":"Reunion Brewing","city":"Portland",) <>
                  ~s("latitude":45.512230,"longitude":-122.658722})

  setup_all do
    opts = Bier.ConformanceServer.base_opts()
    conn_opts = Keyword.take(opts, [:hostname, :port, :database, :username, :password])
    {:ok, conn} = Postgrex.start_link(conn_opts)

    drop = ["DROP SCHEMA IF EXISTS #{@schema} CASCADE"]

    create = [
      "CREATE SCHEMA #{@schema}",
      """
      CREATE TABLE #{@schema}.breweries (
        id int PRIMARY KEY,
        name text,
        city text,
        latitude numeric(9,6),
        longitude numeric(9,6),
        note text
      )
      """,
      """
      INSERT INTO #{@schema}.breweries VALUES
        (1, 'Reunion Brewing', 'Portland', 45.512230, -122.658722, NULL),
        (2, 'Ecliptic', 'Portland', 45.545000, -122.675000, 'second')
      """
    ]

    exec = fn c, stmts -> Enum.each(stmts, &Postgrex.query!(c, &1, [])) end
    exec.(conn, drop)
    exec.(conn, create)

    port = TestPorts.free_port()
    name = :"render_fx_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Bier.start_link(
        Keyword.merge(opts,
          name: name,
          router: [port: port, scheme: :http],
          db_schemas: [@schema],
          db_profile_default: nil,
          db_profile_schemas: nil
        )
      )

    on_exit(fn ->
      stop(pid)
      {:ok, c} = Postgrex.start_link(conn_opts)
      exec.(c, drop)
    end)

    TestPorts.wait_until_listening(port)
    %{base: "http://localhost:#{port}"}
  end

  defp stop(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp get!(base, path, accept) do
    Req.request!(
      method: :get,
      url: base <> path,
      headers: [{"accept", accept}],
      retry: false,
      decode_body: false
    )
  end

  describe "plain JSON (the baseline that was already correct)" do
    test "passes the executor's text through untouched", %{base: base} do
      resp = get!(base, "/breweries?id=eq.1", "application/json")

      assert resp.status == 200
      assert resp.body == "[" <> @row <> "]"
    end
  end

  describe "application/vnd.pgrst.object+json" do
    test "preserves key order and numeric text", %{base: base} do
      resp = get!(base, "/breweries?id=eq.1", "application/vnd.pgrst.object+json")

      assert resp.status == 200
      assert resp.body == @row
    end

    test "an explicit select keeps the requested column order", %{base: base} do
      resp =
        get!(base, "/breweries?id=eq.1&select=name,city,id", "application/vnd.pgrst.object+json")

      assert resp.status == 200
      assert resp.body == ~s({"name":"Reunion Brewing","city":"Portland","id":1})
    end

    test "Content-Length matches the body it now sends", %{base: base} do
      resp = get!(base, "/breweries?id=eq.1", "application/vnd.pgrst.object+json")

      assert resp.headers["content-length"] == [Integer.to_string(byte_size(resp.body))]
    end

    test "plurality is still enforced", %{base: base} do
      resp = get!(base, "/breweries", "application/vnd.pgrst.object+json")

      assert resp.status == 406
      assert %{"code" => "PGRST116"} = Bier.json_library().decode!(resp.body)
    end
  end

  describe "nulls=stripped" do
    test "drops the null key and preserves order and numeric text", %{base: base} do
      resp =
        get!(base, "/breweries?id=eq.1", "application/vnd.pgrst.array+json;nulls=stripped")

      assert resp.status == 200
      assert resp.body == "[" <> @row_stripped <> "]"
    end

    test "the singular stripped form does the same", %{base: base} do
      resp =
        get!(base, "/breweries?id=eq.1", "application/vnd.pgrst.object+json;nulls=stripped")

      assert resp.status == 200
      assert resp.body == @row_stripped
    end

    test "a non-null column is untouched", %{base: base} do
      resp =
        get!(base, "/breweries?id=eq.2", "application/vnd.pgrst.array+json;nulls=stripped")

      assert resp.status == 200
      assert resp.body =~ ~s("note":"second")
      assert resp.body =~ ~s("latitude":45.545000)
    end
  end
end
