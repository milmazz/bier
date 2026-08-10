defmodule Bier.CsvFidelityTest do
  @moduledoc """
  Two defects in the CSV renderer (#110), sharing the decode/re-encode root
  cause with #109:

    1. **Column order.** With no explicit ordered column list, CSV fell back to
       `Map.keys/1` of a decoded row — sorted, not `SELECT` order. Relation
       reads pass an explicit list and were fine; a routine that is not backed
       by an exposed relation (an anonymous `TABLE(...)` return, or `OUT`
       params) passes none, so its CSV header was alphabetized while the JSON
       body of the very same call was in declaration order.
    2. **Numeric text.** Every cell was re-rendered from a decoded float, so
       `5.00` became `5.0` and `45.512230` became `45.51223`. This one hit
       relation reads too.

  Both are fixed the way #109 fixed the JSON bodies: PostgreSQL renders the
  cells. The CSV body is aggregated as an ordered `[key, value]` pair list per
  row (`json_each_text(to_json(row))`), so column order comes from the row type
  and every value arrives as the exact text PostgreSQL emitted. The RFC-4180
  quoting stays in `Bier.Render` — that is Bier's own writer, deliberately not
  PostgreSQL's `record_out` escaping (which backslash-escapes and does not
  quote embedded newlines).

  No frozen case exercises CSV for a relation-less RPC, and none puts a
  `numeric` column in a CSV body; `spec/content_negotiation.yaml` models the
  header row, the absent trailing newline and the `Content-Type` only. The
  schema here is created and dropped by the test — `spec/**` is untouched.
  """
  use ExUnit.Case, async: false

  alias Bier.TestPorts

  @moduletag :integration

  @schema "bier_csv_fx"

  setup_all do
    opts = Bier.ConformanceServer.base_opts()
    conn_opts = Keyword.take(opts, [:hostname, :port, :database, :username, :password])
    {:ok, conn} = Postgrex.start_link(conn_opts)

    drop = ["DROP SCHEMA IF EXISTS #{@schema} CASCADE"]

    create = [
      "CREATE SCHEMA #{@schema}",
      """
      CREATE TABLE #{@schema}.readings (
        id int PRIMARY KEY,
        label text,
        amount numeric(10,2),
        note text
      )
      """,
      """
      INSERT INTO #{@schema}.readings VALUES
        (1, 'first', 5.00, NULL),
        (2, 'has, comma', 4.67, 'kept')
      """,
      # A routine with an anonymous TABLE(...) return: no exposed relation backs
      # it, so nothing supplies an ordered column list. Declared order is
      # deliberately NOT alphabetical.
      """
      CREATE FUNCTION #{@schema}.top_rated()
        RETURNS TABLE(beer_id int, name text, avg_rating numeric, check_in_count bigint)
        LANGUAGE sql STABLE AS $fn$
          SELECT 4, 'Export Stout', 5.00::numeric, 1::bigint
          UNION ALL
          SELECT 1, 'Trail Crest IPA', 4.67::numeric, 3::bigint
          ORDER BY 3 DESC
        $fn$
      """
    ]

    exec = fn c, stmts -> Enum.each(stmts, &Postgrex.query!(c, &1, [])) end
    exec.(conn, drop)
    exec.(conn, create)

    port = TestPorts.free_port()
    name = :"csv_fx_#{System.unique_integer([:positive])}"

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

  describe "relation-less RPC (anonymous TABLE return)" do
    test "the CSV header follows the declared column order", %{base: base} do
      resp = get!(base, "/rpc/top_rated", "text/csv")

      assert resp.status == 200

      assert resp.body ==
               "beer_id,name,avg_rating,check_in_count\n" <>
                 "4,Export Stout,5.00,1\n" <>
                 "1,Trail Crest IPA,4.67,3"
    end

    test "the JSON body of the same call agrees with it", %{base: base} do
      resp = get!(base, "/rpc/top_rated", "application/json")

      assert resp.status == 200
      assert resp.body =~ ~s({"beer_id":4,"name":"Export Stout","avg_rating":5.00,)
    end
  end

  describe "relation read" do
    test "numeric cells keep their exact text", %{base: base} do
      resp = get!(base, "/readings?id=eq.1&select=label,amount", "text/csv")

      assert resp.status == 200
      assert resp.body == "label,amount\nfirst,5.00"
    end

    test "the explicit select order is still honored", %{base: base} do
      resp = get!(base, "/readings?id=eq.1&select=amount,id,label", "text/csv")

      assert resp.status == 200
      assert resp.body == "amount,id,label\n5.00,1,first"
    end

    test "RFC-4180 quoting and null cells are unchanged", %{base: base} do
      resp = get!(base, "/readings?order=id.asc&select=label,note", "text/csv")

      assert resp.status == 200
      assert resp.body == "label,note\nfirst,\n\"has, comma\",kept"
    end

    test "Content-Length matches the body", %{base: base} do
      resp = get!(base, "/readings?id=eq.1&select=label,amount", "text/csv")

      assert resp.headers["content-length"] == [Integer.to_string(byte_size(resp.body))]
    end
  end
end
