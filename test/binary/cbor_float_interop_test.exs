defmodule Dextrin.Binary.CborFloatInteropTest do
  @moduledoc """
  Regression test for a real interop bug: `Dextrin.Binary.Encoder`
  used to emit floats via the generic minimal-integer-encoding helper
  (`head(7, 27)`), which doesn't understand that major 7's
  additional-info value (unlike every other major type's) is itself
  semantically meaningful, not just an encoding-length detail. That
  produced a non-canonical, oversized float header — and, since
  `Dextrin.Binary.Decoder` was written to match the same
  misunderstanding, a *standard* single-byte CBOR float header (from
  any other conformant producer) failed to decode at all. Every prior
  round-trip test missed this because they all decoded floats this
  same encoder had produced — both sides agreed on the same bug.

  Caught by hand-verifying the CBOR tag registry for an unrelated
  question, then testing this decoder against a standards-conformant
  hand-built float rather than only against its own encoder's output.
  """

  use ExUnit.Case, async: true

  test "decodes a canonical (standards-conformant) double-precision float header" do
    # <<0xFB>> + 8 IEEE-754 double bytes — the single-byte form every
    # conformant CBOR encoder uses, not the 2-byte form this decoder
    # used to require.
    item = <<7::3, 27::5>> <> <<19.99::float>>
    envelope = "DX" <> <<1>> <> item

    assert {:ok, 19.99} = Dextrin.decode_binary(envelope)
  end

  test "dextrin's own encoder now emits the canonical single-byte float header" do
    assert {:ok, <<"DX", 1, 0xFB, _rest::binary-size(8)>>} = Dextrin.encode_binary(19.99)
  end

  test "decodes a single-precision (32-bit) float for interop with other encoders" do
    item = <<7::3, 26::5>> <> <<1.5::float-32>>
    envelope = "DX" <> <<1>> <> item

    assert {:ok, 1.5} = Dextrin.decode_binary(envelope)
  end

  test "half-precision (16-bit) floats are rejected explicitly, not misdecoded" do
    item = <<7::3, 25::5, 0::16>>
    envelope = "DX" <> <<1>> <> item

    assert {:error, %Dextrin.Error{}} = Dextrin.decode_binary(envelope)
  end

  test "special float values still round-trip through the fixed header" do
    for value <- [:nan, :positive_infinity, :negative_infinity, -0.0, 1.0e10] do
      assert {:ok, encoded} = Dextrin.encode_binary(value)
      assert {:ok, ^value} = Dextrin.decode_binary(encoded)
    end
  end
end
