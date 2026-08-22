defmodule Bier.ComputedFieldSearchPathTest do
  # Regression test for #106: a computed field's FUNCTION may live outside the
  # exposed schemas. `query_computed/2` filtered the function's namespace with
  # the same `= ANY($1)` it used for the argument relation's, so a function on
  # `db-extra-search-path` was never selected — no error, no warning, the field
  # simply did not exist. PostgREST's `allComputedRels` puts no schema filter on
  # the function at all, and the docs are explicit: "Computed fields must be
  # created in the exposed schema *or in a schema in the extra search path* to
  # be used in this way." Bier implemented only the first half of that "or".
  #
  # This is the same silent-drop failure mode as #100 reached by a different
  # route: #100 dropped the field by keying on the wrong schema (fixed by
  # carrying `fn_schema` separately), this drops it by never selecting the row.
  #
  # Not reachable from `spec/`: every computed field in
  # `spec/fixtures/02_base.sql` is same-schema and the fixture set has no
  # extra-search-path schema. These schemas are created and dropped by the test
  # itself — `spec/**` is untouched.
  #
  # Note that the fix is independent of #105: discovery is what was missing.
  # Because Bier renders a computed field as the explicitly qualified
  # `"fn_schema"."fn"("alias")` (#100/#104) rather than upstream's unqualified
  # `"alias"."fn"`, the call executes correctly whether or not `search_path` was
  # ever set — the SQL assertions below run against a connection with the
  # default `search_path`.
  use ExUnit.Case, async: false

  @rel_schema "bier_cfsp_rels"
  @ext_schema "bier_cfsp_ext"

  setup_all do
    opts = Bier.ConformanceServer.base_opts()
    conn_opts = Keyword.take(opts, [:hostname, :port, :database, :username, :password])
    {:ok, conn} = Postgrex.start_link(conn_opts)

    drop = [
      "DROP SCHEMA IF EXISTS #{@rel_schema} CASCADE",
      "DROP SCHEMA IF EXISTS #{@ext_schema} CASCADE"
    ]

    create = [
      "CREATE SCHEMA #{@rel_schema}",
      "CREATE SCHEMA #{@ext_schema}",
      "CREATE TABLE #{@rel_schema}.widgets (id int PRIMARY KEY, name text)",
      "INSERT INTO #{@rel_schema}.widgets VALUES (1, 'alpha'), (2, 'beta')",
      "CREATE TABLE #{@rel_schema}.gadgets (id int PRIMARY KEY, widget_id int, label text)",
      """
      INSERT INTO #{@rel_schema}.gadgets
        VALUES (10, 1, 'g-alpha-1'), (11, 1, 'g-alpha-2'), (12, 2, 'g-beta-1')
      """,
      # Computed COLUMN whose function lives OUTSIDE the exposed schemas.
      """
      CREATE FUNCTION #{@ext_schema}.shouty(#{@rel_schema}.widgets) RETURNS text
        LANGUAGE sql STABLE AS $fn$ SELECT upper($1.name) $fn$
      """,
      # Computed RELATIONSHIP, same split.
      """
      CREATE FUNCTION #{@ext_schema}.widget_gadgets(#{@rel_schema}.widgets)
        RETURNS SETOF #{@rel_schema}.gadgets
        LANGUAGE sql STABLE AS
        $fn$ SELECT * FROM #{@rel_schema}.gadgets g WHERE g.widget_id = $1.id ORDER BY g.id $fn$
      """,
      # An RPC-shaped routine in the extra-path schema: widening computed-field
      # discovery must NOT make it a callable /rpc/ target.
      """
      CREATE FUNCTION #{@ext_schema}.not_an_rpc() RETURNS text
        LANGUAGE sql STABLE AS $fn$ SELECT 'nope' $fn$
      """,
      # Precedence: the SAME computed field name defined for the SAME relation
      # in both an exposed schema and an extra-path one. `search_path` would
      # resolve it by position; with explicit qualification Bier has to pick
      # deliberately, and picks the exposed schema.
      "CREATE TABLE #{@rel_schema}.doodads (id int PRIMARY KEY)",
      "INSERT INTO #{@rel_schema}.doodads VALUES (1)",
      """
      CREATE FUNCTION #{@rel_schema}.tag(#{@rel_schema}.doodads) RETURNS text
        LANGUAGE sql STABLE AS $fn$ SELECT 'exposed' $fn$
      """,
      """
      CREATE FUNCTION #{@ext_schema}.tag(#{@rel_schema}.doodads) RETURNS text
        LANGUAGE sql STABLE AS $fn$ SELECT 'extra' $fn$
      """
    ]

    exec = fn c, stmts -> Enum.each(stmts, &Postgrex.query!(c, &1, [])) end

    exec.(conn, drop)
    exec.(conn, create)

    on_exit(fn ->
      {:ok, c} = Postgrex.start_link(conn_opts)
      exec.(c, drop)
    end)

    %{
      conn: conn,
      rels: Bier.Introspection.run(conn, [@rel_schema], [@ext_schema]),
      without: Bier.Introspection.run(conn, [@rel_schema])
    }
  end

  describe "discovery" do
    test "a computed column whose function is on the extra search path is found", %{rels: rels} do
      widgets = rels[{@rel_schema, "widgets"}]

      assert widgets.computed_columns == ["shouty"]
      assert widgets.computed_column_schemas["shouty"] == @ext_schema
      assert widgets.computed_column_types["shouty"] == "text"
    end

    test "so is a computed relationship", %{rels: rels} do
      assert [cr] = rels[{@rel_schema, "widgets"}].computed_relations
      assert cr.name == "widget_gadgets"
      assert cr.fn_schema == @ext_schema
      assert cr.ref_schema == @rel_schema
      assert cr.ref_relation == "gadgets"
    end

    test "with no extra search path configured neither is discovered", %{without: without} do
      widgets = without[{@rel_schema, "widgets"}]

      assert widgets, "the extended relation is exposed either way"
      assert widgets.computed_columns == []
      assert widgets.computed_relations == []
    end

    test "the extended relation must still be exposed", %{conn: conn} do
      # Only the extra-path schema is exposed here, so `widgets` is not a
      # relation at all and its computed members must not leak in under it.
      rels = Bier.Introspection.run(conn, [@ext_schema], [@rel_schema])

      refute Map.has_key?(rels, {@rel_schema, "widgets"})
      assert rels |> Map.values() |> Enum.flat_map(& &1.computed_columns) == []
    end
  end

  describe "precedence when the same name is defined in both" do
    test "the exposed schema wins over the extra search path", %{rels: rels} do
      doodads = rels[{@rel_schema, "doodads"}]

      assert doodads.computed_columns == ["tag"]
      assert doodads.computed_column_schemas["tag"] == @rel_schema
    end
  end

  describe "the RPC surface is unaffected" do
    test "an extra-search-path routine does not become a /rpc/ target", %{conn: conn} do
      fns = Bier.Introspection.functions(conn, [@rel_schema])

      refute Map.has_key?(fns, {@ext_schema, "not_an_rpc"})
      refute Map.has_key?(fns, {@rel_schema, "not_an_rpc"})
    end
  end

  describe "SQL rendering keeps the explicit qualification" do
    test "select list resolves without relying on search_path", %{conn: conn, rels: rels} do
      widgets = rels[{@rel_schema, "widgets"}]
      {:ok, plan} = Bier.QueryParser.parse_request("select=id,name,shouty&order=id.asc")
      assert {:ok, sql, params} = Bier.QueryExecutor.build(widgets, plan, rels)

      assert sql =~ ~s("#{@ext_schema}"."shouty")
      assert [%{"id" => 1, "name" => "alpha", "shouty" => "ALPHA"} | _] = run(conn, sql, params)
    end

    test "computed relationship embed", %{conn: conn, rels: rels} do
      widgets = rels[{@rel_schema, "widgets"}]

      {:ok, plan} =
        Bier.QueryParser.parse_request("select=id,widget_gadgets(label)&order=id.asc")

      assert {:ok, sql, params} = Bier.QueryExecutor.build(widgets, plan, rels)

      assert sql =~ ~s("#{@ext_schema}"."widget_gadgets")

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
