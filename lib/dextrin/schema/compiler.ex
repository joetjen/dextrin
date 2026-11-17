defmodule Dextrin.Schema.Compiler do
  @moduledoc """
  Compiles a parsed `.dxns` document (an ordinary decoded DXN value —
  a `.dxns` file is valid `.dxn`, whose one piece of grammar for schemas
  is what a `%schema` or `%shape` is built from, DXNS.md §4b; what makes
  it a *schema* document is purely the shape of the value it parses to:
  a map from name to type expression) into `Dextrin.Schema.Compiled`
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
  alias Dextrin.Schema.{Bases, Compiled, Deprecations, Field, TypeExpr}
  alias Ichor.Toolkit.Result

  # The scope key the document's names travel under (see compile/3).
  @names :"$names"

  # The scope key the registry and the document travel under, for what
  # needs more than the named types: a generic parameter's bound
  # (G2 of design/typespec.md) asks which schema extends which.
  @lookup :"$lookup"

  # The scope key a generic parameter's bound travels under, inside its
  # generic's body: `{@bound, name}`.
  @bound :"$bound"
  # The version each named type of the document being compiled has
  # (Way B, DXNS.md §5c), so a pin to a sibling (`Color(2)`) is seen.
  @versions :"$versions"

  # A refine's keys whose argument is a type, compiled and resolved as
  # its base is.
  @type_keys ~w(contains content encodes encodes-seq)

  # The sized integers' ranges.
  @sized %{
    "int8" => {-128, 127},
    "int16" => {-32_768, 32_767},
    "uint8" => {0, 255},
    "uint16" => {0, 65_535},
    "int32" => {-2_147_483_648, 2_147_483_647},
    "int64" => {-9_223_372_036_854_775_808, 9_223_372_036_854_775_807},
    "uint32" => {0, 4_294_967_295},
    "uint64" => {0, 18_446_744_073_709_551_615}
  }

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
  # tree's full names (DXNS.md §6, `Dextrin.Schema.Layout`); a bare
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

    with {:ok, alias_entries, versions} <- unversioned(alias_entries),
         document = Map.new(alias_entries ++ schema_entries),
         {:ok, registry, built} <-
           compile_aliases(alias_entries, base_registry, names, schema_entries, versions),
         {:ok, registry} <- compile_schemas(schema_entries, registry, names, document, built) do
      warnings = Deprecations.compile_warnings(named_entries, names, registry)
      {:ok, %{registry | warnings: registry.warnings ++ warnings}}
    end
  end

  def compile(other, _base_registry, _names),
    do: {:error, compile_error("a .dxns document is a map, got #{inspect(other)}")}

  # `Color: %type(2)[T]` (Way B, DXNS.md §5c): the named type's
  # definition `T`, at version 2; a plain definition is version 1. A
  # `{:doc}` around the `%type` stays around `T`.
  defp unversioned(alias_entries) do
    alias_entries
    |> Result.reduce_ok({[], %{}}, fn {name, raw}, {entries, versions} ->
      case type_version(raw) do
        {:ok, type, version} ->
          {:ok, {[{name, type} | entries], Map.put(versions, name, version)}}

        {:error, reason} ->
          {:error, compile_error("named type #{inspect(name)}: #{reason}")}
      end
    end)
    |> case do
      {:ok, {entries, versions}} -> {:ok, Enum.reverse(entries), versions}
      {:error, _} = error -> error
    end
  end

  defp type_version(%Tuple{items: [%Keyword{name: "doc"} = doc, inner, notes]}) do
    with {:ok, type, version} <- type_version(inner),
         do: {:ok, %Tuple{items: [doc, type, notes]}, version}
  end

  defp type_version(%Struct{
         name: "type",
         version: version,
         fields: {:positional, [type]},
         extra: [],
         bases: []
       })
       when is_integer(version),
       do: {:ok, type, version}

  defp type_version(%Struct{name: "type"}),
    do: {:error, "a version of a named type is %type(N)[type]: one type, at version N"}

  defp type_version(raw), do: {:ok, raw, 1}

  defp compile_schemas(schema_entries, registry, names, document, built) do
    Result.reduce_ok(schema_entries, registry, fn {name, entry}, registry ->
      aliases =
        registry.type_aliases
        |> Map.put(@names, names)
        |> Map.put(@lookup, %{registry: registry, document: document})

      lookup = %{
        document: document,
        compiled: registry.type_aliases,
        scope: aliases,
        registry: registry
      }

      case schema_entry(name, entry, built, aliases) do
        {:ok, %Compiled{} = compiled} ->
          with :ok <-
                 discriminators(
                   %{name => {:shape, name, compiled.fields, compiled.extras}},
                   lookup,
                   built
                 ),
               do: Registry.add_struct_schema(registry, name, %{compiled | name: name})

        {:error, reason} ->
          {:error, compile_error("schema #{inspect(name)}: #{reason}")}
      end
    end)
  end

  # A schema built from others (DXNS.md §4b) takes the fields `built`
  # holds for it, each now resolved; any other is compiled from its body.
  defp schema_entry(name, entry, built, aliases) do
    case Map.fetch(built, name) do
      {:ok, %{fields: fields, bases: bases, extras: extras}} ->
        with {:ok, notes} <- entry_annotations(entry),
             {:ok, fields} <- resolved_fields(fields, aliases),
             {:ok, extras} <- resolved_extras(extras, aliases) do
          {:ok,
           %Compiled{
             version: undoc(entry).version || 1,
             fields: fields,
             bases: bases,
             annotations: notes,
             extras: extras
           }}
        end

      :error ->
        compile_entry(entry, aliases)
    end
  end

  defp entry_annotations(%Tuple{items: [%Keyword{name: "doc"}, _inner, raw]}),
    do: annotations(raw, :schema)

  defp entry_annotations(_entry), do: {:ok, %{}}

  defp resolved_fields(fields, aliases) do
    Result.reduce_ok(fields, [], fn field, acc ->
      with {:ok, type} <- resolved(field.type, aliases, []),
           do: {:ok, [%{field | type: type} | acc]}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = error -> error
    end
  end

  defp resolved_extras(extras, aliases), do: resolved_shape_extras(extras, aliases, [])

  defp compile_error(message), do: Dextrin.Error.action(message, "schema/compile")

  # Every named type in a document sees every other (design/
  # shapes-and-case.md, DXNS.md §5): each is compiled with its siblings
  # standing as `{:named, name}`, and those are put in place once all
  # are read -- so the order of a map's entries, which DXN does not
  # give, never matters. A named type may reach itself only through a
  # guard -- a field, or a collection's elements (Jan, 2026-10-20) --
  # and there the reference stays by name, looked up when it is checked.
  #
  # A schema or shape built from others (DXNS.md §4b) is built here too,
  # once the plain named types are compiled and before any is resolved:
  # its bases may be any schema or shape of the document, or one already
  # loaded. A built shape joins the named types; what was built for a
  # schema comes back in `built`, by name.
  defp compile_aliases(alias_entries, registry, names, schema_entries, versions) do
    siblings = Map.new(alias_entries, fn {name, _} -> {name, {:named, name}} end)
    document = Map.new(alias_entries ++ schema_entries)

    scope =
      registry.type_aliases
      |> Map.merge(siblings)
      |> Map.put(@names, names)
      |> Map.put(@lookup, %{registry: registry, document: document})
      |> Map.put(@versions, versions)

    {extending, plain} = Enum.split_with(alias_entries, fn {_, v} -> built_from?(v) end)

    with {:ok, compiled} <-
           Result.reduce_ok(plain, %{}, fn {name, raw_value}, acc ->
             case compile_named(name, raw_value, scope) do
               {:ok, type_expr} ->
                 {:ok, Map.put(acc, name, type_expr)}

               {:error, reason} ->
                 {:error, compile_error("named type #{inspect(name)}: #{reason}")}
             end
           end),
         lookup = %{document: document, compiled: compiled, scope: scope, registry: registry},
         {:ok, built} <-
           Result.reduce_ok(
             extending ++ Enum.filter(schema_entries, fn {_, v} -> built_from?(v) end),
             %{},
             fn {name, _}, built ->
               build(name, [], lookup, built)
             end
           ),
         {:ok, compiled} <- with_built_shapes(compiled, extending, built),
         :ok <- guarded(compiled),
         :ok <- discriminators(compiled, %{lookup | compiled: compiled}, built) do
      known =
        registry.type_aliases
        |> Map.merge(compiled)
        |> Map.put(@lookup, %{registry: registry, document: document})

      Result.reduce_ok(alias_entries, registry, fn {name, _}, registry ->
        case entry_resolved(Map.fetch!(compiled, name), known, [name]) do
          {:ok, type_expr} ->
            Registry.put_type_version(registry, name, Map.get(versions, name, 1), type_expr)

          {:error, reason} ->
            {:error, compile_error("named type #{inspect(name)}: #{reason}")}
        end
      end)
      |> case do
        {:ok, registry} -> {:ok, registry, built}
        {:error, _} = error -> error
      end
    end
  end

  # ---- discriminators (G3 of design/typespec.md) ------------------------------

  # Every variant under a `discriminator` has that field: the field a
  # value's variant is chosen by.
  defp discriminators(compiled, lookup, built) do
    compiled
    |> Enum.sort()
    |> Enum.find_value(:ok, fn {name, type} ->
      type
      |> discriminated()
      |> Enum.find_value(fn {field, variants} ->
        Enum.find_value(variants, fn variant ->
          case variant_fields(variant, lookup, built, []) do
            {:ok, names} ->
              if field in names,
                do: nil,
                else:
                  compile_error(
                    "#{inspect(name)}: its discriminator #{field} is no field of #{variant_label(variant)}"
                  )

            :error ->
              compile_error(
                "#{inspect(name)}: its discriminator #{field} needs every variant to be a schema or a shape; #{variant_label(variant)} is not"
              )
          end
        end)
      end)
      |> case do
        nil -> nil
        error -> {:error, error}
      end
    end)
  end

  # Every `{:doc {:any-of ...} %{discriminator: f}}` in `type`, as
  # `{f, variants}`.
  defp discriminated({:doc, inner, %{"discriminator" => field}}),
    do: [{field, variant_list(inner)} | discriminated(inner)]

  defp discriminated(%Field{type: type}), do: discriminated(type)

  defp discriminated(type) when is_tuple(type),
    do: type |> Elixir.Tuple.to_list() |> Enum.flat_map(&discriminated/1)

  defp discriminated(types) when is_list(types), do: Enum.flat_map(types, &discriminated/1)
  defp discriminated(_leaf), do: []

  defp variant_list({:doc, inner, _}), do: variant_list(inner)
  defp variant_list({_form, types}), do: types

  # The names of a variant's fields: a shape's, or a schema's of the
  # document or one loaded.
  defp variant_fields({:doc, inner, _}, lookup, built, seen),
    do: variant_fields(inner, lookup, built, seen)

  defp variant_fields({:shape, _name, fields, _extras}, _lookup, _built, _seen),
    do: {:ok, Enum.map(fields, & &1.name)}

  defp variant_fields({:named, name}, lookup, built, seen) do
    known = Map.merge(lookup.registry.type_aliases, lookup.compiled)

    case {Map.fetch(known, name), name in seen} do
      {{:ok, type}, false} -> variant_fields(type, lookup, built, [name | seen])
      _ -> :error
    end
  end

  # A variant pinned to a version (G11): that version's fields when it is
  # loaded, otherwise judged by its name as an unpinned one is.
  defp variant_fields({:reference, name, version}, lookup, built, seen) do
    case Registry.fetch_struct_schema(lookup.registry, name, version) do
      {:ok, %Compiled{fields: fields}, _} -> {:ok, Enum.map(fields, & &1.name)}
      _ -> variant_fields({:reference, name}, lookup, built, seen)
    end
  end

  defp variant_fields({:reference, name}, lookup, built, _seen) do
    cond do
      Map.has_key?(built, name) ->
        {:ok, Enum.map(built[name].fields, & &1.name)}

      match?(%Struct{name: "schema", fields: {:keyed, _}}, undoc(Map.get(lookup.document, name))) ->
        %Struct{fields: {:keyed, pairs}} = undoc(Map.fetch!(lookup.document, name))

        case compile_fields(pairs, lookup.scope) do
          {:ok, fields} -> {:ok, Enum.map(fields, & &1.name)}
          _ -> :error
        end

      true ->
        case Registry.fetch_struct_schema(lookup.registry, name) do
          {:ok, %Compiled{fields: fields}, _} -> {:ok, Enum.map(fields, & &1.name)}
          _ -> :error
        end
    end
  end

  defp variant_fields(_type, _lookup, _built, _seen), do: :error

  defp variant_label({:doc, inner, _}), do: variant_label(inner)
  defp variant_label({kind, name}) when kind in [:named, :reference], do: name
  defp variant_label({:reference, name, version}), do: Dextrin.Tuple.pinned_text(name, version)
  defp variant_label(_type), do: "an inline variant"

  # ---- built from others (DXNS.md §4b) ---------------------------------------

  defp built_from?(entry) do
    case undoc(entry) do
      %Struct{name: kind, bases: bases, drops: drops} when kind in ["schema", "shape"] ->
        bases != [] or field_drops(drops) != []

      _ ->
        false
    end
  end

  # `- *` closes a body and `* K => V` types its extras (G1 of
  # design/typespec.md); neither makes a schema or shape built from
  # others. A body's extras are `:open`, `:closed` or `{key_type,
  # value_type}`; `nil` here when the body says nothing.
  defp field_drops(drops), do: Enum.reject(drops, &(&1 == "*"))

  defp own_extras(%Struct{drops: drops, rest: rest}, scope) do
    closed = "*" in drops

    if rest == [] and not closed do
      {:ok, nil}
    else
      rest
      |> Result.reduce_ok([], fn {key, value}, acc ->
        with {:ok, key} <- compile_type_expr(key, scope),
             {:ok, value} <- compile_type_expr(value, scope),
             do: {:ok, [{key, value} | acc]}
      end)
      |> case do
        {:ok, entries} -> {:ok, %{entries: Enum.reverse(entries), closed: closed}}
        {:error, _} = error -> error
      end
    end
  end

  # The fields of the document's entry `name`, built from its bases, kept
  # in `built` with the bases as `Compiled` records them. `path` holds
  # the entries being built, so one that reaches itself is seen.
  defp build(name, path, lookup, built) do
    cond do
      Map.has_key?(built, name) ->
        {:ok, built}

      name in path ->
        {:error, compile_error("#{inspect(name)} is built from itself")}

      true ->
        %Struct{bases: bases, drops: drops} = raw = undoc(Map.fetch!(lookup.document, name))

        with :ok <- has_bases(name, raw),
             :ok <- distinct_bases(name, bases),
             {:ok, own} <- own_fields(name, raw, lookup.scope),
             {:ok, own_extras} <- built_own_extras(name, raw, lookup.scope),
             {:ok, found, built} <- found_bases(name, bases, [name | path], lookup, built),
             {:ok, fields} <- merged(name, found, own, field_drops(drops), lookup),
             {:ok, extras} <- merged_extras(name, found, own, own_extras, lookup),
             :ok <- built_cases(name, fields) do
          recorded = Enum.map(found, &{&1.kind, &1.name, &1.version})
          {:ok, Map.put(built, name, %{fields: fields, bases: recorded, extras: extras})}
        end
    end
  end

  defp has_bases(name, %Struct{bases: []}),
    do:
      {:error, compile_error("#{inspect(name)} drops a field, but names no base to drop it from")}

  defp has_bases(_name, %Struct{name: "shape", version: version}) when version != nil,
    do: {:error, compile_error("a shape has no version: %shape extends Base {field: type, ...}")}

  defp has_bases(_name, %Struct{fields: {:positional, _}, name: kind}),
    do:
      {:error, compile_error("a #{kind} lists its fields by name: %#{kind}(N){field: type, ...}")}

  defp has_bases(_name, _raw), do: :ok

  defp distinct_bases(name, bases) do
    case bases
         |> Enum.map(&elem(&1, 1))
         |> Enum.frequencies()
         |> Enum.find(fn {_, n} -> n > 1 end) do
      nil -> :ok
      {base, _} -> {:error, compile_error("#{inspect(name)} names #{base} twice in its head")}
    end
  end

  defp own_fields(name, %Struct{fields: {:keyed, pairs}}, scope) do
    with {:ok, fields} <- compile_fields(pairs, scope),
         :ok <- distinct_names(fields) do
      {:ok, fields}
    else
      {:error, reason} -> {:error, compile_error("#{inspect(name)}: #{reason}")}
    end
  end

  defp built_own_extras(name, raw, scope) do
    case own_extras(raw, scope) do
      {:ok, extras} -> {:ok, extras}
      {:error, reason} -> {:error, compile_error("#{inspect(name)}: #{reason}")}
    end
  end

  # A built body's extras (G1): its own when it says; otherwise what its
  # bases say, which must agree -- a base that says nothing is open and
  # agrees with any. What `extends` a closed base can pass as it only
  # when it stays closed and adds no field.
  defp merged_extras(name, found, own, own_extras, lookup) do
    known = Map.merge(lookup.registry.type_aliases, lookup.compiled)

    said =
      found
      |> Enum.map(& &1.extras)
      |> Enum.reject(&(&1 == TypeExpr.open_extras()))
      |> Enum.uniq_by(&in_place(&1, known, []))

    closed_base = Enum.find(found, &(&1.kind == :extends and &1.extras.closed))

    cond do
      closed_base &&
          (added_fields(own, closed_base) != [] or own_extras not in [nil, closed_base.extras]) ->
        {:error,
         compile_error(
           "#{inspect(name)} extends #{closed_base.name}, which is closed (- *): " <>
             "it adds no field and no extras, or includes #{closed_base.name} instead"
         )}

      own_extras != nil ->
        {:ok, own_extras}

      length(said) > 1 ->
        {:error,
         compile_error(
           "#{inspect(name)}: its bases differ in their extras (- * or * K => V); " <>
             "say which in its body"
         )}

      true ->
        {:ok, List.first(said, TypeExpr.open_extras())}
    end
  end

  defp added_fields(own, %{fields: fields}) do
    names = MapSet.new(fields, & &1.name)
    Enum.reject(own, &MapSet.member?(names, &1.name))
  end

  defp merged(name, found, own, drops, lookup) do
    known = Map.merge(lookup.registry.type_aliases, lookup.compiled)
    same? = fn a, b -> comparable(a, known) == comparable(b, known) end

    case Bases.merge(found, own, drops, same?) do
      {:ok, fields} -> {:ok, fields}
      {:error, reason} -> {:error, compile_error("#{inspect(name)}: #{reason}")}
    end
  end

  # `field` as it compares with the same field found another way: a
  # base of this document still names its sibling types, one already
  # loaded has them in place.
  defp comparable(field, known), do: %{field | type: in_place(field.type, known, [])}

  defp in_place({:named, name} = reference, known, path) do
    case Map.fetch(known, name) do
      {:ok, type} -> if name in path, do: reference, else: in_place(type, known, [name | path])
      :error -> reference
    end
  end

  defp in_place(type, known, path) when is_tuple(type),
    do: type |> Elixir.Tuple.to_list() |> Enum.map(&in_place(&1, known, path)) |> List.to_tuple()

  defp in_place(types, known, path) when is_list(types),
    do: Enum.map(types, &in_place(&1, known, path))

  defp in_place(%Field{} = field, known, path),
    do: %{field | type: in_place(field.type, known, path)}

  defp in_place(%{} = map, known, path) when not is_struct(map),
    do: Map.new(map, fn {k, v} -> {k, in_place(v, known, path)} end)

  defp in_place(leaf, _known, _path), do: leaf

  # A `{:case}` in a field names a field of the result (DXNS.md §4b), so
  # one whose field was dropped is refused.
  defp built_cases(name, fields) do
    names = MapSet.new(fields, & &1.name)

    case Enum.find(Enum.flat_map(fields, &case_names(&1.type)), &(not MapSet.member?(names, &1))) do
      nil ->
        :ok

      missing ->
        {:error, compile_error("#{inspect(name)}: {:case #{missing} ...} names no field of it")}
    end
  end

  defp case_names({:case, field, branches, otherwise}),
    do: [field | Enum.flat_map([otherwise | Enum.map(branches, &elem(&1, 1))], &case_names/1)]

  defp case_names({:shape, _, _, _}), do: []

  defp case_names(type) when is_tuple(type),
    do: type |> Elixir.Tuple.to_list() |> Enum.flat_map(&case_names/1)

  defp case_names(types) when is_list(types), do: Enum.flat_map(types, &case_names/1)
  defp case_names(_leaf), do: []

  # Each base of the head, found: its fields and the version it was taken
  # at. A base of the document that is itself built is built first.
  defp found_bases(name, bases, path, lookup, built) do
    Enum.reduce_while(bases, {:ok, [], built}, fn {kind, base, version}, {:ok, acc, built} ->
      full = base_target(Map.get(lookup.scope[@names], base, base), lookup, [])

      case found_base(full, version, path, lookup, built) do
        {:ok, {fields, extras}, at, built} ->
          base = %{kind: kind, name: full, fields: fields, extras: extras, version: at}
          {:cont, {:ok, [base | acc], built}}

        {:error, %Dextrin.Error{}} = error ->
          {:halt, error}

        {:error, reason} ->
          {:halt, {:error, compile_error("#{inspect(name)}: base #{base}: #{reason}")}}
      end
    end)
    |> case do
      {:ok, acc, built} -> {:ok, Enum.reverse(acc), built}
      {:error, _} = error -> error
    end
  end

  defp found_base(base, version, path, lookup, built) do
    case {Map.fetch(lookup.document, base), generic_use(base, lookup)} do
      {_, {:ok, body}} when version == nil ->
        {:ok, body, nil, built}

      {_, {:ok, _fields}} ->
        {:error, "a shape has no versions, so #{base}(#{version}) names none"}

      {{:ok, entry}, :none} ->
        document_base(base, undoc(entry), version, path, lookup, built)

      {:error, :none} ->
        loaded_base(base, version, lookup.registry, built)
    end
  end

  # A base named by a named type that stands for a schema or a shape
  # (`Human: Person`) is that schema or shape (G6 of design/typespec.md):
  # its name, followed through such names.
  defp base_target(name, lookup, seen) do
    known = Map.merge(lookup.registry.type_aliases, lookup.compiled)

    schema_or_shape? =
      match?(
        %Struct{name: kind} when kind in ["schema", "shape"],
        undoc(Map.get(lookup.document, name))
      )

    case {schema_or_shape?, name in seen, Map.fetch(known, name)} do
      {false, false, {:ok, type}} ->
        case undoc_type(type) do
          {kind, target} when kind in [:reference, :named] ->
            base_target(target, lookup, [name | seen])

          _ ->
            name
        end

      _ ->
        name
    end
  end

  # A named type that is one use of a generic standing for a shape
  # (`PageOfInt: {:of Page :integer}`): that shape's fields.
  defp generic_use(name, lookup) do
    known = Map.merge(lookup.registry.type_aliases, lookup.compiled)

    with {:ok, type} <- Map.fetch(known, name),
         {:apply, generic, args} <- undoc_type(type),
         {:ok, definition} <- Map.fetch(known, generic),
         {:generic, params, body} <- undoc_type(definition),
         {:ok, args} <- filled_args(generic, args, known),
         {_fields, _extras} = shape <- shape_body(TypeExpr.instantiate(params, body, args)) do
      {:ok, shape}
    else
      _ -> :none
    end
  end

  defp undoc_type({:doc, type, _notes}), do: undoc_type(type)
  defp undoc_type(type), do: type

  defp document_base(base, %Struct{name: "shape"}, version, _path, _lookup, _built)
       when version != nil,
       do: {:error, "a shape has no versions, so #{base}(#{version}) names none"}

  defp document_base(base, %Struct{name: kind} = raw, version, path, lookup, built)
       when kind in ["schema", "shape"] do
    cond do
      built_from?(raw) ->
        with {:ok, built} <- build(base, path, lookup, built),
             do:
               at_version(
                 base,
                 raw,
                 version,
                 {built[base].fields, built[base].extras},
                 lookup,
                 built
               )

      kind == "shape" ->
        {:ok, shape_body(Map.fetch!(lookup.compiled, base)), nil, built}

      true ->
        with {:ok, %Compiled{fields: fields, extras: extras}} <- compile_entry(raw, lookup.scope),
             do: at_version(base, raw, version, {fields, extras}, lookup, built)
    end
  end

  defp document_base(_base, _raw, _version, _path, _lookup, _built),
    do: {:error, "a base is a %schema or a %shape"}

  # A schema of the document, at the version the head asks for: its own,
  # or one already loaded. Without a version, the latest of them.
  defp at_version(_base, %Struct{name: "shape"}, nil, fields, _lookup, built),
    do: {:ok, fields, nil, built}

  defp at_version(base, %Struct{version: own}, version, fields, lookup, built) do
    own = own || 1

    # What is loaded, the resolver asked as for any other base.
    latest =
      case Registry.fetch_struct_schema(lookup.registry, base) do
        {:ok, %Compiled{version: loaded}, _registry} -> max(own, loaded)
        _none -> own
      end

    case version || latest do
      ^own -> {:ok, fields, own, built}
      other -> loaded_base(base, other, lookup.registry, built)
    end
  end

  defp loaded_base(base, version, registry, built) do
    found =
      if version,
        do: Registry.fetch_struct_schema(registry, base, version),
        else: Registry.fetch_struct_schema(registry, base)

    case found do
      {:ok, %Compiled{fields: fields, extras: extras, version: at}, _registry} ->
        {:ok, {fields, extras}, at, built}

      _not_a_schema ->
        case Map.fetch(registry.type_aliases, base) do
          {:ok, type} ->
            cond do
              version != nil -> {:error, "#{base}(#{version}) is not loaded"}
              shape = shape_body(type) -> {:ok, shape, nil, built}
              true -> {:error, "a base is a %schema or a %shape"}
            end

          :error when version != nil ->
            {:error, "#{base}(#{version}) is not loaded"}

          :error ->
            {:error, "no schema or shape is named #{base}"}
        end
    end
  end

  # A shape's fields and extras, as a base gives them.
  defp shape_body({:shape, _, fields, extras}), do: {fields, extras}
  defp shape_body({:doc, type, _}), do: shape_body(type)
  defp shape_body(_other), do: nil

  # A built shape joins the named types under its name, as a plain one
  # does, with its annotations.
  defp with_built_shapes(compiled, extending, built) do
    Result.reduce_ok(extending, compiled, fn {name, entry}, compiled ->
      shape = {:shape, name, built[name].fields, built[name].extras}

      case entry do
        %Tuple{items: [%Keyword{name: "doc"}, _inner, raw]} ->
          with {:ok, notes} <- annotations(raw, shape),
               do: {:ok, Map.put(compiled, name, {:doc, shape, notes})}

        _ ->
          {:ok, Map.put(compiled, name, shape)}
      end
    end)
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

  defp unguarded_names({:if, test, then, otherwise}),
    do: Enum.flat_map([test, then, otherwise], &unguarded_names/1)

  defp unguarded_names({:case, _field, branches, otherwise}),
    do: Enum.flat_map([otherwise | Enum.map(branches, &elem(&1, 1))], &unguarded_names/1)

  defp unguarded_names({:apply, name, args}), do: [name | Enum.flat_map(args, &unguarded_names/1)]
  defp unguarded_names({:generic, _params, body}), do: unguarded_names(body)
  defp unguarded_names(_guarded_or_leaf), do: []

  # `args` for the generic `name`: every parameter given or defaulted,
  # the defaults filled in, each argument within its parameter's bound
  # (G2 of design/typespec.md). A sibling not yet compiled takes them as
  # they are; they are filled once it is.
  defp filled_args(name, args, known) do
    case Map.fetch(known, name) do
      {:ok, {:generic, params, _}} ->
        given = length(args)
        required = Enum.count(params, &(param_default(&1) == :none))

        cond do
          given < required or given > length(params) ->
            {:error,
             "#{name} takes #{arity(required, length(params))} type argument(s), {:of #{name} ...} gives #{given}"}

          true ->
            filled = args ++ Enum.map(Enum.drop(params, given), &param_default/1)

            case Enum.find(Enum.zip(params, filled), fn {p, arg} ->
                   not within_bound?(arg, param_bound(p), known)
                 end) do
              nil ->
                {:ok, filled}

              {p, arg} ->
                {:error,
                 "{:of #{name} ...}'s #{TypeExpr.param_name(p)} takes what its bound takes; #{inspect_arg(arg)} is outside it"}
            end
        end

      {:ok, {:named, _}} ->
        {:ok, args}

      _ ->
        {:error, "{:of #{name} ...} names no generic"}
    end
  end

  defp arity(n, n), do: "#{n}"
  defp arity(required, total), do: "#{required} to #{total}"

  # A generic's parameters' bounds, under the scope keys a use inside its
  # body reads them by.
  defp param_bounds(params),
    do: Map.new(params, &{{@bound, TypeExpr.param_name(&1)}, param_bound(&1)})

  defp param_bound({_name, bound, _default}), do: bound
  defp param_bound(_name), do: :any

  defp param_default({_name, _bound, default}), do: default
  defp param_default(_name), do: :none

  defp inspect_arg({kind, name}) when kind in [:named, :reference, :param], do: name
  defp inspect_arg({:primitive, name}), do: ":" <> name
  defp inspect_arg(type), do: inspect_type(type)

  # Whether `arg` is `bound`, or narrower: a refine or annotation of it,
  # a name standing for it, a const or enum whose values it takes, or a
  # schema that extends it. Nothing broader is worked out: DXNS has no
  # general subtyping, so anything else is outside.
  # Whether `arg` is within `bound`. A type of the same document not yet
  # compiled stands as `{:named, name}` for itself; the check waits for
  # `resolved/3`, which asks again with every definition in hand.
  defp within_bound?(arg, bound, known) do
    if pending?(arg, known) or pending?(bound, known),
      do: true,
      else: within?(arg, bound, known)
  end

  defp pending?({:named, name}, known), do: Map.get(known, name) == {:named, name}
  defp pending?(_type, _known), do: false

  defp within?(_arg, :any, _known), do: true
  defp within?(arg, bound, _known) when arg == bound, do: true

  defp within?({:doc, arg, _}, bound, known), do: within_bound?(arg, bound, known)
  defp within?(arg, {:doc, bound, _}, known), do: within_bound?(arg, bound, known)
  defp within?({:refine, arg, _}, bound, known), do: within_bound?(arg, bound, known)

  defp within?({:enum, literals}, bound, known),
    do: Enum.all?(literals, &TypeExpr.matches?(bound_resolved(bound, known), &1))

  # A parameter passed on is within a bound when its own bound is.
  defp within?({:param, name}, bound, known) do
    case Map.fetch(known, {@bound, name}) do
      {:ok, own} -> within_bound?(own, bound, known)
      :error -> false
    end
  end

  defp within?({:named, name}, bound, known) do
    case Map.fetch(known, name) do
      {:ok, {:named, ^name}} -> false
      {:ok, type} -> within_bound?(type, bound, known)
      :error -> false
    end
  end

  # A pinned reference is within what its schema is within (G11).
  defp within?({:reference, name, _version}, bound, known),
    do: within_bound?({:reference, name}, bound, known)

  defp within?({:reference, name}, {:reference, base}, known),
    do: extends?(name, base, known, [])

  defp within?(arg, {:named, name}, known) do
    case Map.fetch(known, name) do
      {:ok, {:named, ^name}} -> false
      {:ok, bound} -> within_bound?(arg, bound, known)
      :error -> false
    end
  end

  defp within?(_arg, _bound, _known), do: false

  defp bound_resolved({:named, name} = bound, known) do
    case Map.fetch(known, name) do
      {:ok, {:named, ^name}} -> bound
      {:ok, type} -> bound_resolved(type, known)
      :error -> bound
    end
  end

  defp bound_resolved(bound, _known), do: bound

  # Whether the schema `name` extends `base`, directly or through others,
  # in this document or as loaded.
  defp extends?(name, name, _known, _seen), do: true

  defp extends?(name, base, known, seen) do
    if name in seen do
      false
    else
      name
      |> extended_bases(known)
      |> Enum.any?(&extends?(&1, base, known, [name | seen]))
    end
  end

  defp extended_bases(name, known) do
    lookup = Map.get(known, @lookup, %{registry: nil, document: %{}})

    case undoc(Map.get(lookup.document, name)) do
      %Struct{name: "schema", bases: bases} ->
        for {:extends, base, _} <- bases, do: base

      _ ->
        with %Registry{} = registry <- lookup.registry,
             {:ok, %Compiled{bases: bases}, _} <- Registry.fetch_struct_schema(registry, name) do
          for {:extends, base, _} <- bases, do: base
        else
          _ -> []
        end
    end
  end

  defp takes_arguments(name, known) do
    {:generic, params, _} = Map.fetch!(known, name)

    "#{name} is generic: write {:of #{name} #{Enum.map_join(params, " ", &TypeExpr.param_name/1)}}, with a type for each"
  end

  # A shape carries its own name; every other named type is its type.
  defp compile_named(
         name,
         %Tuple{items: [%Keyword{name: "generic"}, params, body]},
         scope
       )
       when is_list(params) do
    with {:ok, params} <- parameters(params, scope),
         names = Enum.map(params, &TypeExpr.param_name/1),
         scope =
           scope
           |> Map.merge(Map.new(names, &{&1, {:param, &1}}))
           |> Map.merge(param_bounds(params)),
         {:ok, body} <- compile_named(name, body, scope) do
      {:ok, {:generic, params, body}}
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
      {:ok, {:shape, nil, fields, extras}} -> {:ok, {:shape, name, fields, extras}}
      other -> other
    end
  end

  # `{:generic [t ...] body}`'s parameters, distinct: a bare symbol, or
  # `{t bound}` or `{t bound default}` (G2 of design/typespec.md), the
  # bound and default compiled in the scope around the generic. A bare
  # parameter stays its name; one with a bound or default is
  # `{name, bound, default}`, `:none` for no default.
  defp parameters(params, scope) do
    with {:ok, params} <-
           Result.reduce_ok(params, [], fn p, acc ->
             with {:ok, param} <- parameter(p, scope), do: {:ok, [param | acc]}
           end) do
      params = Enum.reverse(params)
      names = Enum.map(params, &TypeExpr.param_name/1)

      cond do
        params == [] ->
          {:error, "a generic's parameters are symbols: {:generic [t ...] body}"}

        length(Enum.uniq(names)) != length(names) ->
          {:error, "a generic names a parameter twice"}

        defaulted_then_required?(params) ->
          {:error, "a generic's parameter without a default cannot follow one with a default"}

        bad = Enum.find(params, &default_outside_bound?(&1, scope)) ->
          {:error, "#{TypeExpr.param_name(bad)}'s default is outside its own bound"}

        true ->
          {:ok, params}
      end
    end
  end

  defp parameter(%Symbol{name: name}, _scope), do: {:ok, name}

  defp parameter(%Tuple{items: [%Symbol{name: name}, bound | rest]}, scope)
       when length(rest) <= 1 do
    with {:ok, bound} <- compile_type_expr(bound, scope),
         {:ok, default} <- maybe_compile(List.first(rest, :none), scope),
         do: {:ok, {name, bound, default}}
  end

  defp parameter(other, _scope),
    do:
      {:error,
       "a generic's parameter is a symbol, {t bound} or {t bound default}, not #{shown(other)}"}

  defp defaulted_then_required?(params) do
    params
    |> Enum.map(&(param_default(&1) != :none))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(&(&1 == [true, false]))
  end

  defp default_outside_bound?({_name, bound, default}, scope) when default != :none,
    do: not within_bound?(default, bound, scope)

  defp default_outside_bound?(_param, _scope), do: false

  # A named type's own definition resolved: a generic's body, with its
  # parameters left standing, or the type itself.
  defp entry_resolved({:generic, params, body}, known, path) do
    with {:ok, body} <- resolved(body, Map.merge(known, param_bounds(params)), path),
         do: {:ok, {:generic, params, body}}
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
    with {:ok, args} <-
           Result.reduce_ok(args, [], fn arg, acc ->
             with {:ok, arg} <- resolved(arg, compiled, path), do: {:ok, [arg | acc]}
           end),
         {:ok, args} <- filled_args(name, Enum.reverse(args), compiled),
         do: {:ok, {:apply, name, args}}
  end

  defp resolved({:generic, _, _}, _compiled, _path),
    do: {:error, "a generic is a named type's whole definition, {:generic [t ...] body}"}

  defp resolved({:shape, name, fields, extras}, compiled, path) do
    with {:ok, fields} <-
           Result.reduce_ok(fields, [], fn field, acc ->
             with {:ok, type} <- resolved(field.type, compiled, path),
                  do: {:ok, [%{field | type: type} | acc]}
           end),
         {:ok, extras} <- resolved_shape_extras(extras, compiled, path),
         do: {:ok, {:shape, name, Enum.reverse(fields), extras}}
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

  defp resolved({:if, test, then, otherwise}, compiled, path) do
    with {:ok, test} <- resolved(test, compiled, path),
         {:ok, then} <- resolved(then, compiled, path),
         {:ok, otherwise} <- resolved(otherwise, compiled, path),
         do: {:ok, {:if, test, then, otherwise}}
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

  defp resolved_shape_extras(%{entries: entries} = extras, compiled, path) do
    entries
    |> Result.reduce_ok([], fn {key, value}, acc ->
      with {:ok, key} <- resolved(key, compiled, path),
           {:ok, value} <- resolved(value, compiled, path),
           do: {:ok, [{key, value} | acc]}
    end)
    |> case do
      {:ok, entries} -> {:ok, %{extras | entries: Enum.reverse(entries)}}
      {:error, _} = error -> error
    end
  end

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
  # NaN and the infinities are atoms too, and numbers, not keywords.
  defp atomize_back(atom)
       when is_atom(atom) and
              atom not in [nil, true, false, :nan, :positive_infinity, :negative_infinity],
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
  defp compile_entry(
         %Struct{name: "schema", version: version, fields: {:keyed, pairs}} = raw,
         aliases
       ) do
    with :ok <- not_format_1_0(pairs),
         {:ok, fields} <- compile_fields(pairs, aliases),
         :ok <- distinct_names(fields),
         :ok <- cases_name_fields(pairs, fields),
         {:ok, extras} <- own_extras(raw, aliases) do
      {:ok,
       %Compiled{version: version || 1, fields: fields, extras: extras || TypeExpr.open_extras()}}
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
  # written as now (DXNS.md §4), rather than that a field has no known
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
           "directly, %schema(N){field: type, ...}, and refuses undeclared fields with strict: true (DXNS.md §4)"},
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
        with {:ok, type} <- compile_type_expr(get(field_pairs, "type", :any_keyword), aliases),
             {:ok, default} <-
               field_default(
                 get(field_pairs, "default", :none),
                 get(field_pairs, "computed", :none),
                 type,
                 aliases
               ) do
          {:ok,
           %Field{
             name: name,
             required: required,
             type: type,
             default: default,
             description: get(field_pairs, "description")
           }}
        end

      type_expr_value ->
        with {:ok, type} <- compile_type_expr(type_expr_value, aliases) do
          {:ok, %Field{name: name, required: required, type: type}}
        end
    end
  end

  # A field's default: the value written, or one computed when the field
  # is filled (G8 of design/typespec.md). `computed: :now` takes a date,
  # time, datetime or local date-time, possibly refined, annotated or
  # nilable, and never stands beside a `default`.
  defp field_default(default, :none, _type, _aliases), do: {:ok, default}

  defp field_default(default, _computed, _type, _aliases) when default != :none,
    do: {:error, "a %field has a default or is computed, not both"}

  defp field_default(:none, computed, type, aliases) do
    cond do
      name_of(computed) != "now" ->
        {:error, "a %field is computed: :now, the one value there is; not #{shown(computed)}"}

      kind = temporal_kind(type, aliases) ->
        {:ok, {:computed, "now", kind}}

      true ->
        {:error,
         "a %field computed: :now is a date, time, datetime or local-datetime, not #{inspect_type(type)}"}
    end
  end

  defp temporal_kind({:primitive, kind}, _aliases)
       when kind in ["date", "time", "datetime", "local-datetime"],
       do: kind

  defp temporal_kind({form, type, _}, aliases) when form in [:refine, :doc],
    do: temporal_kind(type, aliases)

  defp temporal_kind({:nilable, type}, aliases), do: temporal_kind(type, aliases)

  defp temporal_kind({:named, name}, aliases) do
    case Map.fetch(aliases, name) do
      {:ok, {:named, ^name}} -> nil
      {:ok, type} -> temporal_kind(type, aliases)
      :error -> nil
    end
  end

  defp temporal_kind(_type, _aliases), do: nil

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
  # A shape built from others is a named entry of its document (DXNS.md
  # §4b), so that its bases are found before it is used.
  defp compile_type_expr(%Struct{name: "shape", bases: bases, drops: drops}, _aliases)
       when bases != [] or drops not in [[], ["*"]],
       do:
         {:error,
          "a shape built from others is an entry of its own, Name: %shape extends Base {...}, " <>
            "used by its name"}

  defp compile_type_expr(
         %Struct{name: "shape", version: nil, fields: {:keyed, pairs}} = raw,
         aliases
       ) do
    with {:ok, fields} <- compile_fields(pairs, aliases),
         :ok <- distinct_names(fields),
         :ok <- cases_name_fields(pairs, fields),
         {:ok, extras} <- own_extras(raw, aliases) do
      {:ok, {:shape, nil, fields, extras || TypeExpr.open_extras()}}
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

  # Sugar (DXNS.md §1, Jan, 2026-10-20): protobuf's and MongoDB's sized
  # numbers as their ranges, `:float32` as single precision, `:number` as
  # every kind of number.
  defp compile_type_expr(%Keyword{name: name}, _aliases) when is_map_key(@sized, name) do
    {least, most} = Map.fetch!(@sized, name)
    {:ok, {:refine, {:primitive, "integer"}, %{"min" => least, "max" => most}}}
  end

  defp compile_type_expr(%Keyword{name: "float32"}, _aliases),
    do: {:ok, {:refine, {:primitive, "float"}, %{"float32" => true}}}

  defp compile_type_expr(%Keyword{name: "number"}, _aliases) do
    {:ok, {:any_of, Enum.map(~w(integer float decimal rational), &{:primitive, &1})}}
  end

  # DXN 0.2's timestamp type, now a datetime in UTC (DXNS.md §2, Jan,
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

  # `Pet(1)`, which DXN reads as `{:at Pet 1}` (G11, DXNS.md §5c): a
  # name pinned to one version. A named type's version is put in place --
  # a sibling at that version stays by name -- and a version of a named
  # type that is not loaded is a compile error; any other name is a
  # schema's, checked when a value meets it.
  defp compile_type_expr(
         %Tuple{items: [%Keyword{name: "at"}, %Symbol{name: written}, version]},
         aliases
       )
       when is_integer(version) and version > 0 do
    name = full_name(written, aliases)
    registry = aliases |> Map.get(@lookup, %{}) |> Map.get(:registry)
    sibling_version = aliases |> Map.get(@versions, %{}) |> Map.get(name)

    cond do
      Map.get(aliases, name) == {:named, name} and sibling_version == version ->
        {:ok, {:named, name}}

      registry && match?({:ok, _}, Registry.fetch_type_version(registry, name, version)) ->
        {:ok, type} = Registry.fetch_type_version(registry, name, version)
        {:ok, type}

      named_type?(name, aliases, registry) ->
        {:error, "#{Dextrin.Tuple.pinned_text(name, version)} is not loaded"}

      true ->
        {:ok, {:reference, name, version}}
    end
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "at"} | _]}, _aliases),
    do: {:error, "a pinned name is Name(N), {:at Name N}, N a positive integer"}

  # `{:of Name type ...}`: one use of the generic `Name`.
  defp compile_type_expr(
         %Tuple{items: [%Keyword{name: "of"}, %Symbol{name: written} | args]},
         aliases
       )
       when args != [] do
    name = full_name(written, aliases)

    with {:ok, args} <- map_compile(args, aliases),
         {:ok, args} <- filled_args(name, args, aliases),
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
  # one item or a `{:repeat ...}` (DXNS.md §1a).
  defp compile_type_expr(%Tuple{items: [%Keyword{name: "list-items"} | particles]}, aliases) do
    with {:ok, ps} <- particles(particles, aliases), do: {:ok, {:list_items, ps}}
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "tuple-of-all"}, elem]}, aliases) do
    with {:ok, t} <- compile_type_expr(elem, aliases), do: {:ok, {:tuple_of_all, t}}
  end

  # `{:const v}`: the one value `v`, `{:enum v}`.
  defp compile_type_expr(%Tuple{items: [%Keyword{name: "const"}, literal]}, _aliases),
    do: {:ok, {:enum, [literal]}}

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "const"} | _]}, _aliases),
    do: {:error, "a const is {:const value}"}

  # `{:if I T E}`: JSON Schema's if, then and else; `E` is `:any` when
  # not given.
  defp compile_type_expr(%Tuple{items: [%Keyword{name: "if"}, test, then | rest]}, aliases)
       when length(rest) <= 1 do
    with {:ok, test} <- compile_type_expr(test, aliases),
         {:ok, then} <- compile_type_expr(then, aliases),
         {:ok, otherwise} <- compile_type_expr(List.first(rest, Keyword.new("any")), aliases),
         do: {:ok, {:if, test, then, otherwise}}
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "if"} | _]}, _aliases),
    do: {:error, "an if is {:if test then else}, else :any when left out"}

  # `{:doc type %{...}}`: the type, annotated (DXNS.md §1b).
  defp compile_type_expr(%Tuple{items: [%Keyword{name: "doc"}, inner, raw]}, aliases) do
    with {:ok, type} <- compile_type_expr(inner, aliases),
         {:ok, notes} <- annotations(raw, type),
         do: {:ok, {:doc, type, notes}}
  end

  defp compile_type_expr(%Tuple{items: [%Keyword{name: "doc"} | _]}, _aliases),
    do: {:error, "a doc is {:doc type %{description: ..., ...}}"}

  # `{:tagged name type}`: a custom tag of that name, its value a type
  # (DXNS.md §1).
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
    do: {:error, "unrecognized type expression: #{shown(other)}"}

  # Whether `name` is a named type -- a sibling of this document, or one
  # loaded -- rather than a schema: what a pin to a version not loaded is
  # refused for (Way B). The scope's own keys are atoms, never names.
  defp named_type?(name, aliases, registry) do
    sibling? = Map.get(aliases, name) == {:named, name}
    loaded? = registry != nil and Map.has_key?(registry.type_versions, name)
    sibling? or loaded? or (Map.has_key?(aliases, name) and not is_atom(name))
  end

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

  # A refine's constraints by name, every key one DXNS.md §2 knows and
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
      key -> {:error, "#{key} is no refine constraint (DXNS.md §2)"}
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
           ~r/^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,126}\/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,126}\z/,
           arg
         ),
       do: :ok,
       else: {:takes, "a media type, \"type/subtype\""}
  end

  defp argument(_key, _arg), do: :ok

  defp offset?("Z"), do: true

  defp offset?(text) when is_binary(text),
    do: Regex.match?(~r/^[+-](?:[01][0-9]|2[0-3]):[0-5][0-9]\z/, text)

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

  @annotation_keys ~w(title description examples read-only write-only deprecated meta values
                      discriminator secret key visibility messages)

  # The stages a field may be seen in (TypeSpec's Lifecycle; G5 of
  # design/typespec.md).
  @visibilities ~w(create read update delete query)

  # Every refine key, the names `messages` may give a message for.
  @refine_keys ~w(min max exclusive-min exclusive-max multiple-of min-length max-length
                  min-bytes max-bytes pattern format encoding media-type content encodes
                  encodes-seq min-count max-count contains min-contains max-contains unique
                  unique-by finite float32 min-precision max-precision min-exponent
                  max-exponent bits before-now after-now within resolution offsets version
                  prefix)

  # A doc's annotations by name, each of its kind (DXNS.md §1b); `type`
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
        {:ok, named} -> with :ok <- visibility_alone(named), do: annotated_values(named)
        error -> error
      end
    end
  end

  defp annotations(raw, _type),
    do: {:error, "a doc's annotations are a map, %{description: ...}, not #{shown(raw)}"}

  # `read-only` says `visibility: [:read]`; the two together would say
  # it twice, perhaps differently.
  defp visibility_alone(%{"visibility" => _, "read-only" => _}),
    do: {:error, "a doc's read-only and visibility say the same thing; give visibility alone"}

  defp visibility_alone(_named), do: :ok

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

  defp annotation("secret", value, _type),
    do: if(is_boolean(value), do: :ok, else: {:takes, "true or false"})

  defp annotation("key", value, _type),
    do:
      if(is_boolean(value) or is_binary(value), do: :ok, else: {:takes, "true, false or a name"})

  defp annotation("visibility", value, _type) when is_list(value) do
    case Enum.reject(value, &(name_of(&1) in @visibilities)) do
      [] ->
        :ok

      [other | _] ->
        {:error,
         "a doc's visibility names #{shown(other)}, which is none of #{Enum.join(@visibilities, ", ")}"}
    end
  end

  defp annotation("visibility", _value, _type),
    do: {:takes, "a list of #{Enum.join(@visibilities, ", ")}"}

  defp annotation("messages", value, _type) when is_map(value) and not is_struct(value) do
    Enum.find_value(Enum.sort(value), :ok, fn {key, message} ->
      cond do
        name_of(key) not in @refine_keys ->
          {:error, "a doc's messages are for refine keys; #{shown(key)} is none"}

        not is_binary(message) ->
          {:error, "a doc's messages are strings, not #{shown(message)}"}

        true ->
          nil
      end
    end)
  end

  defp annotation("messages", _value, _type),
    do: {:takes, "a map of refine keys to messages"}

  defp annotation("discriminator", value, type) do
    cond do
      not (match?(%Keyword{}, value) or match?(%Symbol{}, value) or is_binary(value)) ->
        {:takes, "a field's name"}

      not variants?(type) ->
        {:error,
         "a doc's discriminator stands on an any-of or a one-of, not #{inspect_type(type)}"}

      true ->
        :ok
    end
  end

  defp annotation(key, _value, _type),
    do: {:error, "#{key} is no annotation; a doc holds #{Enum.join(@annotation_keys, ", ")}"}

  # `values`' annotation maps keyed by name, as the doc's own are.
  defp annotated_values(%{"values" => values} = named) do
    {:ok,
     %{
       plain_names(named)
       | "values" =>
           Map.new(values, fn {literal, notes} ->
             {:ok, notes} = annotations(notes, :value)
             {literal, notes}
           end)
     }}
  end

  defp annotated_values(named), do: {:ok, plain_names(named)}

  # The annotations whose values are names, as strings: what a reader
  # compares, whatever spelling the document gave.
  defp plain_names(named) do
    named
    |> then(
      &if(Map.has_key?(&1, "discriminator"),
        do: Map.update!(&1, "discriminator", fn d -> name_of(d) end),
        else: &1
      )
    )
    |> then(
      &if(Map.has_key?(&1, "visibility"),
        do: Map.update!(&1, "visibility", fn v -> Enum.map(v, fn n -> name_of(n) end) end),
        else: &1
      )
    )
    |> then(
      &if(Map.has_key?(&1, "messages"),
        do: Map.update!(&1, "messages", fn m -> Map.new(m, fn {k, v} -> {name_of(k), v} end) end),
        else: &1
      )
    )
  end

  defp variants?({:doc, type, _notes}), do: variants?(type)
  defp variants?({form, _types}) when form in [:any_of, :one_of], do: true
  defp variants?(_type), do: false

  defp inspect_type({form, _}) when is_atom(form),
    do: String.replace(Atom.to_string(form), "_", "-")

  defp inspect_type({form, _, _}) when is_atom(form),
    do: String.replace(Atom.to_string(form), "_", "-")

  defp inspect_type(type), do: inspect(type)

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
