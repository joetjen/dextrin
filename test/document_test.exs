defmodule Dextrin.DocumentTest do
  @moduledoc """
  Phase C of `design/implementation-plan.md`, its first contract
  (`design/comment-retention.md`, "Properties worth testing"): a `.dxn`
  document parsed with everything it holds -- comments, whitespace,
  commas -- renders back byte for byte when nothing was edited, and its
  value is exactly what `Dextrin.decode/2` gives.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Dextrin.Document

  import Dextrin.Generators, only: [dxn_value: 0]

  @commented """
  # A leading comment, above everything.
  # Two lines of it.

  %{
    # Above an entry.
    name: "acme"        # Trailing, same line.
    version:  # between a key and its value
      "1.0.0"
    deps: [
      # Pinned until upstream fixes #431.
      "left-pad", # temporary
      "right-pad"
      # nothing follows this
    ]
    price: @my-app/money  # and between a tag and its value
      500
  }
  # A trailing comment, below everything.
  """

  describe "an untouched document" do
    test "renders back byte for byte" do
      assert {:ok, doc} = Document.parse(@commented)
      assert Document.render(doc) == @commented
    end

    test "and its value is what decode gives" do
      assert {:ok, doc} = Document.parse(@commented)
      assert {:ok, Document.to_value(doc)} == Dextrin.decode(@commented)
    end

    test "decode's options mean the same here" do
      text = ~s|%{name: :admin} # c|
      assert {:ok, doc} = Document.parse(text, trusted: false)
      assert {:ok, Document.to_value(doc)} == Dextrin.decode(text, trusted: false)
    end

    test "so do its schemas" do
      {:ok, schema} = Dextrin.decode("%{User: %schema(2){name: :string}}")
      {:ok, registry} = Dextrin.Schema.compile(schema)
      text = ~s|%User{name: "a"} # the user|

      assert {:ok, doc} = Document.parse(text, registry: registry)
      assert {:ok, Document.to_value(doc)} == Dextrin.decode(text, registry: registry)
      assert Document.render(doc) == text
    end
  end

  test "a .dxns schema is a document too, and compiles the same with comments as without" do
    commented = """
    # The user, version 2.
    %{
      User: %schema(2){
        name: :string     # required
        email?: :string   # optional since 2
      }
    }
    """

    {:ok, doc} = Document.parse(commented)
    {:ok, plain} = Dextrin.decode("%{User: %schema(2){name: :string, email?: :string}}")

    assert Dextrin.Schema.compile(Document.to_value(doc)) == Dextrin.Schema.compile(plain)
    assert Document.render(doc) == commented
  end

  describe "a document that is not one" do
    test "is refused the way decode refuses it" do
      assert Document.parse("[1 2") == Dextrin.decode("[1 2")
    end

    test "with the category decode gives" do
      {:ok, schema} = Dextrin.decode("%{User: %schema{name: :string}}")
      {:ok, registry} = Dextrin.Schema.compile(schema)

      assert {:error, %Dextrin.Error{category: "schema/type-mismatch"}} =
               Document.parse("%User{name: 1}", registry: registry)
    end
  end

  property "any document renders back byte for byte, and its value is decode's" do
    check all(value <- dxn_value(), comment <- string(:printable, max_length: 12)) do
      {:ok, pretty} = Dextrin.encode(value, pretty: true)
      text = "# #{String.replace(comment, "\n", " ")}\n" <> commented_lines(pretty)

      with {:ok, decoded} <- Dextrin.decode(text, trusted: false) do
        assert {:ok, doc} = Document.parse(text, trusted: false)
        assert Document.render(doc) == text
        assert Document.to_value(doc) == decoded
      end
    end
  end

  # Every line of `text` with a comment after it -- legal wherever a line
  # ends outside a literal, and the property only holds a document to
  # its contract when decode accepts it.
  defp commented_lines(text) do
    text |> String.split("\n") |> Enum.map_join("\n", &(&1 <> "  # c"))
  end
end
