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

  # `.dxnb` writes the shortest width that holds a float exactly, and
  # reads every width (DXN.md §2.2, Jan, 2026-10-20).
  test "half-precision floats are read, specials and subnormals included" do
    half = fn bits -> Dextrin.decode_binary("DX" <> <<1, 7::3, 25::5, bits::16>>) end
    assert {:ok, +0.0} = half.(0x0000)
    assert {:ok, -2.0} = half.(0xC000)
    assert {:ok, 65_504.0} = half.(0x7BFF)
    assert {:ok, 5.960464477539063e-8} = half.(0x0001)
    assert {:ok, :positive_infinity} = half.(0x7C00)
    assert {:ok, :negative_infinity} = half.(0xFC00)
    assert {:ok, :nan} = half.(0x7E00)
  end

  test "a float is written in the shortest width that holds it exactly" do
    width = fn f ->
      {:ok, <<"DX", 1, 7::3, info::5, _::binary>>} = Dextrin.encode_binary(f)
      %{25 => :half, 26 => :single, 27 => :double}[info]
    end

    assert width.(1.5) == :half
    assert width.(-0.0) == :half
    assert width.(65_504.0) == :half
    assert width.(65_520.0) == :single
    assert width.(0.1) == :double
    assert width.(3.141592653589793) == :double
    assert width.(:nan) == :half

    for f <- [1.5, -0.0, 65_520.0, 0.1, 1.0e-40, 1.0e300, :nan, :positive_infinity] do
      {:ok, bytes} = Dextrin.encode_binary(f)
      {:ok, back} = Dextrin.decode_binary(bytes)
      assert if(is_float(f), do: <<back::float>> == <<f::float>>, else: back == f), inspect(f)
    end
  end

  test "a UTC datetime is its bare nanoseconds, a regex without flags its bare pattern" do
    {:ok, utc} = Dextrin.decode(~s|@datetime "1970-01-01T00:00:01Z"|)
    # tag 219, then the integer 1_000_000_000: no array, no offset.
    assert {:ok, <<"DX", 1, 0xD8, 219, 0x1A, 1_000_000_000::32>>} = Dextrin.encode_binary(utc)

    {:ok, regex} = Dextrin.decode(~s|@regex "a"|)
    # tag 213, then the string "a".
    assert {:ok, <<"DX", 1, 0xD8, 213, 0x61, ?a>>} = Dextrin.encode_binary(regex)
  end

  test "special float values still round-trip through the fixed header" do
    for value <- [:nan, :positive_infinity, :negative_infinity, -0.0, 1.0e10] do
      assert {:ok, encoded} = Dextrin.encode_binary(value)
      assert {:ok, ^value} = Dextrin.decode_binary(encoded)
    end
  end
end
