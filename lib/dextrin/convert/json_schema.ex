defmodule Dextrin.Convert.JsonSchema do
  @moduledoc """
  JSON Schema to DXNS (T674, design/json-schema.md): drafts 04, 06, 07,
  2019-09 and 2020-12, and MongoDB's `$jsonSchema` with `bsonType`.

  `to_dxns/2` takes one or more schema documents and answers the DXNS
  document as a DXN value -- a map from each name to its type -- and the
  list of what it could not say exactly. Each such place is also kept in
  the type's `meta`, so nothing is lost silently.

  The mapping follows the decisions of design/json-schema.md:

    * an object schema becomes a `%shape` (plain maps, as JSON data is),
      or a `%schema` for a named definition under `structs: true`;
    * a string with a date or time, uuid or uri format becomes that DXN
      type (logical types); any other known format is `format:`, an
      unknown one is kept in `meta`;
    * every keyword applies only to values of its own kind, as JSON
      Schema says: a schema with no `type` checks a string's keywords on
      strings only, with `{:if :string ...}`;
    * `patternProperties`, `additionalProperties` and `propertyNames`
      become `* K => V` entries and `- *`; `unevaluatedProperties` and
      `unevaluatedItems` are worked out where it can be told from the
      schema alone;
    * references stay within the documents given: nothing is fetched.
  """

  alias Dextrin.{Keyword, Struct, Symbol, Tuple}

  @order :__order__

  @typedoc "One place the conversion is not exact: where, and why."
  @type inexact :: %{path: String.t(), why: String.t()}

  @typedoc """
  A schema document to convert: its JSON text, or one decoded with
  `decode_json/1`, and where it came from (a path or a URI), which
  relative references resolve against when it has no `$id`.
  """
  @type source :: {String.t(), String.t() | map()}

  @doc """
  JSON text decoded with each object's key order kept, which the
  converter needs: properties become fields in the order written.
  """
  @spec decode_json(String.t()) :: {:ok, term()} | {:error, String.t()}
  def decode_json(text) when is_binary(text) do
    finish = fn acc, old ->
      pairs = Enum.reverse(acc)
      {pairs |> Map.new() |> Map.put(@order, Enum.uniq(Enum.map(pairs, &elem(&1, 0)))), old}
    end

    # JSON's null is DXN's nil from the start, so a keyword set to null
    # reads as one left out. Elixir's JSON, not OTP's :json, which OTP 26
    # does not have.
    case JSON.decode(text, :ok, object_finish: finish, null: nil) do
      {value, :ok, rest} ->
        if String.trim(rest) == "",
          do: {:ok, value},
          else: {:error, "text after the JSON value"}

      {:error, why} ->
        {:error, "not JSON: #{inspect(why)}"}
    end
  end

  @doc """
  Converts `sources`, the first being the root, to a DXNS document.

  Options:

    * `:name` -- the root's name (otherwise its `title`, otherwise `Root`);
    * `:draft` -- `"04"`, `"06"`, `"07"`, `"2019-09"` or `"2020-12"`, for
      documents with no `$schema` (default 2020-12);
    * `:mongo` -- read the schema as MongoDB's (also when `bsonType`
      appears anywhere);
    * `:structs` -- write named object schemas as `%schema`.

  Answers `{:ok, %{document: map, inexact: [inexact]}}`, or
  `{:error, reason}` for a schema that cannot be read: a reference to a
  document not given, an unknown draft, a value that is no schema.
  """
  @spec to_dxns([source()] | source(), keyword()) ::
          {:ok, %{document: map(), inexact: [inexact()]}} | {:error, String.t()}
  def to_dxns(sources, opts \\ [])
  def to_dxns({_where, _schema} = source, opts), do: to_dxns([source], opts)

  def to_dxns([_ | _] = sources, opts) do
    with {:ok, docs} <- decoded(sources),
         {:ok, draft} <- draft(docs, opts) do
      mongo = Elixir.Keyword.get(opts, :mongo, false) or Enum.any?(docs, &bson?(elem(&1, 1)))
      index = index(docs, draft)

      state = %{
        index: index,
        draft: draft,
        mongo: mongo,
        structs: Elixir.Keyword.get(opts, :structs, false),
        # Formats and content keywords check values before 2019-09; from
        # then on they are annotations, unless asked otherwise.
        assert_formats:
          Elixir.Keyword.get(opts, :assert_formats, false) or draft in ["04", "06", "07"],
        names: %{},
        taken: MapSet.new(),
        inexact: []
      }

      state =
        case docs do
          [{_, %{"$schema" => uri}} | _] when is_binary(uri) ->
            if draft_of(uri),
              do: state,
              else: %{
                state
                | inexact: [
                    %{path: "#/$schema", why: "unknown metaschema #{uri}, read as draft #{draft}"}
                  ]
              }

          _ ->
            state
        end

      with {:ok, state} <- name_targets(docs, opts, state) do
        convert_all(state)
      end
    end
  catch
    {:json_schema, reason} -> {:error, reason}
  end

  # ---- reading ---------------------------------------------------------------

  defp decoded(sources) do
    Enum.reduce_while(sources, {:ok, []}, fn {where, schema}, {:ok, acc} ->
      case schema do
        text when is_binary(text) ->
          case decode_json(text) do
            {:ok, value} -> {:cont, {:ok, [{where, value} | acc]}}
            {:error, why} -> {:halt, {:error, "#{where}: #{why}"}}
          end

        value ->
          {:cont, {:ok, [{where, value} | acc]}}
      end
    end)
    |> case do
      {:ok, docs} -> {:ok, Enum.reverse(docs)}
      error -> error
    end
  end

  @drafts %{
    "http://json-schema.org/draft-04/schema" => "04",
    "http://json-schema.org/draft-06/schema" => "06",
    "http://json-schema.org/draft-07/schema" => "07",
    "https://json-schema.org/draft/2019-09/schema" => "2019-09",
    "https://json-schema.org/draft/2020-12/schema" => "2020-12"
  }

  defp draft([{_where, root} | _], opts) do
    case root do
      %{"$schema" => uri} when is_binary(uri) ->
        case Map.fetch(
               @drafts,
               uri
               |> String.trim_trailing("#")
               |> String.replace_prefix(
                 "https://json-schema.org/draft-0",
                 "http://json-schema.org/draft-0"
               )
             ) do
          {:ok, draft} -> {:ok, draft}
          # A metaschema of its own: read as the draft asked for, and
          # said so.
          :error -> draft([{"", Map.delete(root, "$schema")}], opts)
        end

      _ ->
        draft = Elixir.Keyword.get(opts, :draft, "2020-12")

        if draft in Map.values(@drafts),
          do: {:ok, draft},
          else: {:error, "unknown draft #{draft}: 04, 06, 07, 2019-09 or 2020-12"}
    end
  end

  defp draft_of(uri),
    do:
      Map.get(
        @drafts,
        uri
        |> String.trim_trailing("#")
        |> String.replace_prefix(
          "https://json-schema.org/draft-0",
          "http://json-schema.org/draft-0"
        )
      )

  defp bson?(%{"bsonType" => _}), do: true

  defp bson?(map) when is_map(map),
    do: map |> without_order() |> Map.values() |> Enum.any?(&bson?/1)

  defp bson?(list) when is_list(list), do: Enum.any?(list, &bson?/1)
  defp bson?(_), do: false

  # ---- the index: every schema by URI and pointer ---------------------------------

  # Every subschema reachable by a reference: by its document's base
  # and JSON pointer, by its own `$id`, and by its `$anchor`. Keys are
  # `{base, "#/pointer"}`; `ids` maps any URI a reference may name to one.
  defp index(docs, draft) do
    Process.put(:dextrin_json_schema_draft, draft)

    Enum.reduce(docs, %{nodes: %{}, ids: %{}, roots: []}, fn {where, root}, acc ->
      unless is_map(root) or is_boolean(root),
        do: throw({:json_schema, "#{where}: a schema is an object or a boolean"})

      base = resource_id(root, base_of(where))
      acc = %{acc | roots: acc.roots ++ [{where, base}]}

      # The URI a document was read from names it too, whatever its $id.
      acc =
        if base != base_of(where),
          do: %{acc | ids: Map.put(acc.ids, base_of(where), {base, "#"})},
          else: acc

      if is_boolean(root) do
        entry = {root, base, base, ""}

        %{
          acc
          | nodes: Map.put(acc.nodes, {base, "#"}, entry),
            ids: Map.put(acc.ids, base, {base, "#"})
        }
      else
        walk_index(root, base, "", [], acc)
      end
    end)
  end

  defp base_of(where) do
    if String.contains?(where, "://"), do: strip_fragment(where), else: "file:///" <> where
  end

  # Before 2019-09 a `$ref` hides its siblings, `$id` included; and an
  # `$id` that is only a fragment, `#foo`, is an anchor, not a new base.
  defp resource_id(%{"$ref" => _} = node, base) when not is_map_key(node, :checked_ref) do
    if Process.get(:dextrin_json_schema_draft) in ["04", "06", "07"],
      do: base,
      else: resource_id(Map.put(node, :checked_ref, true), base)
  end

  defp resource_id(%{"$id" => "#" <> _}, base), do: base

  defp resource_id(%{"$id" => id} = _node, base) when is_binary(id),
    do: strip_fragment(resolve_uri(base, id))

  defp resource_id(%{"id" => id} = node, base) when is_binary(id) do
    if Map.has_key?(node, "$schema") or String.contains?(id, "/") or
         not String.starts_with?(id, "#"),
       do: strip_fragment(resolve_uri(base, id)),
       else: base
  end

  defp resource_id(_node, base), do: base

  # `outer` holds the enclosing resources' bases with this schema's
  # pointer from each: a JSON pointer may cross into an embedded
  # resource, so the schema is found from every one of them.
  defp walk_index(node, base, pointer, outer, acc) when is_map(node) do
    own = resource_id(node, base)
    key = {own, if(own == base, do: "#" <> pointer, else: "#")}
    entry = {node, own, base, pointer}
    acc = put_in(acc, [:nodes, {base, "#" <> pointer}], entry)

    acc =
      Enum.reduce(outer, acc, fn {b, p}, acc ->
        update_in(acc, [:nodes], &Map.put_new(&1, {b, "#" <> p}, entry))
      end)

    acc = put_in(acc, [:nodes, key], {node, own, base, pointer})
    # A document's root, or a schema with an `$id` of its own, is what
    # its URI names; a schema inside it is not.
    acc = if own != base or pointer == "", do: put_in(acc, [:ids, own], key), else: acc

    acc =
      Enum.reduce(["$anchor", "$dynamicAnchor"], acc, fn anchor, acc ->
        case node do
          %{^anchor => name} when is_binary(name) -> put_in(acc, [:ids, own <> "#" <> name], key)
          _ -> acc
        end
      end)

    acc =
      Enum.reduce(["id", "$id"], acc, fn kw, acc ->
        case node do
          %{^kw => "#" <> name} when name != "" ->
            put_in(acc, [:ids, own <> "#" <> name], key)

          %{^kw => id} when is_binary(id) ->
            case split_fragment(resolve_uri(base, id)) do
              {_doc, anchor} when anchor not in [nil, ""] ->
                put_in(acc, [:ids, own <> "#" <> anchor], key)

              _ ->
                acc
            end

          _ ->
            acc
        end
      end)

    # Below a schema with an `$id` of its own, pointers start again from it.
    {child_base, child_pointer} = if own != base, do: {own, ""}, else: {base, pointer}
    child_outer = if own != base, do: [{base, pointer} | outer], else: outer

    node
    |> without_order()
    |> Enum.reduce(acc, fn {k, v}, acc ->
      if k in ["enum", "const", "examples", "default"],
        do: acc,
        else:
          walk_index(
            v,
            child_base,
            child_pointer <> "/" <> escape(k),
            deeper(child_outer, k),
            acc
          )
    end)
  end

  defp walk_index(list, base, pointer, outer, acc) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {v, i}, acc ->
      walk_index(v, base, pointer <> "/#{i}", deeper(outer, Integer.to_string(i)), acc)
    end)
  end

  # A boolean schema has no keywords, but a reference may name it.
  defp walk_index(bool, base, pointer, outer, acc) when is_boolean(bool) do
    entry = {bool, base, base, pointer}

    Enum.reduce([{base, pointer} | outer], acc, fn {b, p}, acc ->
      update_in(acc, [:nodes], &Map.put_new(&1, {b, "#" <> p}, entry))
    end)
  end

  defp walk_index(_leaf, _base, _pointer, _outer, acc), do: acc

  defp deeper(outer, segment),
    do: Enum.map(outer, fn {b, p} -> {b, p <> "/" <> escape(segment)} end)

  defp escape(key), do: key |> String.replace("~", "~0") |> String.replace("/", "~1")

  defp unescape(segment),
    do: segment |> URI.decode() |> String.replace("~1", "/") |> String.replace("~0", "~")

  defp strip_fragment(uri), do: uri |> String.split("#", parts: 2) |> hd()

  defp resolve_uri(base, ref) do
    cond do
      ref == "" -> base
      String.starts_with?(ref, "#") -> base <> ref
      true -> URI.merge(URI.parse(base), ref) |> URI.to_string()
    end
  rescue
    _ -> ref
  end

  # The node a reference names, as `{key, node}`.
  defp target(state, base, ref) do
    uri = resolve_uri(base, ref)
    {doc, fragment} = split_fragment(uri)

    found =
      case fragment do
        nil -> Map.get(state.index.ids, doc)
        "" -> Map.get(state.index.ids, doc)
        "/" <> _ -> pointer_target(state, doc, fragment)
        anchor -> Map.get(state.index.ids, doc <> "#" <> anchor)
      end

    case found do
      nil ->
        throw({:json_schema, "$ref #{ref} names no schema among those given (resolved: #{uri})"})

      key ->
        {key, elem(Map.fetch!(state.index.nodes, key), 0)}
    end
  end

  defp split_fragment(uri) do
    case String.split(uri, "#", parts: 2) do
      [doc] -> {doc, nil}
      [doc, fragment] -> {doc, fragment}
    end
  end

  defp pointer_target(state, doc, fragment) do
    pointer =
      fragment |> String.split("/") |> tl() |> Enum.map_join("/", &(&1 |> unescape() |> escape()))

    key = {doc, "#/" <> pointer}

    case Map.fetch(state.index.ids, doc) do
      {:ok, {base, "#" <> prefix}} when prefix != "" ->
        joined = {base, "#" <> prefix <> "/" <> pointer}
        if Map.has_key?(state.index.nodes, joined), do: joined, else: key

      _ ->
        if Map.has_key?(state.index.nodes, key), do: key
    end
  end

  # ---- naming -------------------------------------------------------------------

  # Every schema that gets a name of its own: each document's root, its
  # `$defs` (`definitions`) entries, and whatever a reference names.
  defp name_targets(docs, opts, state) do
    [{_, root_base} | _] = state.index.roots

    state =
      state.index.roots
      |> Enum.with_index()
      |> Enum.reduce(state, fn {{where, base}, i}, state ->
        {key, node} = root_key(state, base)

        name =
          cond do
            i == 0 -> Elixir.Keyword.get(opts, :name) || title_name(node) || "Root"
            true -> title_name(node) || file_name(where)
          end

        name(state, key, name)
      end)

    state =
      Enum.reduce(docs, state, fn {where, root}, state ->
        base = resource_id(root, base_of(where))

        Enum.reduce(["$defs", "definitions"], state, fn defs, state ->
          case root do
            %{^defs => entries} when is_map(entries) ->
              entries
              |> ordered_pairs()
              |> Enum.reduce(state, fn {k, _}, state ->
                name(state, {base, "#/" <> defs <> "/" <> escape(k)}, k)
              end)

            _ ->
              state
          end
        end)
      end)

    state = name_references(docs, state)
    _ = root_base
    {:ok, state}
  end

  defp root_key(state, base) do
    key = Map.fetch!(state.index.ids, base)
    {key, elem(Map.fetch!(state.index.nodes, key), 0)}
  end

  defp title_name(%{"title" => title}) when is_binary(title) and title != "",
    do: identifier(title)

  defp title_name(_), do: nil

  defp file_name(where),
    do: where |> Path.basename() |> String.split(".") |> hd() |> identifier()

  # A name for `key`, made an identifier and unique.
  defp name(state, key, wanted) do
    if Map.has_key?(state.names, key) do
      state
    else
      base = identifier(wanted)

      name =
        Stream.iterate(1, &(&1 + 1))
        |> Stream.map(fn i -> if i == 1, do: base, else: base <> Integer.to_string(i) end)
        |> Enum.find(&(not MapSet.member?(state.taken, &1)))

      %{state | names: Map.put(state.names, key, name), taken: MapSet.put(state.taken, name)}
    end
  end

  @doc false
  def identifier(text) do
    cleaned =
      text
      |> String.replace(~r/[^\p{L}\p{N}_-]+/u, "_")
      |> String.trim("_")

    cond do
      cleaned == "" -> "T"
      Regex.match?(~r/^[\p{L}_]/u, cleaned) -> cleaned
      true -> "T" <> cleaned
    end
  end

  # A reference to a schema with no name yet names it from its path.
  defp name_references(docs, state) do
    Enum.reduce(docs, state, fn {where, root}, state ->
      collect_refs(root, resource_id(root, base_of(where)), state)
    end)
  end

  defp collect_refs(node, base, state) when is_map(node) do
    base = resource_id(node, base)

    state =
      Enum.reduce(["$ref", "$recursiveRef", "$dynamicRef"], state, fn kw, state ->
        case node do
          %{^kw => ref} when is_binary(ref) ->
            {key, _node} = target(state, base, ref)
            name(state, key, path_name(state, key))

          _ ->
            state
        end
      end)

    node
    |> without_order()
    |> Enum.reduce(state, fn {k, v}, state ->
      if k in ["enum", "const", "examples", "default"],
        do: state,
        else: collect_refs(v, base, state)
    end)
  end

  defp collect_refs(list, base, state) when is_list(list),
    do: Enum.reduce(list, state, &collect_refs(&1, base, &2))

  defp collect_refs(_leaf, _base, state), do: state

  defp path_name(state, {base, "#" <> pointer} = key) do
    root =
      case Map.get(state.names, Map.get(state.index.ids, base)) do
        nil -> "T"
        name -> name
      end

    parts =
      pointer
      |> String.split("/", trim: true)
      |> Enum.map(&unescape/1)
      |> Enum.reject(&(&1 in ["properties", "items", "$defs", "definitions"]))
      |> Enum.map(&String.capitalize/1)

    _ = key
    Enum.join([root | parts])
  end

  # ---- converting ---------------------------------------------------------------

  defp convert_all(state) do
    {document, state} =
      state.names
      |> Enum.sort_by(fn {_key, name} -> name end)
      |> Enum.reduce({%{}, state}, fn {key, name}, {doc, state} ->
        {node, _own, base, pointer} = Map.fetch!(state.index.nodes, key)
        ctx = %{base: base, pointer: pointer, top: key, path: "#" <> pointer}
        {type, state} = convert(node, ctx, state)
        type = if state.structs, do: as_struct(type), else: type
        {Map.put(doc, Keyword.new(name), type), state}
      end)

    {:ok, %{document: document, inexact: Enum.reverse(state.inexact)}}
  end

  defp inexact(state, ctx, why),
    do: %{state | inexact: [%{path: ctx.path, why: why} | state.inexact]}

  defp at(ctx, segment),
    do: %{
      ctx
      | pointer: ctx.pointer <> "/" <> escape(segment),
        path: ctx.path <> "/" <> escape(segment),
        top: nil
    }

  # A subschema: by name when it has one of its own, otherwise in place.
  defp sub(node, ctx, state) do
    key = {ctx.base, "#" <> ctx.pointer}

    case Map.fetch(state.names, key) do
      {:ok, name} when key != ctx.top -> {Symbol.new(name), state}
      _ -> convert(node, ctx, state)
    end
  end

  defp convert(true, _ctx, state), do: {kw("any"), state}
  defp convert(false, _ctx, state), do: {kw("never"), state}

  defp convert(node, ctx, state) when is_map(node) do
    # Below a schema with an `$id` of its own, pointers start again from
    # it, as the index has them.
    own = resource_id(node, ctx.base)
    ctx = if own != ctx.base, do: %{ctx | base: own, pointer: ""}, else: ctx

    if Map.has_key?(node, "$ref") and state.draft in ["04", "06", "07"] do
      # Before 2019-09 a $ref stands alone: its siblings are ignored.
      ref(node["$ref"], ctx, state)
    else
      {parts, state} = parts(node, ctx, state)
      type = all_of(parts)
      {annotated, state} = annotated(type, node, ctx, state)
      {annotated, state}
    end
  end

  defp convert(_other, ctx, _state),
    do: throw({:json_schema, "#{ctx.path}: a schema is an object or a boolean"})

  defp ref(ref, ctx, state) do
    {key, node} = target(state, ctx.base, ref)

    case Map.fetch(state.names, key) do
      {:ok, name} ->
        {Symbol.new(name), state}

      :error ->
        {_node, _own, base, pointer} = Map.fetch!(state.index.nodes, key)
        convert(node, %{ctx | base: base, pointer: pointer}, state)
    end
  end

  defp all_of([]), do: kw("any")
  defp all_of([one]), do: one
  defp all_of(parts), do: tup([kw("all-of") | parts])

  # The conjuncts a schema object says: its kinds, its values, its
  # combinators and its references.
  defp parts(node, ctx, state) do
    steps = [
      &ref_part/3,
      &kind_part/3,
      &enum_part/3,
      &combinator_parts/3,
      &conditional_part/3,
      &dependent_parts/3,
      &unevaluated_props_part/3,
      &unevaluated_items_part/3,
      &dynamic_part/3
    ]

    Enum.reduce(steps, {[], state}, fn step, {acc, state} ->
      {more, state} = step.(node, ctx, state)
      {acc ++ more, state}
    end)
  end

  defp ref_part(%{"$ref" => ref}, ctx, state) when is_binary(ref) do
    {type, state} = ref(ref, at(ctx, "$ref"), state)
    {[type], state}
  end

  defp ref_part(_node, _ctx, state), do: {[], state}

  defp dynamic_part(node, ctx, state) do
    case Enum.find(["$recursiveRef", "$dynamicRef"], &Map.has_key?(node, &1)) do
      nil ->
        {[], state}

      kw ->
        state =
          if dynamic_ambiguous?(state),
            do:
              inexact(
                state,
                ctx,
                "#{kw} is read as a plain $ref: which schema it names depends on the evaluation path"
              ),
            else: state

        {type, state} = ref(node[kw], at(ctx, kw), state)
        {[type], state}
    end
  end

  defp dynamic_ambiguous?(state) do
    state.index.nodes
    |> Map.values()
    |> Enum.uniq_by(fn {_node, own, _base, _pointer} -> own end)
    |> Enum.count(fn {node, _, _, _} ->
      Map.has_key?(node, "$dynamicAnchor") or node["$recursiveAnchor"] == true
    end)
    |> Kernel.>(1)
  end

  # ---- kinds ---------------------------------------------------------------------

  @kinds ~w(string number array object boolean null)

  @string_keys ~w(minLength maxLength pattern format contentEncoding contentMediaType contentSchema)
  @number_keys ~w(minimum maximum exclusiveMinimum exclusiveMaximum multipleOf)
  @array_keys ~w(items prefixItems additionalItems minItems maxItems uniqueItems contains minContains maxContains)
  @object_keys ~w(properties required additionalProperties patternProperties propertyNames minProperties maxProperties)

  defp kind_part(node, ctx, state) do
    types = types_of(node, ctx, state)

    cond do
      types != nil ->
        {kinds, state} =
          Enum.map_reduce(types, state, fn kind, state ->
            kind_type(kind, node, ctx, state, true)
          end)

        {[any_of(kinds)], state}

      true ->
        # No type: each kind's keywords apply to values of that kind only.
        Enum.reduce(["string", "number", "array", "object"], {[], state}, fn kind, {acc, state} ->
          if constrains?(node, kind) do
            {type, state} = kind_type(kind, node, ctx, state, false)
            {acc ++ [tup([kw("if"), plain(kind), type])], state}
          else
            {acc, state}
          end
        end)
    end
  end

  defp types_of(%{"bsonType" => bson} = node, ctx, state) do
    bson = List.wrap(bson)
    types = node |> Map.get("type") |> List.wrap()
    _ = {ctx, state}
    Enum.map(bson, &{:bson, &1}) ++ types
  end

  defp types_of(%{"type" => type}, _ctx, _state) when is_binary(type), do: [type]
  defp types_of(%{"type" => types}, _ctx, _state) when is_list(types), do: types
  defp types_of(_node, _ctx, _state), do: nil

  defp constrains?(node, "string"), do: Enum.any?(@string_keys, &Map.has_key?(node, &1))
  defp constrains?(node, "number"), do: Enum.any?(@number_keys, &Map.has_key?(node, &1))
  defp constrains?(node, "array"), do: Enum.any?(@array_keys, &Map.has_key?(node, &1))
  defp constrains?(node, "object"), do: Enum.any?(@object_keys, &Map.has_key?(node, &1))

  defp any_of([one]), do: one
  defp any_of(types), do: tup([kw("any-of") | types])

  # The DXN type of a kind, with no constraint.
  defp plain("string"), do: kw("string")
  defp plain("number"), do: kw("number")
  defp plain("integer"), do: kw("integer")
  defp plain("array"), do: kw("list")
  defp plain("object"), do: kw("map")
  defp plain("boolean"), do: kw("boolean")
  defp plain("null"), do: kw("nil")

  defp kind_type({:bson, bson}, node, ctx, state, typed),
    do: bson_type(bson, node, ctx, state, typed)

  defp kind_type("string", node, ctx, state, typed), do: string_type(node, ctx, state, typed)

  defp kind_type(kind, node, ctx, state, _typed) when kind in ["number", "integer"],
    do: number_type(kind, node, ctx, state)

  defp kind_type("array", node, ctx, state, _typed), do: array_type(node, ctx, state)
  defp kind_type("object", node, ctx, state, _typed), do: object_type(node, ctx, state)

  defp kind_type(kind, _node, _ctx, state, _typed) when kind in ["boolean", "null"],
    do: {plain(kind), state}

  defp kind_type(other, _node, ctx, _state, _typed),
    do:
      throw(
        {:json_schema,
         "#{ctx.path}: unknown type #{inspect(other)}; #{Enum.join(@kinds ++ ["integer"], ", ")}"}
      )

  # ---- MongoDB bsonType ------------------------------------------------------------

  defp bson_type(bson, node, ctx, state, typed) do
    case bson do
      "double" ->
        number_with(kw("float"), node, ctx, state)

      "int" ->
        number_with(kw("int32"), node, ctx, state)

      "long" ->
        number_with(kw("int64"), node, ctx, state)

      "decimal" ->
        number_with(refine(kw("decimal"), [{"max-precision", 34}]), node, ctx, state)

      "number" ->
        number_with(
          any_of([kw("int32"), kw("int64"), kw("float"), kw("decimal")]),
          node,
          ctx,
          state
        )

      "string" ->
        string_type(node, ctx, state, typed)

      "bool" ->
        {kw("boolean"), state}

      "null" ->
        {kw("nil"), state}

      "array" ->
        array_type(node, ctx, state)

      "object" ->
        object_type(node, ctx, state)

      "objectId" ->
        {kw("objectid"), state}

      "date" ->
        {refine(kw("timestamp"), [{"resolution", kw("millisecond")}]), state}

      "binData" ->
        {kw("bytes"), state}

      "regex" ->
        {kw("regex"), state}

      other
      when other in ~w(timestamp javascript minKey maxKey dbPointer symbol undefined javascriptWithScope) ->
        {kw("any"), inexact(state, ctx, "bsonType #{other} has no DXN value; read as :any")}

      other ->
        throw({:json_schema, "#{ctx.path}: unknown bsonType #{inspect(other)}"})
    end
  end

  defp number_with(base, node, ctx, state) do
    {constraints, state} = number_constraints(node, ctx, state)
    {refine(base, constraints), state}
  end

  # ---- strings ---------------------------------------------------------------------

  # A date or time, uuid or uri format on a string is that DXN type
  # (logical types); it applies only where the schema says the value is
  # a string.
  @logical %{
    "date-time" => "datetime",
    "date" => "date",
    "time" => "time",
    "duration" => "duration",
    "uuid" => "uuid",
    "uri" => "uri"
  }

  @formats %{"date-time" => "datetime"}

  defp string_type(node, ctx, state, typed) do
    format = node["format"]
    content = node["contentEncoding"]

    cond do
      state.assert_formats and typed and is_binary(format) and Map.has_key?(@logical, format) and
          only_format?(node) ->
        {kw(@logical[format]), state}

      state.assert_formats and typed and content == "base64" and
        not Map.has_key?(node, "contentMediaType") and only_format?(node) ->
        {kw("bytes"), state}

      true ->
        {constraints, state} = string_constraints(node, ctx, state)
        {refine(kw("string"), constraints), state}
    end
  end

  defp only_format?(node),
    do: not Enum.any?(~w(minLength maxLength pattern), &Map.has_key?(node, &1))

  defp string_constraints(node, ctx, state) do
    {constraints, state} =
      Enum.reduce(@string_keys, {[], state}, fn key, {acc, state} ->
        case {key, node[key]} do
          {_, nil} -> {acc, state}
          {"minLength", n} -> {acc ++ [{"min-length", count(n)}], state}
          {"maxLength", n} -> {acc ++ [{"max-length", count(n)}], state}
          {"pattern", p} -> pattern_constraint(p, at(ctx, "pattern"), acc, state)
          {"format", _} when not state.assert_formats -> {acc, state}
          {"contentEncoding", _} when not state.assert_formats -> {acc, state}
          {"contentMediaType", _} when not state.assert_formats -> {acc, state}
          {"format", f} -> format_constraint(f, ctx, acc, state)
          {"contentEncoding", e} -> encoding_constraint(e, ctx, acc, state)
          {"contentMediaType", m} -> {acc ++ [{"media-type", m}], state}
          {"contentSchema", _} -> {acc, state}
        end
      end)

    {constraints, state}
  end

  defp pattern_constraint(pattern, ctx, acc, state) do
    case regex(pattern) do
      {:ok, regex} -> {acc ++ [{"pattern", regex}], state}
      {:error, why} -> {acc, inexact(state, ctx, "pattern #{inspect(pattern)}: #{why}; left out")}
    end
  end

  defp format_constraint(format, ctx, acc, state) do
    name = Map.get(@formats, format, format)

    if name in Dextrin.Schema.Format.names(),
      do: {acc ++ [{"format", kw(name)}], state},
      else: {acc, state |> meta_note(ctx, "format", format)}
  end

  defp encoding_constraint(encoding, ctx, acc, state) do
    if encoding in ~w(base64 base64url base32 base16),
      do: {acc ++ [{"encoding", kw(encoding)}], state},
      else: {acc, meta_note(state, ctx, "contentEncoding", encoding)}
  end

  # An unknown format or encoding is no check in JSON Schema either; it
  # is kept, not reported (T673 Q5).
  defp meta_note(state, _ctx, _key, _value), do: state

  # ---- numbers ---------------------------------------------------------------------

  defp number_type(kind, node, ctx, state) do
    {constraints, state} = number_constraints(node, ctx, state)
    {refine(plain(kind), constraints), state}
  end

  defp number_constraints(node, _ctx, state) do
    draft04 = state.draft == "04" or state.mongo

    constraints =
      Enum.flat_map(@number_keys, fn key ->
        case {key, node[key]} do
          {_, nil} ->
            []

          {"minimum", n} ->
            [
              {if(draft04 and node["exclusiveMinimum"] == true, do: "exclusive-min", else: "min"),
               n}
            ]

          {"maximum", n} ->
            [
              {if(draft04 and node["exclusiveMaximum"] == true, do: "exclusive-max", else: "max"),
               n}
            ]

          {"exclusiveMinimum", n} when is_number(n) ->
            [{"exclusive-min", n}]

          {"exclusiveMaximum", n} when is_number(n) ->
            [{"exclusive-max", n}]

          {"multipleOf", n} ->
            [{"multiple-of", n}]

          _ ->
            []
        end
      end)

    {constraints, state}
  end

  # ---- arrays ----------------------------------------------------------------------

  defp array_type(node, ctx, state) do
    {prefix, rest, state} = items_of(node, ctx, state)
    {list, state} = list_form(prefix, rest, state)

    constraints =
      [
        {"min-count", count(node["minItems"])},
        {"max-count", count(node["maxItems"])},
        {"unique", if(node["uniqueItems"] == true, do: true)}
      ]
      |> Enum.reject(&is_nil(elem(&1, 1)))

    {contains, state} =
      case node do
        %{"contains" => schema} ->
          {type, state} = sub(schema, at(ctx, "contains"), state)
          least = count(Map.get(node, "minContains", 1))

          more =
            [{"contains", type}, {"min-contains", least}] ++
              if(Map.has_key?(node, "maxContains"),
                do: [{"max-contains", count(node["maxContains"])}],
                else: []
              )

          {more, state}

        _ ->
          {[], state}
      end

    {refine(list, constraints ++ contains), state}
  end

  # The items a list must start with, and what every further one must
  # be (`nil` for none): prefixItems and items in 2020-12, items as an
  # array and additionalItems before.
  defp items_of(node, ctx, state) do
    {prefix_key, rest_key} =
      if state.draft == "2020-12",
        do: {"prefixItems", "items"},
        else: {"items", "additionalItems"}

    {prefix, state} =
      case node[prefix_key] do
        list when is_list(list) ->
          list
          |> Enum.with_index()
          |> Enum.map_reduce(state, fn {schema, i}, state ->
            sub(schema, at(at(ctx, prefix_key), Integer.to_string(i)), state)
          end)

        _ ->
          {nil, state}
      end

    {rest, state} =
      cond do
        state.draft != "2020-12" and is_map_or_bool(node["items"]) ->
          {type, state} = sub(node["items"], at(ctx, "items"), state)
          {{:all, type}, state}

        # 2020-12's items with no prefixItems is every item; an
        # additionalItems with no items array means nothing.
        prefix == nil and state.draft == "2020-12" and Map.has_key?(node, rest_key) ->
          {type, state} = sub(node[rest_key], at(ctx, rest_key), state)
          {{:all, type}, state}

        prefix == nil ->
          {{:all, kw("any")}, state}

        Map.has_key?(node, rest_key) ->
          {type, state} = sub(node[rest_key], at(ctx, rest_key), state)
          {{:rest, type}, state}

        true ->
          {{:rest, kw("any")}, state}
      end

    {prefix, rest, state}
  end

  defp is_map_or_bool(v), do: is_map(v) or is_boolean(v)

  # A count written `2.0` is the integer 2, as JSON Schema reads it.
  defp count(n) when is_float(n) and n == trunc(n), do: trunc(n)
  defp count(n), do: n

  defp list_form(nil, {:all, type}, state), do: {list_of(type), state}
  defp list_form(nil, {:rest, type}, state), do: {list_of(type), state}

  defp list_form(prefix, {:rest, rest}, state) do
    # Each prefix item is optional, but only after the ones before it.
    tail = if rest == kw("never"), do: nil, else: tup([kw("repeat"), rest, 0, nil])

    nested =
      prefix
      |> Enum.reverse()
      |> Enum.reduce(tail, fn item, inner ->
        group = if inner, do: tup([kw("group"), item, inner]), else: item
        tup([kw("repeat"), group, 0, 1])
      end)

    {tup([kw("list-items"), nested]), state}
  end

  defp list_of(type) do
    if type == kw("any"), do: kw("list"), else: tup([kw("list-of"), type])
  end

  # ---- objects ---------------------------------------------------------------------

  defp object_type(node, ctx, state) do
    properties = ordered_pairs(Map.get(node, "properties", %{}))
    required = Map.get(node, "required", [])
    required = if is_list(required), do: required, else: []
    patterns = ordered_pairs(Map.get(node, "patternProperties", %{}))

    {pattern_entries, state} =
      Enum.map_reduce(patterns, state, fn {pattern, schema}, state ->
        pctx = at(at(ctx, "patternProperties"), pattern)
        {value, state} = sub(schema, pctx, state)

        case regex(pattern) do
          {:ok, regex} ->
            {{pattern, regex, value}, state}

          {:error, why} ->
            throw({:json_schema, "#{pctx.path}: pattern #{inspect(pattern)}: #{why}"})
        end
      end)

    names = Enum.map(properties, &elem(&1, 0))
    names = names ++ Enum.reject(required, &(&1 in names))

    {fields, entries, state} =
      Enum.reduce(names, {[], [], state}, fn name, {fields, entries, state} ->
        # A `false` schema is a schema: found by its key, not its truth.
        schema =
          case List.keyfind(properties, name, 0) do
            {_name, value} -> value
            nil -> nil
          end

        {type, state} =
          if schema == nil,
            do: {kw("any"), state},
            else: sub(schema, at(at(ctx, "properties"), name), state)

        # A pattern that matches a declared name applies to it as well.
        matching = for {_p, regex, value} <- pattern_entries, Regex.match?(regex, name), do: value
        type = all_of([type | matching])
        {type, default, state} = with_default(type, schema, state)

        if field_name?(name) do
          key = if name in required, do: name, else: name <> "?"
          value = if default == :none, do: type, else: field(type, default)
          {fields ++ [{key, value}], entries, state}
        else
          {fields, entries ++ [{tup([kw("const"), name]), type}], state}
        end
      end)

    literal_names = for {k, _} <- entries, do: Enum.at(k.items, 1)
    pattern_regexes = for {_p, regex, _v} <- pattern_entries, do: regex

    entries =
      entries ++
        for(
          {_p, regex, value} <- pattern_entries,
          do: {refine(kw("string"), [{"pattern", regex}]), value}
        )

    {entries, closed, state} =
      additional(node, ctx, entries, literal_names, pattern_regexes, state)

    {entries, closed, fields, state} =
      property_names(node, ctx, entries, closed, fields, literal_names, pattern_regexes, state)

    struct = %Struct{
      name: "shape",
      fields: {:keyed, fields},
      rest: entries,
      drops: if(closed, do: ["*"], else: [])
    }

    counts =
      [{"min-count", count(node["minProperties"])}, {"max-count", count(node["maxProperties"])}]
      |> Enum.reject(&is_nil(elem(&1, 1)))

    shape = if fields == [] and entries == [] and not closed, do: kw("map"), else: struct

    # A required name that can't be a field is required by refusing the
    # map without it.
    present = for name <- required, not field_name?(name), do: present_key(name)
    {all_of([refine(shape, counts) | present]), state}
  end

  # additionalProperties: nothing beyond the declared names and patterns
  # (`- *`), or a type for every other key.
  defp additional(node, ctx, entries, literal_names, patterns, state) do
    case Map.fetch(node, "additionalProperties") do
      {:ok, false} ->
        {entries, true, state}

      {:ok, true} ->
        {entries, false, state}

      {:ok, schema} ->
        {value, state} = sub(schema, at(ctx, "additionalProperties"), state)
        key = other_keys(literal_names, patterns)
        {entries ++ [{key, value}], false, state}

      :error ->
        {entries, false, state}
    end
  end

  # The keys no literal name and no pattern takes.
  defp other_keys([], []), do: kw("string")

  defp other_keys(names, patterns) do
    nots =
      if(names == [], do: [], else: [tup([kw("not"), tup([kw("enum") | names])])]) ++
        Enum.map(patterns, &tup([kw("not"), refine(kw("string"), [{"pattern", &1}])]))

    tup([kw("all-of"), kw("string") | nots])
  end

  # propertyNames: every key matches it. Extras that don't are refused
  # by an entry of :never; a declared name is checked here, now.
  defp property_names(node, ctx, entries, closed, fields, literal_names, _patterns, state) do
    case Map.fetch(node, "propertyNames") do
      :error ->
        {entries, closed, fields, state}

      {:ok, schema} ->
        pctx = at(ctx, "propertyNames")
        {type, state} = sub(schema, pctx, state)

        state =
          if fields != [] or literal_names != [],
            do:
              inexact(
                state,
                pctx,
                "propertyNames is checked on extra keys only; declared names are not checked against it"
              ),
            else: state

        {[{tup([kw("not"), type]), kw("never")} | entries], closed, fields, state}
    end
  end

  defp field_name?(name) do
    Regex.match?(~r/^[\p{L}_][\p{L}\p{N}_-]*$/u, name) and
      not String.ends_with?(name, "-") and name not in ~w(nil true false)
  end

  defp with_default(type, %{"default" => default}, state), do: {type, json_value(default), state}
  defp with_default(type, _schema, state), do: {type, :none, state}

  defp field(type, default),
    do: %Struct{name: "field", fields: {:keyed, [{"type", type}, {"default", default}]}}

  # ---- enum, const ----------------------------------------------------------------

  defp enum_part(node, _ctx, state) do
    parts =
      case node do
        %{"enum" => values} when is_list(values) ->
          [tup([kw("enum") | Enum.map(values, &json_value/1)])]

        _ ->
          []
      end ++
        case node do
          %{"const" => value} -> [tup([kw("const"), json_value(value)])]
          _ -> []
        end

    {parts, state}
  end

  # ---- allOf, anyOf, oneOf, not, if --------------------------------------------------

  defp combinator_parts(node, ctx, state) do
    Enum.reduce(
      [{"allOf", "all-of"}, {"anyOf", "any-of"}, {"oneOf", "one-of"}],
      {[], state},
      fn {key, head}, {acc, state} ->
        case node do
          %{^key => list} when is_list(list) ->
            {types, state} =
              list
              |> Enum.with_index()
              |> Enum.map_reduce(state, fn {s, i}, state ->
                sub(s, at(at(ctx, key), Integer.to_string(i)), state)
              end)

            {acc ++ [tup([kw(head) | types])], state}

          _ ->
            {acc, state}
        end
      end
    )
    |> then(fn {acc, state} ->
      case node do
        %{"not" => schema} ->
          {type, state} = sub(schema, at(ctx, "not"), state)
          {acc ++ [tup([kw("not"), type])], state}

        _ ->
          {acc, state}
      end
    end)
  end

  defp conditional_part(%{"if" => test} = node, ctx, state)
       when is_map_key(node, "then") or is_map_key(node, "else") do
    {test, state} = sub(test, at(ctx, "if"), state)

    {then, state} =
      if Map.has_key?(node, "then"),
        do: sub(node["then"], at(ctx, "then"), state),
        else: {kw("any"), state}

    {otherwise, state} =
      if Map.has_key?(node, "else"),
        do: sub(node["else"], at(ctx, "else"), state),
        else: {kw("any"), state}

    {[tup([kw("if"), test, then, otherwise])], state}
  end

  defp conditional_part(_node, _ctx, state), do: {[], state}

  # dependentRequired, dependentSchemas, and draft-04's to 07's
  # dependencies: when a property is present, others are, or the value
  # matches a schema.
  defp dependent_parts(node, ctx, state) do
    required =
      Map.get(node, "dependentRequired", %{}) |> ordered_pairs()

    schemas = Map.get(node, "dependentSchemas", %{}) |> ordered_pairs()

    {old_required, old_schemas} =
      node
      |> Map.get("dependencies", %{})
      |> ordered_pairs()
      |> Enum.split_with(fn {_k, v} -> is_list(v) end)

    {req_parts, state} =
      Enum.map_reduce(required ++ old_required, state, fn {name, needed}, state ->
        {tup([kw("if"), present_shape([name], ctx, state), present_shape(needed, ctx, state)]),
         state}
      end)

    keyed =
      Enum.map(schemas, &{"dependentSchemas", &1}) ++ Enum.map(old_schemas, &{"dependencies", &1})

    {schema_parts, state} =
      Enum.map_reduce(keyed, state, fn {key, {name, schema}}, state ->
        {type, state} = sub(schema, at(at(ctx, key), name), state)
        {tup([kw("if"), present_shape([name], ctx, state), type]), state}
      end)

    {req_parts ++ schema_parts, state}
  end

  # A map with these keys present: a shape whose fields are those names,
  # each of any value.
  defp present_shape(names, _ctx, _state) do
    {fields, others} = Enum.split_with(names, &field_name?/1)

    parts =
      if(fields == [],
        do: [],
        else: [%Struct{name: "shape", fields: {:keyed, Enum.map(fields, &{&1, kw("any")})}}]
      ) ++
        Enum.map(others, &present_key/1)

    if parts == [], do: kw("any"), else: all_of(parts)
  end

  # A map with `name` present, whatever `name` is: one that a shape
  # refusing that key does not take.
  defp present_key(name) do
    absent = %Struct{
      name: "shape",
      fields: {:keyed, []},
      rest: [{tup([kw("const"), name]), kw("never")}]
    }

    all_of([kw("map"), tup([kw("not"), absent])])
  end

  # ---- unevaluated ------------------------------------------------------------------

  # unevaluatedProperties where it can be told from the schema alone:
  # the properties and patterns of this schema, its allOf branches and
  # what it references. A branch of anyOf, oneOf or if that names
  # properties makes it depend on which branch passed: reported.
  defp unevaluated_props_part(%{"unevaluatedProperties" => schema} = node, ctx, state) do
    uctx = at(ctx, "unevaluatedProperties")
    branching = ~w(unevaluatedProperties if then else anyOf oneOf dependentSchemas)
    base = Map.drop(node, branching)

    # Each part that evaluates properties only when something passes --
    # if/then/else, an anyOf or oneOf branch, a dependentSchemas entry --
    # is one condition: the rule is written for each way they can go,
    # chosen by the same conditions with {:if}.
    {conditions, state} = conditions(node, ctx, state)

    if length(conditions) > 6 do
      {[],
       inexact(
         state,
         uctx,
         "unevaluatedProperties over more than six conditional branches; left out"
       )}
    else
      {rule, state} = by_conditions(conditions, [base], schema, ctx, uctx, state)
      {List.wrap(rule), state}
    end
  end

  defp unevaluated_props_part(_node, _ctx, state), do: {[], state}

  # `{test, when_passed, when_failed}`: the type to test, and the schemas
  # whose properties count as evaluated either way.
  defp conditions(node, ctx, state) do
    {ifs, state} =
      case node do
        %{"if" => test} ->
          {type, state} = sub(test, at(ctx, "if"), state)
          {[{type, [test, Map.get(node, "then", true)], [Map.get(node, "else", true)]}], state}

        _ ->
          {[], state}
      end

    {branches, state} =
      Enum.reduce(["anyOf", "oneOf"], {[], state}, fn key, {acc, state} ->
        node
        |> Map.get(key, [])
        |> List.wrap()
        |> Enum.with_index()
        |> Enum.reduce({acc, state}, fn {branch, i}, {acc, state} ->
          {type, state} = sub(branch, at(at(ctx, key), Integer.to_string(i)), state)
          {acc ++ [{type, [branch], []}], state}
        end)
      end)

    dependents =
      for {name, schema} <- ordered_pairs(Map.get(node, "dependentSchemas", %{})),
          do: {present_shape([name], ctx, state), [schema], []}

    {ifs ++ branches ++ dependents, state}
  end

  defp by_conditions([], evaluated, schema, ctx, uctx, state) do
    unevaluated_rule(
      schema,
      evaluated_props(%{"allOf" => evaluated}, ctx.base, state, MapSet.new()),
      uctx,
      state
    )
  end

  defp by_conditions([{test, passed, failed} | more], evaluated, schema, ctx, uctx, state) do
    {yes, state} = by_conditions(more, evaluated ++ passed, schema, ctx, uctx, state)
    {no, state} = by_conditions(more, evaluated ++ failed, schema, ctx, uctx, state)

    cond do
      yes == no -> {yes, state}
      true -> {tup([kw("if"), test, yes || kw("any"), no || kw("any")]), state}
    end
  end

  # The type that says unevaluatedProperties for what `evaluated`
  # names, `nil` for none.
  defp unevaluated_rule(_schema, :all, _uctx, state), do: {nil, state}

  defp unevaluated_rule(_schema, {:dynamic, why}, uctx, state),
    do: {nil, inexact(state, uctx, "unevaluatedProperties depends on #{why}; left out")}

  defp unevaluated_rule(schema, {:static, names, patterns}, uctx, state) do
    {regexes, state} = regexes(patterns, uctx, state)
    known = Enum.map(MapSet.to_list(names), &tup([kw("const"), &1]))

    entries =
      Enum.map(known, &{&1, kw("any")}) ++
        Enum.map(regexes, &{refine(kw("string"), [{"pattern", &1}]), kw("any")})

    {rest, closed, state} =
      case schema do
        false ->
          {[], true, state}

        true ->
          {[], false, state}

        other ->
          {value, state} = sub(other, uctx, state)
          {[{other_keys(MapSet.to_list(names), regexes), value}], false, state}
      end

    if rest == [] and not closed do
      {nil, state}
    else
      shape = %Struct{
        name: "shape",
        fields: {:keyed, []},
        rest: entries ++ rest,
        drops: if(closed, do: ["*"], else: [])
      }

      {tup([kw("if"), kw("map"), shape]), state}
    end
  end

  defp regexes(patterns, ctx, state) do
    Enum.map_reduce(patterns, state, fn p, state ->
      case regex(p) do
        {:ok, r} -> {r, state}
        {:error, why} -> throw({:json_schema, "#{ctx.path}: pattern #{inspect(p)}: #{why}"})
      end
    end)
  end

  defp evaluated_props(node, base, state, seen) when is_map(node) do
    base = resource_id(node, base)

    cond do
      Map.has_key?(node, "additionalProperties") or
          (Map.has_key?(node, "unevaluatedProperties") and seen != MapSet.new()) ->
        :all

      Enum.any?(~w(anyOf oneOf if then else dependentSchemas), &names_props?(node[&1])) ->
        {:dynamic, "which anyOf, oneOf, if or dependentSchemas branch passed"}

      true ->
        own =
          {:static,
           node
           |> Map.get("properties", %{})
           |> ordered_pairs()
           |> Enum.map(&elem(&1, 0))
           |> MapSet.new(),
           node |> Map.get("patternProperties", %{}) |> ordered_pairs() |> Enum.map(&elem(&1, 0))}

        refs =
          case node do
            %{"$ref" => ref} ->
              {key, target} = target(state, base, ref)

              if MapSet.member?(seen, key),
                do: [],
                else: [{target, elem(key, 0), MapSet.put(seen, key)}]

            _ ->
              []
          end

        branches = for b <- List.wrap(node["allOf"]), do: {b, base, MapSet.put(seen, :branch)}

        Enum.reduce(refs ++ branches, own, fn {child, b, s}, acc ->
          merge_eval(acc, evaluated_props(child, b, state, s))
        end)
    end
  end

  defp evaluated_props(_bool, _base, _state, _seen), do: {:static, MapSet.new(), []}

  defp names_props?(nil), do: false
  defp names_props?(list) when is_list(list), do: Enum.any?(list, &names_props?/1)

  defp names_props?(node) when is_map(node) do
    Enum.any?(
      ~w(properties patternProperties additionalProperties unevaluatedProperties),
      &Map.has_key?(node, &1)
    ) or
      Enum.any?(node |> without_order() |> Map.values(), &names_props?/1)
  end

  defp names_props?(_), do: false

  defp merge_eval(:all, _), do: :all
  defp merge_eval(_, :all), do: :all
  defp merge_eval({:dynamic, _} = d, _), do: d
  defp merge_eval(_, {:dynamic, _} = d), do: d

  defp merge_eval({:static, n1, p1}, {:static, n2, p2}),
    do: {:static, MapSet.union(n1, n2), p1 ++ p2}

  # unevaluatedItems, as unevaluatedProperties: the items beyond the
  # longest prefix this schema, its allOf branches and what it references
  # give, unless an `items` takes them all; an item `contains` matches is
  # evaluated too. Conditional branches are written out with {:if}.
  defp unevaluated_items_part(%{"unevaluatedItems" => schema} = node, ctx, state) do
    uctx = at(ctx, "unevaluatedItems")
    base = Map.drop(node, ~w(unevaluatedItems if then else anyOf oneOf dependentSchemas))
    {conditions, state} = conditions(node, ctx, state)

    if length(conditions) > 6 do
      {[],
       inexact(state, uctx, "unevaluatedItems over more than six conditional branches; left out")}
    else
      {rule, state} = items_by_conditions(conditions, [base], schema, ctx, uctx, state)
      {List.wrap(rule), state}
    end
  end

  defp unevaluated_items_part(_node, _ctx, state), do: {[], state}

  defp items_by_conditions([], evaluated, schema, ctx, uctx, state),
    do:
      items_rule(
        schema,
        evaluated_items(
          %{"allOf" => evaluated},
          ctx.base,
          state,
          MapSet.new(),
          {ctx.path, :merged}
        ),
        uctx,
        state
      )

  defp items_by_conditions([{test, passed, failed} | more], evaluated, schema, ctx, uctx, state) do
    {yes, state} = items_by_conditions(more, evaluated ++ passed, schema, ctx, uctx, state)
    {no, state} = items_by_conditions(more, evaluated ++ failed, schema, ctx, uctx, state)

    if yes == no,
      do: {yes, state},
      else: {tup([kw("if"), test, yes || kw("any"), no || kw("any")]), state}
  end

  defp items_rule(_schema, :all, _uctx, state), do: {nil, state}

  defp items_rule(_schema, {:dynamic, why}, uctx, state),
    do: {nil, inexact(state, uctx, "unevaluatedItems depends on #{why}; left out")}

  defp items_rule(schema, {:static, prefix, contains}, uctx, state) do
    {value, state} = sub(schema, uctx, state)

    {contained, state} =
      Enum.map_reduce(contains, state, fn {c, cctx}, state -> sub(c, cctx, state) end)

    rest = if contained == [], do: value, else: any_of(contained ++ [value])

    if rest == kw("any") do
      {nil, state}
    else
      {list, state} =
        list_form(
          if(prefix == 0, do: nil, else: List.duplicate(kw("any"), prefix)),
          {:rest, rest},
          state
        )

      {tup([kw("if"), kw("list"), list]), state}
    end
  end

  # What a schema evaluates of a list: `:all`, or the prefix length and
  # the contains schemas, or `{:dynamic, why}`. `{path, how}` is where
  # the schema is, for a report from inside a contains: `:merged` for the
  # parts of one schema gathered under the path they stand at.
  defp evaluated_items(node, base, state, seen, {path, how}) when is_map(node) do
    base = resource_id(node, base)

    {prefix_key, rest_key} =
      if state.draft == "2020-12",
        do: {"prefixItems", "items"},
        else: {"items", "additionalItems"}

    cond do
      (state.draft != "2020-12" and is_map_or_bool(node["items"])) or
          (Map.has_key?(node, rest_key) and
             (state.draft == "2020-12" or is_list(node["items"]))) ->
        :all

      Map.has_key?(node, "unevaluatedItems") and seen != MapSet.new() ->
        :all

      Enum.any?(~w(anyOf oneOf if then else dependentSchemas), &items_named?(node[&1])) ->
        {:dynamic, "which anyOf, oneOf or if branch passed, below the top"}

      true ->
        own_prefix = if is_list(node[prefix_key]), do: length(node[prefix_key]), else: 0

        contains =
          if (Map.has_key?(node, "contains") and state.draft == "2020-12") or
               (Map.has_key?(node, "contains") and state.draft == "2019-09"),
             do: [
               {node["contains"],
                %{
                  base: base,
                  pointer: "/\u0000" <> path <> "/contains",
                  top: nil,
                  path: path <> "/contains"
                }}
             ],
             else: []

        refs =
          case node do
            %{"$ref" => ref} ->
              {key, target} = target(state, base, ref)

              if MapSet.member?(seen, key),
                do: [],
                else: [{target, elem(key, 0), MapSet.put(seen, key), {elem(key, 1), :own}}]

            _ ->
              []
          end

        branches =
          for {b, i} <- Enum.with_index(List.wrap(node["allOf"])) do
            where = if how == :merged, do: {path, :own}, else: {path <> "/allOf/#{i}", :own}
            {b, base, MapSet.put(seen, :branch), where}
          end

        Enum.reduce(refs ++ branches, {:static, own_prefix, contains}, fn {child, b, s, where},
                                                                          acc ->
          merge_items(acc, evaluated_items(child, b, state, s, where))
        end)
    end
  end

  defp evaluated_items(_bool, _base, _state, _seen, _where), do: {:static, 0, []}

  defp items_named?(nil), do: false
  defp items_named?(list) when is_list(list), do: Enum.any?(list, &items_named?/1)

  defp items_named?(node) when is_map(node) do
    Enum.any?(
      ~w(items prefixItems additionalItems contains unevaluatedItems),
      &Map.has_key?(node, &1)
    ) or
      Enum.any?(node |> without_order() |> Map.values(), &items_named?/1)
  end

  defp items_named?(_), do: false

  defp merge_items(:all, _), do: :all
  defp merge_items(_, :all), do: :all
  defp merge_items({:dynamic, _} = d, _), do: d
  defp merge_items(_, {:dynamic, _} = d), do: d
  defp merge_items({:static, p1, c1}, {:static, p2, c2}), do: {:static, max(p1, p2), c1 ++ c2}

  # ---- annotations -----------------------------------------------------------------

  @notes %{
    "title" => "title",
    "description" => "description",
    "examples" => "examples",
    "readOnly" => "read-only",
    "writeOnly" => "write-only",
    "deprecated" => "deprecated"
  }

  @known ~w(type enum const allOf anyOf oneOf not if then else $ref $recursiveRef $dynamicRef
            $schema $id id $anchor $dynamicAnchor $recursiveAnchor $defs definitions $comment $vocabulary
            dependentRequired dependentSchemas dependencies unevaluatedProperties unevaluatedItems
            default bsonType discriminator title description examples readOnly writeOnly deprecated) ++
           @string_keys ++ @number_keys ++ @array_keys ++ @object_keys

  defp annotated(type, node, _ctx, state) do
    notes =
      for {key, name} <- @notes, Map.has_key?(node, key), into: %{} do
        value = node[key]

        value =
          if key == "examples",
            do: Enum.map(List.wrap(value), &json_value/1),
            else: json_value(value)

        {Keyword.new(name), value}
      end

    notes =
      case node["deprecated"] do
        false -> Map.delete(notes, Keyword.new("deprecated"))
        _ -> notes
      end

    meta =
      node
      |> without_order()
      |> Enum.reject(fn {k, _} -> k in @known end)
      |> Enum.map(fn {k, v} -> {"json-schema." <> k, json_value(v)} end)
      |> then(fn kept ->
        kept ++
          if(
            is_binary(node["format"]) and
              (not state.assert_formats or
                 Map.get(@formats, node["format"], node["format"]) not in Dextrin.Schema.Format.names()),
            do: [{"json-schema.format", node["format"]}],
            else: []
          ) ++
          if(not state.assert_formats,
            do:
              for(
                k <- ~w(contentEncoding contentMediaType),
                Map.has_key?(node, k),
                do: {"json-schema." <> k, node[k]}
              ),
            else: []
          ) ++
          if(Map.has_key?(node, "$comment"),
            do: [{"json-schema.$comment", node["$comment"]}],
            else: []
          ) ++
          if(Map.has_key?(node, "contentSchema"),
            do: [{"json-schema.contentSchema", json_value(node["contentSchema"])}],
            else: []
          )
      end)
      |> Map.new()

    notes = if meta == %{}, do: notes, else: Map.put(notes, Keyword.new("meta"), meta)

    {notes, state} =
      case node["discriminator"] do
        %{"propertyName" => field} when is_binary(field) ->
          {Map.put(notes, Keyword.new("discriminator"), Keyword.new(field)), state}

        _ ->
          {notes, state}
      end

    if notes == %{}, do: {type, state}, else: {tup([kw("doc"), type, notes]), state}
  end

  # ---- structs (--structs) ---------------------------------------------------------

  # A named object schema written as a `%schema`: only where the shape
  # is the whole definition, so nothing but its fields is said.
  defp as_struct(%Struct{name: "shape"} = shape), do: %{shape | name: "schema"}

  defp as_struct(
         %Tuple{items: [%Keyword{name: "doc"}, %Struct{name: "shape"} = shape, notes]} = doc
       ),
       do: %{doc | items: [Keyword.new("doc"), %{shape | name: "schema"}, notes]}

  defp as_struct(other), do: other

  # ---- values ----------------------------------------------------------------------

  @doc false
  def json_value(map) when is_map(map) do
    map |> without_order() |> Map.new(fn {k, v} -> {k, json_value(v)} end)
  end

  def json_value(list) when is_list(list), do: Enum.map(list, &json_value/1)
  def json_value(:null), do: nil
  def json_value(other), do: other

  defp ordered_pairs(map) when is_map(map) do
    keys = Map.get(map, @order) || map |> Map.keys() |> Enum.filter(&is_binary/1) |> Enum.sort()
    Enum.map(keys, &{&1, Map.fetch!(map, &1)})
  end

  defp ordered_pairs(_), do: []

  defp without_order(map), do: Map.delete(map, @order)

  # ---- building DXN values ---------------------------------------------------------

  defp kw(name), do: Keyword.new(name)
  defp tup(items), do: Tuple.new(items)

  defp refine(base, []), do: base

  defp refine(base, constraints),
    do: tup([kw("refine"), base, Map.new(constraints, fn {k, v} -> {Keyword.new(k), v} end)])

  # A JSON Schema (ECMA-262) pattern as a DXN regex, read by code points
  # (the `u` flag) as ECMA-262 reads it: `\\d` and `\\w` are ASCII there,
  # `$` matches only at the very end, `\\uXXXX` is a code point.
  @doc false
  def regex(pattern) do
    with {:ok, source} <- ecma_to_pcre(pattern),
         {:ok, text} <- Dextrin.encode(source),
         {:ok, %Regex{} = regex} <- Dextrin.decode("@regex(u) " <> text) do
      {:ok, regex}
    else
      {:error, %Dextrin.Error{message: why}} -> {:error, why}
      {:error, why} when is_binary(why) -> {:error, why}
      _ -> {:error, "not a regex DXN reads"}
    end
  end

  defp ecma_to_pcre(pattern), do: translate(String.graphemes(pattern), false, [])

  defp translate([], _class, acc), do: {:ok, acc |> Enum.reverse() |> Enum.join()}

  defp translate(["\\", "d" | rest], class, acc),
    do: translate(rest, class, [if(class, do: "0-9", else: "[0-9]") | acc])

  defp translate(["\\", "D" | rest], false, acc), do: translate(rest, false, ["[^0-9]" | acc])

  defp translate(["\\", "w" | rest], class, acc),
    do: translate(rest, class, [if(class, do: "A-Za-z0-9_", else: "[A-Za-z0-9_]") | acc])

  defp translate(["\\", "W" | rest], false, acc),
    do: translate(rest, false, ["[^A-Za-z0-9_]" | acc])

  defp translate(["\\", c | _rest], true, _acc) when c in ["D", "W"],
    do: {:error, "\\#{c} inside a character class can't be written in PCRE here"}

  defp translate(["\\", "u", a, b, c, d | rest], class, acc) do
    if Enum.all?([a, b, c, d], &(&1 =~ ~r/^[0-9A-Fa-f]$/)),
      do: translate(rest, class, ["\\x{" <> a <> b <> c <> d <> "}" | acc]),
      else: translate([a, b, c, d | rest], class, ["\\u" | acc])
  end

  defp translate(["\\", c | rest], class, acc), do: translate(rest, class, ["\\" <> c | acc])
  defp translate(["[" | rest], false, acc), do: translate(rest, true, ["[" | acc])
  defp translate(["]" | rest], true, acc), do: translate(rest, false, ["]" | acc])
  defp translate(["$" | rest], false, acc), do: translate(rest, false, ["\\z" | acc])
  defp translate([c | rest], class, acc), do: translate(rest, class, [c | acc])
end
