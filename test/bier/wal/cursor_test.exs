defmodule Bier.Wal.CursorTest do
  use ExUnit.Case, async: true

  alias Bier.Wal.Cursor

  test "encode/parse round-trip" do
    cursor = {{0x1A, 0x2B3C40}, 2}
    assert Cursor.encode(cursor) == "1A/2B3C40.2"
    assert Cursor.parse("1A/2B3C40.2") == {:ok, cursor}
  end

  test "parse rejects malformed cursors" do
    for bad <- ["", "zz", "1A/2B", "1A/2B.", "1A/2B.x", "1A.2", "/1.2"] do
      assert Cursor.parse(bad) == :error, "expected #{inspect(bad)} to be rejected"
    end
  end

  test "compare follows commit order then sequence" do
    assert Cursor.compare({{0, 5}, 0}, {{0, 5}, 1}) == :lt
    assert Cursor.compare({{1, 0}, 0}, {{0, 9}, 9}) == :gt
    assert Cursor.compare({{0, 5}, 1}, {{0, 5}, 1}) == :eq
  end
end
