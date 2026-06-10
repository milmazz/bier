# Credo configuration. Run with `mix credo --strict` (the CI gate).
#
# Scope: `lib/` only. `test/**` and `spec/**` are the frozen conformance
# harness (ground truth derived from PostgREST v14.12 — see
# docs/CONFORMANCE_IMPL.md) and must not be churned for style. The committed
# query parser `.ex` modules are GENERATED from their `*.ex.exs` templates via
# `mix gen.parsers`, so only the generated output is excluded — the templates
# themselves (the files contributors actually edit) ARE analyzed.
%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "config/"],
        excluded: [
          "lib/bier/query_parser.ex",
          "lib/bier/query_parser/nimble.ex"
        ]
      },
      checks: %{
        extra: [
          # The request pipeline regularly wraps one decision inside a
          # transaction/measure closure; depth 3 is accepted, depth 4 is not.
          {Credo.Check.Refactor.Nesting, [max_nesting: 3]},
          # `Bier.PgError.status_for/2` is a faithful port of PostgREST's
          # `pgErrorStatus` SQLSTATE table (Error.hs); one flat lookup is the
          # most reviewable shape for it, so the file is excluded.
          {Credo.Check.Refactor.CyclomaticComplexity,
           [files: %{excluded: ["lib/bier/pg_error.ex"]}]}
        ],
        disabled: [
          # In-code TODOs are tracked as GitHub issues; a comment referencing
          # future work should not fail the lint gate.
          {Credo.Check.Design.TagTODO, []},
          {Credo.Check.Design.TagFIXME, []}
        ]
      }
    }
  ]
}
