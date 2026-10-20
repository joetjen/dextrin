defmodule Mix.Tasks.Dextrin.Check do
  @moduledoc """
  Checks a tree of `.dxns` schemas (`Dextrin.Schema.Tree`): every file
  under `SCHEMAS` -- files or directories, searched recursively -- read,
  every entry named from its path (DXN.md §4.6) and compiled in the order
  its references need. Every problem is printed as `file:line: message`
  and the task exits non-zero, so CI can run it:

      $ mix dextrin.check schemas/
      $ mix dextrin.check schemas/ --extern google.protobuf

  A name that resolves to nothing in the tree is a problem, unless its
  namespace is given with `--extern` (repeatable): names another tree or
  a provider supplies.
  """

  use Mix.Task

  @shortdoc "Checks a tree of .dxns schemas: syntax, compiling, layout and names"

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: [extern: :keep])

    case args do
      [] -> Mix.raise("usage: mix dextrin.check SCHEMAS... [--extern NAMESPACE]...")
      roots -> check(roots, Elixir.Keyword.get_values(opts, :extern))
    end
  end

  defp check(roots, extern) do
    case Dextrin.Schema.Tree.load(roots, extern: extern) do
      {:ok, _registry, %{files: files, definitions: definitions}} ->
        Mix.shell().info("OK: #{files} files, #{definitions} definitions")

      {:error, problems} ->
        Enum.each(problems, &Mix.shell().error("#{&1.file}:#{&1.line}: #{&1.message}"))
        Mix.raise("#{length(problems)} problem(s)")
    end
  end
end
