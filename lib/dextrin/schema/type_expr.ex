defmodule Dextrin.Schema.TypeExpr do
  @moduledoc """
  Internal, compiled representation of a `.dxns` type expression — the
  vocabulary of DXN.md §4.1 (`any`, `never`, `primitive`, `reference`,
  `list-of`, `list-items`, `set-of`, `tuple-of`, `tuple-of-all`, `map-of`, `array-of`,
  `ordered-map-of`, `sorted-set-of`, `enum`, `one-of`, `any-of`,
  `all-of`, `not`, `nilable`, `refine`, `struct`, and `shape` and `case`,
  design/shapes-and-case.md) `Dextrin.Schema.Compiler` turns a
  parsed `.dxns` value into, and what `matches?/2` below checks a
  decoded value against. This vocabulary is fixed, not extensible from
  outside an actual library change — what schema *authors* extend
  instead is composing these forms into a reusable named type (see
  `Dextrin.Schema.Compiler`'s own moduledoc), which needs no new form
  at all.
  """

  alias Dextrin.{
    Array,
    Bytes,
    Char,
    Duration,
    Keyword,
    Nanos,
    OrderedMap,
    Rational,
    SortedSet,
    Symbol,
    Tuple,
    Uri,
    Uuid
  }

  alias Dextrin.Schema.Validated

  # A refine's keys whose argument is a type (DXN.md §4.2).
  @type_keys ~w(contains content encodes encodes-seq)

  @type t ::
          :any
          | :never
          | {:primitive, String.t()}
          | {:reference, String.t()}
          | {:list_of, t()}
          | {:set_of, t()}
          | {:list_items, [particle()]}
          | {:tuple_of, [t()]}
          | {:tuple_of_all, t()}
          | {:map_of, t(), t()}
          | {:array_of, t()}
          | {:ordered_map_of, t(), t()}
          | {:sorted_set_of, t()}
          | {:enum, [term()]}
          | {:one_of, [t()]}
          | {:any_of, [t()]}
          | {:all_of, [t()]}
          | {:not, t()}
          | {:shape, String.t(), [Dextrin.Schema.Field.t()]}
          | {:case, String.t(), [{term(), t()}], t() | :none}
          | {:named, String.t()}
          | {:generic, [String.t()], t()}
          | {:apply, String.t(), [t()]}
          | {:param, String.t()}
          | {:nilable, t()}
          | {:refine, t(), %{optional(String.t()) => term()}}

  @typedoc """
  One of a `{:list-items}`'s items: a type for exactly one item, or a
  repeat of a group of them, `most` nil when there is no upper bound
  (DXN.md §4.1a).
  """
  @type particle ::
          {:one, t()}
          | {:repeat, [particle()], non_neg_integer(), non_neg_integer() | nil}

  @typedoc """
  What a check knows besides the type and the value: the registry
  (`nil` when there is none -- strict and trusted are then off), and the
  fields of the nearest enclosing struct or shape by name, which a
  `{:case}` reads its sibling from (`nil` outside any).
  """
  @type context :: %{
          registry: Dextrin.Registry.t() | nil,
          siblings: %{String.t() => term()} | nil
        }

  @doc """
  The context for a check with `registry`, the fields `siblings` around
  it.
  """
  @spec context(Dextrin.Registry.t() | nil, %{String.t() => term()} | nil) :: context()
  def context(registry, siblings \\ nil), do: %{registry: registry, siblings: siblings}

  @doc """
  Whether `value` matches `type` — shared by both decode
  (`Dextrin.Schema.Validator.materialize/4`) and encode-time
  validation (`Dextrin.Schema.Validator.validate_for_encode/3`): the
  same recursive check, the same function, for both directions. It is
  `conform/3` answered as a boolean, so there is one check, not two.

  `{:reference, name}` checks the *originating schema's* name, not
  the value's own shape — which is how it correctly rejects a
  materialized value that satisfies its own schema but is the wrong
  one for this field. Three sources carry that name: an *opaque*,
  unregistered `Dextrin.Struct` carries its own wire name directly; a
  value that went through a registered schema (decode *or* encode
  -time validation alike) carries it via `Validated` — `materialize/4`
  wraps every result in one regardless of materializer shape, and
  encode-time validation wraps every recognized struct the same way
  before checking it (`Dextrin.Schema.Validator`'s internal
  `wrap_and_check` helper), specifically so this one function can check both without needing
  two implementations. The third, encode-only source: `registry`
  (`nil` for decode, which never needs it) lets a *real, unwrapped*
  application struct's `__struct__` be checked against whatever module
  was registered for `name` (`Dextrin.Registry.put_struct_module/3`) —
  needed only for a struct that turned out to have no schema of its
  own to be wrapped by. **Nothing else matches a reference** (DXN.md
  §4.7): a plain map, however much it looks like the struct, and an
  application struct registered for no schema or for another are type
  errors -- a value matches only its declared type.
  """
  @spec matches?(t(), term(), Dextrin.Registry.t() | nil) :: boolean()
  def matches?(type, value, registry \\ nil),
    do: match?({:ok, _}, conform(type, value, context(registry)))

  @doc """
  `value` checked against `type` in `context`: `{:ok, value}` with every
  shape's missing defaults filled in (design/shapes-and-case.md, Jan,
  2026-10-20), or `:error`. Nothing but a shape changes a value.
  """
  @spec conform(t(), term(), context()) :: {:ok, term()} | :error
  def conform(:any, value, _context), do: {:ok, value}
  def conform(:never, _value, _context), do: :error

  def conform({:reference, name}, %Dextrin.Struct{name: struct_name} = value, _context),
    do: when_true(struct_name == name, value)

  def conform({:reference, name}, %Validated{name: validated_name} = value, _context),
    do: when_true(validated_name == name, value)

  # A struct is matched only by a struct (DXN.md §4.7): past a struct or
  # checked value of the right name, only the application struct
  # registered for `name` is one. A plain map, or any other value, is not
  # a struct, however much it looks like one -- nothing is converted to
  # make it match.
  def conform({:reference, name}, value, %{registry: %Dextrin.Registry{} = registry})
      when is_struct(value) do
    case Dextrin.Registry.fetch_struct_module(registry, name) do
      {:ok, module} -> when_true(value.__struct__ == module, value)
      :error -> :error
    end
  end

  def conform({:reference, _name}, _value, _context), do: :error

  # A field's type is chosen by its sibling's value, wherever in the
  # field's type the case stands.
  def conform({:case, field, branches, otherwise}, value, context) do
    case chosen(field, branches, otherwise, context.siblings) do
      :none -> :error
      type -> conform(type, value, context)
    end
  end

  # A recursive named type's reference to itself (DXN.md §4.5), looked
  # up when it is checked; with no registry there is nothing to look in.
  def conform(
        {:named, name},
        value,
        %{registry: %Dextrin.Registry{type_aliases: aliases}} = context
      ) do
    case Map.fetch(aliases, name) do
      {:ok, type} -> conform(type, value, context)
      :error -> :error
    end
  end

  def conform({:named, _name}, _value, _context), do: :error

  # One use of a generic: its body, the arguments standing where its
  # parameters stand, checked like any other type.
  def conform(
        {:apply, name, args},
        value,
        %{registry: %Dextrin.Registry{type_aliases: aliases}} = context
      ) do
    case Map.fetch(aliases, name) do
      {:ok, {:generic, params, body}} when length(params) == length(args) ->
        conform(substitute(body, Map.new(Enum.zip(params, args))), value, context)

      _ ->
        :error
    end
  end

  def conform({:apply, _name, _args}, _value, _context), do: :error
  def conform({:param, _name}, _value, _context), do: :error

  def conform(type, %Validated{value: inner} = value, context) do
    with {:ok, conformed} <- conform(type, inner, context), do: {:ok, %{value | value: conformed}}
  end

  def conform({:primitive, name}, value, _context),
    do: when_true(primitive_matches?(name, value), value)

  def conform({:shape, _name, fields}, value, context)
      when is_map(value) and not is_struct(value),
      do: shape(fields, value, context)

  def conform({:shape, _name, _fields}, _value, _context), do: :error

  def conform({:list_of, elem_type}, value, context) when is_list(value),
    do: all(value, &conform(elem_type, &1, context))

  def conform({:list_of, _}, _value, _context), do: :error

  def conform({:list_items, particles}, value, context) when is_list(value),
    do: items(particles, value, context, &all_taken/1)

  def conform({:list_items, _}, _value, _context), do: :error

  def conform({:set_of, elem_type}, %MapSet{} = value, context) do
    with {:ok, items} <- all(MapSet.to_list(value), &conform(elem_type, &1, context)),
         do: {:ok, MapSet.new(items)}
  end

  def conform({:set_of, _}, _value, _context), do: :error

  def conform({:tuple_of, types}, %Tuple{items: items} = value, context)
      when length(types) == length(items) do
    with {:ok, conformed} <- all(Enum.zip(types, items), fn {t, v} -> conform(t, v, context) end),
         do: {:ok, %{value | items: conformed}}
  end

  def conform({:tuple_of, _}, _value, _context), do: :error

  def conform({:tuple_of_all, elem_type}, %Tuple{items: items} = value, context) do
    with {:ok, conformed} <- all(items, &conform(elem_type, &1, context)),
         do: {:ok, %{value | items: conformed}}
  end

  def conform({:tuple_of_all, _}, _value, _context), do: :error

  def conform({:map_of, key_type, val_type}, value, context)
      when is_map(value) and not is_struct(value) do
    with {:ok, pairs} <- all(Map.to_list(value), &pair(key_type, val_type, &1, context)),
         do: {:ok, Map.new(pairs)}
  end

  def conform({:map_of, _, _}, _value, _context), do: :error

  def conform({:array_of, elem_type}, %Array{items: items} = value, context) do
    with {:ok, conformed} <- all(Elixir.Tuple.to_list(items), &conform(elem_type, &1, context)),
         do: {:ok, %{value | items: List.to_tuple(conformed)}}
  end

  def conform({:array_of, _}, _value, _context), do: :error

  def conform({:ordered_map_of, key_type, val_type}, %OrderedMap{pairs: pairs} = value, context) do
    with {:ok, conformed} <- all(pairs, &pair(key_type, val_type, &1, context)),
         do: {:ok, %{value | pairs: conformed}}
  end

  def conform({:ordered_map_of, _, _}, _value, _context), do: :error

  def conform({:sorted_set_of, elem_type}, %SortedSet{items: items} = value, context) do
    with {:ok, conformed} <- all(items, &conform(elem_type, &1, context)),
         do: {:ok, %{value | items: conformed}}
  end

  def conform({:sorted_set_of, _}, _value, _context), do: :error

  # A schema's `enum` literals always come from `.dxns` *compilation*
  # (`Dextrin.Schema.Compiler`'s `atomize_back/1` normalizes them to
  # `Dextrin.Keyword`, regardless of how the schema *source* was
  # decoded), but the *data* being checked against them can be either
  # shape depending on the caller's own `trusted:` choice — a plain
  # `in` would only ever match the untrusted (`Dextrin.Keyword`) shape.
  def conform({:enum, literals}, value, _context),
    do: when_true(Enum.any?(literals, &keyword_aware_eq?(&1, value)), value)

  # Exactly one variant matches (JSON Schema's oneOf; Jan, 2026-10-20):
  # every variant is tried, stopping at a second match.
  def conform({:one_of, types}, value, context) do
    Enum.reduce_while(types, :none, fn type, found ->
      case {conform(type, value, context), found} do
        {:error, _} -> {:cont, found}
        {{:ok, _}, {:ok, _}} -> {:halt, :two}
        {{:ok, _} = ok, :none} -> {:cont, ok}
      end
    end)
    |> case do
      {:ok, _} = ok -> ok
      _ -> :error
    end
  end

  # One or more match (JSON Schema's anyOf): the first that does.
  def conform({:any_of, types}, value, context) do
    Enum.find_value(types, :error, fn type ->
      case conform(type, value, context) do
        {:ok, _} = ok -> ok
        :error -> nil
      end
    end)
  end

  def conform({:not, type}, value, context) do
    case conform(type, value, context) do
      {:ok, _} -> :error
      :error -> {:ok, value}
    end
  end

  # Every variant, each taking what the one before it answered.
  def conform({:all_of, types}, value, context) do
    Enum.reduce_while(types, {:ok, value}, fn type, {:ok, current} ->
      case conform(type, current, context) do
        {:ok, _} = ok -> {:cont, ok}
        :error -> {:halt, :error}
      end
    end)
  end

  def conform({:nilable, _type}, nil, _context), do: {:ok, nil}
  def conform({:nilable, type}, value, context), do: conform(type, value, context)

  def conform({:refine, type, constraints}, value, context) do
    with {:ok, conformed} <- conform(type, value, context),
         true <- satisfies_constraints?(conformed, constraints, type, context) do
      {:ok, conformed}
    else
      _ -> :error
    end
  end

  defp when_true(true, value), do: {:ok, value}
  defp when_true(false, _value), do: :error

  # Every item conformed, in order, or `:error` at the first that is not.
  defp all(items, conform_one) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case conform_one.(item) do
        {:ok, conformed} -> {:cont, {:ok, [conformed | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  # ---- list items -------------------------------------------------------------

  # `particles` matched against the front of `left`, then `rest` against
  # what they leave: the items conformed, in order, or `:error`. A repeat
  # takes as many items as it can while the rest still matches, and
  # gives back one at a time until it does (DXN.md §4.1a).
  defp items([], left, _context, rest), do: rest.(left)
  defp items([{:one, _type} | _], [], _context, _rest), do: :error

  defp items([{:one, type} | more], [item | left], context, rest) do
    with {:ok, conformed} <- conform(type, item, context),
         {:ok, tail} <- items(more, left, context, rest),
         do: {:ok, [conformed | tail]}
  end

  defp items([{:repeat, group, least, most} | more], left, context, rest),
    do: repeat(group, least, most, left, context, &items(more, &1, context, rest))

  # One more repetition first, while `most` allows it; stopping once
  # `least` is reached. A repetition that took no item is the last: every
  # further one would take none either, so `least` is met by them.
  defp repeat(group, least, most, left, context, rest) do
    again =
      if most == nil or most > 0 do
        items(group, left, context, fn after_one ->
          if length(after_one) == length(left),
            do: rest.(after_one),
            else: repeat(group, max(least - 1, 0), most && most - 1, after_one, context, rest)
        end)
      else
        :error
      end

    case again do
      {:ok, _} = ok -> ok
      :error when least == 0 -> rest.(left)
      :error -> :error
    end
  end

  # The end of a `{:list-items}`: every item taken.
  defp all_taken([]), do: {:ok, []}
  defp all_taken(_left), do: :error

  defp pair(key_type, val_type, {k, v}, context) do
    with {:ok, k} <- conform(key_type, k, context),
         {:ok, v} <- conform(val_type, v, context),
         do: {:ok, {k, v}}
  end

  # ---- generics -----------------------------------------------------------------

  # `type` with each parameter `bound` names replaced by its argument.
  defp substitute({:param, name} = param, bound), do: Map.get(bound, name, param)

  defp substitute({:apply, name, args}, bound),
    do: {:apply, name, Enum.map(args, &substitute(&1, bound))}

  defp substitute({:shape, name, fields}, bound),
    do: {:shape, name, Enum.map(fields, &%{&1 | type: substitute(&1.type, bound)})}

  defp substitute({:case, field, branches, otherwise}, bound) do
    {:case, field, Enum.map(branches, fn {literal, t} -> {literal, substitute(t, bound)} end),
     substitute(otherwise, bound)}
  end

  defp substitute({:refine, type, constraints}, bound) do
    {:refine, substitute(type, bound),
     Map.new(constraints, fn
       {key, t} when key in @type_keys -> {key, substitute(t, bound)}
       other -> other
     end)}
  end

  defp substitute({:list_items, particles}, bound),
    do: {:list_items, Enum.map(particles, &substitute_particle(&1, bound))}

  defp substitute({form, types}, bound) when form in [:tuple_of, :one_of, :any_of, :all_of],
    do: {form, Enum.map(types, &substitute(&1, bound))}

  defp substitute({form, type}, bound)
       when form in [:list_of, :set_of, :array_of, :sorted_set_of, :tuple_of_all, :not, :nilable],
       do: {form, substitute(type, bound)}

  defp substitute({form, key, value}, bound) when form in [:map_of, :ordered_map_of],
    do: {form, substitute(key, bound), substitute(value, bound)}

  defp substitute(type, _bound), do: type

  defp substitute_particle({:one, type}, bound), do: {:one, substitute(type, bound)}

  defp substitute_particle({:repeat, group, least, most}, bound),
    do: {:repeat, Enum.map(group, &substitute_particle(&1, bound)), least, most}

  # ---- {:case} ----------------------------------------------------------------

  # The type `branches` give the sibling `field`'s value; `otherwise`
  # (`:none` without an `:else`) when none is equal, or the sibling is
  # absent.
  defp chosen(field, branches, otherwise, siblings) when is_map(siblings) do
    case Map.fetch(siblings, field) do
      {:ok, sibling} ->
        sibling = Validated.strip(sibling)

        Enum.find_value(branches, otherwise, fn {literal, type} ->
          if keyword_aware_eq?(literal, sibling), do: type
        end)

      :error ->
        otherwise
    end
  end

  defp chosen(_field, _branches, otherwise, _siblings), do: otherwise

  # ---- %shape{} -----------------------------------------------------------------

  # A plain map against a shape's fields: each declared field matched by
  # name, whatever spelling its key has (`name:`, `"name" =>`,
  # `:"name" =>`) and refused given twice; a missing field takes its
  # default, the key a keyword (an atom when the decode is trusted); an
  # extra key is kept, and refused by a strict decode -- as a struct's
  # fields are (design/shapes-and-case.md).
  defp shape(fields, map, context) do
    with {:ok, named} <- by_name(map),
         siblings = Map.new(named, fn {name, {_key, value}} -> {name, value} end),
         inner = %{context | siblings: siblings},
         {:ok, filled} <- shape_fields(fields, named, map, inner),
         :ok <- extras(fields, map, context) do
      {:ok, filled}
    end
  end

  # The map's keys that name a field, by that name: `:error` when two
  # keys name the same one.
  defp by_name(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case key_name(key) do
        nil -> {:cont, {:ok, acc}}
        name when is_map_key(acc, name) -> {:halt, :error}
        name -> {:cont, {:ok, Map.put(acc, name, {key, value})}}
      end
    end)
  end

  defp key_name(%Keyword{name: name}), do: name
  defp key_name(key) when is_atom(key) and key not in [nil, true, false], do: Atom.to_string(key)
  defp key_name(key) when is_binary(key), do: key
  defp key_name(_key), do: nil

  defp shape_fields(fields, named, map, context) do
    Enum.reduce_while(fields, {:ok, map}, fn field, {:ok, acc} ->
      case shape_field(field, Map.fetch(named, field.name), context) do
        {:put, key, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        :absent -> {:cont, {:ok, acc}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp shape_field(field, {:ok, {key, value}}, context) do
    case conform(field.type, value, context) do
      {:ok, conformed} -> {:put, key, conformed}
      :error -> :error
    end
  end

  defp shape_field(%{default: default} = field, :error, context) when default != :none,
    do: {:put, default_key(field.name, context), default}

  defp shape_field(%{required: true}, :error, _context), do: :error
  defp shape_field(_field, :error, _context), do: :absent

  defp default_key(name, %{registry: %Dextrin.Registry{trusted: true}}), do: String.to_atom(name)
  defp default_key(name, _context), do: Keyword.new(name)

  defp extras(fields, map, %{registry: %Dextrin.Registry{strict: true}}) do
    declared = MapSet.new(fields, & &1.name)
    if Enum.all?(Map.keys(map), &(key_name(&1) in declared)), do: :ok, else: :error
  end

  defp extras(_fields, _map, _context), do: :ok

  # ---- primitives (DXN.md §1.3's 24 non-header types) ------------------------

  defp primitive_matches?("nil", value), do: is_nil(value)
  defp primitive_matches?("boolean", value), do: is_boolean(value)
  defp primitive_matches?("integer", value), do: is_integer(value)

  defp primitive_matches?("float", value),
    do: is_float(value) or value in [:nan, :positive_infinity, :negative_infinity]

  defp primitive_matches?("decimal", value), do: match?(%Decimal{}, value)
  defp primitive_matches?("rational", value), do: match?(%Rational{}, value)
  defp primitive_matches?("string", value), do: is_binary(value)
  defp primitive_matches?("char", value), do: match?(%Char{}, value)
  defp primitive_matches?("symbol", value), do: match?(%Symbol{}, value)
  # A schema-validated value's `keyword` field can be either shape
  # depending on how the caller decoded it (`Dextrin.Registry`'s
  # `trusted:` — real atom by default, `Dextrin.Keyword` if decoded
  # untrusted) — `nil`/`true`/`false` excluded since those are their
  # own `nil`/`boolean` primitives, never a `keyword`, regardless of
  # how permissive an atom check alone would be.
  defp primitive_matches?("keyword", value) do
    match?(%Keyword{}, value) or (is_atom(value) and value not in [nil, true, false])
  end

  defp primitive_matches?("list", value), do: is_list(value)
  defp primitive_matches?("tuple", value), do: match?(%Tuple{}, value)
  defp primitive_matches?("map", value), do: is_map(value) and not is_struct(value)
  defp primitive_matches?("ordered-map", value), do: match?(%OrderedMap{}, value)
  defp primitive_matches?("set", value), do: match?(%MapSet{}, value)
  defp primitive_matches?("sorted-set", value), do: match?(%SortedSet{}, value)
  defp primitive_matches?("array", value), do: match?(%Array{}, value)
  defp primitive_matches?("date", value), do: match?(%Date{}, value)
  # A datetime is one type whatever its offset, UTC included (Jan,
  # 2026-10-20); one finer than a microsecond is a `Dextrin.Nanos`.
  defp primitive_matches?("time", value),
    do: match?(%Time{}, value) or match?(%Dextrin.Nanos{value: %Time{}}, value)

  defp primitive_matches?("datetime", value),
    do: match?(%DateTime{}, value) or match?(%Dextrin.Nanos{value: %DateTime{}}, value)

  defp primitive_matches?("local-datetime", value),
    do: match?(%NaiveDateTime{}, value) or match?(%Dextrin.Nanos{value: %NaiveDateTime{}}, value)

  defp primitive_matches?("duration", value), do: match?(%Duration{}, value)
  defp primitive_matches?("uuid", value), do: match?(%Uuid{}, value)
  defp primitive_matches?("uri", value), do: match?(%Uri{}, value)
  defp primitive_matches?("objectid", value), do: match?(%Dextrin.ObjectId{}, value)
  defp primitive_matches?("ip", value), do: match?(%Dextrin.Ip{}, value)

  defp primitive_matches?("bytes", value),
    do: match?(%Bytes{data: data} when is_binary(data), value)

  # Bits and bytes are one value space (DXN.md §4.1): `:bits` takes both.
  defp primitive_matches?("bits", value), do: match?(%Bytes{}, value)
  defp primitive_matches?("regex", value), do: match?(%Regex{}, value)
  defp primitive_matches?(_name, _value), do: false

  # A schema's `enum` literals always come from `.dxns` *compilation*
  # (`Dextrin.Schema.Compiler`'s `atomize_back/1` normalizes them to
  # `Dextrin.Keyword`, regardless of how the schema *source* was
  # decoded), but the *data* being checked against them can be either
  # shape depending on the caller's own `trusted:` choice.
  defp keyword_aware_eq?(%Keyword{name: name}, value)
       when is_atom(value) and value not in [nil, true, false],
       do: Atom.to_string(value) == name

  defp keyword_aware_eq?(literal, value), do: literal == value

  # ---- refine constraints -----------------------------------------------------

  # A resolution's unit, in nanoseconds.
  @resolutions %{
    "second" => 1_000_000_000,
    "millisecond" => 1_000_000,
    "microsecond" => 1_000,
    "nanosecond" => 1
  }

  @doc false
  @spec resolutions() :: [String.t()]
  def resolutions, do: Map.keys(@resolutions)

  # Every constraint holds. A constraint on a value it does not apply to
  # -- a length on an integer, a range on a string -- refuses it (DXN.md
  # §4.2, Jan, 2026-10-20).
  defp satisfies_constraints?(value, constraints, base, context) do
    Enum.all?(constraints, fn
      {"contains", type} -> contains?(type, constraints, value, context)
      {"content", type} -> content?(type, constraints, value, context)
      {"encodes", type} -> encodes?(type, value, context)
      {"encodes-seq", type} -> encodes_seq?(type, value, context)
      {"min-length", n} -> within?(length_of(value, base), n, nil)
      {"max-length", n} -> within?(length_of(value, base), nil, n)
      {key, arg} -> satisfies_constraint?(key, arg, value)
    end)
  end

  # Between `min-contains` (1 when not given) and `max-contains` of the
  # collection's items are a `type`.
  defp contains?(type, constraints, value, context) do
    case items_of(value) do
      nil ->
        false

      items ->
        count = Enum.count(items, &match?({:ok, _}, conform(type, &1, context)))

        within?(
          count,
          Map.get(constraints, "min-contains", 1),
          Map.get(constraints, "max-contains")
        )
    end
  end

  # The string, decoded by its `encoding` when it has one, is a DXN
  # document whose value is a `type`: `.dxnb` under application/dxnb,
  # text otherwise.
  defp content?(type, constraints, value, context) when is_binary(value) do
    with {:ok, bytes} <- decoded(Map.get(constraints, "encoding"), value),
         {:ok, document} <- read_content(content_media(constraints), bytes),
         do: match?({:ok, _}, conform(type, document, context)),
         else: (_ -> false)
  end

  defp content?(_type, _constraints, _value, _context), do: false

  defp content_media(constraints) do
    case Map.get(constraints, "media-type") do
      nil -> nil
      media -> String.downcase(media)
    end
  end

  defp read_content("application/dxnb", bytes), do: Dextrin.decode_binary(bytes)

  defp read_content(_text, bytes) do
    if String.valid?(bytes), do: Dextrin.decode(bytes), else: :error
  end

  # The bytes are a `.dxnb` document whose value is a `type`.
  defp encodes?(type, %Bytes{data: data}, context) when is_binary(data) do
    case Dextrin.decode_binary(data) do
      {:ok, document} -> match?({:ok, _}, conform(type, document, context))
      {:error, _} -> false
    end
  end

  defp encodes?(_type, _value, _context), do: false

  # The bytes are `.dxnb` documents back to back, each a `type`.
  defp encodes_seq?(type, %Bytes{data: data}, context) when is_binary(data) do
    case Dextrin.Binary.Decoder.decode_sequence(data) do
      {:ok, documents} -> Enum.all?(documents, &match?({:ok, _}, conform(type, &1, context)))
      {:error, _} -> false
    end
  end

  defp encodes_seq?(_type, _value, _context), do: false

  # `text` decoded by RFC 4648's `encoding`; no encoding leaves it as it
  # is. base64 and base32 take their padding, base64url with or without
  # it, base16 either case.
  defp decoded(nil, text), do: {:ok, text}
  defp decoded("base64", text), do: Base.decode64(text)
  defp decoded("base32", text), do: Base.decode32(text)
  defp decoded("base16", text), do: Base.decode16(text, case: :mixed)

  defp decoded("base64url", text) do
    if String.contains?(text, "="),
      do: Base.url_decode64(text),
      else: Base.url_decode64(text, padding: false)
  end

  # Whether `count` lies between `least` and `most`, either `nil` for no
  # bound; a `nil` count, of a value that has none, never does.
  defp within?(nil, _least, _most), do: false

  defp within?(count, least, most),
    do: (least == nil or count >= least) and (most == nil or count <= most)

  # NaN lies outside every range, as every IEEE 754 comparison with it is
  # false; the infinities compare as the numbers they are (Jan,
  # 2026-10-20). Dates, times and durations compare with their own kind.
  defp satisfies_constraint?("min", min, value), do: compare(value, min) in [:gt, :eq]
  defp satisfies_constraint?("max", max, value), do: compare(value, max) in [:lt, :eq]
  defp satisfies_constraint?("exclusive-min", min, value), do: compare(value, min) == :gt
  defp satisfies_constraint?("exclusive-max", max, value), do: compare(value, max) == :lt

  defp satisfies_constraint?("finite", true, value),
    do: match?({:number, n} when is_number(n), ordinal(value))

  defp satisfies_constraint?("finite", false, value), do: match?({:number, _}, ordinal(value))

  # A float single precision holds exactly; NaN and the infinities it holds.
  defp satisfies_constraint?("float32", true, value) when is_float(value),
    do: Dextrin.Binary.Float.single?(value)

  defp satisfies_constraint?("float32", _wanted, value),
    do: value in [:nan, :positive_infinity, :negative_infinity] or is_float(value)

  defp satisfies_constraint?("version", version, %Dextrin.Ip{} = ip),
    do: Dextrin.Ip.version(ip) == version

  defp satisfies_constraint?("prefix", wanted, %Dextrin.Ip{prefix: prefix}),
    do: prefix != nil == wanted

  # The datetime's offset is one of these, `Z` or `±HH:MM`.
  defp satisfies_constraint?("offsets", offsets, value) when is_list(offsets) do
    case ordinal(value) do
      {:datetime, _} ->
        {_nanos, minutes} = Dextrin.Temporal.datetime_parts(value)
        Dextrin.Temporal.offset_name(minutes) in offsets

      _ ->
        false
    end
  end

  defp satisfies_constraint?("multiple-of", n, value) do
    case ordinal(value) do
      {:number, v} when is_number(v) -> rem_zero?(v, to_number(n))
      _ -> false
    end
  end

  defp satisfies_constraint?("encoding", encoding, value) when is_binary(value),
    do: match?({:ok, _}, decoded(encoding, value))

  # What the string holds; it checks nothing more (`content` reads it).
  defp satisfies_constraint?("media-type", _media, value), do: is_binary(value)

  # One of DXN.md §4.2a's formats, checked as `Dextrin.Schema.Format` says.
  defp satisfies_constraint?("format", name, value) when is_binary(value),
    do: Dextrin.Schema.Format.valid?(name, value)

  defp satisfies_constraint?("min-bytes", n, value), do: within?(utf8_size(value), n, nil)
  defp satisfies_constraint?("max-bytes", n, value), do: within?(utf8_size(value), nil, n)

  defp satisfies_constraint?("pattern", %Regex{} = re, value) do
    case pattern_text(value, re) do
      nil -> false
      text -> Regex.match?(re, text)
    end
  end

  defp satisfies_constraint?("min-count", n, value), do: within?(count_of(value), n, nil)
  defp satisfies_constraint?("max-count", n, value), do: within?(count_of(value), nil, n)

  # Counted with `contains`, which reads them.
  defp satisfies_constraint?(key, _n, _value) when key in ["min-contains", "max-contains"],
    do: true

  defp satisfies_constraint?("unique", false, value), do: items_of(value) != nil

  defp satisfies_constraint?("unique", true, value),
    do: distinct?(items_of(value), &{:ok, identity(&1)})

  # Items without the field are compared with none.
  defp satisfies_constraint?("unique-by", field, value),
    do: distinct?(items_of(value), &field_identity(&1, field))

  # A decimal's precision is its coefficient's digit count, as written
  # (`1.50M` has three); its exponent the power of ten that scales them.
  defp satisfies_constraint?("min-precision", n, value), do: within?(precision(value), n, nil)
  defp satisfies_constraint?("max-precision", n, value), do: within?(precision(value), nil, n)
  defp satisfies_constraint?("min-exponent", n, value), do: within?(exponent(value), n, nil)
  defp satisfies_constraint?("max-exponent", n, value), do: within?(exponent(value), nil, n)

  # Only the bits numbered in `allowed` are set (RFC 8610's `.bits`): an
  # unsigned integer's from its lowest, a byte string's from its first
  # byte's lowest.
  defp satisfies_constraint?("bits", allowed, value) when is_integer(value) and value >= 0,
    do: Bitwise.band(value, Bitwise.bnot(mask(allowed, 0))) == 0

  defp satisfies_constraint?("bits", allowed, %Bytes{data: data}) when is_binary(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.all?(fn {byte, i} -> Bitwise.band(byte, Bitwise.bnot(mask(allowed, i * 8))) == 0 end)
  end

  # Against the time of the check.
  defp satisfies_constraint?("before-now", wanted, value), do: from_now(value, wanted, &(&1 < 0))
  defp satisfies_constraint?("after-now", wanted, value), do: from_now(value, wanted, &(&1 > 0))

  defp satisfies_constraint?("within", duration, value) do
    case ordinal(duration) do
      {:duration, span} -> from_now(value, true, &(abs(&1) <= span))
      _ -> false
    end
  end

  # No part of the value is finer than `unit`.
  defp satisfies_constraint?("resolution", unit, value) do
    case nanos_of(value) do
      nil -> false
      nanos -> rem(nanos, Map.fetch!(@resolutions, unit)) == 0
    end
  end

  defp satisfies_constraint?(_key, _arg, _value), do: false

  # A string's, keyword's or symbol's length in codepoints; a byte
  # string's in bytes, in bits under `:bits`; `nil` for anything else.
  defp length_of(value, _base) when is_binary(value), do: codepoints(value)
  defp length_of(%Keyword{name: name}, _base), do: codepoints(name)
  defp length_of(%Symbol{name: name}, _base), do: codepoints(name)
  defp length_of(%Bytes{data: data}, {:primitive, "bits"}), do: bit_size(data)
  defp length_of(%Bytes{data: data}, _base), do: div(bit_size(data) + 7, 8)
  defp length_of(_value, _base), do: nil

  # Codepoints, not graphemes: `"e\u0301"` is two (DXN.md §4.2).
  defp codepoints(text), do: text |> String.to_charlist() |> length()

  defp utf8_size(value) when is_binary(value), do: byte_size(value)
  defp utf8_size(%Keyword{name: name}), do: byte_size(name)
  defp utf8_size(%Symbol{name: name}), do: byte_size(name)
  defp utf8_size(_value), do: nil

  # What a pattern matches: a name's text, or a byte string one
  # character per byte -- its bytes as they are, or, for a pattern with
  # the `u` flag, as the Latin-1 characters they are.
  defp pattern_text(value, _re) when is_binary(value), do: value
  defp pattern_text(%Keyword{name: name}, _re), do: name
  defp pattern_text(%Symbol{name: name}, _re), do: name

  defp pattern_text(%Bytes{data: data}, re) when is_binary(data) do
    if :unicode in Regex.opts(re),
      do: :unicode.characters_to_binary(data, :latin1),
      else: data
  end

  defp pattern_text(_value, _re), do: nil

  defp precision(%Decimal{coef: coef}) when is_integer(coef), do: length(Integer.digits(coef))
  defp precision(_value), do: nil
  defp exponent(%Decimal{coef: coef, exp: exp}) when is_integer(coef), do: exp
  defp exponent(_value), do: nil

  # The bits of `allowed` that fall in the byte starting at bit `from`,
  # shifted down to it; `from` 0 takes them all, for an integer.
  defp mask(allowed, 0) when is_list(allowed),
    do: Enum.reduce(allowed, 0, &Bitwise.bor(&2, Bitwise.bsl(1, &1)))

  defp mask(allowed, from) do
    allowed
    |> Enum.filter(&(&1 >= from and &1 < from + 8))
    |> Enum.reduce(0, &Bitwise.bor(&2, Bitwise.bsl(1, &1 - from)))
  end

  # A datetime's distance from now, in nanoseconds, given to `test`;
  # `wanted` false asks nothing.
  defp from_now(_value, false, _test), do: true

  defp from_now(value, true, test) do
    case ordinal(value) do
      {:datetime, nanos} -> test.(nanos - System.os_time(:nanosecond))
      _ -> false
    end
  end

  # A time's, datetime's, local date-time's or duration's nanoseconds,
  # the part a resolution looks at.
  defp nanos_of(%Dextrin.Duration{nanoseconds: nanos}), do: nanos || 0

  defp nanos_of(value) do
    case ordinal(value) do
      {kind, nanos} when kind in [:time, :datetime, :local] -> nanos
      _ -> nil
    end
  end

  defp count_of(value) do
    case items_of(value) do
      nil -> nil
      items -> length(items)
    end
  end

  # A collection's items, `nil` for a value that is none.
  defp items_of(value) when is_list(value), do: value
  defp items_of(%MapSet{} = value), do: MapSet.to_list(value)
  defp items_of(%Tuple{items: items}), do: items
  defp items_of(%SortedSet{items: items}), do: items
  defp items_of(%Array{items: items}), do: Elixir.Tuple.to_list(items)
  defp items_of(_value), do: nil

  # Whether no two of `items` give the same identity; `identify` answers
  # `{:ok, identity}`, or `:none` for an item left out.
  defp distinct?(nil, _identify), do: false

  defp distinct?(items, identify) do
    identities = for item <- items, {:ok, id} <- [identify.(item)], do: id
    length(identities) == length(Enum.uniq(identities))
  end

  # Two values are the same when their canonical forms are (DXN.md
  # §1.5): `1` and `1.0` differ, as `name:` and `"name" =>` do. A value
  # with no DXN meaning, an application's struct, is compared as itself.
  defp identity(value) do
    case Dextrin.Canonical.print(Validated.strip(value)) do
      {:ok, text} -> text
      {:error, _} -> {:term, value}
    end
  end

  defp field_identity(item, field) do
    case field_of(item, field) do
      {:ok, value} -> {:ok, identity(value)}
      :none -> :none
    end
  end

  # The value of the field named `field`, whatever its key's spelling.
  defp field_of(%Validated{value: value}, field), do: field_of(value, field)

  defp field_of(%Dextrin.Struct{fields: {:keyed, pairs}}, field) do
    case List.keyfind(pairs, field, 0) do
      {_name, value} -> {:ok, value}
      nil -> :none
    end
  end

  defp field_of(%Dextrin.Struct{}, _field), do: :none
  defp field_of(%_{} = struct, field), do: field_of(Map.from_struct(struct), field)

  defp field_of(map, field) when is_map(map) do
    Enum.find_value(map, :none, fn {key, value} -> key_name(key) == field && {:ok, value} end)
  end

  defp field_of(_value, _field), do: :none

  defp rem_zero?(a, b) when is_integer(a) and is_integer(b), do: rem(a, b) == 0
  defp rem_zero?(a, b), do: :math.fmod(a, b) == 0.0

  # `:lt`, `:eq` or `:gt`, or `:nan` for two values that do not compare:
  # NaN with anything, or two values of different kinds.
  defp compare(a, b) do
    case {ordinal(a), ordinal(b)} do
      {{kind, x}, {kind, y}} -> compare_ordinals(x, y)
      _ -> :nan
    end
  end

  defp compare_ordinals(x, y) do
    case {x, y} do
      {:nan, _} -> :nan
      {_, :nan} -> :nan
      {x, y} when x == y -> :eq
      {:negative_infinity, _} -> :lt
      {_, :negative_infinity} -> :gt
      {:positive_infinity, _} -> :gt
      {_, :positive_infinity} -> :lt
      {x, y} when x < y -> :lt
      _ -> :gt
    end
  end

  # A value as its kind and its place in that kind's order: a number
  # (NaN and the infinities as their atoms), or a date, time, datetime,
  # local date-time or duration as a count of days or nanoseconds. A
  # duration with years or months has no place: their length varies.
  @doc false
  # Whether `value` has a place in some kind's order: a range's bound.
  @spec comparable?(term()) :: boolean()
  def comparable?(value), do: ordinal(value) != :none

  @doc false
  # Whether `value` is a finite number other than zero: a `multiple-of`.
  @spec nonzero_number?(term()) :: boolean()
  def nonzero_number?(value),
    do: match?({:number, n} when is_number(n) and n != 0, ordinal(value))

  @doc false
  # Whether `value` is a duration of a fixed length: a `within`.
  @spec span?(term()) :: boolean()
  def span?(value), do: match?({:duration, _}, ordinal(value))

  defp ordinal(special) when special in [:nan, :positive_infinity, :negative_infinity],
    do: {:number, special}

  defp ordinal(n) when is_number(n), do: {:number, n}
  defp ordinal(%Decimal{coef: coef} = d) when is_integer(coef), do: {:number, Decimal.to_float(d)}
  defp ordinal(%Rational{} = r), do: {:number, to_number(r)}
  defp ordinal(%Date{} = date), do: {:date, Date.to_gregorian_days(date)}
  defp ordinal(%Time{} = time), do: {:time, Dextrin.Temporal.time_nanos(time)}
  defp ordinal(%Nanos{value: %Time{}} = time), do: {:time, Dextrin.Temporal.time_nanos(time)}
  defp ordinal(%DateTime{} = dt), do: {:datetime, elem(Dextrin.Temporal.datetime_parts(dt), 0)}

  defp ordinal(%Nanos{value: %DateTime{}} = dt),
    do: {:datetime, elem(Dextrin.Temporal.datetime_parts(dt), 0)}

  defp ordinal(%NaiveDateTime{} = n), do: {:local, Dextrin.Temporal.local_nanos(n)}
  defp ordinal(%Nanos{value: %NaiveDateTime{}} = n), do: {:local, Dextrin.Temporal.local_nanos(n)}

  defp ordinal(%Dextrin.Duration{years: years, months: months} = d)
       when years in [nil, 0] and months in [nil, 0] do
    {:duration,
     (d.weeks || 0) * 604_800_000_000_000 + (d.days || 0) * 86_400_000_000_000 +
       (d.hours || 0) * 3_600_000_000_000 + (d.minutes || 0) * 60_000_000_000 +
       (d.nanoseconds || 0)}
  end

  defp ordinal(_value), do: :none

  defp to_number(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_number(%Rational{numerator: n, denominator: d}), do: n / d
  defp to_number(n) when is_number(n), do: n
end
