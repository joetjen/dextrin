defmodule Dextrin.CustomTag do
  @moduledoc """
  Opaque DXN custom tag (`@tag value`), produced when no decoder is
  registered for its name (DXN.md §1.2, DESIGN.md §4.3).
  """

  @type t :: %__MODULE__{name: String.t(), value: term()}

  defstruct [:name, :value]

  @spec new(String.t(), term()) :: t()
  def new(name, value) when is_binary(name), do: %__MODULE__{name: name, value: value}
end
