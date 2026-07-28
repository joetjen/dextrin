defmodule Dextrin.Symbol do
  @moduledoc """
  DXN `symbol` — a bare, unevaluated identifier reference. Wraps a
  plain `String.t()`, never an Elixir atom: atoms are never garbage
  collected on the BEAM, and a decoder fed adversarial or merely large
  third-party input must not be able to exhaust the atom table by
  decoding enough distinct symbols (DESIGN.md §4.2).
  """

  @type t :: %__MODULE__{name: String.t()}

  defstruct [:name]

  @spec new(String.t()) :: t()
  def new(name) when is_binary(name), do: %__MODULE__{name: name}
end
