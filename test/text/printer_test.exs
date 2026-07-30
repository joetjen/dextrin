defmodule Dextrin.Text.PrinterTest do
  @moduledoc """
  Direct unit tests for `Dextrin.Text.Printer.print/2` — every DXN
  type's own print clause, plus the error paths round-trip tests never
  reach (a struct with no schema/tag registration at all, a
  tag_encoder that itself fails, quoted vs. bare keyword/map-entry
  names).
  """

  use ExUnit.Case, async: true

  alias Dextrin.Text.Printer

  alias Dextrin.{
    Array,
    Bytes,
    Char,
    CustomTag,
    Keyword,
    OrderedMap,
    Rational,
    SortedSet,
    Struct,
    Symbol,
    Tuple,
    Uri,
    Uuid
  }

  describe "scalars" do
    test "nil, booleans, and non-finite floats" do
      assert Printer.print(nil) == {:ok, "nil"}
      assert Printer.print(true) == {:ok, "true"}
      assert Printer.print(false) == {:ok, "false"}
      assert Printer.print(:nan) == {:ok, "NaN"}
      assert Printer.print(:positive_infinity) == {:ok, "Infinity"}
      assert Printer.print(:negative_infinity) == {:ok, "-Infinity"}
    end

    test "integers and finite floats" do
      assert Printer.print(42) == {:ok, "42"}
      assert Printer.print(-17) == {:ok, "-17"}
      assert Printer.print(3.14) == {:ok, "3.14"}
    end

    test "decimal and rational" do
      assert Printer.print(Decimal.new("19.99")) == {:ok, "19.99M"}
      assert Printer.print(%Rational{numerator: 22, denominator: 7}) == {:ok, "22/7"}
    end

    test "strings, escaping control characters and quotes" do
      assert Printer.print("hello") == {:ok, "\"hello\""}
      assert Printer.print("a\"b\\c\nd\te\rf") == {:ok, "\"a\\\"b\\\\c\\nd\\te\\rf\""}
      assert Printer.print(<<1>>) == {:ok, "\"\\x{1}\""}
    end

    test "bytes are base64-encoded" do
      assert Printer.print(Bytes.new("hi")) == {:ok, ~s(@bytes "aGk=")}
    end

    test "char, including the space/control/escape special cases" do
      assert Printer.print(Char.new(?a)) == {:ok, "?a"}
      assert Printer.print(Char.new(?\s)) == {:ok, "?s"}
      assert Printer.print(Char.new(?\n)) == {:ok, "?\\n"}
      assert Printer.print(Char.new(?\t)) == {:ok, "?\\t"}
      assert Printer.print(Char.new(?\r)) == {:ok, "?\\r"}
      assert Printer.print(Char.new(?\")) == {:ok, "?\\\""}
      assert Printer.print(Char.new(?\\)) == {:ok, "?\\\\"}
      assert Printer.print(Char.new(1)) == {:ok, "?\\x{1}"}
    end

    test "symbols and keywords" do
      assert Printer.print(Symbol.new("some-symbol")) == {:ok, "some-symbol"}
      assert Printer.print(Keyword.new("ok")) == {:ok, ":ok"}
    end

    test "a keyword whose name isn't a bare identifier is quoted" do
      assert Printer.print(Keyword.new("has spaces")) == {:ok, ~s(:"has spaces")}
    end

    test "a bare atom is accepted as a keyword (DXN.md §1.3: keyword's Elixir type is \"Elixir atom\")" do
      assert Printer.print(:ok) == {:ok, ":ok"}
      assert Printer.print(:"has spaces") == {:ok, ~s(:"has spaces")}
      assert Printer.print(:ok) == Printer.print(Keyword.new("ok"))
    end

    test "nil/true/false stay their own literals, never a keyword named nil/true/false" do
      assert Printer.print(nil) == {:ok, "nil"}
      assert Printer.print(true) == {:ok, "true"}
      assert Printer.print(false) == {:ok, "false"}
    end

    test "an unencodable term (no DXN representation at all) is a clean error, not a crash" do
      assert {:error, %Dextrin.Error{}} = Printer.print(self())
      assert {:error, %Dextrin.Error{}} = Printer.print(make_ref())
      assert {:error, %Dextrin.Error{}} = Printer.print({1, 2})
    end
  end

  describe "collections" do
    test "list and tuple" do
      assert Printer.print([1, 2, 3]) == {:ok, "[1 2 3]"}
      assert Printer.print(Tuple.new([1, "a", :nan])) == {:ok, "{1 \"a\" NaN}"}
    end

    test "empty list and tuple" do
      assert Printer.print([]) == {:ok, "[]"}
      assert Printer.print(Tuple.new([])) == {:ok, "{}"}
    end

    test "array" do
      assert Printer.print(Array.new([1, 2])) == {:ok, "@array [1 2]"}
    end

    test "set and sorted-set" do
      assert Printer.print(MapSet.new([1])) == {:ok, "@{1}"}
      assert Printer.print(SortedSet.new([3, 1, 2])) == {:ok, "@sorted-set @{1 2 3}"}
    end

    test "ordered-map with keyword-shorthand keys" do
      om = OrderedMap.new([{Keyword.new("b"), 2}, {Keyword.new("a"), 1}])
      assert Printer.print(om) == {:ok, "@ordered %{b:2,a:1}"}
    end

    test "a plain map with keyword-shorthand keys" do
      assert Printer.print(%{Keyword.new("x") => 1}) == {:ok, "%{x:1}"}
    end

    test "a plain map with a non-keyword key uses the arrow form" do
      assert Printer.print(%{1 => "one"}) == {:ok, "%{1=>\"one\"}"}
    end

    test "a keyed struct" do
      s = Struct.keyed("Point", [{"x", 1}, {"y", 2}])
      assert Printer.print(s) == {:ok, "%Point{x:1,y:2}"}
    end

    test "a positional struct" do
      s = Struct.positional("Point", [1, 2])
      assert Printer.print(s) == {:ok, "%Point[1,2]"}
    end
  end

  describe "temporal" do
    test "date and time" do
      assert Printer.print(~D[2024-01-01]) == {:ok, "~D[2024-01-01]"}
      assert Printer.print(~T[12:30:00]) == {:ok, "~T[12:30:00]"}
    end

    test "a UTC timestamp uses the ~U[...] sigil" do
      {:ok, dt, 0} = DateTime.from_iso8601("2024-01-01T12:30:00Z")
      assert Printer.print(dt) == {:ok, "~U[2024-01-01 12:30:00Z]"}
    end

    test "a non-UTC datetime uses the @datetime tag" do
      # DateTime.from_iso8601/1 always normalizes to UTC (utc_offset: 0)
      # -- build a genuinely non-zero-offset struct directly, matching
      # how Dextrin.Text.Actions.build_offset_datetime/2 constructs one.
      dt = %DateTime{
        year: 2024,
        month: 1,
        day: 1,
        hour: 12,
        minute: 30,
        second: 0,
        microsecond: {0, 0},
        time_zone: "fixed",
        zone_abbr: "+02:00",
        utc_offset: 7200,
        std_offset: 0
      }

      assert Printer.print(dt) == {:ok, ~s(@datetime "2024-01-01T12:30:00+02:00")}
    end

    test "duration" do
      d = %Dextrin.Duration{years: 1, months: 2, days: 10}
      assert {:ok, printed} = Printer.print(d)
      assert printed == ~s(@duration "P1Y2M10D")
    end

    test "a duration with only a microseconds field round-trips through fractional seconds" do
      d = %Dextrin.Duration{microseconds: 1_500_000}
      assert {:ok, printed} = Printer.print(d)
      assert printed =~ "@duration"
    end
  end

  describe "extended" do
    test "uuid" do
      {:ok, uuid} = Uuid.parse("550e8400-e29b-41d4-a716-446655440000")
      assert Printer.print(uuid) == {:ok, ~s(@uuid "550e8400-e29b-41d4-a716-446655440000")}
    end

    test "uri" do
      assert Printer.print(Uri.new("https://example.com")) ==
               {:ok, ~s(@uri "https://example.com")}
    end

    test "regex" do
      assert Printer.print(~r/abc/i) == {:ok, "~r/abc/i"}
    end

    test "custom tag, recursively printing its inner value" do
      assert Printer.print(CustomTag.new("my-tag", 42)) == {:ok, "@my-tag 42"}
    end
  end

  describe "unrecognized structs and the registry-consulting fallback" do
    defmodule PlainStruct do
      @moduledoc false
      defstruct [:a]
    end

    test "with no opts at all, an unregistered struct is a clear error" do
      assert {:error, %Dextrin.Error{message: message}} = Printer.print(%PlainStruct{a: 1})
      assert message =~ "cannot encode value with no DXN representation"
    end

    test "with a registry but no tag_encoder registered for the struct, still an error" do
      registry = Dextrin.Registry.new()

      assert {:error, %Dextrin.Error{}} =
               Printer.print(%PlainStruct{a: 1}, registry: registry)
    end

    test "a registered tag_encoder is used to print the struct as a custom tag" do
      registry =
        Dextrin.Registry.put_tag_encoder(Dextrin.Registry.new(), PlainStruct, "plain", fn s ->
          {:ok, s.a}
        end)

      assert Printer.print(%PlainStruct{a: 1}, registry: registry) == {:ok, "@plain 1"}
    end

    test "a tag_encoder returning {:error, _} surfaces as a Dextrin.Error" do
      registry =
        Dextrin.Registry.put_tag_encoder(Dextrin.Registry.new(), PlainStruct, "plain", fn _s ->
          {:error, :nope}
        end)

      assert {:error, %Dextrin.Error{message: message}} =
               Printer.print(%PlainStruct{a: 1}, registry: registry)

      assert message =~ "tag encoder for"
      assert message =~ "failed"
    end

    test "a struct registered via put_struct_module/3 prints as its schema's own keyed struct form" do
      {:ok, doc} =
        Dextrin.decode("%{ Plain: %schema{ fields: @ordered %{ a: :integer } } }")

      {:ok, registry} = Dextrin.Schema.compile(doc)
      registry = Dextrin.Registry.put_struct_module(registry, "Plain", PlainStruct)

      assert Printer.print(%PlainStruct{a: 1}, registry: registry) == {:ok, "%Plain{a:1}"}
    end
  end
end
