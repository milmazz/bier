# Credo configuration. Run with `mix credo --strict` (the CI gate).
#
# Scope: `lib/` only. `test/**` and `spec/**` are the frozen conformance
# harness (ground truth derived from PostgREST v14.12 — see
# docs/CONFORMANCE_IMPL.md) and must not be churned for style. The committed
# `lib/bier/query_parser.ex` is GENERATED from its `.ex.exs` template via
# `mix gen.parsers`, so only that generated output is excluded — the template
# (the file contributors actually edit) IS analyzed.
%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "config/"],
        excluded: [
          "lib/bier/query_parser.ex"
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
           [files: %{excluded: ["lib/bier/pg_error.ex"]}]},
          # `Bier.Config` mirrors PostgREST's full option surface in
          # `Bier.schema/0` (41 fields today, growing as PostgREST keys are
          # implemented). The VM map-representation concern (structs >= 32
          # fields) doesn't apply: Config is created once per instance at
          # boot, never per request.
          {Credo.Check.Warning.StructFieldAmount,
           [max_fields: 45, files: %{included: ["lib/bier/config.ex"]}]},
          # `Bier.ErrorLogger` tags its entries with `:bier_instance` /
          # `:bier_error_code` metadata for host log pipelines. A library has
          # no say in the host's `:logger` formatter config, so the "key not
          # found in Logger config" heuristic cannot apply here.
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig,
           [files: %{excluded: ["lib/bier/error_logger.ex"]}]}
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
