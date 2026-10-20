defmodule Dextrin.Schema.TypeExpr do
  @moduledoc """
  Internal, compiled representation of a `.dxns` type expression — the
  vocabulary of DXN.md §4.1 (`any`, `never`, `primitive`, `reference`,
  `list-of`, `set-of`, `tuple-of`, `map-of`, `array-of`,
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
    OrderedMap,
    Rational,
    SortedSet,
    Symbol,
    Tuple,
    Uri,
    Uuid
  }

  alias Dextrin.Schema.Validated

  @type t ::
          :any
          | :never
          | {:primitive, String.t()}
          | {:reference, String.t()}
          | {:list_of, t()}
          | {:set_of, t()}
          | {:tuple_of, [t()]}
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
         true <- satisfies_constraints?(conformed, constraints) do
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

  defp substitute({:refine, type, constraints}, bound),
    do: {:refine, substitute(type, bound), constraints}

  defp substitute({form, types}, bound) when form in [:tuple_of, :one_of, :any_of, :all_of],
    do: {form, Enum.map(types, &substitute(&1, bound))}

  defp substitute({form, type}, bound)
       when form in [:list_of, :set_of, :array_of, :sorted_set_of, :not, :nilable],
       do: {form, substitute(type, bound)}

  defp substitute({form, key, value}, bound) when form in [:map_of, :ordered_map_of],
    do: {form, substitute(key, bound), substitute(value, bound)}

  defp substitute(type, _bound), do: type

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
  defp primitive_matches?("time", value), do: match?(%Time{}, value)

  defp primitive_matches?("timestamp", value),
    do: match?(%DateTime{utc_offset: 0, std_offset: 0}, value)

  defp primitive_matches?("datetime", %DateTime{utc_offset: 0, std_offset: 0}), do: false
  defp primitive_matches?("datetime", value), do: match?(%DateTime{}, value)
  defp primitive_matches?("duration", value), do: match?(%Duration{}, value)
  defp primitive_matches?("uuid", value), do: match?(%Uuid{}, value)
  defp primitive_matches?("uri", value), do: match?(%Uri{}, value)

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

  defp satisfies_constraints?(value, constraints) do
    Enum.all?(constraints, fn {key, arg} -> satisfies_constraint?(key, arg, value) end)
  end

  defp satisfies_constraint?("min", min, value), do: to_number(value) >= to_number(min)
  defp satisfies_constraint?("max", max, value), do: to_number(value) <= to_number(max)
  defp satisfies_constraint?("exclusive-min", min, value), do: to_number(value) > to_number(min)
  defp satisfies_constraint?("exclusive-max", max, value), do: to_number(value) < to_number(max)

  defp satisfies_constraint?("multiple-of", n, value),
    do: rem_zero?(to_number(value), to_number(n))

  defp satisfies_constraint?("min-length", n, value), do: String.length(value) >= n
  defp satisfies_constraint?("max-length", n, value), do: String.length(value) <= n
  defp satisfies_constraint?("pattern", %Regex{} = re, value), do: Regex.match?(re, value)
  defp satisfies_constraint?("min-count", n, value), do: count_of(value) >= n
  defp satisfies_constraint?("max-count", n, value), do: count_of(value) <= n
  defp satisfies_constraint?(_key, _arg, _value), do: false

  defp count_of(value) when is_list(value), do: length(value)
  defp count_of(%MapSet{} = value), do: MapSet.size(value)
  defp count_of(%Tuple{items: items}), do: length(items)
  defp count_of(%SortedSet{items: items}), do: length(items)

  defp rem_zero?(a, b) when is_integer(a) and is_integer(b), do: rem(a, b) == 0
  defp rem_zero?(a, b), do: :math.fmod(a, b) == 0.0

  defp to_number(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_number(%Rational{numerator: n, denominator: d}), do: n / d
  defp to_number(n) when is_number(n), do: n
end
