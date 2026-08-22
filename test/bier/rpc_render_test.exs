defmodule Bier.RpcRenderTest do
  @moduledoc """
  `Bier.Rpc` used to send a scalar/composite routine's JSON body verbatim under
  whatever media type was negotiated, never calling `Bier.Render` (#119). Only
  the set-returning clause routed through it, so:

    1. **CSV.** `Accept: text/csv` on a scalar or composite RPC returned the JSON
       body labelled `text/csv`. Upstream renders CSV in SQL for *every* routine
       shape — `handlerF` picks `asCsvF`, which wraps whatever `_postgrest_t`
       the call produced (`Query/Statements.hs` `mainCall`) — so a scalar comes
       back as a one-column CSV. The column has no name of its own, so the
       header is the alias the call query gave it: `pgrst_scalar`
       (`QueryBuilder.hs` `callPlanToQuery`). Verified against PostgreSQL by
       running upstream's own `asCsvF` over the fixture DB.
    2. **`nulls=stripped`.** `asJsonF`/`asJsonSingleF` apply `addNullsToSnip` to
       the `returnsScalar` and `returnsSingleComposite` branches too, so the
       strip was silently dropped for these return kinds.

  Fixing (2) means building the body with upstream's own expression,
  `json_agg(_postgrest_t)->0`, instead of `to_jsonb(t)`. That also settles two
  things the old expression got wrong on its own:

    * `to_jsonb` renders through `jsonb`, which **sorts object keys and pads
      them with spaces** — a `json`-returning routine came back as
      `{"a": null, "b": 1}` where upstream (and PostgreSQL's `json`) says
      `{"b":1,"a":null}`. Same wire-byte concern as #109/#110.
    * `to_jsonb` is strict, so a routine returning SQL NULL produced a `nil`
      body and blew up in `byte_size/1`. `json_agg(…)->0` yields the JSON text
      `null`, which is what upstream sends.

  The frozen suite does not model any of this: no case pairs a scalar/composite
  RPC with `text/csv`, and the `content_negotiation` area doc (the submodule's
  `spec/spec/content_negotiation.yaml`) does not model the
  RPC return-kind split. The schema here is created and dropped by the test —
  `spec/**` is untouched.
  """
  use ExUnit.Case, async: false

  alias Bier.TestPorts

  @moduletag :integration

  @schema "bier_rpc_render_fx"

  setup_all do
    opts = Bier.ConformanceServer.base_opts()
    conn_opts = Keyword.take(opts, [:hostname, :port, :database, :username, :password])
    {:ok, conn} = Postgrex.start_link(conn_opts)

    drop = ["DROP SCHEMA IF EXISTS #{@schema} CASCADE"]

    create = [
      "CREATE SCHEMA #{@schema}",
      # Scalar text carrying a comma, so the CSV writer has to quote it.
      """
      CREATE FUNCTION #{@schema}.scalar_text() RETURNS text
        LANGUAGE sql STABLE AS $fn$ SELECT 'hello, world'::text $fn$
      """,
      # Scalar numeric: `5.00` must not become `5.0` in either body.
      """
      CREATE FUNCTION #{@schema}.scalar_numeric() RETURNS numeric
        LANGUAGE sql STABLE AS $fn$ SELECT 5.00::numeric $fn$
      """,
      # Scalar json with a null member and a deliberately non-alphabetical key
      # order.
      """
      CREATE FUNCTION #{@schema}.scalar_json() RETURNS json
        LANGUAGE sql STABLE AS $fn$ SELECT '{"b":1,"a":null,"c":"x"}'::json $fn$
      """,
      """
      CREATE FUNCTION #{@schema}.scalar_null() RETURNS text
        LANGUAGE sql STABLE AS $fn$ SELECT NULL::text $fn$
      """,
      # Composite: declared order is not alphabetical and one field is NULL.
      "CREATE TYPE #{@schema}.reading AS (id int, label text, amount numeric, note text)",
      """
      CREATE FUNCTION #{@schema}.one_reading() RETURNS #{@schema}.reading
        LANGUAGE sql STABLE AS $fn$
          SELECT ROW(1, 'first', 5.00::numeric, NULL)::#{@schema}.reading
        $fn$
      """,
      """
      CREATE FUNCTION #{@schema}.setof_ints() RETURNS SETOF int
        LANGUAGE sql STABLE AS $fn$ SELECT * FROM (VALUES (1), (2), (3)) v(i) $fn$
      """,
      # A SETOF <exposed relation> routine, which takes the read pipeline rather
      # than the flat-call path — the plan has to cover it too.
      "CREATE TABLE #{@schema}.readings (id int PRIMARY KEY, label text)",
      "INSERT INTO #{@schema}.readings VALUES (1, 'first'), (2, 'second')",
      """
      CREATE FUNCTION #{@schema}.all_readings() RETURNS SETOF #{@schema}.readings
        LANGUAGE sql STABLE AS $fn$ SELECT * FROM #{@schema}.readings $fn$
      """
    ]

    exec = fn c, stmts -> Enum.each(stmts, &Postgrex.query!(c, &1, [])) end
    exec.(conn, drop)
    exec.(conn, create)

    port = TestPorts.free_port()
    name = :"rpc_render_fx_#{System.unique_integer([:positive])}"

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

  describe "text/csv on a scalar routine" do
    test "renders a one-column CSV headed pgrst_scalar, not the JSON body", %{base: base} do
      resp = get!(base, "/rpc/scalar_text", "text/csv")

      assert resp.status == 200
      assert resp.headers["content-type"] == ["text/csv; charset=utf-8"]
      assert resp.body == "pgrst_scalar\n\"hello, world\""
    end

    test "numeric cells keep the text PostgreSQL emitted", %{base: base} do
      resp = get!(base, "/rpc/scalar_numeric", "text/csv")

      assert resp.status == 200
      assert resp.body == "pgrst_scalar\n5.00"
    end

    test "Content-Length matches the rendered body", %{base: base} do
      resp = get!(base, "/rpc/scalar_text", "text/csv")

      assert resp.headers["content-length"] == [Integer.to_string(byte_size(resp.body))]
    end

    test "the single-row Content-Range is unchanged", %{base: base} do
      resp = get!(base, "/rpc/scalar_text", "text/csv")

      assert resp.headers["content-range"] == ["0-0/*"]
    end
  end

  describe "text/csv on a composite routine" do
    test "renders the composite's fields in declared order", %{base: base} do
      resp = get!(base, "/rpc/one_reading", "text/csv")

      assert resp.status == 200
      assert resp.headers["content-type"] == ["text/csv; charset=utf-8"]
      assert resp.body == "id,label,amount,note\n1,first,5.00,"
    end
  end

  describe "text/csv on a set-of-scalar routine" do
    test "renders one CSV row per element", %{base: base} do
      resp = get!(base, "/rpc/setof_ints", "text/csv")

      assert resp.status == 200
      assert resp.body == "pgrst_scalar\n1\n2\n3"
    end
  end

  describe "nulls=stripped" do
    test "is applied to a scalar json result", %{base: base} do
      resp =
        get!(base, "/rpc/scalar_json", "application/vnd.pgrst.array+json;nulls=stripped")

      assert resp.status == 200
      assert resp.body == ~s({"b":1,"c":"x"})
    end

    test "is applied to a singular composite result", %{base: base} do
      resp =
        get!(base, "/rpc/one_reading", "application/vnd.pgrst.object+json;nulls=stripped")

      assert resp.status == 200
      assert resp.body == ~s({"id":1,"label":"first","amount":5.00})
    end
  end

  describe "the JSON bodies these share a clause with" do
    test "a json scalar keeps PostgreSQL's key order and spacing", %{base: base} do
      resp = get!(base, "/rpc/scalar_json", "application/json")

      assert resp.status == 200
      assert resp.body == ~s({"b":1,"a":null,"c":"x"})
    end

    test "a composite keeps its declared field order", %{base: base} do
      resp = get!(base, "/rpc/one_reading", "application/json")

      assert resp.status == 200
      assert resp.body == ~s({"id":1,"label":"first","amount":5.00,"note":null})
    end

    test "a routine returning SQL NULL answers 200 with a JSON null", %{base: base} do
      resp = get!(base, "/rpc/scalar_null", "application/json")

      assert resp.status == 200
      assert resp.body == "null"
    end

    test "a singular Accept on a scalar still returns the bare value", %{base: base} do
      resp = get!(base, "/rpc/scalar_numeric", "application/vnd.pgrst.object+json")

      assert resp.status == 200
      assert resp.body == "5.00"
    end
  end

  # `application/vnd.pgrst.plan` was the last media type an RPC never rendered:
  # `EXPLAIN` only ever ran on the relation path, so a call answered with its
  # ordinary body under the plan `Content-Type`. Upstream has no RPC-specific
  # plan code — `mtSnippet` wraps `mainCall`'s snippet in `explainF` exactly as
  # it wraps `mainRead`'s (`Query/Statements.hs`), so every return kind, the
  # SETOF-relation one included, is explained.
  describe "application/vnd.pgrst.plan on a call" do
    test "a scalar routine is explained, not executed", %{base: base} do
      resp = get!(base, "/rpc/scalar_text", "application/vnd.pgrst.plan+json")

      assert resp.status == 200

      assert resp.headers["content-type"] ==
               [~s(application/vnd.pgrst.plan+json; for="application/json"; charset=utf-8)]

      assert [%{"Plan" => %{"Node Type" => _}} | _] = JSON.decode!(resp.body)
    end

    test "a bare plan Accept defaults to the text format", %{base: base} do
      resp = get!(base, "/rpc/scalar_text", "application/vnd.pgrst.plan")

      assert resp.status == 200

      assert resp.headers["content-type"] ==
               [~s(application/vnd.pgrst.plan+text; for="application/json"; charset=utf-8)]

      assert resp.body =~ ~r/\(cost=/
    end

    test "a composite routine's plan names the function", %{base: base} do
      resp = get!(base, "/rpc/one_reading", "application/vnd.pgrst.plan")

      assert resp.status == 200
      assert resp.body =~ "Function Scan on one_reading"
    end

    test "a SETOF-relation routine is explained through the read pipeline", %{base: base} do
      resp = get!(base, "/rpc/all_readings", "application/vnd.pgrst.plan")

      assert resp.status == 200
      assert resp.body =~ ~r/Scan on readings/
    end

    test "the plan response carries an open Content-Range", %{base: base} do
      resp = get!(base, "/rpc/scalar_text", "application/vnd.pgrst.plan")

      assert resp.headers["content-range"] == ["*/*"]
    end

    test "filters on a SETOF-relation routine reach the explained query", %{base: base} do
      resp = get!(base, "/rpc/all_readings?id=eq.1", "application/vnd.pgrst.plan")

      assert resp.status == 200
      # An `Index Cond` or a `Filter` depending on what the planner picks; either
      # way the `id=eq.1` reached the statement that was explained.
      assert resp.body =~ ~r/(Index Cond|Filter): \(id = 1\)/
    end
  end
end
