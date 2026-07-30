defmodule Dextrin.ValueTest do
  @moduledoc """
  Direct unit tests for the small value-wrapper modules' own public API
  — constructors and accessors that aren't already exercised
  end-to-end by decode/encode round-trip tests elsewhere (e.g.
  `Dextrin.Rational.reduce/1` and `Dextrin.OrderedMap.fetch/2` are
  public API but never called by `dextrin`'s own decode/encode paths).
  """

  use ExUnit.Case, async: true

  describe "Dextrin.Duration.new/1" do
    test "builds a struct from a keyword list, all fields optional" do
      assert Dextrin.Duration.new(years: 1, days: 2) == %Dextrin.Duration{years: 1, days: 2}
    end

    test "defaults to all-nil fields when given none" do
      assert Dextrin.Duration.new() == %Dextrin.Duration{
               years: nil,
               months: nil,
               weeks: nil,
               days: nil,
               hours: nil,
               minutes: nil,
               microseconds: nil
             }
    end

    test "an unknown field raises, like any other struct!/2 call" do
      assert_raise KeyError, fn -> Dextrin.Duration.new(not_a_real_field: 1) end
    end
  end

  describe "Dextrin.OrderedMap" do
    test "fetch/2 finds a present key" do
      om = Dextrin.OrderedMap.new([{"a", 1}, {"b", 2}])
      assert Dextrin.OrderedMap.fetch(om, "a") == {:ok, 1}
      assert Dextrin.OrderedMap.fetch(om, "b") == {:ok, 2}
    end

    test "fetch/2 returns :error for a missing key" do
      om = Dextrin.OrderedMap.new([{"a", 1}])
      assert Dextrin.OrderedMap.fetch(om, "missing") == :error
    end

    test "to_list/1 returns the pairs in insertion order" do
      om = Dextrin.OrderedMap.new([{"b", 2}, {"a", 1}])
      assert Dextrin.OrderedMap.to_list(om) == [{"b", 2}, {"a", 1}]
    end
  end

  describe "Dextrin.Array" do
    test "new/1 accepts a list, storing it as a tuple" do
      assert Dextrin.Array.new([1, 2, 3]) == %Dextrin.Array{items: {1, 2, 3}}
    end

    test "new/1 accepts a tuple directly" do
      assert Dextrin.Array.new({1, 2, 3}) == %Dextrin.Array{items: {1, 2, 3}}
    end

    test "to_list/1 returns the items as a list, in order" do
      array = Dextrin.Array.new({:a, :b, :c})
      assert Dextrin.Array.to_list(array) == [:a, :b, :c]
    end
  end

  describe "Dextrin.Rational" do
    test "new/2 stores numerator/denominator exactly, unreduced" do
      assert Dextrin.Rational.new(44, 14) == %Dextrin.Rational{numerator: 44, denominator: 14}
    end

    test "reduce/1 divides both by their gcd" do
      assert Dextrin.Rational.reduce(%Dextrin.Rational{numerator: 44, denominator: 14}) ==
               %Dextrin.Rational{numerator: 22, denominator: 7}
    end

    test "reduce/1 is idempotent on an already-reduced value" do
      reduced = Dextrin.Rational.reduce(Dextrin.Rational.new(22, 7))
      assert Dextrin.Rational.reduce(reduced) == reduced
    end

    test "reduce/1 handles a negative numerator" do
      assert Dextrin.Rational.reduce(Dextrin.Rational.new(-4, 8)) ==
               %Dextrin.Rational{numerator: -1, denominator: 2}
    end
  end

  describe "Dextrin.SortedSet" do
    test "new/1 sorts and deduplicates on construction" do
      assert Dextrin.SortedSet.new([3, 1, 2, 1, 3]) == %Dextrin.SortedSet{items: [1, 2, 3]}
    end

    test "to_list/1 returns the sorted, deduplicated items" do
      set = Dextrin.SortedSet.new([5, 3, 4])
      assert Dextrin.SortedSet.to_list(set) == [3, 4, 5]
    end

    test "structural equality holds regardless of construction order (the whole point of always sorting)" do
      assert Dextrin.SortedSet.new([1, 2, 3]) == Dextrin.SortedSet.new([3, 2, 1])
    end
  end

  describe "Dextrin.Uuid.parse/1 error paths" do
    test "rejects a string with the wrong number of hex digits" do
      assert Dextrin.Uuid.parse("not-a-uuid") == {:error, :invalid_uuid}
    end

    test "rejects a string with invalid (non-hex) characters" do
      assert Dextrin.Uuid.parse("gggggggg-gggg-gggg-gggg-gggggggggggg") == {:error, :invalid_uuid}
    end

    test "round-trips a valid canonical UUID string through parse/1 and format/1" do
      text = "550e8400-e29b-41d4-a716-446655440000"
      assert {:ok, uuid} = Dextrin.Uuid.parse(text)
      assert Dextrin.Uuid.format(uuid) == text
    end

    test "parse/1 is case-insensitive on hex digits" do
      assert {:ok, uuid} = Dextrin.Uuid.parse("550E8400-E29B-41D4-A716-446655440000")
      assert Dextrin.Uuid.format(uuid) == "550e8400-e29b-41d4-a716-446655440000"
    end
  end
end
