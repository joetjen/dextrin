defmodule Dextrin.Schema.Deprecations do
  @moduledoc """
  Warnings for what is deprecated (G10 of design/typespec.md, Jan,
  2026-11-17; DXNS.md §1b): "mark Schemas in Dextrin as deprecated, and
  generate a warning when they are used", one version of a schema as
  well as the whole schema.

  `deprecated: true | "why"` stands on a version of a schema, a named
  type, a field's type, a union variant, or an enum value (`values:`).
  It warns in two places:

    * **when a schema compiles** against something deprecated -- a
      field naming a deprecated schema or named type, a base, or a base
      pinned to a deprecated version (`includes Pet(1)`). The registry
      keeps those warnings (`Dextrin.Registry.warnings/1`). Something
      deprecated naming something deprecated stays silent.
    * **when data goes through it**, decoding or encoding: a struct
      written with a deprecated version, or of a schema whose latest
      version is deprecated, and a value accepted through a deprecated
      type, variant or enum value.

  The registry's `deprecations:` says how often data warns -- `:once`
  per registry and deprecated thing (the default), `:every` time,
  `:off`, or `:error`, which refuses the data (`schema/deprecated`).
  `on_deprecated:` receives each warning in place of `Logger.warning`.

  "Once" outlives a single decode: the registry holds an `:atomics`
  array, one slot per deprecated thing, given out when its schema
  compiles. An `:atomics` array lives as long as something refers to it,
  so the state goes away with the registry, and no process owns it.
  """

  alias Dextrin.Registry
  alias Dextrin.Schema.Compiled

  require Logger

  @category "schema/deprecated"

  @typedoc """
  One warning: what is deprecated (`name` and `version` where it has
  them), the reason it gives (`nil` for `deprecated: true`), its
  category, and, at compile time, the schema or type that uses it.
  """
  @type warning :: %{
          name: String.t() | nil,
          version: pos_integer() | nil,
          message: String.t() | nil,
          category: String.t(),
          at: String.t() | nil
        }

  @typedoc "What a slot is kept for."
  @type key ::
          {:schema, String.t(), pos_integer()}
          | {:node, non_neg_integer()}
          | {:value, non_neg_integer(), term()}

  @doc "The category of every deprecation warning, and of the error `:error` makes of one."
  @spec category() :: String.t()
  def category, do: @category

  @doc """
  Whether `notes`, an annotation map, deprecates what it stands on:
  `{:deprecated, why}`, `why` the reason or `nil`, or `:none`.
  """
  @spec reason(map()) :: {:deprecated, String.t() | nil} | :none
  def reason(%{"deprecated" => why}) when is_binary(why), do: {:deprecated, why}
  def reason(%{"deprecated" => true}), do: {:deprecated, nil}
  def reason(_notes), do: :none

  @doc "A warning about `name` at `version`, for `why`."
  @spec warning(String.t() | nil, pos_integer() | nil, String.t() | nil, String.t() | nil) ::
          warning()
  def warning(name, version, why, at \\ nil),
    do: %{name: name, version: version, message: why, category: @category, at: at}

  # ---- data going through it ----------------------------------------------------

  @doc """
  A struct of `name` written with `version` (`nil`: the latest) has
  been read or checked: a warning for that version when it is
  deprecated, and for the latest when that is -- the whole schema.
  `:ok`, or the error `deprecations: :error` makes of the first.
  """
  @spec struct_used(Registry.t(), String.t(), pos_integer() | nil) ::
          :ok | {:error, Dextrin.Error.t()}
  def struct_used(%Registry{deprecations: :off}, _name, _version), do: :ok

  def struct_used(%Registry{} = registry, name, version) do
    with {:ok, %Compiled{version: latest}, _} <- Registry.fetch_struct_schema(registry, name) do
      [version || latest, latest]
      |> Enum.uniq()
      |> Enum.reduce_while(:ok, fn at, :ok ->
        case version_used(registry, name, at) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      _unknown -> :ok
    end
  end

  defp version_used(registry, name, version) do
    with {:ok, %Compiled{annotations: notes}, _} <-
           Registry.fetch_struct_schema(registry, name, version),
         {:deprecated, why} <- reason(notes) do
      used(registry, {:schema, name, version}, warning(name, version, why))
    else
      _ -> :ok
    end
  end

  @doc """
  A value went through `node`, a `{:doc type notes}` that deprecates
  what it stands on, or through `literal`, one of its deprecated enum
  values: reported as the registry says.
  """
  @spec node_used(Registry.t() | nil, tuple(), term(), map()) :: :ok | {:error, Dextrin.Error.t()}
  def node_used(%Registry{deprecations: deprecations} = registry, node, conformed, notes)
      when deprecations != :off do
    with :ok <- whole_node(registry, node, notes) do
      enum_value(registry, node, conformed, notes)
    end
  end

  def node_used(_registry, _node, _conformed, _notes), do: :ok

  defp whole_node(registry, node, notes) do
    case reason(notes) do
      {:deprecated, why} ->
        used(registry, {:node, :erlang.phash2(node)}, warning(notes["title"], nil, why))

      :none ->
        :ok
    end
  end

  defp enum_value(registry, node, conformed, %{"values" => values}) when is_map(values) do
    case Enum.find(values, fn {literal, _notes} -> same_literal?(literal, conformed) end) do
      {literal, value_notes} when is_map(value_notes) ->
        case reason(value_notes) do
          {:deprecated, why} ->
            key = {:value, :erlang.phash2(node), literal}
            used(registry, key, warning(nil, nil, why))

          :none ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp enum_value(_registry, _node, _conformed, _notes), do: :ok

  # An enum value's annotation is keyed by the literal as written; the
  # value may be a keyword or, decoded trusted, an atom.
  defp same_literal?(literal, value), do: plain(literal) == plain(value)

  defp plain(%Dextrin.Keyword{name: name}), do: {:keyword, name}

  defp plain(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: {:keyword, Atom.to_string(atom)}

  defp plain(other), do: other

  # One use of the deprecated thing `key`, reported as the registry says.
  defp used(%Registry{deprecations: :error}, _key, warning),
    do: {:error, Dextrin.Error.action(text(warning), @category)}

  defp used(%Registry{deprecations: :every} = registry, _key, warning),
    do: report(registry, warning)

  defp used(%Registry{} = registry, key, warning) do
    if first_use?(registry, key), do: report(registry, warning), else: :ok
  end

  # A thing with no slot -- a generic's use, filled in when it is
  # checked -- warns each time rather than never.
  defp first_use?(%Registry{deprecation_slots: slots, deprecation_seen: seen}, key) do
    case Map.fetch(slots, key) do
      {:ok, index} when seen != nil -> :atomics.compare_exchange(seen, index, 0, 1) == :ok
      _no_slot -> true
    end
  end

  defp report(%Registry{on_deprecated: fun}, warning) when is_function(fun, 1) do
    fun.(warning)
    :ok
  end

  defp report(_registry, warning) do
    Logger.warning(text(warning), dextrin_deprecated: warning.name, category: @category)
    :ok
  end

  @doc "A warning in words."
  @spec text(warning()) :: String.t()
  def text(%{name: name, version: version, message: why, at: at}) do
    what =
      case {name, version} do
        {nil, _} -> "a deprecated type or value"
        {name, nil} -> name
        {name, version} -> "#{name}(#{version})"
      end

    used = if at, do: "#{at} uses #{what}, which is deprecated", else: "#{what} is deprecated"
    if why, do: used <> ": " <> why, else: used
  end

  # ---- compiling ------------------------------------------------------------------

  @doc """
  `registry` with a slot for each deprecated thing `item` holds -- a
  schema version (`Compiled`) or a named type's definition -- the
  slots it had keeping theirs and what they have seen. Called as each
  is put in the registry, so one loaded later by a resolver has its
  slots too.
  """
  @spec slotted(Registry.t(), Compiled.t() | term()) :: Registry.t()
  def slotted(%Registry{deprecation_slots: slots, deprecation_seen: seen} = registry, item) do
    case item |> keys() |> Enum.reject(&Map.has_key?(slots, &1)) |> Enum.uniq() do
      [] ->
        registry

      new ->
        slots = Enum.reduce(new, slots, fn key, acc -> Map.put(acc, key, map_size(acc) + 1) end)
        grown = :atomics.new(map_size(slots), signed: false)

        if seen do
          for index <- 1..:atomics.info(seen).size//1,
              do: :atomics.put(grown, index, :atomics.get(seen, index))
        end

        %{registry | deprecation_slots: slots, deprecation_seen: grown}
    end
  end

  defp keys(%Compiled{name: name, version: version, annotations: notes, fields: fields}) do
    own = if reason(notes) == :none, do: [], else: [{:schema, name, version}]
    own ++ Enum.flat_map(fields, &node_keys(&1.type))
  end

  defp keys(type), do: node_keys(type)

  @doc """
  The warnings compiling `entries` -- a document's `{name, raw}` entries
  as written, now in `registry` -- gives: each entry that is not itself
  deprecated and names something that is, by a type reference anywhere
  in its body or a base in its head, ordered by the entry's name. A
  reference never pins a version,
  so it warns when the latest is deprecated; a base pinned to a version
  (`includes Pet(1)`) warns when that one is. `names` maps a name as
  written to the name it was loaded under.
  """
  @spec compile_warnings(
          [{String.t(), term()}],
          %{optional(String.t()) => String.t()},
          Registry.t()
        ) ::
          [warning()]
  def compile_warnings(entries, names, %Registry{} = registry) do
    for {at, raw} <- Enum.sort_by(entries, &elem(&1, 0)),
        not deprecated_entry?(raw),
        {name, version} <- Enum.uniq(used_names(raw)),
        full = Map.get(names, name, name),
        full != at,
        {:deprecated, why, version} <- [deprecated_target(registry, full, version)],
        do: warning(full, version, why, at)
  end

  defp deprecated_entry?(%Dextrin.Tuple{items: [%Dextrin.Keyword{name: "doc"}, _inner, notes]})
       when is_map(notes),
       do:
         Enum.any?(notes, fn {key, value} ->
           plain(key) in [{:keyword, "deprecated"}, "deprecated"] and value not in [false, nil]
         end)

  defp deprecated_entry?(_raw), do: false

  # The names `raw` uses: every symbol in it, at no version, and each
  # base of a `%schema` or `%shape` head at the version it names.
  defp used_names(%Dextrin.Struct{bases: bases, fields: fields, rest: rest}) do
    rest_types = if rest, do: Tuple.to_list(rest), else: []

    Enum.map(bases, fn {_kind, base, version} -> {base, version} end) ++
      used_names(fields) ++ used_names(rest_types)
  end

  defp used_names(%Dextrin.Symbol{name: name}), do: [{name, nil}]
  # `Pet(1)`: the name at the version it pins.
  defp used_names(%Dextrin.Tuple{items: items} = tuple) do
    case Dextrin.Tuple.pinned(tuple) do
      {:ok, name, version} -> [{name, version}]
      :error -> Enum.flat_map(items, &used_names/1)
    end
  end

  defp used_names(%Dextrin.CustomTag{value: value}), do: used_names(value)

  defp used_names(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.flat_map(&used_names/1)

  defp used_names(list) when is_list(list), do: Enum.flat_map(list, &used_names/1)

  defp used_names(%{} = map) when not is_struct(map),
    do: Enum.flat_map(map, fn {key, value} -> used_names(key) ++ used_names(value) end)

  defp used_names(_leaf), do: []

  # Whether `name` at `version` (`nil`: the latest) is deprecated: a
  # schema's version, or a named type.
  defp deprecated_target(registry, name, version) do
    case Map.fetch(registry.structs, name) do
      {:ok, versions} when map_size(versions) > 0 ->
        at = version || versions |> Map.keys() |> Enum.max()

        with %Compiled{annotations: notes} <- Map.get(versions, at),
             {:deprecated, why} <- reason(notes) do
          {:deprecated, why, at}
        else
          _ -> :none
        end

      _ ->
        deprecated_type(registry, name, version)
    end
  end

  # A named type, at `version` when one is pinned (Way B): the version
  # in the warning only where the type has more than one.
  defp deprecated_type(registry, name, version) do
    versions = Map.get(registry.type_versions, name, %{})
    type = if version, do: Map.get(versions, version), else: Map.get(registry.type_aliases, name)
    shown = if map_size(versions) > 1, do: version || Enum.max(Map.keys(versions))

    notes =
      case type do
        {:doc, _type, notes} -> notes
        {:generic, _params, {:doc, _body, notes}} -> notes
        _ -> %{}
      end

    case reason(notes) do
      {:deprecated, why} -> {:deprecated, why, shown}
      :none -> :none
    end
  end

  # Every `{:doc}` in `type` that deprecates, and every deprecated enum
  # value it annotates, however deep.
  defp node_keys({:doc, inner, notes} = node) when is_map(notes) do
    own = if reason(notes) == :none, do: [], else: [{:node, :erlang.phash2(node)}]

    values =
      for {literal, value_notes} <- Map.get(notes, "values", %{}),
          is_map(value_notes),
          reason(value_notes) != :none,
          do: {:value, :erlang.phash2(node), literal}

    own ++ values ++ node_keys(inner)
  end

  defp node_keys(type) when is_tuple(type),
    do: type |> Tuple.to_list() |> Enum.flat_map(&node_keys/1)

  defp node_keys(types) when is_list(types), do: Enum.flat_map(types, &node_keys/1)
  defp node_keys(%Dextrin.Schema.Field{type: type}), do: node_keys(type)

  defp node_keys(%{} = map) when not is_struct(map),
    do: map |> Map.values() |> Enum.flat_map(&node_keys/1)

  defp node_keys(_leaf), do: []
end
