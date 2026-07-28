defmodule Dextrin.Array do
  @moduledoc """
  DXN `array` (`@array[ ... ]`) — fixed-size, indexed. Wraps an
  Elixir tuple, the one DXN collection type where Elixir's own
  fixed-arity tuple is actually the right fit (DESIGN.md §4.2).
  """

  @type t :: %__MODULE__{items: tuple()}

  defstruct items: {}

  @spec new([term()] | tuple()) :: t()
  def new(items) when is_list(items), do: %__MODULE__{items: List.to_tuple(items)}
  def new(items) when is_tuple(items), do: %__MODULE__{items: items}

  @spec to_list(t()) :: [term()]
  def to_list(%__MODULE__{items: items}), do: Tuple.to_list(items)
end
