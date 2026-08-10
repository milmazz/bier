defmodule Bier.ReviewFollowupsTest do
  @moduledoc """
  The two behavioral items from the PR #101 review collected in #102:

    * item 1 — `Range: +0-5` was honored. `digits/1` used `Integer.parse/1`,
      which accepts a leading `+`; PostgREST validates the header against
      `^([0-9]+)-([0-9]*)$` (`rangeParse`, `RangeQuery.hs`) and treats a
      non-matching `Range` as absent.
    * item 3 — the 404 fuzzy hints ran unbounded Levenshtein scoring over every
      candidate name with no bound on the request-supplied term. Upstream
      amortizes with a prebuilt `FuzzySet`; the cheap equivalent is to skip the
      match entirely past a term length no real identifier can reach.

  Items 4 (`Warning.record/2`) and 5 (a comment) are covered by the suite
  compiling and staying green.
  """
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 3]
  import Plug.Conn, only: [put_req_header: 3]

  alias Bier.Fuzzy
  alias Bier.Pagination

  defp window(range_header) do
    request =
      case range_header do
        nil -> conn(:get, "/items", "")
        value -> put_req_header(conn(:get, "/items", ""), "range", value)
      end

    {:ok, plan} = Pagination.apply_window(%{offset: nil, limit: nil}, request, nil)
    {plan.offset, plan.limit}
  end

  describe "Range header: only bare digits (#102 item 1)" do
    test "a well-formed range applies" do
      assert window("0-5") == {0, 6}
      assert window("2-") == {2, nil}
    end

    test "a leading + fails the pattern, so the header is ignored" do
      assert window("+0-5") == window(nil)
      assert window("0-+5") == window(nil)
    end

    test "the other non-matching shapes stay ignored" do
      # (`" 0-5"` is NOT here: RFC 7230 optional whitespace around a field value
      # is stripped before the pattern is applied, which `read_range/1` already
      # does.)
      for bad <- ["-5", "a-5", "0-b", "0- 5", "0x0-5", "0-5x"] do
        assert window(bad) == window(nil), "expected #{inspect(bad)} to be ignored"
      end
    end
  end

  describe "fuzzy hints are bounded by term length (#102 item 3)" do
    test "a plausible misspelling still matches" do
      assert Fuzzy.best_match("itemss", ["items", "projects"], 0.75) == "items"
    end

    test "a term longer than any identifier is skipped without scoring" do
      # PostgreSQL identifiers are capped at NAMEDATALEN-1 = 63 bytes, so a term
      # this long cannot be one. The guard is deliberately unconditional: even
      # an exact match is skipped, which is what makes it a hard cost bound
      # rather than a heuristic.
      long = String.duplicate("a", 65)

      assert Fuzzy.best_match(long, [long, "items"], 0.75) == nil
    end

    test "the boundary itself still matches" do
      at_limit = String.duplicate("a", 64)

      assert Fuzzy.best_match(at_limit, [at_limit], 0.75) == at_limit
    end
  end
end
