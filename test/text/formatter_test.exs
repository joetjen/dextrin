defmodule Dextrin.Text.FormatterTest do
  @moduledoc """
  Direct unit tests for `Dextrin.Text.Formatter.pretty/2` — every
  collection type's multi-line rendering, both empty (a one-liner, no
  indentation needed) and non-empty (indented, recursively), the
  configurable `indent:` opt, and the scalar/error fallback onto
  `Dextrin.Text.Printer`.
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
      assert Formatter.pretty([]) == {:ok, "[]"}
    end

    test "empty tuple, set, sorted-set, array, ordered-map, and map" do
      assert Formatter.pretty(Tuple.new([])) == {:ok, "{}"}
      assert Formatter.pretty(MapSet.new([])) == {:ok, "@{}"}
      assert Formatter.pretty(SortedSet.new([])) == {:ok, "@sorted-set @{}"}
      assert Formatter.pretty(Array.new([])) == {:ok, "@array[]"}
      assert Formatter.pretty(OrderedMap.new([])) == {:ok, "@ordered %{}"}
      assert Formatter.pretty(%{}) == {:ok, "%{}"}
    end
  end

  describe "non-empty collections render multi-line, indented" do
    test "list" do
      assert Formatter.pretty([1, 2, 3]) == {:ok, "[\n  1\n  2\n  3\n]"}
    end

    test "tuple" do
      assert Formatter.pretty(Tuple.new([1, "a"])) == {:ok, "{\n  1\n  \"a\"\n}"}
    end

    test "set" do
      assert Formatter.pretty(MapSet.new([1])) == {:ok, "@{\n  1\n}"}
    end

    test "sorted-set, always in sorted order regardless of construction order" do
      assert Formatter.pretty(SortedSet.new([3, 1, 2])) ==
               {:ok, "@sorted-set @{\n  1\n  2\n  3\n}"}
    end

    test "array" do
      assert Formatter.pretty(Array.new([1, 2])) == {:ok, "@array[\n  1\n  2\n]"}
    end

    test "ordered-map, keyword-shorthand keys" do
      om = OrderedMap.new([{Keyword.new("b"), 2}, {Keyword.new("a"), 1}])
      assert Formatter.pretty(om) == {:ok, "@ordered %{\n  b: 2\n  a: 1\n}"}
    end

    test "a plain map with keyword-shorthand keys" do
      assert Formatter.pretty(%{Keyword.new("x") => 1}) == {:ok, "%{\n  x: 1\n}"}
    end

    test "a plain map with a non-keyword key uses the arrow form" do
      assert Formatter.pretty(%{1 => "one"}) == {:ok, "%{\n  1 => \"one\"\n}"}
    end

    test "a plain map with a raw (trusted) atom key uses keyword-shorthand" do
      assert Formatter.pretty(%{x: 1}) == {:ok, "%{\n  x: 1\n}"}
    end

    # Regression: a string-typed key that happens to look like a bare
    # identifier used to be indistinguishable, inside render_entry/4,
    # from a Dextrin.Struct field name (also a bare binary string) —
    # both fell into the same clause, so a genuinely string-keyed map
    # entry rendered as `id: 1` (keyword shorthand) instead of
    # `"id" => 1`, silently changing the key's type on re-decode.
    test "a plain map with a string key that looks like a bare identifier keeps its string-ness (quoted arrow form)" do
      assert Formatter.pretty(%{"id" => 1}) == {:ok, "%{\n  \"id\" => 1\n}"}
      assert {:ok, text} = Formatter.pretty(%{"id" => 1})
      assert Dextrin.decode(text) == {:ok, %{"id" => 1}}
    end

    # Regression: :nan/:positive_infinity/:negative_infinity are the
    # exact atoms a *float value* Infinity/-Infinity/NaN decodes to
    # (see Dextrin.Value's own moduledoc) — render_entry/4 used to have
    # no dedicated atom-key clause, so a map keyed by one of these three
    # atoms fell through to the generic key-is-a-value delegate, which
    # deliberately prints those three atoms as the float sigils in
    # *value* position. In *key* position that's wrong: the key is a
    # keyword named e.g. "positive_infinity", not the float value.
    test "a plain map keyed by :nan/:positive_infinity/:negative_infinity renders the key as a keyword, not a float sigil" do
      assert Formatter.pretty(%{positive_infinity: :ok}) ==
               {:ok, "%{\n  positive_infinity: :ok\n}"}

      assert Formatter.pretty(%{negative_infinity: :ok}) ==
               {:ok, "%{\n  negative_infinity: :ok\n}"}

      assert Formatter.pretty(%{nan: :ok}) == {:ok, "%{\n  nan: :ok\n}"}
    end

    test "a keyed struct" do
      s = Struct.keyed("Point", [{"x", 1}, {"y", 2}])
      assert Formatter.pretty(s) == {:ok, "%Point{\n  x: 1\n  y: 2\n}"}
    end

    test "a keyed struct whose field value is a float special value still prints via the float sigil (value position, unaffected)" do
      s = Struct.keyed("Reading", [{"value", :positive_infinity}])
      assert Formatter.pretty(s) == {:ok, "%Reading{\n  value: Infinity\n}"}
    end

    test "a positional struct" do
      s = Struct.positional("Point", [1, 2])
      assert Formatter.pretty(s) == {:ok, "%Point[\n  1\n  2\n]"}
    end
  end

  # `width: 1` breaks every nested collection, so the indentation shows.
  describe "nesting increases indentation at each level" do
    test "a list of maps" do
      assert Formatter.pretty([%{Keyword.new("a") => 1}], width: 1) ==
               {:ok, "[\n  %{\n    a: 1\n  }\n]"}
    end

    test "a map whose value is a list" do
      assert Formatter.pretty(%{Keyword.new("xs") => [1, 2]}, width: 1) ==
               {:ok, "%{\n  xs: [\n    1\n    2\n  ]\n}"}
    end
  end

  describe "indent: controls spaces per nesting level" do
    test "default is 2 spaces" do
      assert Formatter.pretty(%{Keyword.new("x") => 1}) == {:ok, "%{\n  x: 1\n}"}
    end

    test "indent: 4" do
      assert Formatter.pretty(%{Keyword.new("x") => 1}, indent: 4) == {:ok, "%{\n    x: 1\n}"}
    end

    test "indent: 0 (no leading whitespace, still one entry per line)" do
      assert Formatter.pretty([1, 2], indent: 0) == {:ok, "[\n1\n2\n]"}
    end

    test "compounds across nesting levels" do
      assert Formatter.pretty(%{Keyword.new("xs") => [1, 2]}, indent: 4, width: 1) ==
               {:ok, "%{\n    xs: [\n        1\n        2\n    ]\n}"}
    end
  end

  describe "scalars and errors fall back to Dextrin.Text.Printer" do
    test "scalars print exactly as Printer.print/2 would, single-line" do
      assert Formatter.pretty(42) == {:ok, "42"}
      assert Formatter.pretty("hi") == {:ok, "\"hi\""}
      assert Formatter.pretty(nil) == {:ok, "nil"}
    end

    test "an unencodable value returns {:error, _}, same as Printer.print/2, not a raise" do
      assert {:error, %Dextrin.Error{message: message}} = Formatter.pretty(%UnknownStruct{a: 1})
      assert message =~ "cannot encode value with no DXN representation"
    end

    test "an unencodable value nested inside a collection also surfaces as {:error, _}" do
      assert {:error, %Dextrin.Error{}} = Formatter.pretty([%UnknownStruct{a: 1}])
    end
  end

  describe "opts (e.g. registry) thread through recursively" do
    test "a registered struct nested inside a list is still resolved via the registry" do
      {:ok, doc} = Dextrin.decode("%{ Thing: %schema{ a: :integer } }")
      {:ok, registry} = Dextrin.Schema.compile(doc)
      registry = Dextrin.Registry.put_struct_module(registry, "Thing", NestedStruct)

      assert Formatter.pretty([%NestedStruct{a: 1}], registry: registry) ==
               {:ok, "[\n  %Thing(1){a: 1}\n]"}
    end
  end

  # Jan, 2026-10-20: the top-level collection always breaks, one entry
  # per line; a nested one stays on one line when that line fits the
  # width (80, `:width`), its entries single-space separated.
  describe "layout: a nested collection that fits stays on one line" do
    test "the top level breaks however short it is" do
      assert Formatter.pretty([1, 2]) == {:ok, "[\n  1\n  2\n]"}
      assert Formatter.pretty(%{a: 1}) == {:ok, "%{\n  a: 1\n}"}
    end

    test "a nested collection that fits is written on one line" do
      assert Formatter.pretty([[1, 2], Tuple.new([3, "a"])]) ==
               {:ok, "[\n  [1 2]\n  {3 \"a\"}\n]"}

      assert Formatter.pretty(%{a: %{b: Array.new([1])}}) ==
               {:ok, "%{\n  a: %{b: @array[1]}\n}"}

      assert Formatter.pretty([OrderedMap.new([{Keyword.new("y"), 2}, {Keyword.new("x"), 1}])]) ==
               {:ok, "[\n  @ordered %{y: 2 x: 1}\n]"}

      assert Formatter.pretty([Struct.keyed("P", [{"q", 1}, {"r", "s"}])]) ==
               {:ok, "[\n  %P{q: 1 r: \"s\"}\n]"}

      assert Formatter.pretty([Struct.positional("P", [1, 2])]) == {:ok, "[\n  %P[1 2]\n]"}
    end

    test "the line it fits on counts its indent and its key" do
      # "  key: [1 2 3]" is 14 columns.
      assert Formatter.pretty(%{key: [1, 2, 3]}, width: 14) == {:ok, "%{\n  key: [1 2 3]\n}"}

      assert Formatter.pretty(%{key: [1, 2, 3]}, width: 13) ==
               {:ok, "%{\n  key: [\n    1\n    2\n    3\n  ]\n}"}
    end

    test "one that does not fit breaks, and what it holds is laid out again" do
      long = String.duplicate("x", 40)

      assert Formatter.pretty([[[1, 2], long, long]]) ==
               {:ok, "[\n  [\n    [1 2]\n    \"#{long}\"\n    \"#{long}\"\n  ]\n]"}
    end

    test "the width is 80 unless given" do
      # "  [\"" and "\"]" leave 74 columns of 80 for the string.
      fits = String.duplicate("x", 74)
      assert Formatter.pretty([[fits]]) == {:ok, "[\n  [\"#{fits}\"]\n]"}

      over = String.duplicate("x", 75)
      assert Formatter.pretty([[over]]) == {:ok, "[\n  [\n    \"#{over}\"\n  ]\n]"}
    end
  end
end
