defmodule Dextrin.Schema.FileResolver do
  @moduledoc """
  A `struct_resolver` finding a struct's schema in `.dxns` files on disk,
  by the convention DXN.md §4.6 states for every implementation -- so one
  set of schema files serves them all. Swappable like any resolver
  (`Dextrin.Registry.put_resolver/2`): anyone with another convention
  writes their own.

  **The convention.** A name is segments joined by `.`, with at most one
  `/` between a namespace and a name (`Foo.Bar/Baz`); every segment is a
  directory but the last, which names the file. A schema of version `N`
  named `Foo.Bar/Baz` is looked for, on each search path in order, in

  | layout | version 1 | version N |
  |---|---|---|
  | directories | `Foo/Bar/Baz.dxns`, `Foo/Bar/Baz-v1.dxns` | `Foo/Bar/Baz-vN.dxns` |
  | a directory per name | `Foo/Bar/Baz/v1.dxns` | `Foo/Bar/Baz/vN.dxns` |
  | flat | `Foo.Bar.Baz.dxns`, `Foo.Bar.Baz-v1.dxns` | `Foo.Bar.Baz-vN.dxns` |
  | the namespace file | the entry `Baz` in `Foo.Bar.dxns` | the same, by its `%schema(N)` |

  and a name with no `/` is its own namespace: `Money` in `Money.dxns`.

  - **The first search path that has the name at all decides.**
  - **A file's version is its schema's**: `Baz-v2.dxns` holds `Baz` as
    `%schema(2)`, or is refused (`schema/compile`).
  - **One version is found once**: two files holding the same version
    are refused, naming both, rather than one being picked.
  - **Every version found is loaded**, so that a struct written with an
    older one reaches the materializer.
  """

  @doc """
  A `struct_resolver` searching `search_paths` in order.
  """
  @spec for_paths([Path.t()]) :: Dextrin.Registry.struct_resolver()
  def for_paths(search_paths) when is_list(search_paths) do
    fn name -> Enum.find_value(search_paths, :unknown, &in_path(&1, name)) end
  end

  # What `dir` holds for `name`: nil when it holds nothing, so the next
  # search path is asked; otherwise every version found, or why they
  # cannot be used.
  defp in_path(dir, name) do
    {entry, candidates} = candidates(dir, name)

    found =
      Enum.flat_map(candidates, fn {path, expected} -> load(path, entry, expected, dir, name) end)

    case Enum.find(found, &match?({:error, _}, &1)) do
      {:error, error} -> {:error, error}
      nil when found == [] -> nil
      nil -> distinct(name, found)
    end
  end

  # The entry a file holds the schema under -- the name after its `/`,
  # or the whole name when it has none -- and every file that may hold
  # it, each with the version its name says (`:any` for the namespace
  # file, which holds whichever its `%schema(N)` says).
  defp candidates(dir, name) do
    {namespace, entry} =
      case String.split(name, "/", parts: 2) do
        [namespace, entry] -> {namespace, entry}
        [entry] -> {nil, entry}
      end

    segments = String.split(name, ["/", "."])
    stem = List.last(segments)
    nested = Path.join([dir | Enum.drop(segments, -1)])
    flat = Path.join(dir, Enum.join(segments, "."))

    versioned =
      [{Path.join(nested, stem <> ".dxns"), 1}, {flat <> ".dxns", 1}] ++
        numbered(Path.join(nested, stem <> "-v*.dxns"), ~r/-v(\d+)\.dxns$/) ++
        numbered(Path.join([nested, stem, "v*.dxns"]), ~r/v(\d+)\.dxns$/) ++
        numbered(flat <> "-v*.dxns", ~r/-v(\d+)\.dxns$/)

    namespace_file = {Path.join(dir, (namespace || entry) <> ".dxns"), :any}

    # One path, one candidate: a name without a namespace is both its own
    # version-1 file and its namespace file, and is read as the latter.
    candidates =
      [namespace_file | versioned]
      |> Enum.uniq_by(fn {path, _expected} -> Path.expand(path) end)

    {entry, candidates}
  end

  # The files matching `pattern`, each with the version its name carries.
  defp numbered(pattern, version_in_name) do
    for path <- Path.wildcard(pattern),
        [_, digits] <- [Regex.run(version_in_name, path)],
        version = String.to_integer(digits),
        version > 0,
        do: {path, version}
  end

  # The versions of `entry` in the file at `path`: `[{version, compiled,
  # path}]`, `[]` when the file is not there or holds no such entry, or
  # `[{:error, why}]`.
  #
  # The file is compiled as a tree compiles it (`Dextrin.Schema.Tree`):
  # its entries under their full names (DXN.md §4.6), over the named
  # types the rest of its search path defines -- so a field naming
  # another file's shape or named type resolves.
  defp load(path, entry, expected, dir, name) do
    with true <- File.regular?(path),
         {:ok, source} <- File.read(path),
         {:ok, doc} <- Dextrin.decode(source),
         names = file_names(doc, Path.relative_to(path, dir)),
         base = %{Dextrin.Registry.new() | type_aliases: Dextrin.Schema.Tree.named_types([dir])},
         {:ok, registry} <- Dextrin.Schema.compile(doc, base, names) do
      versions = Map.get(registry.structs, name, Map.get(registry.structs, entry, %{}))
      checked(path, entry, expected, versions)
    else
      false ->
        []

      {:error, %Dextrin.Error{} = error} ->
        [{:error, %{error | message: "#{path}: #{error.message}"}}]

      {:error, reason} ->
        [{:error, refusal("#{path}: #{inspect(reason)}")}]
    end
  end

  defp file_names(doc, relative) when is_map(doc) and not is_struct(doc) do
    keys =
      Enum.map(Map.keys(doc), fn
        %Dextrin.Keyword{name: n} -> n
        %Dextrin.Symbol{name: n} -> n
        n when is_atom(n) -> Atom.to_string(n)
        n -> n
      end)

    Dextrin.Schema.Layout.of(relative, keys).names
  end

  defp file_names(_doc, _relative), do: %{}

  defp checked(_path, _entry, _expected, versions) when map_size(versions) == 0, do: []

  defp checked(path, _entry, :any, versions),
    do: Enum.map(versions, fn {version, compiled} -> {version, compiled, path} end)

  defp checked(path, entry, expected, versions) do
    case Map.keys(versions) do
      [^expected] ->
        [{expected, Map.fetch!(versions, expected), path}]

      found ->
        [
          {:error,
           refusal(
             "#{path} holds #{entry} as version #{Enum.join(found, ", ")}, " <>
               "but its name says version #{expected} (DXN.md §4.6)"
           )}
        ]
    end
  end

  # Every version once, each under the name it was asked for -- or the
  # first version two files both hold, naming them.
  defp distinct(name, found) do
    case found
         |> Enum.group_by(&elem(&1, 0))
         |> Enum.find(fn {_v, holders} -> length(holders) > 1 end) do
      nil ->
        {:ok, Enum.map(found, fn {_version, compiled, _path} -> %{compiled | name: name} end)}

      {version, holders} ->
        paths = holders |> Enum.map(&elem(&1, 2)) |> Enum.sort() |> Enum.join(" and ")

        {:error,
         refusal(
           "#{name} version #{version} is in two files, #{paths}; it is found once (DXN.md §4.6)"
         )}
    end
  end

  defp refusal(message), do: Dextrin.Error.action(message, "schema/compile")
end
