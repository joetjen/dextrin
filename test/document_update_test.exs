defmodule Dextrin.DocumentUpdateTest do
  @moduledoc """
  Phase C, the update (`design/comment-retention.md`, "Edits are
  explicit; the diff is a convenience over them" and "Ambiguity is
  detected"): `update/3` turns a new value into the explicit edits that
  make it, answers them as a changeset, and refuses by default only
  where guessing would lose a comment somebody wrote.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Dextrin.Document

  import Dextrin.Generators, only: [dxn_value: 0]

  @deps """
  %{
    name: "acme"  # the name
    version: "1.0.0"
    deps: [
      "left-pad"  # temporary
      "right-pad"
    ]
  }
  """

  defp parsed(text) do
    {:ok, doc} = Document.parse(text)
    doc
  end

  test "an equal value changes nothing, however it is written" do
    text = "%{a: 1.50, b: [1   2]} # c\n"
    assert {:ok, doc, []} = Document.update(parsed(text), %{a: 1.5, b: [1, 2]})
    assert Document.render(doc) == text
  end

  test "a changed value is replaced in place, its comment kept" do
    assert {:ok, doc, [replace: {[:version], "2.0.0"}]} =
             Document.update(parsed(@deps), %{
               name: "acme",
               version: "2.0.0",
               deps: ["left-pad", "right-pad"]
             })

    assert Document.render(doc) == String.replace(@deps, ~s|"1.0.0"|, ~s|"2.0.0"|)
  end

  test "an added item is inserted, and a removed one deleted with its comments" do
    assert {:ok, doc, changes} =
             Document.update(parsed(@deps), %{
               name: "acme",
               version: "1.0.0",
               deps: ["right-pad", "zero"]
             })

    assert changes == [delete: [:deps, 0], insert: {[:deps], 1, "zero"}]

    assert Document.render(doc) == """
           %{
             name: "acme"  # the name
             version: "1.0.0"
             deps: [
               "right-pad"
               "zero"
             ]
           }
           """
  end

  test "an added key goes in after the last, and a removed one goes with its comments" do
    assert {:ok, doc, changes} =
             Document.update(parsed(@deps), %{
               version: "1.0.0",
               deps: ["left-pad", "right-pad"],
               license: "Apache-2.0"
             })

    assert changes == [delete: [:name], insert: {[], :license, "Apache-2.0"}]
    refute Document.render(doc) =~ "the name"

    assert Document.to_value(doc) == %{
             version: "1.0.0",
             deps: ["left-pad", "right-pad"],
             license: "Apache-2.0"
           }
  end

  describe "a deleted item followed by an inserted one" do
    @changed %{name: "acme", version: "1.0.0", deps: ["other-pad", "right-pad"]}

    test "is refused by default when the deleted one owns a comment: which reading is meant decides where it goes" do
      assert {:error, {:ambiguous, [:deps, 0]}} = Document.update(parsed(@deps), @changed)
    end

    test "is a replace when asked to guess, and the comment stays" do
      assert {:ok, doc, [replace: {[:deps, 0], "other-pad"}]} =
               Document.update(parsed(@deps), @changed, on_ambiguity: :guess)

      assert Document.render(doc) =~ ~s|"other-pad"  # temporary|
    end

    test "is a replace by default when there is no comment to lose" do
      assert {:ok, _doc, [replace: {[:deps, 1], "other"}]} =
               Document.update(parsed(@deps), %{@changed | deps: ["left-pad", "other"]})
    end

    test "and refused even then when every ambiguity is to be refused" do
      assert {:error, {:ambiguous, [:deps, 1]}} =
               Document.update(parsed(@deps), %{@changed | deps: ["left-pad", "other"]},
                 on_ambiguity: :error
               )
    end
  end

  property "the updated document holds the new value, and an unchanged one is untouched" do
    check all(old <- dxn_value(), new <- dxn_value()) do
      {:ok, pretty} = Dextrin.encode(old, pretty: true)
      text = pretty |> String.split("\n") |> Enum.map_join("\n", &(&1 <> "  # c"))

      with {:ok, doc} <- Document.parse(text, trusted: false) do
        assert {:ok, same, []} = Document.update(doc, Document.to_value(doc))
        assert Document.render(same) == text
        assert {:ok, updated, _changes} = Document.update(doc, new, on_ambiguity: :guess)
        assert Document.to_value(updated) == new
      end
    end
  end
end
