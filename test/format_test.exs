defmodule Dextrin.FormatTest do
  @moduledoc """
  `Dextrin.Format` (DXN.md §6): the media types and extensions of the
  three forms, which form a media type names, and a cheap test of whether
  a body is worth decoding as a form -- ASCO's proposal
  (`design/network-safety-and-media-types.md`), the text rule as Jan set
  it on 2026-10-20.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Format

  doctest Dextrin.Format

  describe "names" do
    test "each form has a media type and an extension" do
      assert Format.media_type(:text) == "application/vnd.dxn"
      assert Format.media_type(:binary) == "application/vnd.dxnb"
      assert Format.media_type(:schema) == "application/vnd.dxns"
      assert Format.extension(:text) == ".dxn"
      assert Format.extension(:binary) == ".dxnb"
      assert Format.extension(:schema) == ".dxns"
    end

    test "a media type names its form, a +dxn suffix text, in any case" do
      assert Format.form("application/vnd.dxn") == {:ok, :text}
      assert Format.form("application/vnd.dxnb") == {:ok, :binary}
      assert Format.form("application/vnd.dxns") == {:ok, :schema}
      assert Format.form("application/vnd.acme.event+dxn") == {:ok, :text}
      assert Format.form("Application/VND.DXN") == {:ok, :text}
    end

    test "and nothing else does: no +dxnb suffix, no parameters" do
      assert Format.form("application/json") == :error
      assert Format.form("application/vnd.acme.event+dxnb") == :error
      assert Format.form("application/vnd.dxn; charset=utf-8") == :error
      assert Format.form("") == :error
    end
  end

  describe "identifies?/2 for text and schemas: the first significant character is %" do
    test "a map, a struct, a schema, a tuple-ish %(" do
      for body <- [
            "%{a: 1}",
            "%Point{x: 1}",
            "%ns/Name{x: 1}",
            "%{P: %schema{x: :integer}}",
            "%(1)"
          ] do
        assert Format.identifies?(body, :text), body
        assert Format.identifies?(body, :schema), body
      end
    end

    test "after whitespace, commas, comments and a header" do
      body = "\n  , # a comment\n# another\n@dxn \"1.1\"  # the version\n\n%{a: 1}"
      assert Format.identifies?(body, :text)
    end

    test "a list or a scalar is left unrecognised on purpose: they overlap with JSON" do
      for body <- [
            "[1 2]",
            "\"a\"",
            "1",
            ":a",
            "{1 2}",
            "@array[1]",
            "true",
            "",
            "# only a comment"
          ] do
        refute Format.identifies?(body, :text), body
      end
    end

    test "nor is JSON" do
      refute Format.identifies?(~s|{"a": 1}|, :text)
    end
  end

  describe "identifies?/2 for binary: the envelope's magic and a version byte" do
    test "DX and a version byte" do
      {:ok, bytes} = Dextrin.encode_binary(%{"a" => 1})
      assert Format.identifies?(bytes, :binary)
      assert Format.identifies?(<<"DX", 1>>, :binary)
    end

    test "nothing shorter, nothing else" do
      refute Format.identifies?("DX", :binary)
      refute Format.identifies?("%{a: 1}", :binary)
      refute Format.identifies?(<<>>, :binary)
    end
  end
end
