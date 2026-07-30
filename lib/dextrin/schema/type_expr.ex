defmodule Dextrin.Schema.TypeExpr do
  @moduledoc """
  Internal, compiled representation of a `.dxns` type expression — the
  13-form vocabulary (`any`, `primitive`, `reference`, `list-of`,
  `set-of`, `tuple-of`, `map-of`, `enum`, `one-of`, `all-of`,
  `nilable`, `refine`, `struct`) `Dextrin.Schema.Compiler` turns a
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
          | {:primitive, String.t()}
          | {:reference, String.t()}
          | {:list_of, t()}
          | {:set_of, t()}
          | {:tuple_of, [t()]}
          | {:map_of, t(), t()}
          | {:enum, [term()]}
          | {:one_of, [t()]}
          | {:all_of, [t()]}
          | {:nilable, t()}
          | {:refine, t(), %{optional(String.t()) => term()}}

  @doc """
  Whether `value` matches `type` — shared by both decode
  (`Dextrin.Schema.Validator.materialize/4`) and encode-time
  validation (`Dextrin.Schema.Validator.validate_for_encode/3`): the
  same recursive check, the same function, for both directions.

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
  own to be wrapped by. A plain map (no name, no `__struct__`) or an
  unregistered name has nothing to check and is trusted, either way.
  """
  @spec matches?(t(), term(), Dextrin.Registry.t() | nil) :: boolean()
  def matches?(type, value, registry \\ nil)

  def matches?(:any, _value, _registry), do: true

  def matches?({:reference, name}, %Dextrin.Struct{name: struct_name}, _registry),
    do: struct_name == name

  def matches?({:reference, name}, %Validated{name: validated_name}, _registry),
    do: validated_name == name

  def matches?({:reference, name}, value, registry)
      when not is_nil(registry) and is_struct(value) do
    case Dextrin.Registry.fetch_struct_module(registry, name) do
      {:ok, module} -> value.__struct__ == module
      :error -> true
    end
  end

  def matches?({:reference, _name}, _value, _registry), do: true

  def matches?(type, %Validated{value: inner}, registry), do: matches?(type, inner, registry)

  def matches?({:primitive, name}, value, _registry), do: primitive_matches?(name, value)

  def matches?({:list_of, elem_type}, value, registry) do
    is_list(value) and Enum.all?(value, &matches?(elem_type, &1, registry))
  end

  def matches?({:set_of, elem_type}, %MapSet{} = value, registry) do
    Enum.all?(MapSet.to_list(value), &matches?(elem_type, &1, registry))
  end

  def matches?({:set_of, _}, _value, _registry), do: false

  def matches?({:tuple_of, types}, %Tuple{items: items}, registry) do
    length(types) == length(items) and
      Enum.all?(Enum.zip(types, items), fn {t, v} -> matches?(t, v, registry) end)
  end

  def matches?({:tuple_of, _}, _value, _registry), do: false

  def matches?({:map_of, key_type, val_type}, value, registry)
      when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {k, v} ->
      matches?(key_type, k, registry) and matches?(val_type, v, registry)
    end)
  end

  def matches?({:map_of, _, _}, _value, _registry), do: false

  # A schema's `enum` literals always come from `.dxns` *compilation*
  # (`Dextrin.Schema.Compiler`'s `atomize_back/1` normalizes them to
  # `Dextrin.Keyword`, regardless of how the schema *source* was
  # decoded), but the *data* being checked against them can be either
  # shape depending on the caller's own `trusted:` choice — a plain
  # `in` would only ever match the untrusted (`Dextrin.Keyword`) shape.
  def matches?({:enum, literals}, value, _registry),
    do: Enum.any?(literals, &keyword_aware_eq?(&1, value))

  def matches?({:one_of, types}, value, registry),
    do: Enum.any?(types, &matches?(&1, value, registry))

  def matches?({:all_of, types}, value, registry),
    do: Enum.all?(types, &matches?(&1, value, registry))

  def matches?({:nilable, _type}, nil, _registry), do: true
  def matches?({:nilable, type}, value, registry), do: matches?(type, value, registry)

  def matches?({:refine, type, constraints}, value, registry) do
    matches?(type, value, registry) and satisfies_constraints?(value, constraints)
  end

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
  defp primitive_matches?("bytes", value), do: match?(%Bytes{}, value)
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
