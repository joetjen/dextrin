defmodule Dextrin.Text.NamesTest do
  @moduledoc """
  Names (DXN.md §1.1): segments joined by `.`, with at most one `/`
  between a namespace and a name -- `Foo.Bar/Baz`, `acme.billing/invoice`
  -- wherever a name stands: a struct, a symbol, a keyword, a map key.
  The namespace is everything before the `/`, dots and all (Jan,
  2026-10-19).
  """

  use ExUnit.Case, async: true

  alias Dextrin.{Struct, Symbol}

  defp category({:error, %Dextrin.Error{category: category}}), do: category

  test "a struct's name may be dotted and namespaced" do
    assert {:ok, %Struct{name: "Foo.Bar/Baz"}} = Dextrin.decode("%Foo.Bar/Baz{a: 1}")

    assert {:ok, %Struct{name: "Foo.Bar.Baz", version: 2}} =
             Dextrin.decode("%Foo.Bar.Baz(2){a: 1}")
  end

  test "and so may a symbol, a keyword and a map key" do
    assert Dextrin.decode("a.b.c") == {:ok, Symbol.new("a.b.c")}

    assert Dextrin.decode(":acme.billing/invoice") ==
             {:ok, Dextrin.Keyword.new("acme.billing/invoice")}

    assert Dextrin.decode(":acme.billing/invoice", trusted: true) ==
             {:ok, :"acme.billing/invoice"}

    assert {:ok, %{%Dextrin.Keyword{name: "a.b"} => 1}} = Dextrin.decode("%{a.b: 1}")
  end

  test "each is written back as it was" do
    for text <- ["%Foo.Bar/Baz{a: 1}", "a.b.c", ":acme.billing/invoice", "%{a.b: 1}"] do
      {:ok, value} = Dextrin.decode(text)
      {:ok, written} = Dextrin.encode(value)
      assert Dextrin.decode(written) == {:ok, value}, text
    end

    assert Dextrin.encode(Symbol.new("Foo.Bar/Baz")) == {:ok, "Foo.Bar/Baz"}
  end

  test "a name has at most one slash, and no empty segment" do
    for text <- ["Foo/Bar/Baz", "Foo.", ".Foo", "Foo..Bar", "Foo./Bar", "Foo/.Bar"] do
      assert category(Dextrin.decode(text)) == "syntax", text
    end
  end
end
