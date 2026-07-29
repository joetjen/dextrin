defmodule Dextrin.Text.FormatterTest do
  @moduledoc """
  Direct unit tests for `Dextrin.Text.Formatter.pretty/2` — every
  collection type's multi-line rendering, both empty (a one-liner, no
  indentation needed) and non-empty (indented, recursively), plus the
  scalar/error fallback onto `Dextrin.Text.Printer`.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Text.Formatter
  alias Dextrin.{Array, Keyword, OrderedMap, SortedSet, Struct, Tuple}

  defmodule UnknownStruct do
    @moduledoc false
    defstruct [:a]
  end

  defmodule NestedStruct do
    @moduledoc false
    defstruct [:a]
  end

  describe "empty collections render as a single-line form" do
    test "empty list falls through to the printer's own [] " do
      assert Formatter.pretty([]) == "[]"
    end

    test "empty tuple, set, sorted-set, array, ordered-map, and map" do
      assert Formatter.pretty(Tuple.new([])) == "{}"
      assert Formatter.pretty(MapSet.new([])) == "@{}"
      assert Formatter.pretty(SortedSet.new([])) == "@sorted-set @{}"
      assert Formatter.pretty(Array.new([])) == "@array[]"
      assert Formatter.pretty(OrderedMap.new([])) == "@ordered %{}"
      assert Formatter.pretty(%{}) == "%{}"
    end
  end

  describe "non-empty collections render multi-line, indented" do
    test "list" do
      assert Formatter.pretty([1, 2, 3]) == "[\n  1\n  2\n  3\n]"
    end

    test "tuple" do
      assert Formatter.pretty(Tuple.new([1, "a"])) == "{\n  1\n  \"a\"\n}"
    end

    test "set" do
      assert Formatter.pretty(MapSet.new([1])) == "@{\n  1\n}"
    end

    test "sorted-set, always in sorted order regardless of construction order" do
      assert Formatter.pretty(SortedSet.new([3, 1, 2])) == "@sorted-set @{\n  1\n  2\n  3\n}"
    end

    test "array" do
      assert Formatter.pretty(Array.new([1, 2])) == "@array[\n  1\n  2\n]"
    end

    test "ordered-map, keyword-shorthand keys" do
      om = OrderedMap.new([{Keyword.new("b"), 2}, {Keyword.new("a"), 1}])
      assert Formatter.pretty(om) == "@ordered %{\n  b: 2\n  a: 1\n}"
    end

    test "a plain map with keyword-shorthand keys" do
      assert Formatter.pretty(%{Keyword.new("x") => 1}) == "%{\n  x: 1\n}"
    end

    test "a plain map with a non-keyword key uses the arrow form" do
      assert Formatter.pretty(%{1 => "one"}) == "%{\n  1 => \"one\"\n}"
    end

    test "a keyed struct" do
      s = Struct.keyed("Point", [{"x", 1}, {"y", 2}])
      assert Formatter.pretty(s) == "%Point{\n  x: 1\n  y: 2\n}"
    end

    test "a positional struct" do
      s = Struct.positional("Point", [1, 2])
      assert Formatter.pretty(s) == "%Point[\n  1\n  2\n]"
    end
  end

  describe "nesting increases indentation at each level" do
    test "a list of maps" do
      assert Formatter.pretty([%{Keyword.new("a") => 1}]) == "[\n  %{\n    a: 1\n  }\n]"
    end

    test "a map whose value is a list" do
      assert Formatter.pretty(%{Keyword.new("xs") => [1, 2]}) ==
               "%{\n  xs: [\n    1\n    2\n  ]\n}"
    end
  end

  describe "scalars and errors fall back to Dextrin.Text.Printer" do
    test "scalars print exactly as Printer.print/2 would, single-line" do
      assert Formatter.pretty(42) == "42"
      assert Formatter.pretty("hi") == "\"hi\""
      assert Formatter.pretty(nil) == "nil"
    end

    test "an unencodable value raises ArgumentError with the formatted Dextrin.Error message" do
      assert_raise ArgumentError, ~r/cannot encode value with no DXN representation/, fn ->
        Formatter.pretty(%UnknownStruct{a: 1})
      end
    end
  end

  describe "opts (e.g. registry) thread through recursively" do
    test "a registered struct nested inside a list is still resolved via the registry" do
      {:ok, doc} = Dextrin.decode("%{ Thing: %schema{ fields: @ordered %{ a: :integer } } }")
      {:ok, registry} = Dextrin.Schema.compile(doc)
      registry = Dextrin.Registry.put_struct_module(registry, "Thing", NestedStruct)

      assert Formatter.pretty([%NestedStruct{a: 1}], registry: registry) ==
               "[\n  %Thing{\n    a: 1\n  }\n]"
    end
  end
end
