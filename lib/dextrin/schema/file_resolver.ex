defmodule Dextrin.Schema.FileResolver do
  @moduledoc """
  An optional convenience `struct_resolver` resolving `Namespace/Name`
  references to `.dxns` files on disk.

  Composing multiple compiled schemas into one registry needs no
  special mechanism at all — `Dextrin.Schema.compile/3`'s
  `base_registry` parameter threads across repeated calls. What
  genuinely needs a policy decision is *automatically* resolving a
  bare `Namespace/Name` reference to a file path, and this module is
  *one* reasonable, swappable answer to that — not a mandated
  convention baked into `Dextrin.Registry`/`Dextrin.Schema` itself.
  Anyone with a different convention in mind writes their own
  `struct_resolver` function directly against `put_resolver/2`; this
  module exists only because the convention below is a common,
  unsurprising default, not because it's the only correct one.

  **Convention**: `Namespace/Name` resolves to `<search_path>/Namespace.dxns`,
  read for the specific entry named `Name` — a `.dxns` file is already
  a map of possibly-many schema names, so "Namespace" names the
  *file*, "Name" one schema defined inside it. A bare reference with
  no `/` (`Name`) resolves to `<search_path>/Name.dxns`, read for the
  entry also named `Name` — the same rule, just with the file and the
  entry sharing one name when there's no namespace to separate them.
  """

  @doc """
  Builds a `struct_resolver` searching `search_paths` in order,
  returning the first match. `predicates` is forwarded to
  `Dextrin.Schema.compile/3` for any `refine-fn:` the loaded files use.
  """
  @spec for_paths([Path.t()], %{optional(String.t()) => Dextrin.Schema.Compiled.refine_fn()}) ::
          Dextrin.Registry.struct_resolver()
  def for_paths(search_paths, predicates \\ %{}) when is_list(search_paths) do
    fn name ->
      {file_stem, entry_name} = split_name(name)
      Enum.find_value(search_paths, :unknown, &resolve_in(&1, file_stem, entry_name, predicates))
    end
  end

  defp resolve_in(dir, file_stem, entry_name, predicates) do
    path = Path.join(dir, "#{file_stem}.dxns")

    with true <- File.regular?(path),
         {:ok, source} <- File.read(path),
         {:ok, doc} <- Dextrin.decode(source),
         {:ok, registry} <- Dextrin.Schema.compile(doc, Dextrin.Registry.new(), predicates),
         {:ok, compiled, _registry} <- Dextrin.Registry.fetch_struct_schema(registry, entry_name) do
      {:ok, compiled}
    else
      _ -> nil
    end
  end

  defp split_name(name) do
    case String.split(name, "/", parts: 2) do
      [namespace, short_name] -> {namespace, short_name}
      [short_name] -> {short_name, short_name}
    end
  end
end
