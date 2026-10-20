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

  # The names whose atoms are already values: NaN and the infinities,
  # nil and the booleans.
  @taken ~w(nan positive_infinity negative_infinity nil true false)

  @doc """
  The keyword `name` as a trusted decode reads it: its atom, but a
  `Dextrin.Keyword` still for a name whose atom is already a value --
  `:nan`, `:positive_infinity`, `:negative_infinity`, `:nil`, `:true`,
  `:false` -- so the keyword stays a keyword (Jan, 2026-10-20).

      iex> Dextrin.Keyword.trusted("ok")
      :ok
      iex> Dextrin.Keyword.trusted("nan")
      %Dextrin.Keyword{name: "nan"}
  """
  @spec trusted(String.t()) :: atom() | t()
  def trusted(name) when name in @taken, do: new(name)
  def trusted(name) when is_binary(name), do: String.to_atom(name)
end
