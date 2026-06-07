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
      test: ["bier.fixtures.load", "test"]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.0"},
      {:benchee, "~> 1.3", only: :dev},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:nimble_options, "~> 1.0"},
      {:nimble_parsec, "~> 1.4"},
      {:plug, "~> 1.19"},
      {:postgrex, "~> 0.20"},
      {:req, "~> 0.5", only: :test},
      {:yaml_elixir, "~> 2.11", only: :test}
    ]
  end
end
