defmodule Dextrin.Text.EscapesTest do
  @moduledoc """
  Direct unit tests for `Dextrin.Text.Escapes` — every escape sequence
  `DXN.md` §1.1's `escape` production defines, plus the error paths for
  a malformed `\\x{...}` and an otherwise-unrecognized escape.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Text.Escapes

  describe "decode/1 — whole-body decoding" do
    test "a body with no escapes at all passes through unchanged" do
      assert Escapes.decode("hello, world") == {:ok, "hello, world"}
    end

    test "the empty body decodes to the empty string" do
      assert Escapes.decode("") == {:ok, ""}
    end

    test "decodes every standalone escape letter" do
      assert Escapes.decode(~S(\")) == {:ok, "\""}
      assert Escapes.decode(~S(\\)) == {:ok, "\\"}
      assert Escapes.decode(~S(\n)) == {:ok, "\n"}
      assert Escapes.decode(~S(\t)) == {:ok, "\t"}
      assert Escapes.decode(~S(\r)) == {:ok, "\r"}
      assert Escapes.decode(~S(\0)) == {:ok, <<0>>}
      assert Escapes.decode(~S(\a)) == {:ok, <<7>>}
      assert Escapes.decode(~S(\b)) == {:ok, <<8>>}
      assert Escapes.decode(~S(\f)) == {:ok, <<12>>}
      assert Escapes.decode(~S(\v)) == {:ok, <<11>>}
    end

    test "decodes a \\x{...} hex escape to its Unicode codepoint" do
      assert Escapes.decode(~S(\x{41})) == {:ok, "A"}
      assert Escapes.decode(~S(\x{1F600})) == {:ok, <<0x1F600::utf8>>}
    end

    test "mixes plain text and multiple escapes in one body" do
      assert Escapes.decode(~S(line1\nline2\ttabbed)) == {:ok, "line1\nline2\ttabbed"}
    end

    test "handles multi-byte UTF-8 characters outside of any escape" do
      assert Escapes.decode("héllo 日本語") == {:ok, "héllo 日本語"}
    end

    test "propagates a malformed \\x{...} escape as an error" do
      assert {:error, _reason} = Escapes.decode(~S(\x{}))
      assert {:error, _reason} = Escapes.decode(~S(\x{zz}))
      assert {:error, _reason} = Escapes.decode(~S(\x{41))
    end

    test "propagates an unrecognized escape letter as an error" do
      assert {:error, _reason} = Escapes.decode(~S(\q))
    end
  end

  describe "decode_escape/1 — one escape at a time" do
    test "returns the decoded character and the leftover text after it" do
      assert Escapes.decode_escape("n rest") == {:ok, "\n", " rest"}
    end

    test "\\x{...} consumes exactly through the closing brace" do
      assert Escapes.decode_escape("x{41}rest") == {:ok, "A", "rest"}
    end

    test "an empty \\x{} is invalid (at least one hex digit required)" do
      assert Escapes.decode_escape("x{}") == {:error, "invalid \\x{...} escape"}
    end

    test "a \\x{...} with a non-hex character inside is invalid" do
      assert Escapes.decode_escape("x{4g}") == {:error, "invalid \\x{...} escape"}
    end

    test "a \\x{...} missing its closing brace is invalid" do
      assert Escapes.decode_escape("x{41") == {:error, "invalid \\x{...} escape"}
    end

    test "any other letter is an unrecognized escape" do
      assert Escapes.decode_escape("q") == {:error, "unrecognized escape sequence"}
    end

    test "an empty string (backslash at the very end of input) is unrecognized" do
      assert Escapes.decode_escape("") == {:error, "unrecognized escape sequence"}
    end
  end
end
