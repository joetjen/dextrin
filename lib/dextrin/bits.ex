defmodule Dextrin.Bits do
  @moduledoc """
  `bits` (DXN.md §1.4): a run of bits that is not whole bytes, written
  as its bytes and their bit count -- `@bits {"oA==" 3}` in text,
  `T_BITS` around `[bytes, count]` in `.dxnb`.

  **Bits and bytes are one value space.** An Elixir bitstring is the
  value, held in a `Dextrin.Bytes` like any bytes; one whose size is a
  multiple of 8 is a binary, and is written as bytes. This module is the
  one place the two halves of the written form are made and checked, so
  text, binary and the canonical form cannot disagree about them.
  """

  @doc """
  `bits` as written: its bytes, the unused low bits of the last one
  zero, and how many of their bits are the value.

      iex> Dextrin.Bits.parts(<<5::3>>)
      {<<0b10100000>>, 3}
  """
  @spec parts(bitstring()) :: {binary(), non_neg_integer()}
  def parts(bits) when is_bitstring(bits) do
    count = bit_size(bits)
    pad = rem(8 - rem(count, 8), 8)
    {<<bits::bitstring, 0::size(pad)>>, count}
  end

  @doc """
  The bits `data` and `count` write, or `:error` when they do not write
  any: `count` must be a non-negative integer and `data` exactly the
  bytes it needs. The unused low bits of the last byte are ignored.

      iex> Dextrin.Bits.from_parts(<<0b10100111>>, 3)
      {:ok, <<5::3>>}

      iex> Dextrin.Bits.from_parts(<<1, 2>>, 3)
      :error
  """
  @spec from_parts(term(), term()) :: {:ok, bitstring()} | :error
  def from_parts(data, count)
      when is_binary(data) and is_integer(count) and count >= 0 and
             byte_size(data) == div(count + 7, 8) do
    <<bits::bitstring-size(count), _padding::bitstring>> = data
    {:ok, bits}
  end

  def from_parts(_data, _count), do: :error
end
