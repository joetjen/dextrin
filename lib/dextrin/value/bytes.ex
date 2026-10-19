defmodule Dextrin.Bytes do
  @moduledoc """
  DXN `bytes` (`@bytes "..."`, base64 in text, raw binary in `.dxnb`).
  Wraps a plain Elixir `binary()` — needed because `string` is *also*
  a plain Elixir `binary()` (`String.t()` is not a distinct runtime
  type), so a bare binary can't otherwise tell "UTF-8 text" and "raw
  bytes that happen to be valid UTF-8" apart on re-encode. The same
  kind of ambiguity `Dextrin.Char`/`Dextrin.Symbol`/`Dextrin.Keyword`
  each wrap a bare value to avoid.

  **It holds bits too** (DXN.md §1.4, `Dextrin.Bits`): a bitstring
  whose size is not a multiple of 8 is DXN `bits`, written
  `@bits {"..." n}`. Bits and bytes are one value space, so one struct
  holds both.
  """

  @type t :: %__MODULE__{data: bitstring()}

  defstruct [:data]

  @spec new(bitstring()) :: t()
  def new(data) when is_bitstring(data), do: %__MODULE__{data: data}
end
