# Credo configuration. Run with `mix credo --strict` (the CI gate).
#
# Scope: `lib/` only. `test/**` and `spec/**` are the frozen conformance
# harness (ground truth derived from PostgREST v14.12 — see
# docs/CONFORMANCE_IMPL.md) and must not be churned for style. The query
# parser modules are GENERATED from their `*.ex.exs` templates via
# `mix gen.parsers` and are excluded for the same reason.
%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "config/"],
        excluded: [
          "lib/bier/query_parser.ex",
          "lib/bier/query_parser.ex.exs",
          "lib/bier/query_parser/nimble.ex",
          "lib/bier/query_parser/nimble.ex.exs"
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
