defmodule Bier.MixProject do
  use Mix.Project

  @version "0.1.1-dev"

  def project do
    [
      app: :bier,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [tool: ExCoveralls],
      aliases: aliases(),
      escript: escript(),
      releases: releases(),
      deps: deps()
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        # `precommit` ends with the test suite, and the suite needs the :test
        # build (test/support, fixtures task), so the whole alias runs there.
        precommit: :test
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Bier.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp escript do
    [main_module: Bier.CLI, app: nil]
  end

  # Standalone-server release: `MIX_ENV=prod mix release` builds a self-contained
  # `bier` release whose `bin/bier start` boots one instance from `PGRST_*` env
  # (see `Bier.Application` + `BIER_STANDALONE`). Used by the Dockerfile.
  defp releases do
    [
      bier: [
        include_executables_for: [:unix],
        applications: [bier: :permanent]
      ]
    ]
  end

  defp aliases do
    [
      test: ["bier.fixtures.load", "test"],
      # Every CI gate in one command (see CONTRIBUTING.md). The `test` step
      # expands to the alias above, so it loads the fixture DB first. CI runs
      # the same steps individually to report each gate separately.
      precommit: [
        "deps.unlock --check-unused",
        "format --check-formatted",
        "hex.audit",
        "compile --warnings-as-errors",
        "credo --strict",
        "docs --warnings-as-errors",
        "test"
      ],
      # Regenerate the dependency-free parser module from its `.ex.exs`
      # template. Run in `:dev` (nimble_parsec is a dev/test-only dep). The
      # generated `.ex` file is the source `mix compile` reads; commit both.
      "gen.parsers": [
        "nimble_parsec.compile lib/bier/query_parser.ex.exs",
        "format"
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.0"},
      {:benchee, "~> 1.3", only: :dev},
      # Static analysis (`mix credo --strict`, a CI gate). See .credo.exs.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      # :test as well so the `docs` step of `mix precommit` (which runs in the
      # :test env) can build the docs.
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false},
      # JWT signature verification (HS*/RS*/ES*/PS*/EdDSA) from the configured
      # secret or JWK — see Bier.JWT.
      {:jose, "~> 1.11"},
      {:excoveralls, "~> 0.18", only: :test},
      {:nimble_options, "~> 1.0"},
      # nimble_parsec is only needed to RUN `mix gen.parsers` (the
      # `nimble_parsec.compile` template task). The committed parser module
      # `Bier.QueryParser` is a generated, dependency-free `.ex` file, so
      # `:prod` compiles without it. Declared for :test too only
      # because ex_doc (:dev/:test for `mix precommit`) pulls makeup_elixir,
      # whose nimble_parsec requirement spans [:dev, :test] — Mix requires the
      # top-level :only to cover every dependent's environments.
      {:nimble_parsec, "~> 1.4", only: [:dev, :test], runtime: false},
      {:plug, "~> 1.19"},
      {:postgrex, "~> 0.20"},
      {:telemetry, "~> 1.0"},
      {:req, "~> 0.5", only: :test},
      {:yaml_elixir, "~> 2.11", only: :test}
    ]
  end
end
