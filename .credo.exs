# .credo.exs — Bier Credo configuration.
#
# We want `mix credo --strict` to be a meaningful gate (per
# docs/AGENT_PLAN.md §8 #3) but not to fail on TODO/FIXME tags. The
# multi-agent factory uses TODO/FIXME comments as the in-code
# coordination signal between slices and as a record of intentional
# stubs — flagging every one of them on every PR makes the signal
# useless.
#
# Anything else credo would flag at strict level still fails the
# build.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "src/",
          "test/",
          "web/",
          "apps/*/lib/",
          "apps/*/src/",
          "apps/*/test/",
          "apps/*/web/"
        ],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        disabled: [
          # Tracked via the AGENT_PLAN, not via credo; see header.
          {Credo.Check.Design.TagTODO, []},
          {Credo.Check.Design.TagFIXME, []}
        ]
      }
    }
  ]
}
