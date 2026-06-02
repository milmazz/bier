defmodule Bier.ConformanceTest do
  @moduledoc """
  One ExUnit test per spec conformance case. HTTP cases run against the shared
  Bier instance and currently FAIL (lib/ returns canned responses). CLI cases
  are tagged :cli and excluded until a Bier CLI exists.
  """
  use Bier.HttpCase, async: true

  @moduletag :conformance

  for c <- Bier.ConformanceCase.load_all() do
    case c.kind do
      :http ->
        @tag area: String.to_atom(c.area)
        test "#{c.id} #{c.feature}" do
          case_data = unquote(Macro.escape(c))
          resp = perform(case_data)
          assert_expect(resp, case_data.expect)
        end

      :cli ->
        @tag :cli
        @tag :pending
        @tag area: String.to_atom(c.area)
        test "#{c.id} #{c.feature} (cli, pending)" do
          # No Bier CLI entrypoint yet; recorded as pending. See COVERAGE.md.
          flunk("CLI conformance case #{unquote(c.id)} has no execution target yet")
        end
    end
  end
end
