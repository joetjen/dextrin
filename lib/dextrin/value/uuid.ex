defmodule Dextrin.Uuid do
  @moduledoc """
  DXN `uuid` (`@uuid "..."`, RFC 4122). Wraps 16 raw bytes, not the
  36-char text form — the text form exists only at the `.dxn`/`.dxnb`
  boundary (DESIGN.md §4).
  """

  @type t :: %__MODULE__{bytes: <<_::128>>}

  defstruct [:bytes]

  @spec new(<<_::128>>) :: t()
  def new(<<bytes::binary-size(16)>>), do: %__MODULE__{bytes: bytes}

  @doc "Parses the canonical 36-char hyphenated text form."
  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid_uuid}
  def parse(str) when is_binary(str) do
    case String.replace(str, "-", "") do
      <<hex::binary-size(32)>> ->
        case Base.decode16(hex, case: :mixed) do
          {:ok, bytes} -> {:ok, %__MODULE__{bytes: bytes}}
          :error -> {:error, :invalid_uuid}
        end

      _ ->
        {:error, :invalid_uuid}
    end
  end

  @doc "Renders the canonical 36-char hyphenated text form."
  @spec format(t()) :: String.t()
  def format(%__MODULE__{bytes: <<a::32, b::16, c::16, d::16, e::48>>}) do
    hex = fn n, width -> n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0") end
    "#{hex.(a, 8)}-#{hex.(b, 4)}-#{hex.(c, 4)}-#{hex.(d, 4)}-#{hex.(e, 12)}"
  end
end
