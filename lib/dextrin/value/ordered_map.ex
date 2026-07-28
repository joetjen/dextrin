defmodule Dextrin.OrderedMap do
  @moduledoc """
  DXN `ordered-map` (`@ordered %{ ... }`) — order is part of the
  value's identity, unlike plain `map`. Wraps an ordered list of
  `{key, value}` pairs rather than a plain Elixir map, so insertion
  order survives structural `==` comparison.
  """

  @type t :: %__MODULE__{pairs: [{term(), term()}]}

  defstruct pairs: []

  @spec new([{term(), term()}]) :: t()
  def new(pairs) when is_list(pairs), do: %__MODULE__{pairs: pairs}

  @spec fetch(t(), term()) :: {:ok, term()} | :error
  def fetch(%__MODULE__{pairs: pairs}, key) do
    case List.keyfind(pairs, key, 0) do
      {^key, value} -> {:ok, value}
      nil -> :error
    end
  end

  @spec to_list(t()) :: [{term(), term()}]
  def to_list(%__MODULE__{pairs: pairs}), do: pairs
end
