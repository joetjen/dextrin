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
  alias Dextrin.Schema.{Compiled, Field, TypeExpr}
  alias Ichor.Toolkit.Result

  # The scope key the document's names travel under (see compile/3).
  @names :"$names"

  # A refine's keys whose argument is a type, compiled and resolved as
  # its base is.
  @type_keys ~w(contains content encodes encodes-seq)

  @primitives ~w(nil boolean integer float decimal rational string char symbol keyword
                 list tuple map ordered-map set sorted-set array
                 date time datetime local-datetime duration uuid objectid ip uri bytes bits regex)

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
  @spec compile(term(), Dextrin.Registry.t(), %{String.t() => String.t()}) ::
          {:ok, Dextrin.Registry.t()} | {:error, Dextrin.Error.t()}
  #
  # `names` maps an entry's key to the name it is registered under -- a
  # tree's full names (DXN.md §4.6, `Dextrin.Schema.Layout`); a bare
  # symbol naming a sibling resolves to the sibling's full name. It
  # travels in the scope under `@names`, beside the named types.
  #
  # A plain map only: a struct (`%P{...}`, `@ordered %{...}`) and a tuple
  # are maps to `is_map/1` too, and crashed what follows (ASCO's report).
  def compile(schema_doc, base_registry, names \\ %{})

  def compile(schema_doc, base_registry, names)
      when is_map(schema_doc) and not is_struct(schema_doc) do
    schema_doc = atomize_back(schema_doc)

    named_entries =
      Enum.map(schema_doc, fn {k, v} ->
        name = entry_name(k)
        {Map.get(names, name, name), v}
      end)

    {schema_entries, alias_entries} =
      Enum.split_with(named_entries, fn {_name, v} ->
        match?(%Struct{name: "schema"}, undoc(v))
      end)

    with {:ok, registry} <- compile_aliases(alias_entries, base_registry, names) do
      Result.reduce_ok(schema_entries, registry, fn {name, entry}, registry ->
        case compile_entry(entry, Map.put(registry.type_aliases, @names, names)) do
          {:ok, %Compiled{} = compiled} ->
            Registry.add_struct_schema(registry, name, %{compiled | name: name})

          {:error, reason} ->
            {:error, compile_error("schema #{inspect(name)}: #{reason}")}
        end
      end)
    end
  end

  def compile(other, _base_registry, _names),
    do: {:error, compile_error("a .dxns document is a map, got #{inspect(other)}")}

  defp compile_error(message), do: Dextrin.Error.action(message, "schema/compile")

  # Every named type in a document sees every other (design/
  # shapes-and-case.md, DXN.md §4.5): each is compiled with its siblings
  # standing as `{:named, name}`, and those are put in place once all
  # are read -- so the order of a map's entries, which DXN does not
  # give, never matters. A named type may reach itself only through a
  # guard -- a field, or a collection's elements (Jan, 2026-10-20) --
  # and there the reference stays by name, looked up when it is checked.
  defp compile_aliases(alias_entries, registry, names) do
    siblings = Map.new(alias_entries, fn {name, _} -> {name, {:named, name}} end)
    scope = registry.type_aliases |> Map.merge(siblings) |> Map.put(@names, names)

    with {:ok, compiled} <-
           Result.reduce_ok(alias_entries, %{}, fn {name, raw_value}, acc ->
             case compile_named(name, raw_value, scope) do
               {:ok, type_expr} ->
                 {:ok, Map.put(acc, name, type_expr)}

               {:error, reason} ->
                 {:error, compile_error("named type #{inspect(name)}: #{reason}")}
             end
           end),
         :ok <- guarded(compiled) do
      known = Map.merge(registry.type_aliases, compiled)

      Result.reduce_ok(alias_entries, registry, fn {name, _}, registry ->
        case entry_resolved(Map.fetch!(compiled, name), known, [name]) do
          {:ok, type_expr} -> {:ok, Registry.put_type_alias(registry, name, type_expr)}
          {:error, reason} -> {:error, compile_error("named type #{inspect(name)}: #{reason}")}
        end
      end)
    end
  end

  # Every cycle among `compiled`'s named types passes a guard: a field
  # of a shape, or a collection's elements, so that each step of a
  # check reads a smaller part of the value. A cycle with none --
  # `A: {:nilable A}` -- describes no value and would never finish.
  defp guarded(compiled) do
    edges = Map.new(compiled, fn {name, type} -> {name, unguarded_names(type)} end)

    case Enum.find_value(Enum.sort(Map.keys(edges)), &unguarded_cycle(&1, edges, [])) do
      nil ->
        :ok

      cycle ->
        {:error,
         compile_error(
           "named type #{inspect(hd(cycle))}: reaches itself with no field or collection " <>
             "between (#{Enum.join(cycle, " -> ")}); it describes no value"
         )}
    end
  end

  # The cycle back to the first of `path` through unguarded references,
  # or nil.
  defp unguarded_cycle(name, edges, path) do
    cond do
      path != [] and name == List.last(path) ->
        Enum.reverse([name | path])

      name in path ->
        nil

      true ->
        Enum.find_value(Map.get(edges, name, []), &unguarded_cycle(&1, edges, [name | path]))
    end
  end

  # The named types `type` refers to without a guard on the way.
  defp unguarded_names({:named, name}), do: [name]

  defp unguarded_names({form, types}) when form in [:one_of, :any_of, :all_of],
    do: Enum.flat_map(types, &unguarded_names/1)

  defp unguarded_names({form, type}) when form in [:not, :nilable], do: unguarded_names(type)
  defp unguarded_names({:refine, type, _}), do: unguarded_names(type)
  defp unguarded_names({:doc, type, _}), do: unguarded_names(type)

  defp unguarded_names({:case, _field, branches, otherwise}),
    do: Enum.flat_map([otherwise | Enum.map(branches, &elem(&1, 1))], &unguarded_names/1)

  defp unguarded_names({:apply, name, args}), do: [name | Enum.flat_map(args, &unguarded_names/1)]
  defp unguarded_names({:generic, _params, body}), do: unguarded_names(body)
  defp unguarded_names(_guarded_or_leaf), do: []

  # Whether `name` is a generic taking `count` arguments.
  defp applies(name, count, known) do
    case Map.fetch(known, name) do
      {:ok, {:generic, params, _}} when length(params) == count ->
        :ok

      {:ok, {:generic, params, _}} ->
        {:error,
         "#{name} takes #{length(params)} type argument(s), {:of #{name} ...} gives #{count}"}

      {:ok, {:named, _}} ->
        :ok

      _ ->
        {:error, "{:of #{name} ...} names no generic"}
    end
  end

  defp takes_arguments(name, known) do
    {:generic, params, _} = Map.fetch!(known, name)
    "#{name} is generic: write {:of #{name} #{Enum.join(params, " ")}}, with a type for each"
  end

  # A shape carries its own name; every other named type is its type.
  defp compile_named(
         name,
         %Tuple{items: [%Keyword{name: "generic"}, params, body]},
         scope
       )
       when is_list(params) do
    with {:ok, names} <- parameter_names(params),
         scope = Map.merge(scope, Map.new(names, &{&1, {:param, &1}})),
         {:ok, body} <- compile_named(name, body, scope) do
      {:ok, {:generic, names, body}}
    end
  end

  # A named type's annotations wrap it whole: a generic keeps them on its
  # body, a shape takes the name as it would bare.
  defp compile_named(name, %Tuple{items: [%Keyword{name: "doc"}, inner, raw]}, scope) do
    with {:ok, compiled} <- compile_named(name, inner, scope) do
      case compiled do
        {:generic, params, body} ->
          with {:ok, notes} <- annotations(raw, body),
               do: {:ok, {:generic, params, {:doc, body, notes}}}

        type ->
          with {:ok, notes} <- annotations(raw, type), do: {:ok, {:doc, type, notes}}
      end
    end
  end

  defp compile_named(_name, %Struct{name: "schema"}, _scope),
    do:
      {:error,
       "a struct schema cannot be generic: a struct goes on the wire under its one name; " <>
         "make the generic a %shape, or give each use a schema of its own"}

  defp compile_named(name, raw_value, scope) do
    case compile_type_expr(raw_value, scope) do
      {:ok, {:shape, nil, fields}} -> {:ok, {:shape, name, fields}}
      other -> other
    end
  end

  # `{:generic [t ...] body}`'s parameters: distinct bare symbols.
  defp parameter_names(params) do
    names = Enum.map(params, fn p -> match?(%Symbol{}, p) && p.name end)

    cond do
      names == [] or false in names ->
        {:error, "a generic's parameters are symbols: {:generic [t ...] body}"}

      length(Enum.uniq(names)) != length(names) ->
        {:error, "a generic names a parameter twice"}

      true ->
        {:ok, names}
    end
  end

  # A named type's own definition resolved: a generic's body, with its
  # parameters left standing, or the type itself.
  defp entry_resolved({:generic, params, body}, known, path) do
    with {:ok, body} <- resolved(body, known, path), do: {:ok, {:generic, params, body}}
  end

  defp entry_resolved(type_expr, known, path), do: resolved(type_expr, known, path)

  # `type_expr` with every `{:named, name}` replaced by that named type,
  # `path` the names being resolved, so a cycle is seen.
  # A reference back to a type being resolved closes a cycle, which
  # `guarded/1` has passed: it stays a reference by name.
  defp resolved({:named, name} = reference, compiled, path) do
    cond do
      name in path ->
        {:ok, reference}

      match?({:generic, _, _}, Map.fetch!(compiled, name)) ->
        {:error, takes_arguments(name, compiled)}

      true ->
        resolved(Map.fetch!(compiled, name), compiled, [name | path])
    end
  end

  # `{:of Name type ...}` stays a use of the generic, its arguments
  # resolved; the generic's body is filled in when it is checked.
  defp resolved({:apply, name, args}, compiled, path) do
    with :ok <- applies(name, length(args), compiled),
         {:ok, args} <-
           Result.reduce_ok(args, [], fn arg, acc ->
             with {:ok, arg} <- resolved(arg, compiled, path), do: {:ok, [arg | acc]}
           end),
         do: {:ok, {:apply, name, Enum.reverse(args)}}
  end

  defp resolved({:generic, _, _}, _compiled, _path),
    do: {:error, "a generic is a named type's whole definition, {:generic [t ...] body}"}

  defp resolved({:shape, name, fields}, compiled, path) do
    with {:ok, fields} <-
           Result.reduce_ok(fields, [], fn field, acc ->
             with {:ok, type} <- resolved(field.type, compiled, path),
                  do: {:ok, [%{field | type: type} | acc]}
           end),
         do: {:ok, {:shape, name, Enum.reverse(fields)}}
  end

  defp resolved({:case, field, branches, otherwise}, compiled, path) do
    with {:ok, branches} <-
           Result.reduce_ok(branches, [], fn {literal, type}, acc ->
             with {:ok, type} <- resolved(type, compiled, path),
                  do: {:ok, [{literal, type} | acc]}
           end),
         {:ok, otherwise} <- resolved(otherwise, compiled, path) do
      {:ok, {:case, field, Enum.reverse(branches), otherwise}}
    end
  end

  defp resolved({:refine, type, constraints}, compiled, path) do
    with {:ok, type} <- resolved(type, compiled, path),
         {:ok, constraints} <- resolved_types(constraints, compiled, path),
         do: {:ok, {:refine, type, constraints}}
  end

  defp resolved({:doc, type, notes}, compiled, path) do
    with {:ok, type} <- resolved(type, compiled, path), do: {:ok, {:doc, type, notes}}
  end

  defp resolved({:tagged, name, type}, compiled, path) do
    with {:ok, type} <- resolved(type, compiled, path), do: {:ok, {:tagged, name, type}}
  end

  defp resolved({:list_items, particles}, compiled, path) do
    with {:ok, particles} <- resolved_particles(particles, compiled, path),
         do: {:ok, {:list_items, particles}}
  end

  defp resolved({form, types}, compiled, path)
       when form in [:tuple_of, :one_of, :any_of, :all_of] do
    with {:ok, types} <-
           Result.reduce_ok(types, [], fn type, acc ->
             with {:ok, type} <- resolved(type, compiled, path), do: {:ok, [type | acc]}
           end),
         do: {:ok, {form, Enum.reverse(types)}}
  end

  defp resolved({form, type}, compiled, path)
       when form in [:list_of, :set_of, :array_of, :sorted_set_of, :tuple_of_all, :not, :nilable] do
    with {:ok, type} <- resolved(type, compiled, path), do: {:ok, {form, type}}
  end

  defp resolved({form, key, value}, compiled, path) when form in [:map_of, :ordered_map_of] do
    with {:ok, key} <- resolved(key, compiled, path),
         {:ok, value} <- resolved(value, compiled, path),
         do: {:ok, {form, key, value}}
  end

  defp resolved(type_expr, _compiled, _path), do: {:ok, type_expr}

  # A refine's types -- `contains`, `content`, `encodes`, `encodes-seq` --
  # resolved as its base is.
  defp resolved_types(constraints, compiled, path) do
    Result.reduce_ok(@type_keys, constraints, fn key, acc ->
      case Map.fetch(acc, key) do
        :error ->
          {:ok, acc}

        {:ok, type} ->
          with {:ok, t} <- resolved(type, compiled, path), do: {:ok, %{acc | key => t}}
      end
    end)
  end

  defp resolved_particles(particles, compiled, path) do
    Result.reduce_ok(particles, [], fn
      {:one, type}, acc ->
        with {:ok, type} <- resolved(type, compiled, path), do: {:ok, [{:one, type} | acc]}

      {:repeat, group, least, most}, acc ->
        with {:ok, group} <- resolved_particles(group, compiled, path),
             do: {:ok, [{:repeat, group, least, most} | acc]}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
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
         :ok <- distinct_names(fields),
         :ok <- cases_name_fields(pairs, fields) do
      {:ok, %Compiled{version: version || 1, fields: fields}}
    end
  end

  # A schema's annotations, `{:doc %schema{...} %{...}}`, kept on its
  # `Compiled`.
  defp compile_entry(%Tuple{items: [%Keyword{name: "doc"}, inner, raw]}, aliases) do
    with {:ok, compiled} <- compile_entry(inner, aliases),
         {:ok, notes} <- annotations(raw, :schema),
         do: {:ok, %{compiled | annotations: notes}}
  end

  defp compile_entry(%Struct{name: "schema", fields: {:positional, _}}, _aliases),
    do: {:error, "a schema lists its fields by name: %schema(N){field: type, ...}"}

  defp compile_entry(other, _aliases) do
    {:error, "expected a %schema(N){...} entry, got #{inspect(other)}"}
  end

  # A schema written in Dextrin 0.1's syntax -- `fields: @ordered %{...}`,
  # `closed: true`, `forbidden: [...]` -- says so, and what a schema is
  # written as now (DXN.md §4.4), rather than that a field has no known
  # type. Only those shapes: now `fields`, `closed` and `forbidden` are
  # ordinary field names, whose values are type expressions. The format
  # itself stays 1.0 until 1.0.0 (Jan, 2026-10-20), so the old syntax is
  # named by the release that had it.
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
         "this is Dextrin 0.1's schema syntax (fields:, closed:, forbidden:); a schema lists its fields " <>
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

  # Every `{:case field ...}` written in `pairs`' field types names one
  # of `fields` -- told from the source, so a named type the case
  # reaches through is not looked into.
  defp cases_name_fields(pairs, fields) do
    names = MapSet.new(fields, & &1.name)

    case Enum.find(Enum.flat_map(pairs, fn {_k, v} -> case_fields(v) end), &(&1 not in names)) do
      nil -> :ok
      missing -> {:error, "{:case #{missing} ...} names no field of its schema or shape"}
    end
  end

  defp case_fields(%Tuple{items: [%Keyword{name: "case"}, %Symbol{name: field} | rest]}),
    do: [field | Enum.flat_map(rest, &case_fields/1)]

  defp case_fields(%Tuple{items: items}), do: Enum.flat_map(items, &case_fields/1)
  defp case_fields(%Struct{name: "shape"}), do: []

  defp case_fields(%Struct{name: "field", fields: {:keyed, pairs}}),
    do: case_fields(get(pairs, "type"))

  defp case_fields(map) when is_map(map) and not is_struct(map),
    do: Enum.flat_map(map, fn {_k, v} -> case_fields(v) end)

  defp case_fields(_other), do: []

  # ---- type expressions -------------------------------------------------------

  # `%shape{field: type, ...}` (design/shapes-and-case.md): a plain map's
  # fields, as a schema's are written; no version, never positional.
  defp compile_type_expr(%Struct{name: "shape", version: nil, fields: {:keyed, pairs}}, aliases) do
    with {:ok, fields} <- compile_fields(pairs, aliases),
         :ok <- distinct_names(fields),
         :ok <- cases_name_fields(pairs, fields) do
      {:ok, {:shape, nil, fields}}
    end
  end

  defp compile_type_expr(%Struct{name: "shape", fields: {:keyed, _}}, _aliases),
    do: {:error, "a shape has no version: %shape{field: type, ...}"}

  defp compile_type_expr(%Struct{name: "shape"}, _aliases),
    do: {:error, "a shape lists its fields by name: %shape{field: type, ...}"}

  # `{:case field %{value => type, ..., :else => type}}`: the type the
  # sibling `field`'s value chooses.
  defp compile_type_expr(
         %Tuple{items: [%Keyword{name: "case"}, %Symbol{name: field}, table]},
         aliases
       )
       when is_map(table) and not is_struct(table) do
    {otherwise, branches} = Map.pop(table, Keyword.new("else"), :none)

    with {:ok, otherwise} <- maybe_compile(otherwise, aliases),
         {:ok, branches} <-
           Result.reduce_ok(Enum.sort(branches), [], fn {literal, type}, acc ->
             with {:ok, t} <- compile_type_expr(type, aliases), do: {:ok, [{literal, t} | acc]}
           end) do
      {:ok, {:case, field, Enum.reverse(branches), otherwise}}
    end
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "case"} | _]}, _aliases),
    do: {:error, "a case is {:case field %{value => type, ..., :else => type}}"}

  defp compile_type_expr(%Keyword{name: "any"}, _aliases), do: {:ok, :any}
  defp compile_type_expr(%Keyword{name: "never"}, _aliases), do: {:ok, :never}
  defp compile_type_expr(:any_keyword, _aliases), do: {:ok, :any}

  defp compile_type_expr(%Keyword{name: name}, _aliases) when name in @primitives,
    do: {:ok, {:primitive, name}}

  # DXN 0.2's timestamp type, now a datetime in UTC (DXN.md §4.2, Jan,
  # 2026-10-20): a schema naming it keeps its meaning.
  defp compile_type_expr(%Keyword{name: "timestamp"}, _aliases),
    do: {:ok, {:refine, {:primitive, "datetime"}, %{"offsets" => ["Z"]}}}

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

  defp compile_type_expr(%Symbol{name: written}, aliases) do
    name = full_name(written, aliases)

    case Map.fetch(aliases, name) do
      {:ok, {:generic, _, _}} -> {:error, takes_arguments(name, aliases)}
      {:ok, type_expr} -> {:ok, type_expr}
      :error -> {:ok, {:reference, name}}
    end
  end

  # `{:of Name type ...}`: one use of the generic `Name`.
  defp compile_type_expr(
         %Tuple{items: [%Keyword{name: "of"}, %Symbol{name: written} | args]},
         aliases
       )
       when args != [] do
    name = full_name(written, aliases)

    with :ok <- applies(name, length(args), aliases),
         {:ok, args} <- map_compile(args, aliases),
         do: {:ok, {:apply, name, args}}
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "of"} | _]}, _aliases),
    do: {:error, "a use of a generic is {:of Name type ...}"}

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "generic"} | _]}, _aliases),
    do: {:error, "a generic is a named type's whole definition, {:generic [t ...] body}"}

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
    with {:ok, t} <- compile_type_expr(elem, aliases),
         {:ok, constraints} <- refine_constraints(constraints, aliases),
         do: {:ok, {:refine, t, constraints}}
  end

  # `{:list-items p ...}`: a list's items in order, each `p` a type for
  # one item or a `{:repeat ...}` (DXN.md §4.1a).
  defp compile_type_expr(%Tuple{items: [%Keyword{name: "list-items"} | particles]}, aliases) do
    with {:ok, ps} <- particles(particles, aliases), do: {:ok, {:list_items, ps}}
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "tuple-of-all"}, elem]}, aliases) do
    with {:ok, t} <- compile_type_expr(elem, aliases), do: {:ok, {:tuple_of_all, t}}
  end

  # `{:doc type %{...}}`: the type, annotated (DXN.md §4.1b).
  defp compile_type_expr(%Tuple{items: [%Keyword{name: "doc"}, inner, raw]}, aliases) do
    with {:ok, type} <- compile_type_expr(inner, aliases),
         {:ok, notes} <- annotations(raw, type),
         do: {:ok, {:doc, type, notes}}
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "doc"} | _]}, _aliases),
    do: {:error, "a doc is {:doc type %{description: ..., ...}}"}

  # `{:tagged name type}`: a custom tag of that name, its value a type
  # (DXN.md §4.1).
  defp compile_type_expr(%Tuple{items: [%Keyword{name: "tagged"}, name, type]}, aliases) do
    case name_of(name) do
      nil ->
        {:error, "a tagged is {:tagged name type}, the name a symbol, keyword or string"}

      tag ->
        if tag in Dextrin.Text.Actions.built_in_tags(),
          do:
            {:error, "#{tag} is a built-in tag (DXN.md §1.3), no custom one: its type is :#{tag}"},
          else: with({:ok, t} <- compile_type_expr(type, aliases), do: {:ok, {:tagged, tag, t}})
    end
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "tagged"} | _]}, _aliases),
    do: {:error, "a tagged is {:tagged name type}"}

  defp compile_type_expr(%Tuple{items: [%Keyword{name: form} | _]}, _aliases)
       when form in ["repeat", "group"],
       do: {:error, "a #{form} stands only among {:list-items ...}'s items"}

  defp compile_type_expr(other, _aliases),
    do: {:error, "unrecognized type expression: #{inspect(other)}"}

  # The name a written symbol stands for: itself where it is in scope
  # already (a generic's parameter, a name known so), otherwise the full
  # name this document's `names` give it.
  defp full_name(written, aliases) do
    if Map.has_key?(aliases, written),
      do: written,
      else: Map.get(Map.get(aliases, @names, %{}), written, written)
  end

  # A `{:list-items}`'s or a group's items: `{:one, type}` for a type,
  # `{:repeat, particles, least, most}` for a repeat, `most` nil when
  # there is no upper bound.
  defp particles(values, aliases) do
    Result.reduce_ok(values, [], fn value, acc ->
      with {:ok, p} <- particle(value, aliases), do: {:ok, [p | acc]}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp particle(%Tuple{items: [%Keyword{name: "repeat"}, inner, least, most]}, aliases)
       when is_integer(least) and least >= 0 and
              (is_nil(most) or (is_integer(most) and most >= least)) do
    group =
      case inner do
        %Tuple{items: [%Keyword{name: "group"} | items]} -> items
        single -> [single]
      end

    with {:ok, ps} <- particles(group, aliases), do: {:ok, {:repeat, ps, least, most}}
  end

  defp particle(%Tuple{items: [%Keyword{name: "repeat"} | _]}, _aliases),
    do: {:error, "a repeat is {:repeat type min max}: 0 <= min <= max, max nil for no bound"}

  defp particle(%Tuple{items: [%Keyword{name: "group"} | _]}, _aliases),
    do: {:error, "a group stands only in a repeat, {:repeat {:group a b ...} min max}"}

  defp particle(value, aliases) do
    with {:ok, t} <- compile_type_expr(value, aliases), do: {:ok, {:one, t}}
  end

  @refine_keys ~w(min max exclusive-min exclusive-max multiple-of min-length max-length
                  min-bytes max-bytes pattern min-count max-count finite float32 offsets
                  version prefix contains min-contains max-contains unique unique-by
                  min-precision max-precision min-exponent max-exponent bits before-now
                  after-now within resolution format encoding media-type content encodes
                  encodes-seq)

  @counts ~w(min-length max-length min-bytes max-bytes min-count max-count min-contains
             max-contains min-precision max-precision)
  @flags ~w(finite float32 unique before-now after-now prefix)
  @bounds ~w(min max exclusive-min exclusive-max)
  @encodings ~w(base64 base64url base32 base16)

  # What `content` reads a string as, by its media type.
  @content_readers [nil, "application/dxn", "application/dxnb"]

  # A refine's constraints by name, every key one DXN.md §4.2 knows and
  # every argument one it takes: a misspelt key would otherwise refuse
  # every value, silently, and a bad argument fail at check time. The
  # types are compiled here; `unique-by`, `format`, `resolution` and
  # `encoding` become names.
  defp refine_constraints(constraints, aliases) do
    with {:ok, named} <- constraint_names(constraints),
         :ok <- known_keys(named),
         :ok <- contains_counted(named),
         {:ok, named} <- named_arg(named, "unique-by", nil),
         {:ok, named} <- named_arg(named, "format", Dextrin.Schema.Format.names()),
         {:ok, named} <- named_arg(named, "resolution", TypeExpr.resolutions()),
         {:ok, named} <- named_arg(named, "encoding", @encodings),
         :ok <- arguments(named),
         :ok <- content_readable(named),
         do: types(named, aliases)
  end

  # The constraints keyed by their names; a key that is no name is an
  # error, not a crash.
  defp constraint_names(constraints) do
    Enum.reduce_while(constraints, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case name_of(key) do
        nil -> {:halt, {:error, "a refine constraint's key is a name, not #{shown(key)}"}}
        name -> {:cont, {:ok, Map.put(acc, name, value)}}
      end
    end)
  end

  defp known_keys(named) do
    case Enum.find(Enum.sort(Map.keys(named)), &(&1 not in @refine_keys)) do
      nil -> :ok
      key -> {:error, "#{key} is no refine constraint (DXN.md §4.2)"}
    end
  end

  defp contains_counted(named) do
    if not Map.has_key?(named, "contains") and
         (Map.has_key?(named, "min-contains") or Map.has_key?(named, "max-contains")),
       do: {:error, "min-contains and max-contains count the items a contains matches"},
       else: :ok
  end

  # `key`'s argument as a name, one of `allowed` when they are given.
  defp named_arg(named, key, allowed) do
    case Map.fetch(named, key) do
      :error ->
        {:ok, named}

      {:ok, arg} ->
        name = name_of(arg)

        if name != nil and (allowed == nil or name in allowed),
          do: {:ok, %{named | key => name}},
          else: {:error, "#{key} takes #{expected(allowed)}, not #{shown(arg)}"}
    end
  end

  defp expected(nil), do: "a name"
  defp expected(allowed), do: "one of " <> Enum.map_join(Enum.sort(allowed), " ", &":#{&1}")

  # Every argument the kind its key takes, in key order.
  defp arguments(named) do
    named
    |> Enum.sort()
    |> Enum.find_value(:ok, fn {key, arg} ->
      case argument(key, arg) do
        :ok -> nil
        {:takes, what} -> {:error, "#{key} takes #{what}, not #{shown(arg)}"}
      end
    end)
  end

  defp argument(key, arg) when key in @counts do
    if is_integer(arg) and arg >= 0, do: :ok, else: {:takes, "a non-negative integer"}
  end

  defp argument(key, arg) when key in ["min-exponent", "max-exponent"] do
    if is_integer(arg), do: :ok, else: {:takes, "an integer"}
  end

  defp argument(key, arg) when key in @flags do
    if is_boolean(arg), do: :ok, else: {:takes, "true or false"}
  end

  defp argument(key, arg) when key in @bounds do
    if TypeExpr.comparable?(arg),
      do: :ok,
      else:
        {:takes,
         "a number, date, time, datetime, local date-time or a duration without years or months"}
  end

  defp argument("multiple-of", arg) do
    if TypeExpr.nonzero_number?(arg), do: :ok, else: {:takes, "a number other than 0"}
  end

  defp argument("pattern", arg) do
    if match?(%Regex{}, arg), do: :ok, else: {:takes, "a regex, @regex \"...\""}
  end

  defp argument("version", arg) do
    if arg in [4, 6], do: :ok, else: {:takes, "4 or 6"}
  end

  defp argument("offsets", arg) do
    if is_list(arg) and Enum.all?(arg, &offset?/1),
      do: :ok,
      else: {:takes, "a list of offsets, \"Z\" or \"±HH:MM\""}
  end

  defp argument("bits", arg) do
    if is_list(arg) and Enum.all?(arg, &(is_integer(&1) and &1 >= 0)),
      do: :ok,
      else: {:takes, "a list of bit numbers, non-negative integers"}
  end

  defp argument("within", arg) do
    if TypeExpr.span?(arg), do: :ok, else: {:takes, "a duration without years or months"}
  end

  # RFC 6838's type/subtype, without parameters.
  defp argument("media-type", arg) do
    if is_binary(arg) and
         Regex.match?(
           ~r/^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,126}\/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,126}$/,
           arg
         ),
       do: :ok,
       else: {:takes, "a media type, \"type/subtype\""}
  end

  defp argument(_key, _arg), do: :ok

  defp offset?("Z"), do: true

  defp offset?(text) when is_binary(text),
    do: Regex.match?(~r/^[+-](?:[01][0-9]|2[0-3]):[0-5][0-9]$/, text)

  defp offset?(_other), do: false

  # `content` reads a DXN document: text, or `.dxnb` under
  # application/dxnb, which a string holds only encoded.
  defp content_readable(%{"content" => _} = named) do
    media = named |> Map.get("media-type") |> then(&(&1 && String.downcase(&1)))

    cond do
      media not in @content_readers ->
        {:error, "content reads application/dxn or application/dxnb, not #{shown(media)}"}

      media == "application/dxnb" and not Map.has_key?(named, "encoding") ->
        {:error, "content under application/dxnb needs an encoding: a string holds no raw bytes"}

      true ->
        :ok
    end
  end

  defp content_readable(_named), do: :ok

  defp types(named, aliases) do
    Result.reduce_ok(@type_keys, named, fn key, acc ->
      case Map.fetch(acc, key) do
        :error ->
          {:ok, acc}

        {:ok, type} ->
          with {:ok, t} <- compile_type_expr(type, aliases), do: {:ok, %{acc | key => t}}
      end
    end)
  end

  # `value` as DXN writes it, for a message.
  defp shown(value) do
    case Dextrin.Canonical.print(value) do
      {:ok, text} -> text
      {:error, _} -> inspect(value)
    end
  end

  defp name_of(%Keyword{name: name}), do: name
  defp name_of(%Symbol{name: name}), do: name
  defp name_of(name) when is_binary(name), do: name
  defp name_of(_other), do: nil

  @annotation_keys ~w(title description examples read-only write-only deprecated meta values)

  # A doc's annotations by name, each of its kind (DXN.md §4.1b); `type`
  # is what they annotate, `:schema` for a whole schema, so `values` can
  # be checked against an enum's literals.
  defp annotations(raw, type) when is_map(raw) and not is_struct(raw) do
    with {:ok, named} <- constraint_names(raw) do
      named
      |> Enum.sort()
      |> Enum.find_value({:ok, named}, fn {key, value} ->
        case annotation(key, value, type) do
          :ok -> nil
          {:takes, what} -> {:error, "a doc's #{key} is #{what}, not #{shown(value)}"}
          {:error, _} = error -> error
        end
      end)
      |> case do
        {:ok, named} -> annotated_values(named)
        error -> error
      end
    end
  end

  defp annotations(raw, _type),
    do: {:error, "a doc's annotations are a map, %{description: ...}, not #{shown(raw)}"}

  defp annotation(key, value, _type) when key in ["title", "description"],
    do: if(is_binary(value), do: :ok, else: {:takes, "a string"})

  defp annotation("examples", value, _type),
    do: if(is_list(value), do: :ok, else: {:takes, "a list"})

  defp annotation(key, value, _type) when key in ["read-only", "write-only"],
    do: if(is_boolean(value), do: :ok, else: {:takes, "true or false"})

  defp annotation("deprecated", value, _type),
    do:
      if(is_boolean(value) or is_binary(value),
        do: :ok,
        else: {:takes, "true, false or a reason"}
      )

  defp annotation("meta", value, _type),
    do: if(is_map(value) and not is_struct(value), do: :ok, else: {:takes, "a map"})

  defp annotation("values", value, {:enum, literals})
       when is_map(value) and not is_struct(value) do
    Enum.find_value(Enum.sort(value), :ok, fn {literal, notes} ->
      cond do
        literal not in literals ->
          {:error,
           "a doc's values annotate the enum's own values; #{shown(literal)} is none of them"}

        not (is_map(notes) and not is_struct(notes)) ->
          {:error, "a doc's values hold a map of annotations for each value"}

        Map.has_key?(notes, Keyword.new("values")) ->
          {:error, "a value's annotations hold no values of their own"}

        true ->
          case annotations(notes, :value) do
            {:ok, _} -> nil
            error -> error
          end
      end
    end)
  end

  defp annotation("values", _value, _type),
    do: {:takes, "a map of an enum's values to their annotations, on an enum"}

  defp annotation(key, _value, _type),
    do: {:error, "#{key} is no annotation; a doc holds #{Enum.join(@annotation_keys, ", ")}"}

  # `values`' annotation maps keyed by name, as the doc's own are.
  defp annotated_values(%{"values" => values} = named) do
    {:ok,
     %{
       named
       | "values" =>
           Map.new(values, fn {literal, notes} ->
             {:ok, notes} = annotations(notes, :value)
             {literal, notes}
           end)
     }}
  end

  defp annotated_values(named), do: {:ok, named}

  # An entry's value without the `{:doc ...}` around it.
  defp undoc(%Tuple{items: [%Keyword{name: "doc"}, inner, _]}), do: inner
  defp undoc(value), do: value

  defp maybe_compile(:none, _aliases), do: {:ok, :none}
  defp maybe_compile(value, aliases), do: compile_type_expr(value, aliases)

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
