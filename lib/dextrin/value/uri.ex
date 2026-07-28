defmodule Dextrin.Uri do
  @moduledoc """
  DXN `uri` (`@uri "..."`, RFC 3986). Wraps the raw string exactly as
  given, not parsed into `URI.t()` — `URI.parse/1` is lenient in ways
  RFC 3986 isn't, and `URI.to_string/1` doesn't always reproduce the
  original text byte-for-byte, which would risk breaking round-trip
  (DESIGN.md §4.2).
  """

  @type t :: %__MODULE__{value: String.t()}

  defstruct [:value]

  @spec new(String.t()) :: t()
  def new(value) when is_binary(value), do: %__MODULE__{value: value}
end
