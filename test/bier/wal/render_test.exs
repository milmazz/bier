defmodule Bier.Wal.RenderTest do
  use ExUnit.Case, async: true

  alias Bier.Wal.Render

  @commit_at ~U[2026-08-24 03:11:30.972793Z]

  defp insert_event(row) do
    %{
      kind: :insert,
      relation: %{
        schema: "api",
        table: "orders",
        columns: [
          %{name: "id", type_oid: 23, type_mod: -1, key?: true},
          %{name: "ok", type_oid: 16, type_mod: -1, key?: false},
          %{name: "price", type_oid: 1700, type_mod: -1, key?: false},
          %{name: "meta", type_oid: 3802, type_mod: -1, key?: false},
          %{name: "tags", type_oid: 1009, type_mod: -1, key?: false}
        ]
      },
      row: row
    }
  end

  test "types bool/int/jsonb, leaves numeric and arrays as text" do
    row = %{"id" => "3", "ok" => "t", "price" => "9.50", "meta" => ~s({"a":1}), "tags" => "{x,y}"}
    data = Render.data(insert_event(row), @commit_at, :all)

    assert data == %{
             "type" => "INSERT",
             "schema" => "api",
             "table" => "orders",
             "commit_at" => "2026-08-24T03:11:30.972793Z",
             "row" => %{
               "id" => 3,
               "ok" => true,
               "price" => "9.50",
               "meta" => %{"a" => 1},
               "tags" => "{x,y}"
             },
             "unchanged" => []
           }
  end

  test "null stays null; unchanged TOAST moves to the unchanged list" do
    row = %{"id" => "3", "ok" => nil, "price" => :unchanged_toast, "meta" => nil, "tags" => nil}
    data = Render.data(insert_event(row), @commit_at, :all)
    assert data["row"] == %{"id" => 3, "ok" => nil, "meta" => nil, "tags" => nil}
    assert data["unchanged"] == ["price"]
  end

  test "column filter drops unlisted columns from row and old" do
    event =
      insert_event(%{"id" => "3", "ok" => "t", "price" => "1", "meta" => nil, "tags" => nil})
      |> Map.merge(%{
        kind: :update,
        old: %{"id" => "3", "ok" => "f", "price" => "2", "meta" => nil, "tags" => nil},
        old_kind: :full
      })

    data = Render.data(event, @commit_at, MapSet.new(["id", "ok"]))
    assert data["type"] == "UPDATE"
    assert data["row"] == %{"id" => 3, "ok" => true}
    assert data["old"] == %{"id" => 3, "ok" => false}
    assert data["old_kind"] == "full"
  end

  test "update with no old tuple omits old keys" do
    event =
      insert_event(%{"id" => "1", "ok" => nil, "price" => nil, "meta" => nil, "tags" => nil})

    data =
      Render.data(Map.merge(event, %{kind: :update, old: nil, old_kind: nil}), @commit_at, :all)

    refute Map.has_key?(data, "old")
    refute Map.has_key?(data, "old_kind")
  end

  test "truncate has no row/old" do
    event = %{kind: :truncate, relation: %{schema: "api", table: "orders", columns: []}}
    data = Render.data(event, @commit_at, :all)
    assert data["type"] == "TRUNCATE"
    refute Map.has_key?(data, "row")
  end

  test "float NaN/Infinity render as strings" do
    event = %{
      kind: :insert,
      relation: %{
        schema: "s",
        table: "t",
        columns: [%{name: "f", type_oid: 701, type_mod: -1, key?: false}]
      },
      row: %{"f" => "NaN"}
    }

    assert Render.data(event, @commit_at, :all)["row"] == %{"f" => "NaN"}
  end

  test "SSE frame with id" do
    frame = Bier.Events.SSE.frame("orders", ~s({"a":1}), "1A/2B.0") |> IO.iodata_to_binary()
    assert frame == "event: orders\nid: 1A/2B.0\ndata: {\"a\":1}\n\n"
  end
end
