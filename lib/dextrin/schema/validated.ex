defmodule Dextrin.Schema.Validated do
  @moduledoc """
  Internal only — never appears in a value handed back to
  `Dextrin.decode/2`/`decode_binary/2`'s caller.

  Tracks which schema produced a materialized value, so an outer
  `{:reference, name}` check (DESIGN.md §10) can verify identity even
  after materialization has replaced the value with a plain map or
  application struct that carries no name of its own — unlike an
  *opaque* `Dextrin.Struct`, which already carries its own name and
  never needed this. `Dextrin.Schema.Validator.materialize/4` (decode)
  and `wrap_and_check/2` (encode-time validation) both wrap every
  successfully-checked struct's result in one of these — one wrapper,
  shared by both directions; `strip/1` removes every occurrence,
  recursively, once the value reaches somewhere that isn't itself
  another schema check — a field whose declared type isn't a
  reference, or the true top of decoding (`Dextrin.decode/2`/
  `decode_binary/2`), for a struct that was never anyone's field to
  begin with.
  """

  @type t :: %__MODULE__{name: String.t(), value: term()}

  defstruct [:name, :value]

  alias Dextrin.{Array, CustomTag, OrderedMap, SortedSet, Struct}

  @doc "Recursively removes every Validated wrapper from a decoded value tree."
  @spec strip(term()) :: term()
  def strip(%__MODULE__{value: value}), do: strip(value)
  def strip(list) when is_list(list), do: Enum.map(list, &strip/1)
  def strip(%Dextrin.Tuple{items: items} = t), do: %{t | items: Enum.map(items, &strip/1)}

  def strip(%Array{items: items} = a) do
    %{a | items: items |> Tuple.to_list() |> Enum.map(&strip/1) |> List.to_tuple()}
  end

  def strip(%OrderedMap{pairs: pairs} = om) do
    %{om | pairs: Enum.map(pairs, fn {k, v} -> {strip(k), strip(v)} end)}
  end

  def strip(%MapSet{} = set), do: set |> Enum.map(&strip/1) |> MapSet.new()
  def strip(%SortedSet{items: items} = ss), do: %{ss | items: Enum.map(items, &strip/1)}

  def strip(%Struct{fields: {:keyed, pairs}} = s) do
    %{s | fields: {:keyed, Enum.map(pairs, fn {k, v} -> {k, strip(v)} end)}}
  end

  def strip(%Struct{fields: {:positional, items}} = s), do: %{s | fields: {:positional, Enum.map(items, &strip/1)}}
  def strip(%CustomTag{value: value} = c), do: %{c | value: strip(value)}
  def strip(%{} = map) when not is_struct(map), do: Map.new(map, fn {k, v} -> {strip(k), strip(v)} end)
  def strip(other), do: other
end
