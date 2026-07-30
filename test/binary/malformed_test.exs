defmodule Dextrin.Binary.MalformedTest do
  @moduledoc """
  Fuzz/malformed-input coverage for `Dextrin.Binary.Decoder`: truncated
  `.dxnb`, invalid UTF-8, an out-of-range tag-29 shared-value
  reference, unrecognized/malformed tag payloads, and similar --
  the decoder must return `{:error, %Dextrin.Error{}}` for every one
  of these, never raise or hang. Most cases are built by taking a
  known-good encoding and corrupting one specific part of it, rather
  than hand-building CBOR bytes from scratch.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Binary.Tags

  defp assert_decode_error(bytes) do
    assert {:error, %Dextrin.Error{}} = Dextrin.decode_binary(bytes)
  end

  test "missing/wrong magic bytes" do
    assert_decode_error(<<0, 0, 0>>)
    assert_decode_error("")
  end

  test "correct magic but unsupported version byte" do
    assert_decode_error(<<"DX", 99>>)
  end

  test "a truncated item (envelope present, CBOR cut short)" do
    {:ok, full} = Dextrin.encode_binary([1, 2, 3])
    truncated = binary_part(full, 0, byte_size(full) - 2)
    assert_decode_error(truncated)
  end

  test "invalid UTF-8 inside a text (major 3) item" do
    {:ok, valid} = Dextrin.encode_binary("hi")
    # Header + length byte are the same regardless of content; corrupt
    # just the payload byte(s) that follow, keeping the length intact.
    header_size = byte_size(valid) - 2
    corrupted = binary_part(valid, 0, header_size) <> <<0xFF, 0xFE>>
    assert_decode_error(corrupted)
  end

  test "a half-precision (16-bit) float is explicitly rejected" do
    body = <<7::3, 25::5, 0::16>>
    assert_decode_error("DX" <> <<1>> <> body)
  end

  test "an unrecognized CBOR tag" do
    # tag 999 (well outside both the IANA-registered tags this library
    # uses and its own private 200-214 block), wrapping a small integer.
    body = <<6::3, 25::5, 999::16, 1::8>>
    assert_decode_error("DX" <> <<1>> <> body)
  end

  test "trailing bytes after the top-level value" do
    {:ok, valid} = Dextrin.encode_binary(1)
    assert_decode_error(valid <> <<0>>)
  end

  test "a tag-29 shared-value reference to a not-yet-seen index" do
    # tag 29 (t_shared_ref), payload: integer 0 -- valid CBOR shape,
    # but nothing has been tag-28-marked yet in this (trivial) document.
    body = <<6::3, 25::5, Tags.t_shared_ref()::16, 0::8>>
    assert_decode_error("DX" <> <<1>> <> body)
  end

  test "@ordered's payload must itself be a map (major 5), not any other major type" do
    {:ok, array_payload} = Dextrin.encode_binary([1, 2])
    # array_payload is "DX" <> version <> (major-4 array item); splice
    # that same major-4 item in as tag T_ORDERED's payload instead of
    # a real major-5 map.
    envelope_size = 3

    major4_item =
      binary_part(array_payload, envelope_size, byte_size(array_payload) - envelope_size)

    body = <<6::3, 25::5, Tags.t_ordered()::16>> <> major4_item
    assert_decode_error("DX" <> <<1>> <> body)
  end

  test "a malformed struct payload (name isn't a string)" do
    # tag T_STRUCT wrapping a one-element array whose sole item is an
    # integer, not [name_string | fields].
    body = <<6::3, 25::5, Tags.t_struct()::16, 4::3, 1::5, 1::8>>
    assert_decode_error("DX" <> <<1>> <> body)
  end

  test "a malformed decimal payload (not a 2-element [exponent, mantissa] array)" do
    body = <<6::3, 25::5, Tags.t_decimal()::16, 4::3, 1::5, 1::8>>
    assert_decode_error("DX" <> <<1>> <> body)
  end

  test "a malformed duration payload (bitmask doesn't match field count)" do
    # bitmask says 2 fields are present (bits 0 and 1), but only 1
    # field value follows.
    body = <<6::3, 25::5, Tags.t_duration()::16, 4::3, 2::5, 3::8, 1::8>>
    assert_decode_error("DX" <> <<1>> <> body)
  end

  test "a malformed regex payload (missing the flags byte)" do
    body = <<6::3, 25::5, Tags.t_regex()::16, 4::3, 1::5, 3::8, ?a, ?b, ?c>>
    assert_decode_error("DX" <> <<1>> <> body)
  end

  test "a malformed custom-tag payload (only one element instead of [name, value])" do
    body = <<6::3, 25::5, Tags.t_custom()::16, 4::3, 1::5, 3::8, ?a, ?b, ?c>>
    assert_decode_error("DX" <> <<1>> <> body)
  end

  test "a malformed time payload (not an integer) — found by property-based fuzzing, not by hand" do
    body = <<6::3, 25::5, Tags.t_time()::16, 4::3, 0::5>>
    assert_decode_error("DX" <> <<1>> <> body)
  end
end
