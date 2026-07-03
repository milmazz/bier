defmodule Bier.ConformanceTest do
  @moduledoc """
  One ExUnit test per spec conformance case. Fully-evaluable HTTP cases run
  against the shared Bier instance and currently FAIL (lib/ returns canned
  responses). Cases the current harness cannot evaluate are tagged :pending and
  excluded (see pending_reason): :cli (no CLI),
  :status_text (req does not expose the HTTP reason phrase).
  These are tracked for a follow-up, like the schema_cache deferral in
  spec/COVERAGE.md.
  """
  use Bier.HttpCase, async: true

  @moduletag :conformance

  for c <- Bier.ConformanceCase.load_all() do
    pending_reason =
      cond do
        c.kind == :cli ->
          :cli

        Map.has_key?(c.expect, "status_text") ->
          :status_text

        true ->
          nil
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
        resp = perform(case_data)
        assert_expect(resp, case_data.expect)
      end
    end
  end
end
