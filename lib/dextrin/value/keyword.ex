defmodule Dextrin.Keyword do
  @moduledoc """
  DXN `keyword` (`:name` in value position). Wraps a plain
  `String.t()`, never an Elixir atom, for the same reason as
  `Dextrin.Symbol` — see DESIGN.md §4.2.
  """

  @type t :: %__MODULE__{name: String.t()}

  defstruct [:name]

  @spec new(String.t()) :: t()
  def new(name) when is_binary(name), do: %__MODULE__{name: name}
end
