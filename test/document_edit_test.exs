defmodule Dextrin.DocumentEditTest do
  @moduledoc """
  Phase C, the explicit edits (`design/comment-retention.md`, "Edits are
  explicit" and "Trivia ownership"): `replace/3`, `delete/2` and
  `insert/4` change exactly what they name. Every byte they do not touch
  is rendered as it was, a replaced value keeps its comments, and a
  deleted entry takes its own -- the blocks above it and the block
  trailing it -- and nobody else's.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Dextrin.Document

  import Dextrin.Generators, only: [dxn_value: 0]

  defp parsed(text) do
    {:ok, doc} = Document.parse(text)
    doc
  end

  defp edited({:ok, doc}), do: Document.render(doc)

  describe "replace/3" do
    test "keeps the comment beside the value, even if it is now stale" do
      text = ~s|%{\n  version: "1.0.0" # bumped for the security fix\n}\n|

      assert edited(Document.replace(parsed(text), [:version], "2.0.0")) ==
               ~s|%{\n  version: "2.0.0" # bumped for the security fix\n}\n|
    end

    test "and every other byte of the document" do
      text = ~s|# top\n%{a: 1,   b: [1 2 3] # list\n}\n|

      assert edited(Document.replace(parsed(text), [:b, 1], 20)) ==
               ~s|# top\n%{a: 1,   b: [1 20 3] # list\n}\n|
    end

    test "lays a collection out at the indentation it replaces" do
      text = ~s|%{\n  deps: "none"\n}\n|

      assert edited(Document.replace(parsed(text), [:deps], ["a", "b"])) ==
               ~s|%{\n  deps: [\n    "a"\n    "b"\n  ]\n}\n|
    end

    test "and the value is what it says" do
      {:ok, doc} = Document.replace(parsed(~s|%{a: %{b: [1 2]}}|), [:a, :b, 0], :x)
      assert Document.to_value(doc) == %{a: %{b: [:x, 2]}}
    end

    test "a struct's field is named by its string" do
      {:ok, doc} = Document.replace(parsed(~s|%P{x: 1, y: 2}|), ["y"], 3)
      assert Document.render(doc) == ~s|%P{x: 1, y: 3}|
    end

    test "a path that leads nowhere is refused" do
      assert {:error, {:not_found, [:nope]}} = Document.replace(parsed("%{a: 1}"), [:nope], 2)
      assert {:error, {:not_found, [:a, 0]}} = Document.replace(parsed("%{a: 1}"), [:a, 0], 2)
    end
  end

  describe "delete/2" do
    @deps """
    %{
      deps: [
        # Pinned until upstream fixes #431.
        "left-pad"  # temporary
        "right-pad"
      ]
    }
    """

    test "takes the entry's above block and its trailing block with it" do
      assert edited(Document.delete(parsed(@deps), [:deps, 0])) == """
             %{
               deps: [
                 "right-pad"
               ]
             }
             """
    end

    test "and leaves the next entry's comments where they are" do
      text = """
      [
        "a" # about a

        # about b
        "b"
      ]
      """

      assert edited(Document.delete(parsed(text), [0])) == """
             [

               # about b
               "b"
             ]
             """
    end

    test "a block with no blank line after a trailing comment trails, and goes too" do
      text = """
      %{
        a: 1 # about a
        # still about a
        b: 2
      }
      """

      assert edited(Document.delete(parsed(text), [:a])) == """
             %{
               b: 2
             }
             """
    end

    test "the comment above the end of a collection stays" do
      text = """
      [
        "a"
        # nothing follows this
      ]
      """

      assert edited(Document.delete(parsed(text), [0])) == """
             [
               # nothing follows this
             ]
             """
    end

    test "an entry on a shared line goes alone" do
      assert edited(Document.delete(parsed("[1 2 3] # three\n"), [1])) == "[1 3] # three\n"
    end

    test "a map entry by its key" do
      {:ok, doc} = Document.delete(parsed(~s|%{a: 1, b: 2}|), [:a])
      assert Document.to_value(doc) == %{b: 2}
    end
  end

  describe "edits mean what they say" do
    # A list or a map of generated values, pretty-printed with a numbered
    # comment on every line: legal everywhere a line ends, and each one
    # findable afterwards.
    defp commented(value) do
      {:ok, pretty} = Dextrin.encode(value, pretty: true)

      pretty
      |> String.split("\n")
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {line, i} -> line <> "  # c#{i}" end)
    end

    defp comments(text), do: Regex.scan(~r/# c\d+/, text) |> List.flatten() |> Enum.sort()

    property "replace/3 changes one item" do
      check all(
              items <- list_of(dxn_value(), min_length: 1, max_length: 5),
              index <- integer(0..(length(items) - 1)),
              new <- dxn_value()
            ) do
        with {:ok, doc} <- Document.parse(commented(items), trusted: false) do
          assert {:ok, edited} = Document.replace(doc, [index], new)
          assert Document.to_value(edited) == List.replace_at(items, index, new)
        end
      end
    end

    # The comments inside a replaced collection belong to its entries,
    # which are gone; every comment beside a value written on one line
    # stays.
    property "and keeps every comment around a value written on one line" do
      check all(
              items <- list_of(dxn_value(), min_length: 1, max_length: 5),
              pick <- integer(0..4),
              new <- dxn_value()
            ) do
        text = commented(items)
        one_line = for {item, i} <- Enum.with_index(items), one_line?(item), do: i

        with [_ | _] <- one_line,
             index = Enum.at(one_line, rem(pick, length(one_line))),
             {:ok, doc} <- Document.parse(text, trusted: false) do
          assert {:ok, edited} = Document.replace(doc, [index], new)
          assert comments(Document.render(edited)) == comments(text)
        end
      end
    end

    defp one_line?(value) do
      {:ok, pretty} = Dextrin.encode(value, pretty: true)
      not String.contains?(pretty, "\n")
    end

    property "delete/2 removes one item" do
      check all(
              items <- list_of(dxn_value(), min_length: 1, max_length: 5),
              index <- integer(0..(length(items) - 1))
            ) do
        with {:ok, doc} <- Document.parse(commented(items), trusted: false) do
          assert {:ok, edited} = Document.delete(doc, [index])
          assert Document.to_value(edited) == List.delete_at(items, index)
        end
      end
    end

    property "insert/4 adds one item where it says" do
      check all(
              items <- list_of(dxn_value(), max_length: 5),
              index <- integer(0..length(items)),
              new <- dxn_value()
            ) do
        with {:ok, doc} <- Document.parse(commented(items), trusted: false) do
          assert {:ok, edited} = Document.insert(doc, [], index, new)
          assert Document.to_value(edited) == List.insert_at(items, index, new)
        end
      end
    end

    property "and the same for a map's keys" do
      check all(values <- list_of(dxn_value(), min_length: 1, max_length: 4), new <- dxn_value()) do
        map = values |> Enum.with_index() |> Map.new(fn {v, i} -> {:"k#{i}", v} end)

        # Trusted, so the keys are atoms -- and so is any keyword inside a
        # value, which is why each expectation is read back the same way.
        read = fn value ->
          {:ok, text} = Dextrin.encode(value)
          {:ok, read} = Dextrin.decode(text)
          read
        end

        with {:ok, doc} <- Document.parse(commented(map)) do
          assert {:ok, put} = Document.insert(doc, [], :added, new)
          assert Document.to_value(put) == read.(Map.put(map, :added, new))
          assert {:ok, gone} = Document.delete(doc, [:k0])
          assert Document.to_value(gone) == read.(Map.delete(map, :k0))
          assert {:ok, changed} = Document.replace(doc, [:k0], new)
          assert Document.to_value(changed) == read.(Map.put(map, :k0, new))
        end
      end
    end
  end

  describe "insert/4" do
    test "at the end of a list, before the comment above its end" do
      text = """
      [
        "a"
        # nothing follows this
      ]
      """

      assert edited(Document.insert(parsed(text), [], -1, "b")) == """
             [
               "a"
               "b"
               # nothing follows this
             ]
             """
    end

    test "before an entry, above its comments, so they stay with it" do
      text = """
      [
        # about a
        "a"
      ]
      """

      assert edited(Document.insert(parsed(text), [], 0, "z")) == """
             [
               "z"
               # about a
               "a"
             ]
             """
    end

    test "into a list on one line" do
      assert edited(Document.insert(parsed("[1 2] # c\n"), [], 1, 9)) == "[1 9 2] # c\n"
      assert edited(Document.insert(parsed("[1 2]"), [], -1, 9)) == "[1 2 9]"
      assert edited(Document.insert(parsed("[]"), [], -1, 9)) == "[9]"
    end

    test "a new key into a map" do
      text = """
      %{
        name: "acme" # the name
      }
      """

      assert edited(Document.insert(parsed(text), [], :version, "1.0.0")) == """
             %{
               name: "acme" # the name
               version: "1.0.0"
             }
             """
    end

    test "a key the map already has is refused: that is replace's" do
      assert {:error, {:exists, [:a]}} = Document.insert(parsed("%{a: 1}"), [], :a, 2)
    end
  end
end
