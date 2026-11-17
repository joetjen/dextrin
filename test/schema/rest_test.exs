defmodule Dextrin.Schema.RestTest do
  @moduledoc """
  G1 of design/typespec.md (T673, Jan, 2026-11-17): typed extras and
  closed bodies, written `* K => V` and `- *` in a `%schema` or
  `%shape` body (DXNS.md §4b).
  """

  use ExUnit.Case, async: true

  alias Dextrin.Schema

  defp compiled(text, registry \\ Dextrin.Registry.new()) do
    with {:ok, doc} <- Dextrin.decode(text), do: Schema.compile(doc, registry)
  end

  defp registry(text) do
    {:ok, registry} = compiled(text)
    registry
  end

  defp compile_error(text) do
    {:error, %Dextrin.Error{category: "schema/compile", message: message}} = compiled(text)
    message
  end

  defp category({:error, %Dextrin.Error{category: category}}), do: category
  defp category(other), do: other

  defp takes?(registry, name, text) do
    {:ok, value} = Dextrin.decode(text)
    Schema.check(value, registry, name) == :ok
  end

  describe "G1: * K => V types the extras" do
    @rest """
    %{
      Tags: %shape{name: :string, * :string => :integer}
      Box: %schema{tags: Tags}
      Counts: %schema{total: :integer, * :string => :integer}
    }
    """

    test "an extra of a shape must match the rest" do
      r = registry(@rest)
      assert takes?(r, "Tags", ~s|%{name: "a", "x" => 1, "y" => 2}|)
      refute takes?(r, "Tags", ~s|%{name: "a", "x" => "one"}|)
      refute takes?(r, "Tags", ~s|%{name: "a", :x => 1}|)
      assert takes?(r, "Tags", ~s|%{name: "a"}|)
    end

    test "a declared field is no extra, whatever the rest says" do
      assert takes?(registry(@rest), "Tags", ~s|%{name: "a"}|)
    end

    test "a struct's extras match the rest, and a strict decode keeps them" do
      r = registry(@rest)
      assert {:ok, _} = Dextrin.decode(~s|%Counts{total: 1, "a" => 2}|, registry: r)

      assert category(Dextrin.decode(~s|%Counts{total: 1, "a" => "x"}|, registry: r)) ==
               "schema/type-mismatch"

      assert {:ok, _} = Dextrin.decode(~s|%Counts{total: 1, "a" => 2}|, registry: r, strict: true)
    end

    test "K and V may name the document's other types" do
      r =
        registry(
          "%{Count: {:refine :integer %{min: 0}}, T: %shape{a: :integer, * :string => Count}}"
        )

      assert takes?(r, "T", ~s|%{a: 1, "x" => 2}|)
      refute takes?(r, "T", ~s|%{a: 1, "x" => -2}|)
    end

    test "a refused extra says why" do
      r = registry(@rest)

      assert {:error, %Dextrin.Error{message: message}} =
               Dextrin.decode(~s|%Counts{total: 1, "a" => "x"}|, registry: r)

      assert message =~ ~s|"a"|
    end
  end

  describe "G1: - * refuses every extra" do
    @closed """
    %{
      Point: %shape{x: :integer, y: :integer - *}
      Pin: %schema{at: Point - *}
    }
    """

    test "a closed shape takes no extra" do
      r = registry(@closed)
      assert takes?(r, "Point", "%{x: 1, y: 2}")
      refute takes?(r, "Point", "%{x: 1, y: 2, z: 3}")
    end

    test "a closed schema refuses an extra even without a strict decode" do
      r = registry(@closed)
      assert {:ok, _} = Dextrin.decode("%Pin{at: %{x: 1, y: 2}}", registry: r)

      assert category(Dextrin.decode("%Pin{at: %{x: 1, y: 2}, note: 1}", registry: r)) ==
               "schema/undeclared-field"
    end

    test "- * does not go with * K => V" do
      assert compile_error("%{P: %shape{x: :integer - * * :string => :any}}") =~ "* K => V"
    end
  end

  describe "G1: written and read back" do
    test "both entries print as written, and read back the same" do
      text = "%{P: %shape{- * x: :integer}, Q: %schema{* :string => :integer, y: :string}}"
      {:ok, doc} = Dextrin.decode(text)
      {:ok, printed} = Dextrin.encode(doc)
      assert printed =~ "- *"
      assert printed =~ "* :string => :integer"
      assert {:ok, ^doc} = Dextrin.decode(printed)
    end

    test "only a %schema or a %shape takes them" do
      assert {:error, %Dextrin.Error{message: message}} = Dextrin.decode("%Foo{- *}")
      assert message =~ "%Foo"
      assert {:error, %Dextrin.Error{message: message}} = Dextrin.decode("%Foo{* :a => 1}")
      assert message =~ "%Foo"
    end

    test "a body takes one * K => V at most" do
      assert {:error, %Dextrin.Error{message: message}} =
               Dextrin.decode("%shape{* :string => :any * :keyword => :any}")

      assert message =~ "once"
    end
  end

  describe "G1: built from others" do
    test "the rest and closed are inherited, and the body's own replace them" do
      r =
        registry("""
        %{
          Base: %shape{a: :integer, * :string => :integer}
          Kept: %shape includes Base {b: :integer}
          Mine: %shape includes Base {b: :integer, * :string => :string}
        }
        """)

      refute takes?(r, "Kept", ~s|%{a: 1, b: 2, "x" => "s"}|)
      assert takes?(r, "Mine", ~s|%{a: 1, b: 2, "x" => "s"}|)
    end

    test "two bases whose rest differs are a compile error, unless the body settles it" do
      assert compile_error("""
             %{
               A: %shape{a: :integer, * :string => :integer}
               B: %shape{b: :integer - *}
               C: %shape includes A B {}
             }
             """) =~ "extras"

      assert {:ok, _} =
               compiled("""
               %{
                 A: %shape{a: :integer, * :string => :integer}
                 B: %shape{b: :integer - *}
                 C: %shape includes A B {- *}
               }
               """)
    end

    test "extending a closed base with a field of its own is a compile error" do
      assert compile_error("""
             %{
               A: %schema{a: :integer - *}
               B: %schema extends A {b: :integer}
             }
             """) =~ "closed"
    end
  end

  test "- * stands once in a body" do
    assert {:error, %Dextrin.Error{message: message}} =
             Dextrin.decode("%{P: %shape{x: :integer - * - *}}")

    assert message =~ "once"
  end
end
