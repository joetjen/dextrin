defmodule Dextrin.DocumentFormatTest do
  @moduledoc """
  Phase C, the formatter rebuilt on the document
  (`design/implementation-plan.md`): `Dextrin.Document.format/2` lays a
  document out the way the pretty printer does -- one entry per line,
  indented -- and keeps every comment with the entry it belongs to.
  It changes layout only: every token is written as it was, so `1.50`
  stays `1.50` and an escape stays an escape.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Dextrin.Document

  import Dextrin.Generators, only: [dxn_value: 0]

  defp formatted(text, opts \\ []) do
    {:ok, doc} = Document.parse(text, opts)
    Document.format(doc)
  end

  test "lays out a document and keeps its comments where they belong" do
    text = """
    # The project.

    %{name:   "acme",  # the name
      deps: [ "left-pad" # temporary
    # still about left-pad
         "right-pad",

    # pinned below
      "zero"
    # nothing follows this
      ], empty: [], version: 1.50}
    # the end
    """

    assert formatted(text) == """
           # The project.

           %{
             name: "acme"  # the name
             deps: [
               "left-pad"  # temporary
                           # still about left-pad
               "right-pad"

               # pinned below
               "zero"
               # nothing follows this
             ]
             empty: []
             version: 1.50
           }
           # the end
           """
  end

  # The header is `@dxn` and its version, one space between them,
  # however they were spaced.
  test "the header keeps one space between its tag and its version" do
    assert formatted(~s|@dxn   "1.0"\n[1]|) == ~s|@dxn "1.0"\n[\n  1\n]|
  end

  # A formatter run on save must not take a file's last newline away;
  # one the source did not end with, it does not add.
  test "a document that ends with a newline still does" do
    assert formatted("%{a: 1}\n") == "%{\n  a: 1\n}\n"
    assert formatted("%{a: 1}") == "%{\n  a: 1\n}"
  end

  test "a comment beside an opening bracket stays on its line" do
    assert formatted("[ # the list\n1 2]") == "[  # the list\n  1\n  2\n]"
  end

  test "a comment between a key and its value stays between them" do
    assert formatted("%{version: # pinned\n \"1.0\"}") ==
             "%{\n  version:  # pinned\n    \"1.0\"\n}"
  end

  property "a document with no comments comes out as the pretty printer writes its value" do
    check all(value <- dxn_value()) do
      {:ok, pretty} = Dextrin.encode(value, pretty: true)
      assert formatted(pretty, trusted: false) == pretty
    end
  end

  property "a commented one keeps its value and every comment, and formatting it again changes nothing" do
    check all(value <- dxn_value()) do
      {:ok, pretty} = Dextrin.encode(value, pretty: true)

      text =
        pretty
        |> String.split("\n")
        |> Enum.with_index()
        |> Enum.map_join("\n", fn {line, i} -> line <> " # c#{i}" end)

      {:ok, doc} = Document.parse(text, trusted: false)
      once = Document.format(doc)
      {:ok, again} = Document.parse(once, trusted: false)

      assert Document.to_value(again) == Document.to_value(doc)
      assert comments(once) == comments(text)
      assert Document.format(again) == once
    end
  end

  # Jan, 2026-10-20: a nested collection that fits goes on one line, as
  # Dextrin.Text.Formatter writes it -- unless it holds a comment or a
  # blank line, which keep it over lines.
  describe "layout" do
    test "a nested collection that fits is written on one line" do
      assert formatted("%{deps: [\"a\" \"b\"], at: %{x: 1, y: 2}}") ==
               "%{\n  deps: [\"a\" \"b\"]\n  at: %{x: 1 y: 2}\n}"
    end

    test "the top level breaks however short it is" do
      assert formatted("[1]") == "[\n  1\n]"
    end

    test "a comment inside keeps it over lines" do
      assert formatted("%{deps: [\"a\" # why\n]}") == "%{\n  deps: [\n    \"a\"  # why\n  ]\n}"
    end

    test "and so does a blank line between its entries" do
      assert formatted("%{deps: [\"a\"\n\n\"b\"]}") ==
               "%{\n  deps: [\n    \"a\"\n\n    \"b\"\n  ]\n}"
    end

    test "the width counts the indent and the key" do
      {:ok, doc} = Document.parse("%{key: [1 2 3]}")
      assert Document.format(doc, width: 14) == "%{\n  key: [1 2 3]\n}"
      assert Document.format(doc, width: 13) == "%{\n  key: [\n    1\n    2\n    3\n  ]\n}"
    end
  end

  defp comments(text), do: Regex.scan(~r/# c\d+/, text) |> List.flatten() |> Enum.sort()
end
