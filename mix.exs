defmodule Bier.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :bier,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
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
      {:bandit, "~> 1.0-pre"},
      {:ex_doc, "~> 0.25", only: :dev, runtime: false},
      {:jason, "~> 1.2"},
      {:nimble_options, "~> 0.3"},
      {:nimble_parsec, "~> 1.2"},
      {:plug, "~> 1.4"}
    ]
  end
end
