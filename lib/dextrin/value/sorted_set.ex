defmodule Dextrin.SortedSet do
  @moduledoc """
  DXN `sorted-set` (`@sorted-set @{ ... }`). Wraps a list kept sorted
  (and deduplicated) as a hard invariant at every construction site —
  `new/1` is the *only* way to build one, precisely so that structural
  `==` between two `Dextrin.SortedSet`s is valid set-equality rather
  than something that happens to work only when both were built the
  same way — every construction site (decode, encode, public API)
  goes through `new/1`, so the sorted/deduplicated invariant can never
  be bypassed.
  """

  @type t :: %__MODULE__{items: [term()]}

  defstruct items: []

  @spec new([term()]) :: t()
  def new(items) when is_list(items) do
    %__MODULE__{items: items |> Enum.uniq() |> Enum.sort()}
  end

  @spec to_list(t()) :: [term()]
  def to_list(%__MODULE__{items: items}), do: items
end
