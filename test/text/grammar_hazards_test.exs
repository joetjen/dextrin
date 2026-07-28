defmodule Dextrin.Text.GrammarHazardsTest do
  @moduledoc """
  Regression tests for the two lexer hazards found and resolved while
  writing `priv/grammar/dxn.aether` (see the `MAP_KEY`/`AT_DISCARD`
  comments there) — exactly the two places a future grammar edit is
  most likely to silently reintroduce ambiguity.
  """

  use ExUnit.Case, async: true

  describe "§5.5 — MAP_KEY vs KEYWORD" do
    test "no space before colon is a shorthand map key" do
      assert {:ok, %{x: 1}} = normalize(Dextrin.decode("%{x:1}"))
    end

    test "space after colon is still a shorthand map key" do
      assert {:ok, %{x: 1}} = normalize(Dextrin.decode("%{x: 1}"))
    end

    test "space before colon is NOT a valid shorthand key (documented restriction)" do
      assert {:error, %Dextrin.Error{}} = Dextrin.decode("%{x : 1}")
    end

    defp normalize({:ok, map}) do
      {:ok, Map.new(map, fn {%Dextrin.Keyword{name: name}, v} -> {String.to_atom(name), v} end)}
    end

    defp normalize(other), do: other
  end

  describe "§5.6 — AT_DISCARD vs a custom tag" do
    test "@_ followed directly by a value is always discard, never a tag named \"_...\"" do
      assert {:ok, 2} = Dextrin.decode("@_ 1 2")
    end

    test "@_foo is discard-of-symbol-foo, never a custom tag literally named \"_foo\"" do
      assert {:ok, %Dextrin.Symbol{name: "next"}} = Dextrin.decode("@_foo next")
    end

    test "a custom tag can be named without a leading underscore" do
      assert {:ok, %Dextrin.CustomTag{name: "foo", value: 1}} = Dextrin.decode("@foo 1")
    end
  end

  describe "malformed input never raises, always {:error, ...}" do
    test "unterminated string" do
      assert {:error, %Dextrin.Error{}} = Dextrin.decode(~s("unterminated))
    end

    test "unbalanced brackets" do
      assert {:error, %Dextrin.Error{}} = Dextrin.decode("[1, 2")
    end

    test "rational with zero denominator" do
      assert {:error, %Dextrin.Error{}} = Dextrin.decode("1/0")
    end

    test "invalid uuid" do
      assert {:error, %Dextrin.Error{}} = Dextrin.decode(~s(@uuid "not-a-uuid"))
    end

    test "invalid base64 in @bytes" do
      assert {:error, %Dextrin.Error{}} = Dextrin.decode(~s(@bytes "not base64!!"))
    end

    test "truncated .dxnb (envelope present, item cut short)" do
      {:ok, full} = Dextrin.encode_binary([1, 2, 3])
      truncated = binary_part(full, 0, byte_size(full) - 1)
      assert {:error, %Dextrin.Error{}} = Dextrin.decode_binary(truncated)
    end

    test "missing .dxnb envelope entirely" do
      assert {:error, %Dextrin.Error{}} = Dextrin.decode_binary(<<1, 2, 3>>)
    end

    test "out-of-range CBOR tag" do
      # tag 999 wrapping a plain integer 1 — no such tag is recognized.
      item = <<6::3, 25::5, 999::16, 0::3, 1::5>>
      assert {:error, %Dextrin.Error{}} = Dextrin.decode_binary("DX" <> <<1>> <> item)
    end

    test "invalid UTF-8 inside a string/symbol major-3 item" do
      # major 3 (text), length 2, two bytes that aren't valid UTF-8.
      bad_utf8 = <<3::3, 2::5, 0xFF, 0xFE>>
      assert {:error, %Dextrin.Error{}} = Dextrin.decode_binary("DX" <> <<1>> <> bad_utf8)
    end

    test "a cyclic tag-28/29 reference is a decode error, not a hang" do
      # tag 28 (mark shareable) immediately wrapping a tag-29 (reference)
      # pointing at index 0 — the item currently being marked as index 0
      # referring to itself before it's ever finished being seen.
      cyclic = <<6::3, 24::5, 28::8>> <> <<6::3, 24::5, 29::8>> <> <<0::3, 0::5>>
      assert {:error, %Dextrin.Error{}} = Dextrin.decode_binary("DX" <> <<1>> <> cyclic)
    end
  end

  describe "Unicode identifiers (§5.2's generated XID_Start/XID_Continue ranges)" do
    test "non-ASCII symbols decode correctly across scripts" do
      for {text, expected_name} <- [
            {"café", "café"},
            {"Ω", "Ω"},
            {"变量", "变量"},
            {"переменная", "переменная"},
            {"naïve_bayes", "naïve_bayes"}
          ] do
        assert {:ok, %Dextrin.Symbol{name: ^expected_name}} = Dextrin.decode(text)
      end
    end

    test "namespaced identifiers work with non-ASCII on both sides of the slash" do
      assert {:ok, %Dextrin.Symbol{name: "日本語/変数"}} = Dextrin.decode("日本語/変数")
    end

    test "a second slash is rejected — the grammar allows exactly one namespace segment" do
      assert {:error, %Dextrin.Error{}} = Dextrin.decode("a/b/c")
    end
  end
end
