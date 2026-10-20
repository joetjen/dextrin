defmodule Dextrin.ObjectId do
  @moduledoc """
  DXN `objectid` (`@objectid "..."`, Jan, 2026-10-20): BSON's 12-byte
  ObjectId, built in like `uuid` -- readable in text, its raw bytes in
  `.dxnb`. The value holds the bytes; the 24 hex digits exist only at
  the text boundary.

      iex> {:ok, id} = Dextrin.ObjectId.parse("507F1F77BCF86CD799439011")
      iex> Dextrin.ObjectId.format(id)
      "507f1f77bcf86cd799439011"
  """

  @type t :: %__MODULE__{bytes: <<_::96>>}

  defstruct [:bytes]

  @doc "An ObjectId from its 12 raw bytes."
  @spec new(<<_::96>>) :: t()
  def new(<<bytes::binary-size(12)>>), do: %__MODULE__{bytes: bytes}

  @doc "Parses 24 hex digits, either case."
  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid_objectid}
  def parse(<<hex::binary-size(24)>>) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> {:ok, %__MODULE__{bytes: bytes}}
      :error -> {:error, :invalid_objectid}
    end
  end

  def parse(_text), do: {:error, :invalid_objectid}

  @doc "The 24 lowercase hex digits."
  @spec format(t()) :: String.t()
  def format(%__MODULE__{bytes: bytes}), do: Base.encode16(bytes, case: :lower)
end
