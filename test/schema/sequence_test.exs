defmodule Dextrin.Schema.SequenceTest do
  @moduledoc """
  Lists and sequences, the superset's group 4 (design/schema-superset.md,
  Jan, 2026-10-20): a list's items in order (`{:list-items ...}` with
  `{:repeat ...}` and `{:group ...}`), a tuple of any length
  (`{:tuple-of-all T}`), and the refine keys `contains`, `min-contains`,
  `max-contains`, `unique` and `unique-by`.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Schema

  defp compiled(type) do
    {:ok, doc} = Dextrin.decode("%{T: #{type}}")
    Schema.compile(doc)
  end

  # Whether the value written `text` is a `type`.
  defp takes?(type, text) do
    {:ok, registry} = compiled(type)
    {:ok, value} = Dextrin.decode(text)
    Schema.check(value, registry, "T") == :ok
  end

  defp compile_error(type) do
    {:error, %Dextrin.Error{category: "schema/compile", message: message}} = compiled(type)
    message
  end

  describe "{:list-items ...}" do
    test "a type stands for exactly one item, in order" do
      type = "{:list-items :string :integer}"
      assert takes?(type, ~s|["a" 1]|)
      refute takes?(type, ~s|[1 "a"]|)
      refute takes?(type, ~s|["a"]|)
      refute takes?(type, ~s|["a" 1 2]|)
      refute takes?(type, ~s|{"a" 1}|)
    end

    test "a repeat takes between min and max items, nil for no upper bound" do
      head_and_tail = "{:list-items :string {:repeat :integer 0 nil}}"
      assert takes?(head_and_tail, ~s|["a"]|)
      assert takes?(head_and_tail, ~s|["a" 1 2 3]|)
      refute takes?(head_and_tail, ~s|["a" 1 "b"]|)

      two_or_three = "{:list-items {:repeat :integer 2 3}}"
      refute takes?(two_or_three, "[1]")
      assert takes?(two_or_three, "[1 2]")
      assert takes?(two_or_three, "[1 2 3]")
      refute takes?(two_or_three, "[1 2 3 4]")
    end

    test "a group repeats several items together" do
      pairs = "{:list-items {:repeat {:group :string :integer} 1 nil}}"
      assert takes?(pairs, ~s|["a" 1 "b" 2]|)
      refute takes?(pairs, ~s|["a" 1 "b"]|)
      refute takes?(pairs, "[]")
    end

    test "a repeat gives back items the rest needs" do
      type = "{:list-items {:repeat :any 0 nil} :string}"
      assert takes?(type, ~s|[1 2 "end"]|)
      refute takes?(type, "[1 2 3]")
    end

    test "a group that can match nothing still ends" do
      type = "{:list-items {:repeat {:group {:repeat :integer 0 nil}} 2 nil}}"
      assert takes?(type, "[]")
      assert takes?(type, "[1 2]")
    end

    test "a shape's defaults are filled in the items it matched" do
      {:ok, doc} =
        Dextrin.decode("""
        %{
          T: {:list-items Line {:repeat Line 0 nil}}
          Line: %shape{sku: :string, qty: %field{type: :integer, default: 1}}
        }
        """)

      {:ok, registry} = Schema.compile(doc)
      {:ok, value} = Dextrin.decode(~s|[%{sku: "a"} %{sku: "b", qty: 2}]|)
      assert {:ok, [first, second]} = Schema.conform(value, registry, "T")
      assert Map.values(first) |> Enum.sort() == [1, "a"] |> Enum.sort()
      assert Map.values(second) |> Enum.sort() == [2, "b"] |> Enum.sort()
    end

    test "a repeat or a group stands only where items are counted" do
      assert compile_error("{:repeat :integer 0 nil}") =~ "repeat"
      assert compile_error("{:list-items {:group :integer :string}}") =~ "group"
      assert compile_error("{:list-items {:repeat :integer 3 2}}") =~ "repeat"
      assert compile_error("{:list-items {:repeat :integer -1 nil}}") =~ "repeat"
    end

    test "it guards a named type's recursion, as list-of does" do
      assert {:ok, _} = compiled("{:list-items :string {:repeat T 0 nil}}")
    end
  end

  describe "{:tuple-of-all T}" do
    test "a tuple of any length, every item a T" do
      assert takes?("{:tuple-of-all :integer}", "{}")
      assert takes?("{:tuple-of-all :integer}", "{1 2 3}")
      refute takes?("{:tuple-of-all :integer}", ~s|{1 "a"}|)
      refute takes?("{:tuple-of-all :integer}", "[1 2]")
    end
  end

  describe "contains" do
    test "at least one item is a T" do
      type = "{:refine {:list-of :any} %{contains: :string}}"
      assert takes?(type, ~s|[1 "a"]|)
      refute takes?(type, "[1 2]")
      refute takes?(type, "[]")
    end

    test "min-contains and max-contains count the items that are" do
      type = "{:refine {:list-of :any} %{contains: :string, min-contains: 2, max-contains: 3}}"
      refute takes?(type, ~s|[1 "a"]|)
      assert takes?(type, ~s|["a" 1 "b"]|)
      assert takes?(type, ~s|["a" "b" "c"]|)
      refute takes?(type, ~s|["a" "b" "c" "d"]|)
      assert takes?("{:refine {:list-of :any} %{contains: :string, min-contains: 0}}", "[1]")
    end

    test "is checked on sets, tuples, sorted sets and arrays too" do
      assert takes?("{:refine {:set-of :any} %{contains: :string}}", ~s|@{1 "a"}|)
      assert takes?("{:refine {:tuple-of-all :any} %{contains: :string}}", ~s|{1 "a"}|)
      assert takes?("{:refine {:array-of :any} %{contains: :string}}", ~s|@array[1 "a"]|)
    end

    test "min-contains or max-contains without contains is refused" do
      assert compile_error("{:refine {:list-of :any} %{min-contains: 1}}") =~ "contains"
      assert compile_error("{:refine {:list-of :any} %{max-contains: 1}}") =~ "contains"
    end
  end

  describe "unique" do
    test "no two items are the same value" do
      assert takes?("{:refine {:list-of :any} %{unique: true}}", "[1 2 3]")
      refute takes?("{:refine {:list-of :any} %{unique: true}}", "[1 2 1]")
      assert takes?("{:refine {:list-of :any} %{unique: false}}", "[1 1]")
      refute takes?("{:refine {:array-of :any} %{unique: true}}", "@array[1 1]")
    end

    test "values are the same when their canonical forms are: 1 and 1.0 differ" do
      assert takes?("{:refine {:list-of :any} %{unique: true}}", "[1 1.0]")
      assert takes?("{:refine {:list-of :any} %{unique: true}}", ~s|[%{a: 1} %{"a" => 1}]|)
    end

    test "unique-by: no two items share that field's value" do
      type = "{:refine {:list-of :any} %{unique-by: :id}}"
      assert takes?(type, ~s|[%{id: 1} %{id: 2}]|)
      refute takes?(type, ~s|[%{id: 1} %{"id" => 1}]|)
      assert takes?(type, ~s|[%{id: 1} %{name: "no id"} %{name: "none either"}]|)
    end
  end

  describe "in a generic" do
    test "a parameter stands in list items and in contains alike" do
      {:ok, doc} =
        Dextrin.decode("""
        %{
          NonEmpty: {:generic [t] {:list-items t {:repeat t 0 nil}}}
          Tagged: {:generic [t] {:refine {:list-of :any} %{contains: t}}}
          T: %schema{names: {:of NonEmpty :string}, tags: {:of Tagged :integer}}
        }
        """)

      {:ok, registry} = Schema.compile(doc)
      assert {:ok, _} = Dextrin.decode(~s|%T{names: ["a"], tags: ["x" 1]}|, registry: registry)
      assert {:error, _} = Dextrin.decode(~s|%T{names: [], tags: ["x" 1]}|, registry: registry)
      assert {:error, _} = Dextrin.decode(~s|%T{names: ["a"], tags: ["x"]}|, registry: registry)
    end
  end

  describe "refine keys" do
    test "min-count and max-count count an array's items too" do
      assert takes?("{:refine {:array-of :any} %{min-count: 2}}", "@array[1 2]")
      refute takes?("{:refine {:array-of :any} %{max-count: 1}}", "@array[1 2]")
    end

    test "an unknown key is refused when the schema compiles" do
      assert compile_error("{:refine :string %{min-lenght: 1}}") =~ "min-lenght"
    end
  end
end
