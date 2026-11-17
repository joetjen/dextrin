defmodule Dextrin.Tuple do
  @moduledoc """
  DXN `tuple` (`{ ... }`) — ordered, heterogeneous, arbitrary length.
  Wraps a list, not an Elixir tuple: DXN tuples have no fixed arity in
  the type system the way Elixir's do, and `Dextrin.Array` already
  claims the Elixir tuple for the one DXN type that actually is
  fixed-size/indexed.
  """

  @type t :: %__MODULE__{items: [term()]}

  defstruct items: []

  @spec new([term()]) :: t()
  def new(items) when is_list(items), do: %__MODULE__{items: items}

  @doc """
  The name and version a tuple `{:at Name N}` pins (DXNS.md §5c), which
  text writes `Name(N)`: `{:ok, name, version}`, or `:error` for any
  other tuple. Shared by every writer, so the printer, the formatter and
  the canonical form agree.

      iex> {:ok, at} = Dextrin.decode("Pet(2)")
      iex> Dextrin.Tuple.pinned(at)
      {:ok, "Pet", 2}
      iex> Dextrin.Tuple.pinned(Dextrin.Tuple.new([1, 2]))
      :error
  """
  @spec pinned(t()) :: {:ok, String.t(), pos_integer()} | :error
  def pinned(%__MODULE__{items: [at, %Dextrin.Symbol{name: name}, version]})
      when is_integer(version) and version > 0 do
    if at in [:at, %Dextrin.Keyword{name: "at"}], do: {:ok, name, version}, else: :error
  end

  def pinned(%__MODULE__{}), do: :error

  @doc "How `pinned/1`'s name and version are written: `Name(N)`."
  @spec pinned_text(String.t(), pos_integer()) :: String.t()
  def pinned_text(name, version), do: name <> "(" <> Integer.to_string(version) <> ")"
end
