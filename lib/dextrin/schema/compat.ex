defmodule Dextrin.Schema.Compat do
  @moduledoc """
  The version discipline check (DXNS.md §8): compares the schemas of a
  previous release with the current ones.

    * **A schema whose content changed must have a new version.** A
      version present in both whose fields differ -- a field added,
      removed, moved, or one whose type, requiredness or default changed
      -- is a problem: two documents claiming to be `User` v3 must mean
      the same thing.
    * **A version never goes down.** A schema whose latest version is
      lower than before is a problem.
    * **Informational: what the materializer has to upgrade.** For each
      schema, every older version still loaded beside the latest, with
      the fields the latest added, removed and changed since -- a
      checklist for the materializer's branches.

  There are no compatibility modes and no append-only rule: changing
  positions is allowed, and documented as what older readers misread
  (DXNS.md §8). A field's description is documentation, not content.
  CI runs this against the previous release's schema files
  (`mix dextrin.compat OLD NEW`).
  """

  alias Dextrin.Registry
  alias Dextrin.Schema.{Compiled, Field}

  @type problem ::
          %{schema: String.t(), version: pos_integer(), problem: :changed_without_new_version}
          | %{
              schema: String.t(),
              problem: :version_went_down,
              from: pos_integer(),
              to: pos_integer()
            }

  @type upgrade :: %{
          schema: String.t(),
          from: pos_integer(),
          to: pos_integer(),
          added: [String.t()],
          removed: [String.t()],
          changed: [String.t()]
        }

  @doc """
  `old`'s schemas against `new`'s: the problems, and the upgrade
  checklist for `new`, each sorted by schema name and version.
  """
  @spec check(Registry.t(), Registry.t()) :: %{problems: [problem()], upgrades: [upgrade()]}
  def check(%Registry{structs: old}, %Registry{structs: new}) do
    %{problems: problems(old, new), upgrades: upgrades(new)}
  end

  defp problems(old, new) do
    for {name, new_versions} <- Enum.sort(new),
        {:ok, old_versions} <- [Map.fetch(old, name)],
        problem <-
          changed(name, old_versions, new_versions) ++ went_down(name, old_versions, new_versions),
        do: problem
  end

  defp changed(name, old_versions, new_versions) do
    for {version, compiled} <- Enum.sort(new_versions),
        {:ok, before} <- [Map.fetch(old_versions, version)],
        shape(before) != shape(compiled),
        do: %{schema: name, version: version, problem: :changed_without_new_version}
  end

  defp went_down(name, old_versions, new_versions) do
    from = latest(old_versions)
    to = latest(new_versions)

    if to < from,
      do: [%{schema: name, problem: :version_went_down, from: from, to: to}],
      else: []
  end

  defp upgrades(new) do
    for {name, versions} <- Enum.sort(new),
        to = latest(versions),
        {from, older} <- Enum.sort(versions),
        from < to,
        do: upgrade(name, from, older, to, Map.fetch!(versions, to))
  end

  defp upgrade(name, from, %Compiled{} = older, to, %Compiled{} = latest) do
    before = Map.new(older.fields, &{&1.name, field_shape(&1)})
    now = Map.new(latest.fields, &{&1.name, field_shape(&1)})

    %{
      schema: name,
      from: from,
      to: to,
      added: for(%Field{name: n} <- latest.fields, not Map.has_key?(before, n), do: n),
      removed: for(%Field{name: n} <- older.fields, not Map.has_key?(now, n), do: n),
      changed:
        for(
          %Field{name: n} <- latest.fields,
          Map.has_key?(before, n) and before[n] != now[n],
          do: n
        )
    }
  end

  defp latest(versions), do: versions |> Map.keys() |> Enum.max()

  # What a schema's content is, for this check: its fields in order.
  defp shape(%Compiled{fields: fields}), do: Enum.map(fields, &{&1.name, field_shape(&1)})

  defp field_shape(%Field{required: required, type: type, default: default}),
    do: {required, type, default}
end
