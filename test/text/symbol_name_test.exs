defmodule Dextrin.Text.SymbolNameTest do
  @moduledoc """
  A symbol is an identifier (DXN.md §1.1), so text can only write one
  whose name is an identifier. Any other name has no text form, and
  writing it verbatim would answer text that reads back as something
  else, or as nothing: the symbol `""` came out as an empty document,
  `"{"` as the start of a tuple. It is refused instead, as
  `encode/unsupported`. `.dxnb` keeps any name, its tag holding text.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Symbol

  defp category({:error, %Dextrin.Error{category: category}}), do: category

  test "a symbol named by an identifier is written as it is" do
    assert Dextrin.encode(Symbol.new("ok")) == {:ok, "ok"}
    assert Dextrin.encode(Symbol.new("my-app/money")) == {:ok, "my-app/money"}
  end

  test "any other name has no text form, and is refused" do
    for name <- ["", "{", "a b", "1x", "nil", "x:"] do
      assert category(Dextrin.encode(Symbol.new(name))) == "encode/unsupported", name

      assert category(Dextrin.encode(Symbol.new(name), pretty: true)) == "encode/unsupported",
             name

      assert category(Dextrin.Canonical.print(Symbol.new(name))) == "encode/unsupported", name
    end
  end

  test "and so is one inside another value" do
    assert category(Dextrin.encode([1, Symbol.new("")])) == "encode/unsupported"
  end

  test "binary keeps any name" do
    {:ok, bytes} = Dextrin.encode_binary(Symbol.new("a b"))
    assert Dextrin.decode_binary(bytes) == {:ok, Symbol.new("a b")}
  end
end
