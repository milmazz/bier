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
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_add_apps: [:ex_unit, :mix],
        plt_local_path: "priv/plts/local.plt",
        plt_core_path: "priv/plts/core.plt"
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.xml": :test,
        "coveralls.github": :test
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

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Runtime
      {:bandit, "~> 1.0"},
      {:ecto_sql, "~> 3.13"},
      {:jose, "~> 1.11"},
      {:joken, "~> 2.6"},
      {:nimble_options, "~> 1.0"},
      {:nimble_parsec, "~> 1.4"},
      {:plug, "~> 1.19"},
      {:postgrex, "~> 0.21"},

      # Dev / docs
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},

      # Test
      {:excoveralls, "~> 0.18", only: :test},
      {:jason, "~> 1.4", only: [:dev, :test]},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:yaml_elixir, "~> 2.11", only: :test}
    ]
  end
end
