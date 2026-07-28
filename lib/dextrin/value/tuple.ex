defmodule Dextrin.Tuple do
  @moduledoc """
  DXN `tuple` (`{ ... }`) — ordered, heterogeneous, arbitrary length.
  Wraps a list, not an Elixir tuple: DXN tuples have no fixed arity in
  the type system the way Elixir's do, and `Dextrin.Array` already
  claims the Elixir tuple for the one DXN type that actually is
  fixed-size/indexed (DESIGN.md §4.2).
  """

  @type t :: %__MODULE__{items: [term()]}

  defstruct items: []

  @spec new([term()]) :: t()
  def new(items) when is_list(items), do: %__MODULE__{items: items}
end
