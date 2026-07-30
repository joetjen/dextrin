defmodule Dextrin.Binary.StringRefTest do
  @moduledoc """
  `DXN.md` §2.4's string-reference sharing extension (CBOR tags
  256/25) — decode support is spec-mandatory ("a conforming decoder
  MUST accept it") regardless of whether `dextrin`'s own encoder ever
  produces it. It doesn't: unlike §2.5's tag 28/29 (`share: true`),
  producing tags 256/25 is deliberately out of scope here — these
  tests hand-build the bytes to exercise decode-side acceptance only.
  """

  use ExUnit.Case, async: true

  # tag 256 needs the 2-byte-argument form (major 6, additional info
  # 25, big-endian uint16 256); tag 25 and tag 201 (T_SYMBOL) both need
  # the 1-byte-argument form (major 6, additional info 24, uint8) —
  # same convention `ValueSharingTest` uses for tags 28/29.
  @tag_stringref_ns <<6::3, 25::5, 256::16>>
  @tag_stringref <<6::3, 24::5, 25::8>>
  @t_symbol <<6::3, 24::5, 201::8>>

  defp text(str) when byte_size(str) < 24, do: <<3::3, byte_size(str)::5>> <> str
  defp ref(index) when index < 24, do: @tag_stringref <> <<0::3, index::5>>
  defp list(count) when count < 24, do: <<4::3, count::5>>

  test "a repeated symbol's text resolves through a stringref back-reference" do
    first = @t_symbol <> text("foo")
    second = @t_symbol <> ref(0)
    envelope = "DX" <> <<1>> <> @tag_stringref_ns <> list(2) <> first <> second

    assert {:ok, [%Dextrin.Symbol{name: "foo"}, %Dextrin.Symbol{name: "foo"}]} =
             Dextrin.decode_binary(envelope)
  end

  test "works for a bare, untagged repeated string too (the extension is text-level, not tag-level)" do
    first = text("foo")
    second = ref(0)
    envelope = "DX" <> <<1>> <> @tag_stringref_ns <> list(2) <> first <> second

    assert {:ok, ["foo", "foo"]} = Dextrin.decode_binary(envelope)
  end

  test "a nested stringref namespace gets its own independent table" do
    # outer scope: [ "outerA", <inner scope: ["innerX", ref(0)]>, ref(0) ]
    # the outer scope's own ref(0) must resolve to "outerA", not
    # "innerX" — the inner namespace's table is discarded, not merged
    # back, once its one wrapped item finishes decoding.
    inner =
      @tag_stringref_ns <>
        list(2) <>
        (@t_symbol <> text("innerX")) <>
        @t_symbol <> ref(0)

    outer_first = @t_symbol <> text("outerA")
    outer_last = @t_symbol <> ref(0)

    envelope =
      "DX" <> <<1>> <> @tag_stringref_ns <> list(3) <> outer_first <> inner <> outer_last

    assert {:ok,
            [
              %Dextrin.Symbol{name: "outerA"},
              [%Dextrin.Symbol{name: "innerX"}, %Dextrin.Symbol{name: "innerX"}],
              %Dextrin.Symbol{name: "outerA"}
            ]} = Dextrin.decode_binary(envelope)
  end

  test "a reference to an already-closed inner scope's table is a decode error, not a leak" do
    inner = @tag_stringref_ns <> list(1) <> @t_symbol <> text("innerX")
    outer_last = @t_symbol <> ref(0)

    envelope = "DX" <> <<1>> <> @tag_stringref_ns <> list(2) <> inner <> outer_last

    assert {:error, %Dextrin.Error{}} = Dextrin.decode_binary(envelope)
  end

  test "a forward reference (index not yet registered) is a decode error, not a crash" do
    first = @t_symbol <> ref(0)
    second = @t_symbol <> text("foo")
    envelope = "DX" <> <<1>> <> @tag_stringref_ns <> list(2) <> first <> second

    assert {:error, %Dextrin.Error{message: message}} = Dextrin.decode_binary(envelope)
    assert message =~ "not-yet-seen"
  end

  test "a stringref with no active namespace at all is a decode error" do
    envelope = "DX" <> <<1>> <> ref(0)

    assert {:error, %Dextrin.Error{message: message}} = Dextrin.decode_binary(envelope)
    assert message =~ "no active stringref namespace"
  end

  test "a non-integer stringref payload is a decode error" do
    bad_ref = @tag_stringref <> <<7::3, 21::5>>
    envelope = "DX" <> <<1>> <> @tag_stringref_ns <> bad_ref

    assert {:error, %Dextrin.Error{}} = Dextrin.decode_binary(envelope)
  end

  test "a struct's repeated positional type-name resolves the same way (DXN.md's own example)" do
    point_struct = fn field_count, name_item ->
      <<6::3, 24::5, 208::8>> <> list(field_count + 1) <> name_item <> <<0::3, 1::5>>
    end

    first = point_struct.(1, text("Point"))
    second = point_struct.(1, ref(0))

    envelope = "DX" <> <<1>> <> @tag_stringref_ns <> list(2) <> first <> second

    assert {:ok,
            [
              %Dextrin.Struct{name: "Point", fields: {:positional, [1]}},
              %Dextrin.Struct{name: "Point", fields: {:positional, [1]}}
            ]} = Dextrin.decode_binary(envelope)
  end

  test "regular encode_binary/decode_binary round-trips are untouched by this extension existing" do
    value = %{Dextrin.Keyword.new("a") => 1, Dextrin.Keyword.new("b") => 2}
    assert {:ok, encoded} = Dextrin.encode_binary(value)
    refute encoded =~ <<6::3, 25::5, 256::16>>
    assert {:ok, ^value} = Dextrin.decode_binary(encoded, trusted: false)
  end
end
