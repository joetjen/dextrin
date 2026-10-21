defmodule Mix.Tasks.Dextrin.Compat do
  @moduledoc """
  The version discipline check (`Dextrin.Schema.Compat`, DXNS.md §8):
  compares the schemas in `OLD` with those in `NEW`, each a `.dxns` file
  or a directory searched for them. A version whose content changed
  without a new version, or a version that went down, is reported and
  exits non-zero, so CI can run it against the previous release's schema
  files. What the latest version's materializer has to upgrade is listed
  either way.

      $ mix dextrin.compat schemas-v1.4.0/ schemas/
  """

  use Mix.Task

  alias Dextrin.Schema.Compat

  @shortdoc "Checks that schema changes come with new versions, and lists what to upgrade"

  @impl Mix.Task
  def run(argv) do
    case argv do
      [old, new] -> check(old, new)
      _ -> Mix.raise("usage: mix dextrin.compat OLD NEW (each a .dxns file or a directory)")
    end
  end

  defp check(old, new) do
    %{problems: problems, upgrades: upgrades} = Compat.check(loaded(old), loaded(new))

    for upgrade <- upgrades, do: Mix.shell().info(upgrade_line(upgrade))

    case problems do
      [] -> Mix.shell().info("OK: no version discipline problems")
      _ -> Mix.raise(Enum.map_join(problems, "\n", &problem_line/1))
    end
  end

  # Every .dxns document under `path`, compiled into one registry -- so
  # several versions of a schema, each in its own document, sit side by
  # side.
  defp loaded(path) do
    files =
      if File.dir?(path),
        do: Path.wildcard(Path.join(path, "**/*.dxns")) |> Enum.sort(),
        else: [path]

    Enum.reduce(files, Dextrin.Registry.new(), fn file, registry ->
      with {:ok, doc} <- Dextrin.decode(File.read!(file)),
           {:ok, registry} <- Dextrin.Schema.compile(doc, registry) do
        registry
      else
        {:error, error} -> Mix.raise("#{file}: #{Dextrin.Error.format(error)}")
      end
    end)
  end

  defp problem_line(%{schema: name, version: version, problem: :changed_without_new_version}),
    do: "#{name} version #{version} changed without a new version"

  defp problem_line(%{schema: name, problem: :version_went_down, from: from, to: to}),
    do: "#{name} went down from version #{from} to #{to}"

  defp upgrade_line(%{schema: name, from: from, to: to} = upgrade) do
    changes =
      [added: upgrade.added, removed: upgrade.removed, changed: upgrade.changed]
      |> Enum.reject(fn {_what, fields} -> fields == [] end)
      |> Enum.map_join("; ", fn {what, fields} -> "#{what} #{Enum.join(fields, ", ")}" end)

    "#{name} #{from} -> #{to}: " <> if(changes == "", do: "no field changes", else: changes)
  end
end
