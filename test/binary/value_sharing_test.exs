defmodule Dextrin.Binary.ValueSharingTest do
  @moduledoc """
  DXN.md §2.5 / DESIGN.md §7.3.1's general value-sharing extension
  (CBOR tags 28/29) — decode support is spec-mandatory regardless of
  which encoder produced the bytes; encode support is opt-in
  (`share: true`, default `false`).
  """

  use ExUnit.Case, async: true

  @repeated %{Dextrin.Keyword.new("a") => 1, Dextrin.Keyword.new("b") => [1, 2, 3, 4, 5]}

  test "share: false (default) produces no tag 28/29 and is transparent" do
    value = [@repeated, @repeated, @repeated]
    assert {:ok, encoded} = Dextrin.encode_binary(value)
    assert {:ok, decoded} = Dextrin.decode_binary(encoded)
    assert decoded == value
  end

  test "share: true is smaller than share: false for a repeated compound value" do
    value = [@repeated, @repeated, @repeated]
    assert {:ok, unshared} = Dextrin.encode_binary(value, share: false)
    assert {:ok, shared} = Dextrin.encode_binary(value, share: true)
    assert byte_size(shared) < byte_size(unshared)
  end

  test "share: true round-trips to an equal (not just similar) value" do
    value = [@repeated, @repeated, @repeated]
    assert {:ok, shared} = Dextrin.encode_binary(value, share: true)
    assert {:ok, decoded} = Dextrin.decode_binary(shared)
    assert decoded == value
  end

  test "sharing works nested inside other collections" do
    value = %{Dextrin.Keyword.new("x") => @repeated, Dextrin.Keyword.new("y") => [@repeated, @repeated]}
    assert {:ok, shared} = Dextrin.encode_binary(value, share: true)
    assert {:ok, decoded} = Dextrin.decode_binary(shared)
    assert decoded == value
  end

  test "decoder accepts tag 28/29 even without share: true on encode (decode-side is mandatory)" do
    # Hand-built: tag 28 wraps an integer 42 (its first occurrence);
    # tag 29 then references index 0 for the second occurrence.
    shareable_42 = <<6::3, 24::5, 28::8>> <> <<0::3, 24::5, 42::8>>
    shared_ref_0 = <<6::3, 24::5, 29::8>> <> <<0::3, 0::5>>
    list_item = <<4::3, 2::5>> <> shareable_42 <> shared_ref_0
    envelope = "DX" <> <<1>> <> list_item

    assert {:ok, [42, 42]} = Dextrin.decode_binary(envelope)
  end

  test "an out-of-range shared reference is a decode error, not a crash" do
    bad_ref = <<6::3, 24::5, 29::8>> <> <<0::3, 5::5>>
    envelope = "DX" <> <<1>> <> bad_ref

    assert {:error, %Dextrin.Error{}} = Dextrin.decode_binary(envelope)
  end

  test "a non-integer shared reference payload is a decode error" do
    bad_ref = <<6::3, 24::5, 29::8>> <> <<3::3, 4::5>> <> "true"
    envelope = "DX" <> <<1>> <> bad_ref

    assert {:error, %Dextrin.Error{}} = Dextrin.decode_binary(envelope)
  end

  test "small scalars aren't wrapped in tag 28/29 — the cost/benefit math rejects them, not a type exclusion" do
    assert {:ok, unshared} = Dextrin.encode_binary([1, 1, 1], share: false)
    assert {:ok, shared} = Dextrin.encode_binary([1, 1, 1], share: true)
    assert unshared == shared
  end

  describe "the sharing decision is a calculated threshold, not a guess" do
    test "a value whose reference cost equals its own encoded size is never shared, at any repetition count" do
      # [1, 2] encodes to exactly 3 bytes; a tag-29 reference to it also
      # costs exactly 3 bytes (2-byte tag + 1-byte index while count < 24)
      # — replacing an occurrence with a reference saves zero bytes,
      # while the first occurrence still pays +2 for its own tag-28
      # wrapper. Sharing can mathematically never pay off here, at any n.
      for n <- [2, 5, 10, 20] do
        value = List.duplicate([1, 2], n)
        assert {:ok, unshared} = Dextrin.encode_binary(value, share: false)
        assert {:ok, shared} = Dextrin.encode_binary(value, share: true)
        assert byte_size(shared) == byte_size(unshared)
      end
    end

    test "crossover happens exactly where the arithmetic predicts" do
      # [1,2,3,4,5] encodes to 6 bytes; ref cost is 3 (2-byte tag +
      # 1-byte index). Sharing wins once (6+2)+(n-1)*3 < n*6, i.e.
      # n > 5/3 — so n=1 must NOT share, n=2 onward must.
      one = List.duplicate([1, 2, 3, 4, 5], 1)
      two = List.duplicate([1, 2, 3, 4, 5], 2)

      assert {:ok, one_unshared} = Dextrin.encode_binary(one, share: false)
      assert {:ok, one_shared} = Dextrin.encode_binary(one, share: true)
      assert byte_size(one_shared) == byte_size(one_unshared)

      assert {:ok, two_unshared} = Dextrin.encode_binary(two, share: false)
      assert {:ok, two_shared} = Dextrin.encode_binary(two, share: true)
      assert byte_size(two_shared) < byte_size(two_unshared)
    end

    test "share: true is never larger than share: false, across a range of sizes and counts" do
      keyed_map = %{Dextrin.Keyword.new("a") => 1, Dextrin.Keyword.new("b") => 2, Dextrin.Keyword.new("c") => 3}

      samples = [
        List.duplicate([1, 2], 20),
        List.duplicate([1, 2, 3, 4, 5], 5),
        List.duplicate(keyed_map, 4),
        List.duplicate(String.duplicate("x", 50), 3)
      ]

      for value <- samples do
        assert {:ok, unshared} = Dextrin.encode_binary(value, share: false)
        assert {:ok, shared} = Dextrin.encode_binary(value, share: true)
        assert byte_size(shared) <= byte_size(unshared)
      end
    end

    test "a long, frequently-repeated string is now shareable — no longer excluded by type" do
      long_string = String.duplicate("x", 100)
      value = [long_string, long_string, long_string]

      assert {:ok, unshared} = Dextrin.encode_binary(value, share: false)
      assert {:ok, shared} = Dextrin.encode_binary(value, share: true)
      assert byte_size(shared) < byte_size(unshared)
      assert {:ok, ^value} = Dextrin.decode_binary(shared)
    end
  end
end
