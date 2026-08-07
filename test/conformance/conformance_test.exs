defmodule Bier.ConformanceTest do
  @moduledoc """
  One ExUnit test per spec conformance case. Fully-evaluable HTTP cases run
  against the shared Bier instance and currently FAIL (lib/ returns canned
  responses). Cases the current harness cannot evaluate are tagged :pending and
  excluded (see pending_reason): :status_text (req does not expose the HTTP
  reason phrase). CLI cases — including the db-config role-settings ones,
  1724/1725 (#64) — run directly via `Bier.CliCase`.
  """
  use Bier.HttpCase, async: true

  @moduletag :conformance

  for c <- Bier.ConformanceCase.load_all() do
    pending_reason =
      if Map.has_key?(c.expect, "status_text") do
        :status_text
      end

    @tag area: String.to_atom(c.area)

    if pending_reason do
      @tag :pending
      @tag pending_reason: pending_reason
      test "#{c.id} #{c.feature} (pending: #{pending_reason})" do
        flunk(
          "conformance case #{unquote(c.id)} pending — harness cannot evaluate " <>
            "#{unquote(pending_reason)} yet"
        )
      end
    else
      test "#{c.id} #{c.feature}" do
        case_data = unquote(Macro.escape(c))

        resp =
          unquote(
            if c.kind == :cli do
              quote(do: Bier.CliCase.perform(var!(case_data)))
            else
              quote(do: perform(var!(case_data)))
            end
          )

        assert_expect(resp, case_data.expect)
      end
    end
  end
end
