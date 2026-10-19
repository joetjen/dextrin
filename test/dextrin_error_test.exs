defmodule Dextrin.ErrorTest do
  @moduledoc """
  Direct unit tests for `Dextrin.Error`'s constructors and `format/1`'s
  three branches (wrapped `Ichor.Error`, a binary error with a byte
  offset, and one without).
  """

  use ExUnit.Case, async: true

  describe "constructors" do
    test "from_ichor/1 carries the message/stage through and keeps the original error" do
      ichor_error = Ichor.Error.new(message: "boom", stage: :parser)
      error = Dextrin.Error.from_ichor(ichor_error)

      assert %Dextrin.Error{message: "boom", stage: :parser, ichor_error: ^ichor_error} = error
    end

    test "binary/2 defaults byte_offset to nil" do
      assert Dextrin.Error.binary("bad bytes") == %Dextrin.Error{
               message: "bad bytes",
               stage: :binary,
               category: "binary",
               byte_offset: nil
             }
    end

    test "binary/2 accepts an explicit byte offset" do
      assert Dextrin.Error.binary("bad bytes", 42) == %Dextrin.Error{
               message: "bad bytes",
               stage: :binary,
               category: "binary",
               byte_offset: 42
             }
    end

    test "action/1 builds a stage: :action error with no byte offset" do
      assert Dextrin.Error.action("schema violation") == %Dextrin.Error{
               message: "schema violation",
               stage: :action
             }
    end
  end

  describe "categories (DXN.md §5)" do
    test "an error from the text grammar is a syntax error" do
      error = Dextrin.Error.from_ichor(Ichor.Error.new(message: "boom", stage: :parser))
      assert error.category == "syntax"
    end

    test "a binary error is a binary error" do
      assert Dextrin.Error.binary("bad bytes").category == "binary"
    end

    test "action/2 takes its category explicitly" do
      assert Dextrin.Error.action("no DXN meaning", "encode/unsupported").category ==
               "encode/unsupported"
    end

    test "action/1 leaves it unassigned, which no conformance case ever expects" do
      assert Dextrin.Error.action("schema violation").category == nil
    end

    test "decoding text that does not parse answers a syntax error" do
      assert {:error, %Dextrin.Error{category: "syntax"}} = Dextrin.decode("[1 2")
    end

    test "decoding bytes without the magic answers a binary error" do
      assert {:error, %Dextrin.Error{category: "binary"}} = Dextrin.decode_binary(<<0x18, 0x2A>>)
    end

    test "encoding a value with no DXN meaning answers an encode error" do
      assert {:error, %Dextrin.Error{category: "encode/unsupported"}} = Dextrin.encode(self())
    end
  end

  describe "format/1" do
    test "delegates to Ichor.Error.format/1 when an ichor_error is present" do
      ichor_error = Ichor.Error.new(message: "syntax error", stage: :parser)
      error = Dextrin.Error.from_ichor(ichor_error)

      assert Dextrin.Error.format(error) == Ichor.Error.format(ichor_error)
    end

    test "a binary error with no offset formats as just the message" do
      assert Dextrin.Error.format(Dextrin.Error.binary("bad bytes")) == "bad bytes"
    end

    test "a binary error with an offset appends it" do
      assert Dextrin.Error.format(Dextrin.Error.binary("bad bytes", 7)) ==
               "bad bytes (at byte offset 7)"
    end

    test "an action error (no ichor_error, no offset) formats as just the message" do
      assert Dextrin.Error.format(Dextrin.Error.action("schema violation")) == "schema violation"
    end
  end
end
