defmodule Dextrin.Bytes do
  @moduledoc """
  DXN `bytes` (`@bytes "..."`, base64 in text, raw binary in `.dxnb`).
  Wraps a plain Elixir `binary()` — needed because `string` is *also*
  a plain Elixir `binary()` (`String.t()` is not a distinct runtime
  type), so a bare binary can't otherwise tell "UTF-8 text" and "raw
  bytes that happen to be valid UTF-8" apart on re-encode (the same
  kind of ambiguity §4.2 already wraps `char`/`symbol`/`keyword` to
  avoid — this one was missed in the original design and found while
  implementing the encoder).
  """

  @type t :: %__MODULE__{data: binary()}

  defstruct [:data]

  @spec new(binary()) :: t()
  def new(data) when is_binary(data), do: %__MODULE__{data: data}
end
