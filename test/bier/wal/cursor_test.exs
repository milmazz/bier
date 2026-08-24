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

  test "parse rejects cursors this server could never have issued" do
    # `Last-Event-ID` is attacker-controlled, so the parser is the boundary.
    bad = [
      # An LSN half is 32 bits: anything wider was never a real cursor.
      "1FFFFFFFF/0.0",
      "0/1FFFFFFFF.0",
      # `Integer.parse/1` accepts a leading sign, which would otherwise make
      # these synonyms for a legitimate cursor.
      "+1A/2B.0",
      "1A/+2B.0",
      "1A/2B.+0",
      "-1/2.0",
      # Oversized input is rejected on sight rather than parsed into a
      # bignum first.
      String.duplicate("9", 200) <> "/0.0"
    ]

    for cursor <- bad do
      assert Cursor.parse(cursor) == :error, "expected #{inspect(cursor)} to be rejected"
    end

    # The boundary itself still parses: 0xFFFFFFFF is a legal LSN half.
    assert Cursor.parse("FFFFFFFF/FFFFFFFF.0") == {:ok, {{0xFFFF_FFFF, 0xFFFF_FFFF}, 0}}
  end

  test "compare follows commit order then sequence" do
    assert Cursor.compare({{0, 5}, 0}, {{0, 5}, 1}) == :lt
    assert Cursor.compare({{1, 0}, 0}, {{0, 9}, 9}) == :gt
    assert Cursor.compare({{0, 5}, 1}, {{0, 5}, 1}) == :eq
  end
end
