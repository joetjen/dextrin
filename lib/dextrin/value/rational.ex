defmodule Dextrin.Rational do
  @moduledoc """
  DXN `rational` (`int/uint`) — an exact ratio, stored exactly as
  given and never silently reduced (`22/7` and `44/14` are distinct
  DXN values; `reduce/1` is opt-in — DESIGN.md §4.1).
  """

  @type t :: %__MODULE__{numerator: integer(), denominator: pos_integer()}

  defstruct [:numerator, :denominator]

  @spec new(integer(), pos_integer()) :: t()
  def new(numerator, denominator)
      when is_integer(numerator) and is_integer(denominator) and denominator > 0 do
    %__MODULE__{numerator: numerator, denominator: denominator}
  end

  @spec reduce(t()) :: t()
  def reduce(%__MODULE__{numerator: n, denominator: d}) do
    g = Integer.gcd(n, d)
    %__MODULE__{numerator: div(n, g), denominator: div(d, g)}
  end
end
