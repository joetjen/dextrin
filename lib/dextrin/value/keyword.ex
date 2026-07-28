defmodule Dextrin.Keyword do
  @moduledoc """
  DXN `keyword` (`:name` in value position). Wraps a plain
  `String.t()`, never an Elixir atom, for the same reason as
  `Dextrin.Symbol`: atoms are never garbage collected on the BEAM, and
  decoding untrusted, attacker-controlled data must never be able to
  exhaust the atom table.
  """

  @type t :: %__MODULE__{name: String.t()}

  defstruct [:name]

  @spec new(String.t()) :: t()
  def new(name) when is_binary(name), do: %__MODULE__{name: name}
end
