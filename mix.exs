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
      {:ichor, "~> 0.1.1"},
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
      links: %{"GitHub" => "https://github.com/joetjen/dextrin"},
      files:
        ~w(lib priv/grammar priv/unicode priv/schema .formatter.exs mix.exs README.md CHANGELOG.md LICENSE.txt)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/joetjen/dextrin",
      source_ref: "v#{@version}",
      extras: extras(),
      groups_for_extras: groups_for_extras(),
      groups_for_modules: groups_for_modules()
    ]
  end

  defp extras do
    [
      "README.md",
      "guides/TUTORIAL.md",
      "guides/EXAMPLES.md",
      "guides/CHEATSHEET.md",
      "guides/dxn/TUTORIAL.md",
      "guides/dxn/DXN.md",
      "guides/dxn/DXN_EXAMPLES.md",
      "guides/dxn/DXN_CHEATSHEET.md",
      "CHANGELOG.md",
      "CONTRIBUTION.md",
      "LICENSE.txt"
    ]
  end

  defp groups_for_extras do
    [
      DXN: Path.wildcard("guides/dxn/*.md")
    ]
  end

  defp groups_for_modules do
    [
      Core: [
        Dextrin,
        Dextrin.Value,
        Dextrin.Registry,
        Dextrin.Error
      ],
      "Value types": [
        Dextrin.Array,
        Dextrin.Bytes,
        Dextrin.Char,
        Dextrin.CustomTag,
        Dextrin.Duration,
        Dextrin.Keyword,
        Dextrin.OrderedMap,
        Dextrin.Rational,
        Dextrin.SortedSet,
        Dextrin.Struct,
        Dextrin.Symbol,
        Dextrin.Tuple,
        Dextrin.Uri,
        Dextrin.Uuid
      ],
      "Text pipeline (.dxn)": [
        Dextrin.Text.Grammar,
        Dextrin.Text.Actions,
        Dextrin.Text.Printer,
        Dextrin.Text.Formatter,
        Dextrin.Text.Escapes
      ],
      "Binary pipeline (.dxnb)": [
        Dextrin.Binary.Encoder,
        Dextrin.Binary.Decoder,
        Dextrin.Binary.Tags
      ],
      "Schema (.dxns)": [
        Dextrin.Schema,
        Dextrin.Schema.Compiler,
        Dextrin.Schema.Compiled,
        Dextrin.Schema.Field,
        Dextrin.Schema.TypeExpr,
        Dextrin.Schema.Validator,
        Dextrin.Schema.Validated,
        Dextrin.Schema.Std,
        Dextrin.Schema.FileResolver,
        Dextrin.Schema.Provider
      ],
      Unicode: [
        Dextrin.Unicode.RangeGenerator
      ],
      "Mix tasks": [
        Mix.Tasks.Dextrin.Validate,
        Mix.Tasks.Dextrin.Encode,
        Mix.Tasks.Dextrin.Decode,
        Mix.Tasks.Dextrin.Format,
        Mix.Tasks.Dextrin.Gen.Schema,
        Mix.Tasks.Dextrin.Gen.Unicode
      ]
    ]
  end
end
