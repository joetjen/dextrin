defmodule Dextrin.BitsTest do
  @moduledoc """
  `bits` (DXN.md §1.3, §1.4, §2.3): a run of bits that is not whole
  bytes -- `@bits {"oA==" 3}` in text, `T_BITS` (216) around
  `[bytes, count]` in `.dxnb`. Bits and bytes are one value space: a
  whole number of bytes is bytes. An Elixir bitstring is the value; a
  `Dextrin.Bytes` holds it like any bytes.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Bytes

  doctest Dextrin.Bits

  defp category({:error, %Dextrin.Error{category: category}}), do: category

  describe "text" do
    test "reads a run of bits, from the high bit of the first byte" do
      assert Dextrin.decode(~s|@bits {"oA==" 3}|) == {:ok, Bytes.new(<<5::3>>)}
    end

    test "a whole number of bytes is bytes" do
      assert Dextrin.decode(~s|@bits {"AQID" 24}|) == {:ok, Bytes.new(<<1, 2, 3>>)}
    end

    test "the unused low bits of the last byte are ignored" do
      assert Dextrin.decode(~s|@bits {"pw==" 3}|) == {:ok, Bytes.new(<<5::3>>)}
    end

    test "a count the data does not match is refused" do
      assert category(Dextrin.decode(~s|@bits {"oA==" 9}|)) == "syntax"
      assert category(Dextrin.decode(~s|@bits {"AAA=" 3}|)) == "syntax"
      assert category(Dextrin.decode(~s|@bits {"oA==" -1}|)) == "syntax"
      assert category(Dextrin.decode(~s|@bits "oA=="|)) == "syntax"
    end

    test "is written with the count, the unused bits zero" do
      assert Dextrin.encode(Bytes.new(<<5::3>>)) == {:ok, ~s|@bits {"oA==" 3}|}
      assert Dextrin.encode(Bytes.new(<<5::3>>), pretty: true) == {:ok, ~s|@bits {"oA==" 3}|}
    end

    test "a bare bitstring is bits too: it can be no string" do
      assert Dextrin.encode(<<5::3>>) == {:ok, ~s|@bits {"oA==" 3}|}
    end

    test "and whole bytes are written as bytes" do
      assert Dextrin.encode(Bytes.new(<<1, 2, 3>>)) == {:ok, ~s|@bytes "AQID"|}
    end

    test "the canonical form is the same" do
      assert Dextrin.Canonical.print(Bytes.new(<<5::3>>)) == {:ok, ~s|@bits {"oA==" 3}|}
    end
  end

  describe ".dxnb" do
    test "is T_BITS around the bytes and the count" do
      assert Dextrin.encode_binary(Bytes.new(<<5::3>>)) ==
               {:ok, Base.decode16!("445801D8D88241A003")}
    end

    test "and reads back" do
      {:ok, bytes} = Dextrin.encode_binary(Bytes.new(<<1, 5::3>>))
      assert Dextrin.decode_binary(bytes) == {:ok, Bytes.new(<<1, 5::3>>)}
    end

    test "a count its bytes do not match is malformed" do
      assert category(Dextrin.decode_binary(Base.decode16!("445801D8D88241A009"))) == "binary"
      assert category(Dextrin.decode_binary(Base.decode16!("445801D8D86161"))) == "binary"
    end
  end

  test "bits that are not whole bytes are no map key" do
    assert category(Dextrin.decode(~s|%{@bits {"oA==" 3} => 1}|)) == "key/not-allowed"
  end

  describe "a schema" do
    defp registry(type) do
      {:ok, doc} = Dextrin.decode("%{S: %schema{b: #{type}}}")
      {:ok, registry} = Dextrin.Schema.compile(doc)
      registry
    end

    test ":bits takes bits and bytes alike" do
      assert {:ok, _} = Dextrin.decode(~s|%S{b: @bits {"oA==" 3}}|, registry: registry(":bits"))
      assert {:ok, _} = Dextrin.decode(~s|%S{b: @bytes "AQ=="}|, registry: registry(":bits"))
    end

    test ":bytes takes only whole bytes" do
      result = Dextrin.decode(~s|%S{b: @bits {"oA==" 3}}|, registry: registry(":bytes"))
      assert category(result) == "schema/type-mismatch"
    end
  end
end
