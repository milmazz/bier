defmodule Bier.ConformanceTest do
  @moduledoc """
  One ExUnit test per spec conformance case. Fully-evaluable HTTP cases run
  against the shared Bier instance and currently FAIL (lib/ returns canned
  responses). Cases the current harness cannot evaluate are tagged :pending and
  excluded (see pending_reason): :status_text (req does not expose the HTTP
  reason phrase). CLI cases — including the db-config role-settings ones,
  1724/1725 (#64) — run directly via `Bier.CliCase`.

  A second, narrower exclusion covers **deliberate divergences**: a case whose
  id is in `@divergences` is tagged :pending with reason :deliberate_divergence.
  The spec file itself is left untouched — it still records what PostgREST does,
  which is the point of `spec/` — and the exemption lives here, where the
  decision not to match it does. Every entry needs operator sign-off and an
  issue; the list is deliberately hard to grow.
  """
  use Bier.HttpCase, async: true

  @moduletag :conformance

  # id => why Bier deliberately does not match this case.
  @divergences %{
    1771 =>
      "Server: bier/<version>, not postgrest/<version> — a Server header names " <>
        "the software that built the response, and wearing upstream's product " <>
        "token would misattribute Bier's bugs to PostgREST. The dialect is " <>
        "advertised through the OpenAPI document's externalDocs instead (#122)."
  }

  # id => {path into the case's expect map, pinned value}. A divergence entry
  # must keep pointing at a live case that still asserts the upstream behavior
  # Bier declines to match; a spec re-sync that renumbers or rewrites the case
  # fails the build here instead of silently keeping (or dangling) the
  # exemption. Every @divergences entry needs a pin here.
  @divergence_pins %{1771 => {["headers_match", "Server"], "^postgrest/.+"}}

  cases_by_id = Map.new(Bier.ConformanceCase.load_all(), &{&1.id, &1})

  for id <- Map.keys(@divergences) do
    {path, pinned} =
      Map.get(@divergence_pins, id) ||
        raise "deliberate-divergence entry #{id} has no @divergence_pins entry"

    case Map.fetch(cases_by_id, id) do
      :error ->
        raise "deliberate-divergence entry #{id} matches no spec case — " <>
                "renumbered in a re-sync? Update @divergences/@divergence_pins."

      {:ok, c} ->
        get_in(c.expect, path) == pinned ||
          raise "spec case #{id} no longer pins #{inspect(path)} == " <>
                  "#{inspect(pinned)} — the deliberate-divergence entry is " <>
                  "stale; re-evaluate it."
    end
  end

  for c <- Bier.ConformanceCase.load_all() do
    pending_reason =
      cond do
        Map.has_key?(c.expect, "status_text") -> :status_text
        Map.has_key?(@divergences, c.id) -> :deliberate_divergence
        true -> nil
      end

    @tag area: String.to_atom(c.area)

    if pending_reason do
      message =
        case pending_reason do
          :deliberate_divergence ->
            "conformance case #{c.id} is a deliberate divergence, not a gap: " <>
              Map.fetch!(@divergences, c.id)

          reason ->
            "conformance case #{c.id} pending — harness cannot evaluate #{reason} yet"
        end

      @tag :pending
      @tag pending_reason: pending_reason
      test "#{c.id} #{c.feature} (pending: #{pending_reason})" do
        flunk(unquote(message))
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
