defmodule Bier.QuoteTypeTest do
  # Regression test for #71: `quote_type/1` must accept PostgreSQL types that
  # carry a type modifier (numeric(p,s), varchar(n), etc — what
  # `format_type/2` returns for such columns) while still rejecting anything
  # outside a conservative charset, since it is also the injection guard for
  # untrusted user casts (`?select=col::<cast>`).
  use ExUnit.Case, async: true

  alias Bier.QueryExecutor

  describe "quote_type/1 accepts legitimate types" do
    test "plain and array/qualified forms (pre-existing behavior)" do
      for type <- ["text", "integer", "text[]", "jsonb", "\"MyType\"", "public.my_domain"] do
        assert QueryExecutor.quote_type(type) == type
      end
    end

    test "parameterized types with a modifier" do
      for type <- [
            "numeric(4,2)",
            "numeric(1000)",
            "character varying(255)",
            "varchar(10)",
            "character(1)",
            "bit(8)",
            "bit varying(8)",
            "numeric(4,2)[]"
          ] do
        assert QueryExecutor.quote_type(type) == type
      end
    end

    test "a modifier followed by trailing words (e.g. timestamp precision)" do
      assert QueryExecutor.quote_type("timestamp(3) without time zone") ==
               "timestamp(3) without time zone"
    end
  end

  describe "quote_type/1 rejects everything else" do
    test "malformed or empty modifiers" do
      for type <- ["numeric()", "numeric(4,)", "numeric(,2)", "numeric(4,,2)", "numeric(a)"] do
        assert catch_throw(QueryExecutor.quote_type(type)) == {:bad_request, :bad_cast}
      end
    end

    test "injection attempts through the cast string" do
      for type <- [
            "int); DROP TABLE users; --",
            "numeric(4,2); SELECT 1",
            "text)) OR 1=1 --",
            "numeric(4,2)) UNION SELECT password FROM users --"
          ] do
        assert catch_throw(QueryExecutor.quote_type(type)) == {:bad_request, :bad_cast}
      end
    end
  end

  describe "end to end: filter and cast on a parameterized-type column" do
    setup do
      opts = Bier.ConformanceServer.base_opts()
      conn_opts = Keyword.take(opts, [:hostname, :port, :database, :username, :password])
      {:ok, conn} = Postgrex.start_link(conn_opts)
      rels = Bier.Introspection.run(conn, ["test"])
      %{conn: conn, types: rels[{"test", "openapi_types"}], rels: rels}
    end

    test "filtering a character(n) column no longer 400s", %{
      conn: conn,
      types: types,
      rels: rels
    } do
      assert Enum.find(types.columns, &(&1.name == "a_character")).type == "character(1)"

      {:ok, plan} = Bier.QueryParser.parse_request("a_character=eq.x")

      assert {:ok, sql, params} = Bier.QueryExecutor.build(types, plan, rels)
      assert %Postgrex.Result{} = Postgrex.query!(conn, sql, params)
    end

    test "casting a select field to a parameterized type no longer 400s", %{
      conn: conn,
      types: types,
      rels: rels
    } do
      {:ok, plan} = Bier.QueryParser.parse_request("select=x:a_numeric::numeric(4,2)")

      assert {:ok, sql, params} = Bier.QueryExecutor.build(types, plan, rels)
      assert %Postgrex.Result{} = Postgrex.query!(conn, sql, params)
    end
  end
end
