defmodule Dextrin.Char do
  @moduledoc """
  DXN `char` (`?c`) — a single Unicode codepoint. Kept distinct from a
  1-grapheme `String.t()` so `char` and `string` never collapse to the
  same Elixir value and silently fail to round-trip (DESIGN.md §4.2).
  """

  @type t :: %__MODULE__{codepoint: non_neg_integer()}

  defstruct [:codepoint]

  @spec new(non_neg_integer()) :: t()
  def new(codepoint) when is_integer(codepoint) and codepoint >= 0 do
    %__MODULE__{codepoint: codepoint}
  end
end
