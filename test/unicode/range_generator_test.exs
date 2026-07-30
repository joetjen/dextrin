defmodule Dextrin.Unicode.RangeGeneratorTest do
  @moduledoc """
  `Dextrin.Unicode.RangeGenerator` — the pure text-processing core
  behind `mix dextrin.gen.unicode`. Exercised against small in-memory
  fixtures shaped like real `DerivedCoreProperties.txt` lines, not the
  ~1MB real file.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Unicode.RangeGenerator

  @fixture """
  # DerivedCoreProperties-99.0.0.txt
  # Date: 2099-01-01, 00:00:00 GMT
  # © 2099 Unicode(R), Inc.

  0041..0045    ; XID_Start # L&   [5] LATIN CAPITAL LETTER A..LATIN CAPITAL LETTER E
  0046..004A    ; XID_Start # L&   [5] LATIN CAPITAL LETTER F..LATIN CAPITAL LETTER J
  0050..0055    ; XID_Start # L&   [6] LATIN CAPITAL LETTER P..LATIN CAPITAL LETTER U
  005F          ; Other_ID_Start  # a property we don't care about
  0030..0039    ; XID_Continue # Nd  [10] DIGIT ZERO..DIGIT NINE
  0041..005A    ; XID_Continue # L&  [26] LATIN CAPITAL LETTER A..LATIN CAPITAL LETTER Z
  """

  describe "version/1" do
    test "extracts the version from the header line" do
      assert RangeGenerator.version(@fixture) == "99.0.0"
    end
  end

  describe "ranges/2" do
    test "extracts only the requested property, ignoring others" do
      ranges = RangeGenerator.ranges(@fixture, "XID_Start")
      assert {0x41, 0x4A} in ranges
      assert {0x50, 0x55} in ranges
      refute Enum.any?(ranges, fn {first, _} -> first == 0x5F end)
    end

    test "merges adjacent ranges but keeps non-adjacent ones separate" do
      assert RangeGenerator.ranges(@fixture, "XID_Start") == [{0x41, 0x4A}, {0x50, 0x55}]
    end

    test "single codepoints (no ..) become a one-element range" do
      fixture = "# DerivedCoreProperties-1.0.0.txt\n005F          ; XID_Start # Pc  UNDERSCORE\n"
      assert RangeGenerator.ranges(fixture, "XID_Start") == [{0x5F, 0x5F}]
    end
  end

  describe "range_counts/1" do
    test "returns the merged range counts for both properties" do
      assert RangeGenerator.range_counts(@fixture) == {2, 2}
    end
  end

  describe "generated_block/1" do
    test "renders a well-formed marked block with both token bodies and the version" do
      block = RangeGenerator.generated_block(@fixture)

      assert block =~ "; BEGIN GENERATED UNICODE RANGES (mix dextrin.gen.unicode, Unicode 99.0.0)"
      assert block =~ "; END GENERATED UNICODE RANGES"
      assert block =~ "IDENT_START := [_\\u{41}-\\u{4A}\\u{50}-\\u{55}]"
      assert block =~ "IDENT_CONT  := IDENT_START | [\\u{30}-\\u{39}\\u{41}-\\u{5A}\\-?!]"
      assert block =~ "IDENTIFIER  := IDENT_START IDENT_CONT* (\"/\" IDENT_START IDENT_CONT*)?"
    end
  end

  describe "splice/2" do
    test "replaces an existing marked region in place" do
      source = """
      @grammar "dxn"

      ; BEGIN GENERATED UNICODE RANGES (mix dextrin.gen.unicode, Unicode 1.0.0)
      IDENT_START := [_\\u{41}]
      ; END GENERATED UNICODE RANGES

      document := value
      """

      generated =
        "; BEGIN GENERATED UNICODE RANGES (mix dextrin.gen.unicode, Unicode 2.0.0)\nIDENT_START := [_\\u{42}]\n; END GENERATED UNICODE RANGES\n"

      updated = RangeGenerator.splice(source, generated)

      assert updated =~ "Unicode 2.0.0"
      refute updated =~ "Unicode 1.0.0"
      assert updated =~ "document := value"
    end

    test "appends the block when no marked region exists yet" do
      source = "@grammar \"dxn\"\n"

      generated =
        "; BEGIN GENERATED UNICODE RANGES (mix dextrin.gen.unicode, Unicode 1.0.0)\n; END GENERATED UNICODE RANGES\n"

      updated = RangeGenerator.splice(source, generated)

      assert updated == source <> "\n" <> generated
    end
  end
end
