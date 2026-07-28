defmodule Dextrin.Schema.Compiler do
  @moduledoc """
  Compiles a parsed `.dxns` document (an ordinary decoded DXN value,
  DESIGN.md §4.4) into `Dextrin.Schema.Compiled` entries.

  `%schema{}`/`%field{}` are recognized here directly, as
  `Dextrin.Struct{name: "schema" | "field"}` opaque shapes straight out
  of `Dextrin.decode/1` — they're never looked up in a registry, the
  same way built-in tags are recognized by name in
  `Dextrin.Text.Actions` rather than registered (§4.4's bootstrapping
  note: parsing `.dxns` can't itself depend on a compiled schema).

  An entry whose value *isn't* a `%schema{}` is a **named type**
  (DESIGN.md §4.4.1) instead: a reusable name for some combination of
  the fixed type_expr vocabulary, e.g. `PositiveInt: {:refine :integer
  {min: 1}}`. Purely data — no Elixir code, no registry callback — so
  any conformant reader in any language can resolve it the same way it
  already resolves `refine`/`list-of`/etc.
  """

  alias Dextrin.{Keyword, OrderedMap, Registry, Struct, Symbol, Tuple}
  alias Dextrin.Schema.{Compiled, Field}

  @primitives ~w(nil boolean integer float decimal rational string char symbol keyword
                 list tuple map ordered-map set sorted-set array
                 date time timestamp datetime duration uuid uri bytes regex)

  @doc """
  Compiles every entry of a decoded `.dxns` document into
  `base_registry` — a struct schema for each `%schema{}` entry, a
  named type_expr (§4.4.1) for every other entry. `predicates`
  resolves `refine-fn:` names (DESIGN.md §4.4.4) — a plain map, not
  the struct registry itself, since a refine-fn is a validity check,
  not a decoder.

  Named types defined in *this* document may reference any type
  already known to `base_registry` (from an earlier `compile/3` call),
  but not one declared alongside them in the same document — `.dxns`'s
  own map type has no ordering guarantee to resolve forward references
  against, and no real usage yet justifies the dependency-resolution
  machinery a same-document case would need. A schema's *fields*,
  compiled afterwards, can freely use any named type from either source.
  """
  @spec compile(term(), Dextrin.Registry.t(), %{optional(String.t()) => Compiled.refine_fn()}) ::
          {:ok, Dextrin.Registry.t()} | {:error, term()}
  def compile(schema_doc, base_registry, predicates \\ %{}) when is_map(schema_doc) do
    named_entries = Enum.map(schema_doc, fn {k, v} -> {entry_name(k), v} end)
    {schema_entries, alias_entries} = Enum.split_with(named_entries, fn {_name, v} -> match?(%Struct{name: "schema"}, v) end)

    with {:ok, registry} <- compile_aliases(alias_entries, base_registry) do
      Enum.reduce_while(schema_entries, {:ok, registry}, fn {name, entry}, {:ok, registry} ->
        case compile_entry(entry, predicates, registry.type_aliases) do
          {:ok, %Compiled{} = compiled} ->
            {:cont, {:ok, Registry.put_struct_schema(registry, name, %{compiled | name: name})}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)
    end
  end

  defp compile_aliases(alias_entries, registry) do
    # `base_aliases` is a frozen snapshot, not the accumulating
    # `registry` — every alias in *this* document resolves Symbols
    # against only what base_registry already knew, never against a
    # sibling compiled earlier in the same reduce. A plain map has no
    # ordering guarantee (DXN.md), so accumulating as we went would
    # make cross-alias visibility depend on Elixir's arbitrary map
    # iteration order instead of being a deterministic yes-or-no.
    base_aliases = registry.type_aliases

    Enum.reduce_while(alias_entries, {:ok, registry}, fn {name, raw_value}, {:ok, registry} ->
      case compile_type_expr(raw_value, base_aliases) do
        {:ok, type_expr} -> {:cont, {:ok, Registry.put_type_alias(registry, name, type_expr)}}
        {:error, reason} -> {:halt, {:error, "named type #{inspect(name)}: #{reason}"}}
      end
    end)
  end

  defp entry_name(%Keyword{name: name}), do: name
  defp entry_name(%Symbol{name: name}), do: name
  defp entry_name(name) when is_binary(name), do: name

  defp compile_entry(%Struct{name: "schema", fields: {:keyed, pairs}}, predicates, aliases) do
    fields_value = get(pairs, "fields")
    closed = get(pairs, "closed", false)
    forbidden = get(pairs, "forbidden", []) |> Enum.map(&literal_name/1)
    refine_fn_name = get(pairs, "refine-fn")

    with {:ok, fields} <- compile_fields(fields_value, aliases),
         {:ok, refine_fn} <- resolve_refine_fn(refine_fn_name, predicates) do
      {:ok, %Compiled{fields: fields, closed: closed, forbidden: forbidden, refine_fn: refine_fn}}
    end
  end

  defp compile_entry(other, _predicates, _aliases) do
    {:error, "expected a %schema{} entry, got #{inspect(other)}"}
  end

  defp compile_fields(%OrderedMap{pairs: pairs}, aliases) do
    Enum.reduce_while(pairs, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case compile_field(key, value, aliases) do
        {:ok, field} -> {:cont, {:ok, [field | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp compile_fields(other, _aliases) do
    {:error, "expected fields: to be an @ordered %{...} (field order is load-bearing for .dxnb, DESIGN.md §4.4.2), got #{inspect(other)}"}
  end

  defp compile_field(%Keyword{name: raw_name}, value, aliases) do
    {name, required} =
      if String.ends_with?(raw_name, "?"), do: {String.trim_trailing(raw_name, "?"), false}, else: {raw_name, true}

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

  # ---- type expressions (DESIGN.md §4.4.1) -----------------------------------

  defp compile_type_expr(%Keyword{name: "any"}, _aliases), do: {:ok, :any}
  defp compile_type_expr(:any_keyword, _aliases), do: {:ok, :any}
  defp compile_type_expr(%Keyword{name: name}, _aliases) when name in @primitives, do: {:ok, {:primitive, name}}

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
    with {:ok, kt} <- compile_type_expr(key_type, aliases), {:ok, vt} <- compile_type_expr(val_type, aliases) do
      {:ok, {:map_of, kt, vt}}
    end
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "enum"} | literals]}, _aliases), do: {:ok, {:enum, literals}}

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "one-of"} | elems]}, aliases) do
    with {:ok, ts} <- map_compile(elems, aliases), do: {:ok, {:one_of, ts}}
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "all-of"} | elems]}, aliases) do
    with {:ok, ts} <- map_compile(elems, aliases), do: {:ok, {:all_of, ts}}
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "nilable"}, elem]}, aliases) do
    with {:ok, t} <- compile_type_expr(elem, aliases), do: {:ok, {:nilable, t}}
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "refine"}, elem, constraints]}, aliases) when is_map(constraints) do
    with {:ok, t} <- compile_type_expr(elem, aliases) do
      {:ok, {:refine, t, Map.new(constraints, fn {%Keyword{name: k}, v} -> {k, v} end)}}
    end
  end

  defp compile_type_expr(other, _aliases), do: {:error, "unrecognized type expression: #{inspect(other)}"}

  defp map_compile(values, aliases) do
    Enum.reduce_while(values, {:ok, []}, fn v, {:ok, acc} ->
      case compile_type_expr(v, aliases) do
        {:ok, t} -> {:cont, {:ok, [t | acc]}}
        {:error, _} = err -> {:halt, err}
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

  defp resolve_refine_fn(nil, _predicates), do: {:ok, nil}

  defp resolve_refine_fn(name_value, predicates) do
    name = literal_name(name_value)

    case Map.fetch(predicates, name) do
      {:ok, fun} -> {:ok, fun}
      :error -> {:error, "refine-fn #{inspect(name)} not found in the predicates given to compile/3"}
    end
  end
end
