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

  test "floats become JSON numbers; NaN/Infinity fall back to strings" do
    scalar = fn oid, value ->
      %{
        kind: :insert,
        relation: %{
          schema: "s",
          table: "t",
          columns: [%{name: "f", type_oid: oid, type_mod: -1, key?: false}]
        },
        row: %{"f" => value}
      }
    end

    # The ordinary float must come back as a NUMBER. Without it this test
    # would pass with @float_oids removed entirely, since the catch-all
    # `convert/2` clause also yields the string "NaN".
    assert Render.data(scalar.(701, "9.5"), @commit_at, :all)["row"] == %{"f" => 9.5}
    assert Render.data(scalar.(700, "-0.25"), @commit_at, :all)["row"] == %{"f" => -0.25}

    # JSON has no spelling for these, so they stay strings.
    for value <- ["NaN", "Infinity", "-Infinity"] do
      assert Render.data(scalar.(701, value), @commit_at, :all)["row"] == %{"f" => value}
    end

    # The rest of the OID map, which the wide fixture above never reaches:
    # int2 and int8 alongside int4, and `json` alongside `jsonb`.
    assert Render.data(scalar.(21, "7"), @commit_at, :all)["row"] == %{"f" => 7}

    assert Render.data(scalar.(20, "90071992547409"), @commit_at, :all)["row"] ==
             %{"f" => 90_071_992_547_409}

    assert Render.data(scalar.(114, ~s([1,"a"])), @commit_at, :all)["row"] == %{"f" => [1, "a"]}

    # An int column whose value does not parse passes through as text rather
    # than raising inside the connection process.
    assert Render.data(scalar.(23, "not-a-number"), @commit_at, :all)["row"] ==
             %{"f" => "not-a-number"}
  end

  test "delete carries old only, and a key-only old is announced as such" do
    event = %{
      kind: :delete,
      relation: %{
        schema: "api",
        table: "orders",
        columns: [
          %{name: "id", type_oid: 23, type_mod: -1, key?: true},
          %{name: "ok", type_oid: 16, type_mod: -1, key?: false}
        ]
      },
      # What a DEFAULT replica identity yields: the identity columns only,
      # already filtered by the decoder. `old_kind` is what lets a client
      # tell that apart from a full pre-image that happened to be sparse.
      old: %{"id" => "3"},
      old_kind: :key
    }

    data = Render.data(event, @commit_at, :all)
    assert data["type"] == "DELETE"
    assert data["old"] == %{"id" => 3}
    assert data["old_kind"] == "key"
    # A DELETE has no post-image at all — absent, not null, and no
    # `unchanged` list either.
    refute Map.has_key?(data, "row")
    refute Map.has_key?(data, "unchanged")
  end

  test "SSE frame with id" do
    frame = Bier.Events.SSE.frame("orders", ~s({"a":1}), "1A/2B.0") |> IO.iodata_to_binary()
    assert frame == "event: orders\nid: 1A/2B.0\ndata: {\"a\":1}\n\n"
  end
end
