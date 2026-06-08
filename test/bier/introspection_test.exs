defmodule Bier.IntrospectionTest do
  use ExUnit.Case, async: false

  setup_all do
    opts = Bier.ConformanceServer.base_opts()
    conn_opts = Keyword.take(opts, [:hostname, :port, :database, :username, :password])
    {:ok, conn} = Postgrex.start_link(conn_opts)
    %{conn: conn}
  end

  test "captures column comments, enum labels, char maxLength, relation comment", %{conn: conn} do
    rels = Bier.Introspection.run(conn, ["test"])

    child = rels[{"test", "child_entities"}]
    assert child.comment == "child_entities comment"
    id = Enum.find(child.columns, &(&1.name == "id"))
    assert id.comment == "child_entities id comment"

    menagerie = rels[{"test", "menagerie"}]
    enum_col = Enum.find(menagerie.columns, &(&1.name == "enum"))
    assert enum_col.enum_labels == ["foo", "bar"]
    assert enum_col.type == "test.enum_menagerie_type"

    types = rels[{"test", "openapi_types"}]
    a_char = Enum.find(types.columns, &(&1.name == "a_character"))
    assert a_char.max_length == 1
    a_varchar = Enum.find(types.columns, &(&1.name == "a_character_varying"))
    assert a_varchar.max_length == nil
  end

  test "captures function comment, volatility, and arg flags", %{conn: conn} do
    fns = Bier.Introspection.functions(conn, ["test"])
    [varied | _] = fns[{"test", "varied_arguments_openapi"}]
    assert is_binary(varied.comment)
    assert varied.comment =~ "An RPC function"
    assert varied.volatility == :immutable
    # args carry name/type/variadic?/has_default?
    assert Enum.all?(varied.args, &Map.has_key?(&1, :variadic?))
    assert Enum.all?(varied.args, &Map.has_key?(&1, :has_default?))
  end

  test "schema_comment/2 returns the test schema COMMENT", %{conn: conn} do
    assert Bier.Introspection.schema_comment(conn, "test") =~ "My API title"
    assert Bier.Introspection.schema_comment(conn, "nonexistent_schema_xyz") == nil
  end
end
