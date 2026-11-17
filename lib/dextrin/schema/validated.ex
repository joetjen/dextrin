defmodule Dextrin.Schema.Validated do
  @moduledoc """
  Internal only — never appears in a value handed back to
  `Dextrin.decode/2`/`decode_binary/2`'s caller.

  Tracks which schema produced a materialized value, so an outer
  `{:reference, name}` check can verify identity even after
  materialization has replaced the value with a plain map or
  application struct that carries no name of its own — unlike an
  *opaque* `Dextrin.Struct`, which already carries its own name and
  never needed this. `Dextrin.Schema.Reader.read/5` (decode)
  and `wrap_and_check/2` (encode-time validation) both wrap every
  successfully-checked struct's result in one of these — one wrapper,
  shared by both directions; `strip/1` removes every occurrence,
  recursively, once the value reaches somewhere that isn't itself
  another schema check — a field whose declared type isn't a
  reference, or the true top of decoding (`Dextrin.decode/2`/
  `decode_binary/2`), for a struct that was never anyone's field to
  begin with.
  """

  alias Dextrin.{Array, CustomTag, OrderedMap, SortedSet, Struct}

  @type t :: %__MODULE__{
          name: String.t(),
          value: term(),
          also: [String.t()],
          version: pos_integer() | nil,
          as_read: Dextrin.Struct.t() | nil,
          refused: Dextrin.Error.t() | nil
        }

  # `also` names the schemas the value passes as besides its own: those
  # its schema extends, and that it is a valid one of (DXNS.md §4b).
  # `version` is the version it was read or checked with, and `as_read`
  # the struct as that version reads it, before any materializer: what a
  # field pinned to that version takes instead (DXNS.md §5c). `refused`
  # is why it has no value -- an older version with no materializer to
  # upgrade it -- which stands unless a pinned field takes `as_read`.
  defstruct [:name, :value, :version, :as_read, :refused, also: []]

  @doc """
  `value` with every wrapper removed, as `strip/1` does -- or the first
  refusal one still holds: a struct no field took as read, and that
  could not be upgraded.
  """
  @spec unwrap(term()) :: {:ok, term()} | {:error, Dextrin.Error.t()}
  def unwrap(value) do
    case refusal(value) do
      nil -> {:ok, strip(value)}
      error -> {:error, error}
    end
  end

  defp refusal(%__MODULE__{refused: %Dextrin.Error{} = error}), do: error
  defp refusal(%__MODULE__{value: value}), do: refusal(value)
  defp refusal(list) when is_list(list), do: Enum.find_value(list, &refusal/1)
  defp refusal(%Dextrin.Tuple{items: items}), do: refusal(items)
  defp refusal(%Array{items: items}), do: refusal(Tuple.to_list(items))

  defp refusal(%OrderedMap{pairs: pairs}),
    do: Enum.find_value(pairs, fn {k, v} -> refusal(k) || refusal(v) end)

  defp refusal(%MapSet{} = set), do: Enum.find_value(set, &refusal/1)
  defp refusal(%SortedSet{items: items}), do: refusal(items)
  defp refusal(%Struct{fields: {:keyed, pairs}}), do: refusal(Enum.map(pairs, &elem(&1, 1)))
  defp refusal(%Struct{fields: {:positional, items}}), do: refusal(items)
  defp refusal(%CustomTag{value: value}), do: refusal(value)

  defp refusal(%{} = map) when not is_struct(map),
    do: Enum.find_value(map, fn {k, v} -> refusal(k) || refusal(v) end)

  defp refusal(_other), do: nil

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

  def strip(%Struct{fields: {:positional, items}} = s),
    do: %{s | fields: {:positional, Enum.map(items, &strip/1)}}

  def strip(%CustomTag{value: value} = c), do: %{c | value: strip(value)}

  def strip(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {k, v} -> {strip(k), strip(v)} end)

  def strip(other), do: other
end
