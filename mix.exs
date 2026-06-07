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
      deps: deps()
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.json": :test
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

  defp aliases do
    [
      test: ["bier.fixtures.load", "test"],
      # Regenerate the dependency-free parser modules from their `.ex.exs`
      # templates. Run in `:dev` (nimble_parsec is a dev-only dep). The
      # generated `.ex` files are the source `mix compile` reads; commit both.
      "gen.parsers": [
        "nimble_parsec.compile lib/bier/query_parser/nimble.ex.exs",
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
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      # JWT signature verification (HS*/RS*/ES*/PS*/EdDSA) from the configured
      # secret or JWK — see Bier.JWT.
      {:jose, "~> 1.11"},
      {:excoveralls, "~> 0.18", only: :test},
      {:nimble_options, "~> 1.0"},
      # nimble_parsec is only needed to RUN `mix gen.parsers` (the
      # `nimble_parsec.compile` template task). The committed parser modules
      # `Bier.QueryParser`/`Bier.QueryParser.Nimble` are generated, dependency-free
      # `.ex` files, so `:test`/`:prod` compile without it.
      {:nimble_parsec, "~> 1.4", only: :dev, runtime: false},
      {:plug, "~> 1.19"},
      {:postgrex, "~> 0.20"},
      {:req, "~> 0.5", only: :test},
      {:yaml_elixir, "~> 2.11", only: :test}
    ]
  end
end
