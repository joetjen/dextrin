defmodule Dextrin.CanonicalTest do
  @moduledoc """
  `Dextrin.Canonical` — the one byte-exact rendering of every value
  (`DXN.md` §1.5), which is what the conformance suite compares across
  implementations.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Canonical

  defp canonical(value) do
    {:ok, text} = Canonical.print(value)
    text
  end

  describe "scalars" do
    test "nil and the booleans are themselves" do
      assert canonical(nil) == "nil"
      assert canonical(true) == "true"
      assert canonical(false) == "false"
    end

    test "an integer is its decimal digits, of any size" do
      assert canonical(42) == "42"
      assert canonical(-7) == "-7"

      assert canonical(123_456_789_012_345_678_901_234_567_890) ==
               "123456789012345678901234567890"
    end

    test "a decimal keeps its scale, writes out a positive exponent, and has an unsigned zero" do
      assert canonical(Decimal.new("1.50")) == "1.50M"
      assert canonical(Decimal.new("-2.5")) == "-2.5M"
      assert canonical(Decimal.new("1E+3")) == "1000M"
      assert canonical(Decimal.new("-0.0")) == "0.0M"
    end

    test "a rational is written as held, not reduced" do
      assert canonical(%Dextrin.Rational{numerator: 2, denominator: 4}) == "2/4"
      assert canonical(%Dextrin.Rational{numerator: -1, denominator: 2}) == "-1/2"
    end

    test "a symbol is its identifier" do
      assert canonical(%Dextrin.Symbol{name: "sym"}) == "sym"
    end

    test "a keyword is :name when the name is an identifier, and quoted otherwise" do
      assert canonical(:kw) == ":kw"
      assert canonical(%Dextrin.Keyword{name: "kw"}) == ":kw"
      assert canonical(%Dextrin.Keyword{name: "two words"}) == ~s(:"two words")
      assert canonical(%Dextrin.Keyword{name: "nil"}) == ~s(:"nil")
    end
  end

  describe "floats" do
    test "a whole number keeps its .0" do
      assert canonical(1.0) == "1.0"
      assert canonical(100.0) == "100.0"
      assert canonical(0.0) == "0.0"
    end

    test "negative zero keeps its sign" do
      assert canonical(-0.0) == "-0.0"
    end

    test "a fraction is written out down to a millionth" do
      assert canonical(0.1) == "0.1"
      assert canonical(1.5) == "1.5"
      assert canonical(123.456) == "123.456"
      assert canonical(0.000001) == "0.000001"
    end

    test "smaller than a millionth goes to an exponent" do
      assert canonical(1.5e-7) == "1.5e-7"
    end

    test "up to 21 digits is written out, beyond goes to an exponent without a plus" do
      assert canonical(123_456_789_012_345_680_000.0) == "123456789012345680000.0"
      assert canonical(1.0e21) == "1.0e21"
      assert canonical(2.5e300) == "2.5e300"
      assert canonical(-1.0e21) == "-1.0e21"
    end

    test "NaN and the infinities are written as words" do
      assert canonical(:nan) == "NaN"
      assert canonical(:positive_infinity) == "Infinity"
      assert canonical(:negative_infinity) == "-Infinity"
    end
  end

  describe "strings and chars" do
    test "a string escapes its quote, backslash and the named controls" do
      assert canonical("hi") == ~s("hi")
      assert canonical(~s(a"b\\c)) == ~S("a\"b\\c")
      assert canonical("a\tb\nc\rd") == ~S("a\tb\nc\rd")
    end

    test "and every other control character, and DEL, as lowercase hex" do
      assert canonical(<<1>>) == ~S("\x{1}")
      assert canonical(<<0x1B>>) == ~S("\x{1b}")
      assert canonical(<<0x7F>>) == ~S("\x{7f}")
    end

    test "and keeps everything else literally" do
      assert canonical("é") == ~s("é")
    end

    test "a char is ? then the character, ?s for a space, escapes for the rest" do
      assert canonical(%Dextrin.Char{codepoint: ?a}) == "?a"
      assert canonical(%Dextrin.Char{codepoint: ?\s}) == "?s"
      assert canonical(%Dextrin.Char{codepoint: ?\n}) == ~S(?\n)
      assert canonical(%Dextrin.Char{codepoint: ?\\}) == ~S(?\\)
      assert canonical(%Dextrin.Char{codepoint: 1}) == ~S(?\x{1})
    end
  end

  describe "collections" do
    test "items are separated by one space" do
      assert canonical([1, 2, 3]) == "[1 2 3]"
      assert canonical(%Dextrin.Tuple{items: [1, 2]}) == "{1 2}"
      assert canonical(%Dextrin.Array{items: {1, 2}}) == "@array[1 2]"
      assert canonical([]) == "[]"
    end

    test "a map is in canonical key order, with shorthand for identifier keywords" do
      assert canonical(%{a: 1}) == "%{a: 1}"
      assert canonical(%{"a" => 1}) == ~s(%{"a" => 1})
      assert canonical(%{:b => 2, :a => 1, "z" => 3}) == ~s(%{"z" => 3 a: 1 b: 2})
      assert canonical(%{1 => :a, "1" => :b}) == ~s(%{"1" => :b 1 => :a})
      assert canonical(%{}) == "%{}"
    end

    test "an ordered map keeps its order" do
      assert canonical(%Dextrin.OrderedMap{pairs: [{:b, 2}, {:a, 1}]}) == "@ordered %{b: 2 a: 1}"
    end

    test "a set and a sorted set are in canonical order" do
      assert canonical(MapSet.new([3, 1, 2])) == "@{1 2 3}"
      assert canonical(%Dextrin.SortedSet{items: ["b", "a"]}) == ~s(@sorted-set @{"a" "b"})
    end

    test "a keyed struct keeps its entries in order, a positional one its items" do
      assert canonical(Dextrin.Struct.keyed("P", [{"y", 1}, {"x", 2}])) == "%P{y: 1 x: 2}"
      assert canonical(Dextrin.Struct.positional("P", [1, 2])) == "%P[1 2]"
    end
  end

  describe "temporal and extended types" do
    test "a date" do
      assert canonical(~D[2026-10-17]) == "~D[2026-10-17]"
    end

    test "a time drops trailing zeros from its fraction, and a zero fraction" do
      assert canonical(~T[10:00:00]) == "~T[10:00:00]"
      assert canonical(~T[10:00:00.500000]) == "~T[10:00:00.5]"
      assert canonical(~T[10:00:00.000]) == "~T[10:00:00]"
    end

    test "a timestamp is UTC with a Z" do
      assert canonical(~U[2026-10-17 10:00:00Z]) == "~U[2026-10-17 10:00:00Z]"
      assert canonical(~U[2026-10-17 10:00:00.250000Z]) == "~U[2026-10-17 10:00:00.25Z]"
    end

    test "a datetime keeps its offset" do
      {:ok, dt} = Dextrin.decode(~s(@datetime "2026-10-17T10:00:00+02:00"))
      assert canonical(dt) == ~s(@datetime "2026-10-17T10:00:00+02:00")
    end

    test "a uuid is lowercase" do
      {:ok, uuid} = Dextrin.Uuid.parse("6F9619FF-8B86-D011-B42D-00C04FC964FF")
      assert canonical(uuid) == ~s(@uuid "6f9619ff-8b86-d011-b42d-00c04fc964ff")
    end

    test "bytes are standard base64 with padding" do
      assert canonical(%Dextrin.Bytes{data: <<0, 1>>}) == ~s(@bytes "AAE=")
    end

    test "a uri is written as held" do
      assert canonical(%Dextrin.Uri{value: "https://example.com/a%20b"}) ==
               ~s(@uri "https://example.com/a%20b")
    end

    test "a custom tag is its name and its value" do
      assert canonical(%Dextrin.CustomTag{name: "money", value: [500, :eur]}) ==
               "@money [500 :eur]"
    end
  end

  test "a value with no DXN meaning is an encode error" do
    assert {:error, %Dextrin.Error{category: "encode/unsupported"}} = Canonical.print(self())
  end
end
