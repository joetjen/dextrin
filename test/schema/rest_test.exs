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
      assert takes?(r, "Tags", ~s|%{name: "a"}|)
    end

    # A key K does not take is no business of the entry (T674); `- *`
    # beside it refuses such a key, as a lone `* K => V` did until then.
    test "a key K does not take is kept, unless - * stands beside it" do
      assert takes?(registry(@rest), "Tags", ~s|%{name: "a", :x => 1}|)
      r = registry("%{T: %shape{name: :string * :string => :integer - *}}")
      refute takes?(r, "T", ~s|%{name: "a", :x => 1}|)
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

    # Until T674 (Jan, 2026-11-17) a body had one `* K => V` at most, and
    # not beside `- *`. JSON Schema's patternProperties needs several,
    # and additionalProperties: false beside them.
    test "beside entries, - * refuses only what no entry takes" do
      r =
        registry(
          "%{P: %shape{x: :integer * {:refine :string %{pattern: @regex \"^x-\"}} => :integer - *}}"
        )

      assert takes?(r, "P", ~s|%{x: 1, "x-a" => 2}|)
      refute takes?(r, "P", ~s|%{x: 1, "x-a" => "two"}|)
      refute takes?(r, "P", ~s|%{x: 1, "y" => 2}|)
    end
  end

  describe "several * K => V" do
    @several """
    %{
      P: %shape{
        * {:refine :string %{pattern: @regex "^a"}} => :integer
        * {:refine :string %{pattern: @regex "b$"}} => {:refine :integer %{min: 10}}
      }
    }
    """

    test "a key matches the V of every entry whose K takes it" do
      r = registry(@several)
      assert takes?(r, "P", ~s|%{"a" => 1, "b" => 10, "ab" => 12}|)
      refute takes?(r, "P", ~s|%{"ab" => 3}|)
      refute takes?(r, "P", ~s|%{"b" => 3}|)
    end

    test "a key no entry takes is kept, unless the body is closed or the decode strict" do
      r = registry(@several)
      assert takes?(r, "P", ~s|%{"zzz" => "anything"}|)

      {:ok, value} = Dextrin.decode(~s|%{"zzz" => 1}|)
      strict = %{r | strict: true}
      assert {:error, _} = Schema.check(value, strict, "P")

      {:ok, value} = Dextrin.decode(~s|%{"a" => 1}|)
      assert Schema.check(value, strict, "P") == :ok
    end

    test "a struct's extras follow the same rule" do
      r =
        registry(
          "%{C: %schema{n: :integer * {:refine :string %{pattern: @regex \"^x\"}} => :integer - *}}"
        )

      assert {:ok, _} = Dextrin.decode(~s|%C{n: 1, "xa" => 2}|, registry: r)

      assert category(Dextrin.decode(~s|%C{n: 1, "xa" => "s"}|, registry: r)) ==
               "schema/type-mismatch"

      assert category(Dextrin.decode(~s|%C{n: 1, "ya" => 2}|, registry: r)) ==
               "schema/undeclared-field"
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

    test "several entries are written back in their order" do
      text = "%{P: %shape{* :string => :any * :keyword => :integer - *}}"
      {:ok, doc} = Dextrin.decode(text)
      {:ok, printed} = Dextrin.encode(doc)
      assert printed =~ ~r/\* :string => :any.*\* :keyword => :integer/
      assert {:ok, ^doc} = Dextrin.decode(printed)
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
