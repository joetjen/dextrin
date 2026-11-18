defmodule Mix.Tasks.Dextrin.Gen.Elixir do
  @moduledoc """
  Elixir modules from a tree of `.dxns` schemas (`Dextrin.Codegen.Elixir`,
  design/codegen-elixir.md): per `%schema`, a file of the user's, written
  once, and a generated file, rewritten on every run, whose functions read
  and check every version the schema has, with no schema read at run time.

      $ mix dextrin.gen.elixir schemas/ --prefix MyApp.Schemas --out lib/my_app/schemas
      $ mix dextrin.gen.elixir schemas/ --prefix MyApp.Schemas --out lib/my_app/schemas --check

  What is written by hand survives: the user's files are never rewritten,
  and the lines inside a generated file's `# dextrin:keep NAME` regions are
  put back. Module names and paths are kept as the user's files have them.

  `--check` writes nothing and fails when a generated file is out of date
  with the schemas, or holds an orphaned region: for CI.
  """

  use Mix.Task

  alias Dextrin.Codegen.Elixir, as: Gen

  @shortdoc "Generates Elixir modules from .dxns schemas"

  @impl Mix.Task
  def run(argv) do
    {opts, roots, _} =
      OptionParser.parse(argv, strict: [prefix: :string, out: :string, check: :boolean])

    if roots == [] or opts[:prefix] == nil or opts[:out] == nil,
      do:
        Mix.raise("usage: mix dextrin.gen.elixir SCHEMAS... --prefix MODULE --out DIR [--check]")

    gen_opts = [prefix: opts[:prefix], out: opts[:out]]

    if opts[:check] do
      case Gen.check(roots, gen_opts) do
        :ok -> Mix.shell().info("OK: the generated modules are up to date")
        {:error, problems} -> Mix.raise(Enum.join(problems, "\n"))
      end
    else
      case Gen.write(roots, gen_opts) do
        {:ok, written} -> Enum.each(written, &Mix.shell().info("wrote #{&1}"))
        {:error, problems} -> Mix.raise(Enum.join(problems, "\n"))
      end
    end
  end
end
