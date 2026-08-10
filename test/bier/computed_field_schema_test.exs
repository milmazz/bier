defmodule Bier.ComputedFieldSchemaTest do
  # Regression test for #100: a computed field has TWO identities — the schema
  # the *function* lives in, and the schema of the *relation it extends*.
  # PostgREST keys a computed member by the argument relation
  # (`allComputedRels`: `rel_table_schema`/`rel_table_name` come from the first
  # argument's `pg_type`, while the function's own `pronamespace` is carried
  # separately as `relFunction`), and the docs explicitly allow the two to
  # differ: "Computed fields must be created in the exposed schema or in a
  # schema in the extra search path to be used in this way."
  #
  # Bier used the FUNCTION's schema as the grouping key, so with the function in
  # schema A and its relation in schema B the field was either silently dropped
  # (no `A.X`) or attached to the wrong relation (a different `A.X` exists).
  #
  # Every computed field in `spec/conformance/fixtures.sql` is same-schema, so
  # the frozen conformance suite cannot see this. These schemas are created and
  # dropped by the test itself — `spec/**` is untouched.
  use ExUnit.Case, async: false

  @fn_schema "bier_cf_fns"
  @rel_schema "bier_cf_rels"
  @schemas [@fn_schema, @rel_schema]

  setup_all do
    opts = Bier.ConformanceServer.base_opts()
    conn_opts = Keyword.take(opts, [:hostname, :port, :database, :username, :password])
    {:ok, conn} = Postgrex.start_link(conn_opts)

    drop = [
      "DROP SCHEMA IF EXISTS #{@fn_schema} CASCADE",
      "DROP SCHEMA IF EXISTS #{@rel_schema} CASCADE"
    ]

    create = [
      "CREATE SCHEMA #{@rel_schema}",
      "CREATE SCHEMA #{@fn_schema}",
      "CREATE TABLE #{@rel_schema}.widgets (id int PRIMARY KEY, name text)",
      "INSERT INTO #{@rel_schema}.widgets VALUES (1, 'alpha'), (2, 'beta')",
      "CREATE TABLE #{@rel_schema}.gadgets (id int PRIMARY KEY, widget_id int, label text)",
      """
      INSERT INTO #{@rel_schema}.gadgets
        VALUES (10, 1, 'g-alpha-1'), (11, 1, 'g-alpha-2'), (12, 2, 'g-beta-1')
      """,
      # The decoy. Same relation NAME, living in the FUNCTION's schema. This is
      # what turns failure mode 1 (silent drop) into failure mode 2 (the field
      # attaches here, and is then rendered as a call passing the WRONG row
      # type). It deliberately has no `name` column, so a misrouted
      # `shouty(widgets)` cannot accidentally type-check.
      "CREATE TABLE #{@fn_schema}.widgets (id int PRIMARY KEY, other text)",
      "INSERT INTO #{@fn_schema}.widgets VALUES (99, 'decoy')",
      # Computed COLUMN: function in the fn schema, relation in the rel schema.
      """
      CREATE FUNCTION #{@fn_schema}.shouty(#{@rel_schema}.widgets) RETURNS text
        LANGUAGE sql STABLE AS $fn$ SELECT upper($1.name) $fn$
      """,
      # Computed RELATIONSHIP: same split identity.
      """
      CREATE FUNCTION #{@fn_schema}.widget_gadgets(#{@rel_schema}.widgets)
        RETURNS SETOF #{@rel_schema}.gadgets
        LANGUAGE sql STABLE AS
        $fn$ SELECT * FROM #{@rel_schema}.gadgets g WHERE g.widget_id = $1.id ORDER BY g.id $fn$
      """
    ]

    exec = fn c, stmts -> Enum.each(stmts, &Postgrex.query!(c, &1, [])) end

    exec.(conn, drop)
    exec.(conn, create)

    on_exit(fn ->
      {:ok, c} = Postgrex.start_link(conn_opts)
      exec.(c, drop)
    end)

    rels = Bier.Introspection.run(conn, @schemas)

    %{conn: conn, rels: rels, widgets: rels[{@rel_schema, "widgets"}]}
  end

  describe "introspection keying" do
    test "the computed column lands on the relation it extends, not the function's schema",
         %{rels: rels} do
      assert rels[{@rel_schema, "widgets"}].computed_columns == ["shouty"]
    end

    test "the computed column does NOT attach to the same-named decoy in the function's schema",
         %{rels: rels} do
      decoy = rels[{@fn_schema, "widgets"}]

      assert decoy, "the decoy relation should still be introspected"
      assert decoy.computed_columns == []
      assert decoy.computed_relations == []
    end

    test "the function's own schema is carried on the record", %{widgets: widgets} do
      assert widgets.computed_column_schemas["shouty"] == @fn_schema
      assert widgets.computed_column_types["shouty"] == "text"
    end

    test "the computed relationship is keyed and schema-tagged the same way", %{rels: rels} do
      assert [cr] = rels[{@rel_schema, "widgets"}].computed_relations
      assert cr.name == "widget_gadgets"
      assert cr.fn_schema == @fn_schema
      assert cr.ref_schema == @rel_schema
      assert cr.ref_relation == "gadgets"
    end
  end

  describe "SQL rendering uses the function's schema" do
    test "select list", %{conn: conn, rels: rels, widgets: widgets} do
      {:ok, plan} = Bier.QueryParser.parse_request("select=id,name,shouty&order=id.asc")
      assert {:ok, sql, params} = Bier.QueryExecutor.build(widgets, plan, rels)

      assert sql =~ ~s("#{@fn_schema}"."shouty")
      refute sql =~ ~s("#{@rel_schema}"."shouty")

      assert [%{"id" => 1, "name" => "alpha", "shouty" => "ALPHA"} | _] = run(conn, sql, params)
    end

    test "filter target", %{conn: conn, rels: rels, widgets: widgets} do
      {:ok, plan} = Bier.QueryParser.parse_request("select=id,name&shouty=eq.ALPHA")
      assert {:ok, sql, params} = Bier.QueryExecutor.build(widgets, plan, rels)

      assert sql =~ ~s("#{@fn_schema}"."shouty")
      refute sql =~ ~s("#{@rel_schema}"."shouty")

      assert [%{"id" => 1, "name" => "alpha"}] = run(conn, sql, params)
    end

    test "order term", %{conn: conn, rels: rels, widgets: widgets} do
      {:ok, plan} = Bier.QueryParser.parse_request("select=id,name&order=shouty.desc")
      assert {:ok, sql, params} = Bier.QueryExecutor.build(widgets, plan, rels)

      assert sql =~ ~s("#{@fn_schema}"."shouty")
      refute sql =~ ~s("#{@rel_schema}"."shouty")

      assert [%{"name" => "beta"}, %{"name" => "alpha"}] = run(conn, sql, params)
    end

    test "computed relationship embed", %{conn: conn, rels: rels, widgets: widgets} do
      {:ok, plan} =
        Bier.QueryParser.parse_request("select=id,widget_gadgets(label)&order=id.asc")

      assert {:ok, sql, params} = Bier.QueryExecutor.build(widgets, plan, rels)

      assert sql =~ ~s("#{@fn_schema}"."widget_gadgets")
      refute sql =~ ~s("#{@rel_schema}"."widget_gadgets")

      assert [
               %{"id" => 1, "widget_gadgets" => [%{"label" => "g-alpha-1"} | _]},
               %{"id" => 2, "widget_gadgets" => [%{"label" => "g-beta-1"}]}
             ] = run(conn, sql, params)
    end
  end

  defp run(conn, sql, params) do
    %Postgrex.Result{rows: [[body, _count]]} = Postgrex.query!(conn, sql, params)
    Bier.json_library().decode!(body)
  end
end
