defmodule Bier.ConformanceTest do
  @moduledoc """
  One ExUnit test per spec conformance case. Fully-evaluable HTTP cases run
  against the shared Bier instance and currently FAIL (lib/ returns canned
  responses). Cases the current harness cannot evaluate are tagged :pending and
  excluded (see pending_reason): :jwt (needs JWT signing), :openapi_doc
  (openapi body_jsonpath cases need the generated OpenAPI document, #39),
  :status_text (req does not expose the HTTP reason phrase). CLI cases now run
  directly via `Bier.CliCase` except those deferred as :cli_parity (full-table
  dump / --example flag, cases 1705 and 1727), :unmodeled_key (config keys
  Bier does not yet implement), or :db_config (DB role-settings source). These
  are tracked for a follow-up, like the schema_cache deferral in spec/COVERAGE.md.
  """
  use Bier.HttpCase, async: true

  @moduletag :conformance

  # CLI cases that map onto config Bier does not (yet) implement keep an honest
  # pending reason instead of a façade. See
  # docs/superpowers/specs/2026-06-07-cli-implementation-design.md.
  @cli_deferred %{
    1705 => :cli_parity,
    1727 => :cli_parity,
    1707 => :unmodeled_key,
    1711 => :unmodeled_key,
    1714 => :unmodeled_key,
    1715 => :unmodeled_key,
    1716 => :unmodeled_key,
    1718 => :unmodeled_key,
    1729 => :unmodeled_key,
    1724 => :db_config,
    1725 => :db_config
  }

  for c <- Bier.ConformanceCase.load_all() do
    pending_reason =
      cond do
        c.kind == :cli ->
          Map.get(@cli_deferred, c.id)

        Map.has_key?(c.request, "jwt") ->
          :jwt

        # body_jsonpath now evaluates (see Bier.ConformanceJsonPath), EXCEPT the
        # openapi-area cases, which assert the generated OpenAPI document that is
        # still a stub until #39. Keep those excluded under an honest reason.
        Map.has_key?(c.expect, "body_jsonpath") and c.area == "openapi" ->
          :openapi_doc

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
