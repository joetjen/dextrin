defmodule Dextrin.ConformanceTest do
  @moduledoc """
  `Dextrin.Conformance` — this implementation's answers to a batch of
  conformance cases, in the shape the Dextrin Conformance Suite reads,
  and `mix dextrin.conformance`, which reads and writes them as files.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Conformance

  defp answer(cases) do
    %{"results" => results} = Conformance.answer(%{"cases" => cases})
    results
  end

  test "a decode answers the value's canonical form" do
    assert answer([%{"id" => "a", "operation" => "decode", "text" => "%{b: 2, a: 1}"}]) ==
             [%{"id" => "a", "canonical" => "%{a: 1 b: 2}"}]
  end

  test "text that does not parse answers its category" do
    assert answer([%{"id" => "a", "operation" => "decode", "text" => "[1 2"}]) ==
             [%{"id" => "a", "error" => "syntax"}]
  end

  test "a binary decode reads base64 and answers the canonical form" do
    assert answer([%{"id" => "a", "operation" => "decode-binary", "binary" => "RFgBGCo="}]) ==
             [%{"id" => "a", "canonical" => "42"}]
  end

  test "a binary document that is malformed answers its category" do
    assert answer([%{"id" => "a", "operation" => "decode-binary", "binary" => "GCo="}]) ==
             [%{"id" => "a", "error" => "binary"}]
  end

  @user "%{User: %schema(2){name: :string}}"

  test "a case's schemas are loaded before it runs" do
    assert answer([
             %{
               "id" => "a",
               "operation" => "decode",
               "text" => ~s|%User{name: "x"}|,
               "schemas" => [@user]
             }
           ]) == [%{"id" => "a", "canonical" => ~s|%User(2){name: "x"}|}]
  end

  test "and a schema violation answers its category" do
    assert answer([
             %{
               "id" => "a",
               "operation" => "decode",
               "text" => "%User{name: 1}",
               "schemas" => [@user]
             }
           ]) == [%{"id" => "a", "error" => "schema/type-mismatch"}]
  end

  test "a strict case decodes strictly" do
    assert answer([
             %{
               "id" => "a",
               "operation" => "decode",
               "text" => ~s|%User{name: "x", nick: "y"}|,
               "schemas" => [@user],
               "strict" => true
             }
           ]) == [%{"id" => "a", "error" => "schema/undeclared-field"}]
  end

  test "a schema that does not compile answers its category" do
    assert answer([
             %{"id" => "a", "operation" => "decode", "text" => "1", "schemas" => ["%{User: 1}"]}
           ]) == [%{"id" => "a", "error" => "schema/compile"}]
  end

  describe "documents" do
    @doc_text ~s|%{\n  name: "acme" # the name\n  deps: ["a" "b"]\n}\n|

    test "a format answers the document laid out, its comments kept" do
      assert answer([%{"id" => "a", "operation" => "format", "text" => "[1 # one\n 2]"}]) ==
               [%{"id" => "a", "text" => "[\n  1  # one\n  2\n]"}]
    end

    test "an edit answers the document rendered after its edits, in order" do
      edits = [
        %{"op" => "replace", "path" => "[:name]", "value" => ~s|"other"|},
        %{"op" => "delete", "path" => "[:deps 0]"},
        %{"op" => "insert", "path" => "[:deps]", "where" => "-1", "value" => ~s|"c"|}
      ]

      assert answer([
               %{"id" => "a", "operation" => "edit", "text" => @doc_text, "edits" => edits}
             ]) ==
               [
                 %{
                   "id" => "a",
                   "text" => ~s|%{\n  name: "other" # the name\n  deps: ["b" "c"]\n}\n|
                 }
               ]
    end

    test "an update answers the document holding the new value" do
      edits = [%{"op" => "update", "value" => ~s|%{name: "acme", deps: ["a" "b" "c"]}|}]

      assert answer([
               %{"id" => "a", "operation" => "edit", "text" => @doc_text, "edits" => edits}
             ]) ==
               [
                 %{
                   "id" => "a",
                   "text" => ~s|%{\n  name: "acme" # the name\n  deps: ["a" "b" "c"]\n}\n|
                 }
               ]
    end

    test "a refused edit answers why, as document/<reason>" do
      edits = [%{"op" => "delete", "path" => "[:nope]"}]

      assert answer([
               %{"id" => "a", "operation" => "edit", "text" => @doc_text, "edits" => edits}
             ]) ==
               [%{"id" => "a", "error" => "document/not-found"}]
    end
  end

  test "an encode answers the exact bytes, as base64" do
    assert answer([%{"id" => "a", "operation" => "encode", "text" => "42"}]) ==
             [%{"id" => "a", "binary" => "RFgBGCo="}]
  end

  test "every case is answered, in order" do
    ids =
      answer([
        %{"id" => "one", "operation" => "decode", "text" => "1"},
        %{"id" => "two", "operation" => "decode", "text" => "["}
      ])
      |> Enum.map(& &1["id"])

    assert ids == ["one", "two"]
  end

  describe "mix dextrin.conformance" do
    @tag :tmp_dir
    test "reads a request file and writes the answer file", %{tmp_dir: dir} do
      request = Path.join(dir, "request.json")
      answer = Path.join(dir, "answer.json")

      File.write!(
        request,
        JSON.encode!(%{"cases" => [%{"id" => "a", "operation" => "decode", "text" => "42"}]})
      )

      Mix.Tasks.Dextrin.Conformance.run([request, answer])

      assert JSON.decode!(File.read!(answer)) ==
               %{"results" => [%{"id" => "a", "canonical" => "42"}]}
    end

    test "without both paths it raises a usage error" do
      assert_raise Mix.Error, ~r/usage: mix dextrin.conformance REQUEST ANSWER/, fn ->
        Mix.Tasks.Dextrin.Conformance.run([])
      end
    end
  end
end
