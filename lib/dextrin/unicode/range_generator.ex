defmodule Dextrin.Unicode.RangeGenerator do
  @moduledoc """
  Pure text-processing core for turning a Unicode Character Database
  `DerivedCoreProperties.txt` into the generated `IDENT_START`/
  `IDENT_CONT`/`IDENTIFIER` block spliced into `priv/grammar/dxn.aether`
  (DESIGN.md §5.2). No file or network I/O lives here — that's
  `Mix.Tasks.Dextrin.Gen.Unicode`'s job — so this module can be tested
  directly against small in-memory fixtures instead of the real,
  ~1MB UCD file.
  """

  @line_re ~r/^([0-9A-Fa-f]+)(?:\.\.([0-9A-Fa-f]+))?\s*;\s*(\S+)/
  @marker_re ~r/; BEGIN GENERATED UNICODE RANGES.*?; END GENERATED UNICODE RANGES\n/s

  @doc "Extracts the Unicode version from a DerivedCoreProperties.txt's own header line, e.g. \"17.0.0\"."
  @spec version(String.t()) :: String.t()
  def version(ucd_text) do
    ucd_text
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim_leading("# DerivedCoreProperties-")
    |> String.trim_leading("#")
    |> String.trim()
    |> String.trim_trailing(".txt")
  end

  @doc "Extracts and merges the codepoint ranges for one named derived property (e.g. \"XID_Start\")."
  @spec ranges(String.t(), String.t()) :: [{non_neg_integer(), non_neg_integer()}]
  def ranges(ucd_text, property_name) do
    ucd_text
    |> String.split("\n")
    |> Enum.map(&Regex.run(@line_re, &1))
    |> Enum.filter(&(&1 != nil))
    |> Enum.filter(fn [_, _first, _last, prop] -> prop == property_name end)
    |> Enum.map(fn [_, first, last, _] ->
      first_cp = String.to_integer(first, 16)
      last_cp = if last in [nil, ""], do: first_cp, else: String.to_integer(last, 16)
      {first_cp, last_cp}
    end)
    |> Enum.sort()
    |> merge()
  end

  # Adjacent/overlapping ranges merged for compactness — UCD data is
  # already mostly-merged per property, but not guaranteed maximally so.
  defp merge(ranges) do
    ranges
    |> Enum.reduce([], fn
      {first, last}, [{prev_first, prev_last} | rest] when first <= prev_last + 1 ->
        [{prev_first, max(prev_last, last)} | rest]

      range, acc ->
        [range | acc]
    end)
    |> Enum.reverse()
  end

  defp render_class_body(ranges) do
    Enum.map_join(ranges, "", fn
      {cp, cp} -> "\\u{#{Integer.to_string(cp, 16)}}"
      {first, last} -> "\\u{#{Integer.to_string(first, 16)}}-\\u{#{Integer.to_string(last, 16)}}"
    end)
  end

  @doc "Renders the full generated grammar block (marker comments included) for a given UCD text."
  @spec generated_block(String.t()) :: String.t()
  def generated_block(ucd_text) do
    xid_start = ranges(ucd_text, "XID_Start")
    xid_continue = ranges(ucd_text, "XID_Continue")
    ver = version(ucd_text)

    """
    ; BEGIN GENERATED UNICODE RANGES (mix dextrin.gen.unicode, Unicode #{ver})
    ; XID_Start + "_" (DXN.md §1.1: letter = XID_Start | "_")
    IDENT_START := [_#{render_class_body(xid_start)}]
    ; XID_Continue + "-?!" (DXN.md §1.1: ident_char = XID_Continue | "-" | "?" | "!")
    IDENT_CONT  := IDENT_START | [#{render_class_body(xid_continue)}\\-?!]
    IDENTIFIER  := IDENT_START IDENT_CONT* ("/" IDENT_START IDENT_CONT*)?
    ; END GENERATED UNICODE RANGES
    """
  end

  @doc """
  Splices `generated` into `grammar_source`, replacing the existing
  marked region if one exists, or appending one if not.
  """
  @spec splice(String.t(), String.t()) :: String.t()
  def splice(grammar_source, generated) do
    if Regex.match?(@marker_re, grammar_source) do
      Regex.replace(@marker_re, grammar_source, generated)
    else
      grammar_source <> "\n" <> generated
    end
  end

  @doc "Counts of merged XID_Start/XID_Continue ranges — for status/logging output."
  @spec range_counts(String.t()) :: {non_neg_integer(), non_neg_integer()}
  def range_counts(ucd_text) do
    {length(ranges(ucd_text, "XID_Start")), length(ranges(ucd_text, "XID_Continue"))}
  end
end
