defmodule Dextrin.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :dextrin,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      name: "Dextrin",
      docs: docs()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      # :inets/:ssl (pulling in :public_key/:crypto transitively) are
      # needed by Mix.Tasks.Dextrin.Gen.Unicode to fetch UCD data over
      # HTTPS.
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ichor, path: "../ichor"},
      {:decimal, "~> 2.1"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp description do
    "DXN (Data eXchange Notation) for Elixir -- .dxn text, .dxnb binary, " <>
      "and .dxns schema documents, built on the Ichor grammar compiler."
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib priv/grammar priv/unicode priv/schema .formatter.exs mix.exs README.md DXN.md DESIGN.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "DXN.md", "DESIGN.md"]
    ]
  end
end
