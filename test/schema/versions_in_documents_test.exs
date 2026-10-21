defmodule Dextrin.Schema.VersionsInDocumentsTest do
  @moduledoc """
  B2 of `design/implementation-plan.md`: every struct written against a
  schema carries the version it was written with -- `%Point(2){...}` in
  text and the type name `"Point(2)"` in binary -- and that version is
  always the latest one loaded (DXNS.md §8).
  """

  use ExUnit.Case, async: true

  alias Dextrin.{Registry, Schema, Struct}

  defmodule Point do
    @moduledoc false
    defstruct [:x, :y]
  end

  defp registry(sources) do
    Enum.reduce(sources, Registry.new(), fn source, registry ->
      {:ok, doc} = Dextrin.decode(source)
      {:ok, registry} = Schema.compile(doc, registry)
      registry
    end)
    |> Registry.put_struct_module("Point", Point)
  end

  defp v1, do: "%{Point: %schema{x: :integer}}"
  defp v2, do: "%{Point: %schema(2){x: :integer, y?: :integer}}"

  describe "a struct written against a schema" do
    test "carries the latest version in text" do
      registry = registry([v1(), v2()])
      assert Dextrin.encode(%Point{x: 1, y: 2}, registry: registry) == {:ok, "%Point(2){x:1,y:2}"}
    end

    test "carries version 1 when that is the only one, so a reader never has to guess" do
      registry = registry([v1()])
      assert Dextrin.encode(%Point{x: 1}, registry: registry) == {:ok, "%Point(1){x:1}"}
    end

    test "carries it when laid out over several lines" do
      registry = registry([v1(), v2()])

      assert {:ok, "%Point(2){" <> _} =
               Dextrin.encode(%Point{x: 1, y: 2}, registry: registry, pretty: true)
    end

    test "carries it in binary, as the type name" do
      registry = registry([v1(), v2()])
      {:ok, bytes} = Dextrin.encode_binary(%Point{x: 1, y: 2}, registry: registry)

      assert Dextrin.decode_binary(bytes) ==
               {:ok, %Struct{name: "Point", version: 2, fields: {:positional, [1, 2]}}}
    end

    test "is written with the latest version even when it says an older one" do
      registry = registry([v1(), v2()])
      older = Struct.keyed("Point", [{"x", 1}], 1)
      assert Dextrin.encode(older, registry: registry) == {:ok, "%Point(2){x:1}"}
    end

    test "is written in binary in the schema's field order, whatever order its keys came in" do
      registry = registry([v1(), v2()])

      {:ok, bytes} =
        Dextrin.encode_binary(Struct.keyed("Point", [{"y", 2}, {"x", 1}]), registry: registry)

      assert {:ok, %Struct{fields: {:positional, [1, 2]}}} = Dextrin.decode_binary(bytes)
    end
  end

  describe "a struct with no schema" do
    test "keeps its own version, in binary as in text" do
      {:ok, bytes} = Dextrin.encode_binary(Struct.positional("P", [1], 3))
      assert Dextrin.decode_binary(bytes) == {:ok, Struct.positional("P", [1], 3)}
    end

    test "and has none when it was given none" do
      {:ok, bytes} = Dextrin.encode_binary(Struct.positional("P", [1]))
      assert Dextrin.decode_binary(bytes) == {:ok, Struct.positional("P", [1])}
    end
  end

  test "a binary type name whose version is not a positive integer is refused" do
    {:ok, bytes} = Dextrin.encode_binary(Struct.positional("P(0)", [1]))
    assert {:error, %Dextrin.Error{category: "binary"}} = Dextrin.decode_binary(bytes)
  end

  test "an untagged struct is read as the latest version" do
    registry = registry([v1(), "%{Point: %schema(2){x: :integer, y: :integer}}"])
    assert {:error, _} = Dextrin.decode("%Point{x: 1}", registry: registry)

    assert Dextrin.decode("%Point{x: 1, y: 2}", registry: registry) ==
             {:ok, Struct.keyed("Point", [{"x", 1}, {"y", 2}], 2)}
  end

  test "a struct reference names no version: User(2) in a type expression is a syntax error" do
    assert {:error, %Dextrin.Error{category: "syntax"}} =
             Dextrin.decode("%{P: %schema{u: User(2)}}")
  end
end
