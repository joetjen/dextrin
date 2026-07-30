defmodule Dextrin.Binary.FuzzTest do
  @moduledoc """
  Property-based complement to `Dextrin.Binary.MalformedTest`'s
  hand-picked cases: `Dextrin.decode_binary/2` must never raise or
  hang, for *any* input — valid envelope or not, valid CBOR or not.
  A decoder that only handles the malformed shapes someone thought to
  write by hand is exactly the gap that let the `DXN.md` §2.4
  string-reference tag go unhandled until it was found by hand
  -crafting bytes; undirected fuzzing exists to catch the next one
  before a hand-written test would.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  property "arbitrary bytes never raise, hang, or otherwise crash the decoder" do
    check all(bytes <- binary()) do
      assert match?({:ok, _}, Dextrin.decode_binary(bytes)) or
               match?({:error, %Dextrin.Error{}}, Dextrin.decode_binary(bytes))
    end
  end

  property "a correct envelope with arbitrary garbage after it never crashes" do
    check all(bytes <- binary()) do
      envelope = "DX" <> <<1>> <> bytes

      assert match?({:ok, _}, Dextrin.decode_binary(envelope)) or
               match?({:error, %Dextrin.Error{}}, Dextrin.decode_binary(envelope))
    end
  end

  property "a valid encoding with one random byte flipped never crashes" do
    check all(
            value <- Dextrin.Generators.dxn_value(),
            {:ok, encoded} = {:ok, elem(Dextrin.encode_binary(value), 1)},
            byte_size(encoded) > 0,
            index <- integer(0..(byte_size(encoded) - 1)),
            flip <- integer(1..255)
          ) do
      <<before::binary-size(index), byte, rest::binary>> = encoded
      flipped = <<before::binary, Bitwise.bxor(byte, flip), rest::binary>>

      assert match?({:ok, _}, Dextrin.decode_binary(flipped)) or
               match?({:error, %Dextrin.Error{}}, Dextrin.decode_binary(flipped))
    end
  end
end
