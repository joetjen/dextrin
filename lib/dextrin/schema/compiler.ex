defmodule Dextrin.Schema.Compiler do
  @moduledoc """
  Compiles a parsed `.dxns` document (an ordinary decoded DXN value —
  a `.dxns` file is valid `.dxn`, no new grammar; what makes it a
  *schema* document is purely the shape of the value it parses to: a
  map from name to type expression) into `Dextrin.Schema.Compiled`
  entries.

  A struct schema is written `%schema(N){field: type, ...}` (DXN.md
  §4.4): the body lists the fields directly, and the order they are
  written in is the positional order `.dxnb` encodes them in. The header
  holds only the version; without one the schema is version 1. Each
  `.dxns` document describes one version of each schema it holds, and the
  registry keeps every version it is given (`Dextrin.Registry`).

  `%schema{}`/`%field{}` are recognized here directly, as
  `Dextrin.Struct{name: "schema" | "field"}` opaque shapes straight out
  of `Dextrin.decode/1` — they're never looked up in a registry, the
  same way built-in tags are recognized by name in
  `Dextrin.Text.Actions` rather than registered. This sidesteps an
  obvious bootstrapping question (doesn't parsing a `.dxns` file need
  a schema for its own `schema`/`field` structs?) the same way JSON
  Schema's own vocabulary is fixed tooling knowledge rather than
  itself validated against a schema.

  An entry whose value *isn't* a `%schema{}` is a **named type**
  instead: a reusable name for some combination of the fixed type_expr
  vocabulary, e.g. `PositiveInt: {:refine :integer {min: 1}}` — the
  same move Clojure's Malli makes with `[:map [:x :int]]`-style plain
  data instead of a bespoke schema DSL. Purely data — no Elixir code,
  no registry callback — so any conformant reader in any language can
  resolve it the same way it already resolves `refine`/`list-of`/etc.
  """

  alias Dextrin.{Keyword, OrderedMap, Registry, Struct, Symbol, Tuple}
  alias Dextrin.Schema.{Compiled, Field}
  alias Ichor.Toolkit.Result

  @primitives ~w(nil boolean integer float decimal rational string char symbol keyword
                 list tuple map ordered-map set sorted-set array
                 date time timestamp datetime duration uuid uri bytes bits regex)

  @doc """
  Compiles every entry of a decoded `.dxns` document into
  `base_registry` — a struct schema for each `%schema(N){}` entry, a
  named type_expr for every other entry.

  A schema version already in `base_registry` is an error
  (`schema/duplicate-version`); any other problem with the document is a
  `schema/compile` error. Replacing a loaded version on purpose is
  `Dextrin.Registry.replace_struct_schema/3`.

  Named types defined in *this* document may reference any type
  already known to `base_registry` (from an earlier `compile/3` call),
  but not one declared alongside them in the same document — `.dxns`'s
  own map type has no ordering guarantee to resolve forward references
  against, and no real usage yet justifies the dependency-resolution
  machinery a same-document case would need. A schema's *fields*,
  compiled afterwards, can freely use any named type from either source.
  """
  @spec compile(term(), Dextrin.Registry.t()) ::
          {:ok, Dextrin.Registry.t()} | {:error, Dextrin.Error.t()}
  # A plain map only: a struct (`%P{...}`, `@ordered %{...}`) and a tuple
  # are maps to `is_map/1` too, and crashed what follows (ASCO's report).
  def compile(schema_doc, base_registry) when is_map(schema_doc) and not is_struct(schema_doc) do
    schema_doc = atomize_back(schema_doc)
    named_entries = Enum.map(schema_doc, fn {k, v} -> {entry_name(k), v} end)

    {schema_entries, alias_entries} =
      Enum.split_with(named_entries, fn {_name, v} -> match?(%Struct{name: "schema"}, v) end)

    with {:ok, registry} <- compile_aliases(alias_entries, base_registry) do
      Result.reduce_ok(schema_entries, registry, fn {name, entry}, registry ->
        case compile_entry(entry, registry.type_aliases) do
          {:ok, %Compiled{} = compiled} ->
            Registry.add_struct_schema(registry, name, %{compiled | name: name})

          {:error, reason} ->
            {:error, compile_error("schema #{inspect(name)}: #{reason}")}
        end
      end)
    end
  end

  def compile(other, _base_registry),
    do: {:error, compile_error("a .dxns document is a map, got #{inspect(other)}")}

  defp compile_error(message), do: Dextrin.Error.action(message, "schema/compile")

  defp compile_aliases(alias_entries, registry) do
    # `base_aliases` is a frozen snapshot, not the accumulating
    # `registry` — every alias in *this* document resolves Symbols
    # against only what base_registry already knew, never against a
    # sibling compiled earlier in the same reduce. A plain map has no
    # ordering guarantee (DXN.md), so accumulating as we went would
    # make cross-alias visibility depend on Elixir's arbitrary map
    # iteration order instead of being a deterministic yes-or-no.
    base_aliases = registry.type_aliases

    Result.reduce_ok(alias_entries, registry, fn {name, raw_value}, registry ->
      case compile_type_expr(raw_value, base_aliases) do
        {:ok, type_expr} -> {:ok, Registry.put_type_alias(registry, name, type_expr)}
        {:error, reason} -> {:error, compile_error("named type #{inspect(name)}: #{reason}")}
      end
    end)
  end

  defp entry_name(%Keyword{name: name}), do: name
  defp entry_name(%Symbol{name: name}), do: name
  defp entry_name(name) when is_binary(name), do: name

  # This module's whole vocabulary (`entry_name/1`, `literal_name/1`,
  # every `compile_type_expr/2` clause matching a literal
  # `%Keyword{name: "list-of"}`/etc.) is written against
  # `Dextrin.Keyword` specifically — the shape `Dextrin.decode/2`
  # always produced before `trusted:` existed. `trusted: true` decodes the same `.dxns` text's keyword literals as
  # real atoms instead, which none of those patterns would match.
  # Rather than teaching every one of those clauses to also accept an
  # atom, `compile/3` normalizes the whole decoded document back to
  # `Dextrin.Keyword` once, up front — mirrors
  # `Dextrin.Schema.Validated.strip/1`'s exact recursive-walk shape,
  # whole-tree normalization instead of wrapper removal. A `.dxns`
  # document is schema *definition* syntax, not the untrusted end-user
  # data it describes, so this has nothing to do with whether the
  # schema's own source was itself decoded as trusted or not — the
  # compiler needs one canonical internal shape either way.
  defp atomize_back(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: Keyword.new(Atom.to_string(atom))

  defp atomize_back(list) when is_list(list), do: Enum.map(list, &atomize_back/1)

  defp atomize_back(%Tuple{items: items} = t), do: %{t | items: Enum.map(items, &atomize_back/1)}

  defp atomize_back(%Dextrin.Array{items: items} = a) do
    %{
      a
      | items:
          items |> :erlang.tuple_to_list() |> Enum.map(&atomize_back/1) |> :erlang.list_to_tuple()
    }
  end

  defp atomize_back(%OrderedMap{pairs: pairs} = om) do
    %{om | pairs: Enum.map(pairs, fn {k, v} -> {atomize_back(k), atomize_back(v)} end)}
  end

  defp atomize_back(%MapSet{} = set), do: set |> Enum.map(&atomize_back/1) |> MapSet.new()

  defp atomize_back(%Dextrin.SortedSet{items: items} = ss),
    do: %{ss | items: Enum.map(items, &atomize_back/1)}

  defp atomize_back(%Struct{fields: {:keyed, pairs}} = s) do
    %{s | fields: {:keyed, Enum.map(pairs, fn {k, v} -> {k, atomize_back(v)} end)}}
  end

  defp atomize_back(%Struct{fields: {:positional, items}} = s),
    do: %{s | fields: {:positional, Enum.map(items, &atomize_back/1)}}

  defp atomize_back(%Dextrin.CustomTag{value: value} = c), do: %{c | value: atomize_back(value)}

  defp atomize_back(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {k, v} -> {atomize_back(k), atomize_back(v)} end)

  defp atomize_back(other), do: other

  # `%schema(N){field: type, ...}`: the body is the fields, in the order
  # they are written; the header is the version, 1 when there is none.
  defp compile_entry(%Struct{name: "schema", version: version, fields: {:keyed, pairs}}, aliases) do
    with :ok <- not_format_1_0(pairs),
         {:ok, fields} <- compile_fields(pairs, aliases),
         :ok <- distinct_names(fields) do
      {:ok, %Compiled{version: version || 1, fields: fields}}
    end
  end

  defp compile_entry(%Struct{name: "schema", fields: {:positional, _}}, _aliases),
    do: {:error, "a schema lists its fields by name: %schema(N){field: type, ...}"}

  defp compile_entry(other, _aliases) do
    {:error, "expected a %schema(N){...} entry, got #{inspect(other)}"}
  end

  # A schema written in DXN 1.0's syntax -- `fields: @ordered %{...}`,
  # `closed: true`, `forbidden: [...]` -- says so, and what 1.1 writes
  # instead (DXN.md §4.4), rather than that a field has no known type.
  # Only those shapes: in 1.1 `fields`, `closed` and `forbidden` are
  # ordinary field names, whose values are type expressions.
  defp not_format_1_0(pairs) do
    old? =
      Enum.any?(pairs, fn
        {key, %Dextrin.OrderedMap{}} -> literal_name(key) == "fields"
        {key, flag} when is_boolean(flag) -> literal_name(key) == "closed"
        {key, list} when is_list(list) -> literal_name(key) == "forbidden"
        _ -> false
      end)

    if old?,
      do:
        {:error,
         "this is DXN 1.0's schema syntax (fields:, closed:, forbidden:); DXN 1.1 lists the fields " <>
           "directly, %schema(N){field: type, ...}, and refuses undeclared fields with strict: true (DXN.md §4.4)"},
      else: :ok
  end

  defp compile_fields(pairs, aliases) do
    Result.reduce_ok(pairs, [], fn {key, value}, acc ->
      case compile_field(literal_name(key), value, aliases) do
        {:ok, field} -> {:ok, [field | acc]}
        {:error, reason} -> {:error, "field #{inspect(literal_name(key))}: #{reason}"}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp distinct_names(fields) do
    case fields
         |> Enum.map(& &1.name)
         |> Enum.frequencies()
         |> Enum.find(fn {_, n} -> n > 1 end) do
      nil -> :ok
      {name, _} -> {:error, "field #{inspect(name)} is named twice"}
    end
  end

  defp compile_field(raw_name, value, aliases) when is_binary(raw_name) do
    {name, required} =
      if String.ends_with?(raw_name, "?"),
        do: {String.trim_trailing(raw_name, "?"), false},
        else: {raw_name, true}

    case value do
      %Struct{name: "field", fields: {:keyed, field_pairs}} ->
        with {:ok, type} <- compile_type_expr(get(field_pairs, "type", :any_keyword), aliases) do
          {:ok,
           %Field{
             name: name,
             required: required,
             type: type,
             default: get(field_pairs, "default", :none),
             description: get(field_pairs, "description")
           }}
        end

      type_expr_value ->
        with {:ok, type} <- compile_type_expr(type_expr_value, aliases) do
          {:ok, %Field{name: name, required: required, type: type}}
        end
    end
  end

  # ---- type expressions -------------------------------------------------------

  defp compile_type_expr(%Keyword{name: "any"}, _aliases), do: {:ok, :any}
  defp compile_type_expr(%Keyword{name: "never"}, _aliases), do: {:ok, :never}
  defp compile_type_expr(:any_keyword, _aliases), do: {:ok, :any}

  defp compile_type_expr(%Keyword{name: name}, _aliases) when name in @primitives,
    do: {:ok, {:primitive, name}}

  # `atomize_back/1` deliberately leaves `nil`/`true`/`false` alone
  # (converting them would corrupt a genuine `default: nil`/`true`
  # /`false` field value elsewhere in the same document) — but "nil"
  # is *also* one of `@primitives`' own names, and `Dextrin.Keyword`
  # unaffected, "nil" the primitive type name (`x: :nil`) and the bare
  # literal `nil` decode to the exact same Elixir value once `trusted:
  # true` is in play (`String.to_atom("nil") == nil`), so this one
  # primitive name needs its own clause rather than going through the
  # general atom-was-a-keyword path at all.
  defp compile_type_expr(nil, _aliases), do: {:ok, {:primitive, "nil"}}

  defp compile_type_expr(%Symbol{name: name}, aliases) do
    case Map.fetch(aliases, name) do
      {:ok, type_expr} -> {:ok, type_expr}
      :error -> {:ok, {:reference, name}}
    end
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "list-of"}, elem]}, aliases) do
    with {:ok, t} <- compile_type_expr(elem, aliases), do: {:ok, {:list_of, t}}
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "set-of"}, elem]}, aliases) do
    with {:ok, t} <- compile_type_expr(elem, aliases), do: {:ok, {:set_of, t}}
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "tuple-of"} | elems]}, aliases) do
    with {:ok, ts} <- map_compile(elems, aliases), do: {:ok, {:tuple_of, ts}}
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "map-of"}, key_type, val_type]}, aliases) do
    with {:ok, kt} <- compile_type_expr(key_type, aliases),
         {:ok, vt} <- compile_type_expr(val_type, aliases) do
      {:ok, {:map_of, kt, vt}}
    end
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "enum"} | literals]}, _aliases),
    do: {:ok, {:enum, literals}}

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "array-of"}, elem]}, aliases) do
    with {:ok, t} <- compile_type_expr(elem, aliases), do: {:ok, {:array_of, t}}
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "sorted-set-of"}, elem]}, aliases) do
    with {:ok, t} <- compile_type_expr(elem, aliases), do: {:ok, {:sorted_set_of, t}}
  end

  defp compile_type_expr(
         %Tuple{items: [%Keyword{name: "ordered-map-of"}, key_type, val_type]},
         aliases
       ) do
    with {:ok, kt} <- compile_type_expr(key_type, aliases),
         {:ok, vt} <- compile_type_expr(val_type, aliases) do
      {:ok, {:ordered_map_of, kt, vt}}
    end
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "one-of"} | elems]}, aliases) do
    with {:ok, ts} <- map_compile(elems, aliases), do: {:ok, {:one_of, ts}}
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "any-of"} | elems]}, aliases) do
    with {:ok, ts} <- map_compile(elems, aliases), do: {:ok, {:any_of, ts}}
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "not"}, elem]}, aliases) do
    with {:ok, t} <- compile_type_expr(elem, aliases), do: {:ok, {:not, t}}
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "all-of"} | elems]}, aliases) do
    with {:ok, ts} <- map_compile(elems, aliases), do: {:ok, {:all_of, ts}}
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "nilable"}, elem]}, aliases) do
    with {:ok, t} <- compile_type_expr(elem, aliases), do: {:ok, {:nilable, t}}
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "refine"}, elem, constraints]}, aliases)
       when is_map(constraints) do
    with {:ok, t} <- compile_type_expr(elem, aliases) do
      {:ok, {:refine, t, Map.new(constraints, fn {%Keyword{name: k}, v} -> {k, v} end)}}
    end
  end

  defp compile_type_expr(other, _aliases),
    do: {:error, "unrecognized type expression: #{inspect(other)}"}

  defp map_compile(values, aliases) do
    Result.reduce_ok(values, [], fn v, acc ->
      case compile_type_expr(v, aliases) do
        {:ok, t} -> {:ok, [t | acc]}
        {:error, _} = err -> err
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  # ---- helpers -------------------------------------------------------------

  defp get(pairs, key, default \\ nil) do
    case Enum.find(pairs, fn {k, _v} -> literal_name(k) == key end) do
      {_k, v} -> v
      nil -> default
    end
  end

  defp literal_name(%Keyword{name: name}), do: name
  defp literal_name(%Symbol{name: name}), do: name
  defp literal_name(name) when is_binary(name), do: name
end
