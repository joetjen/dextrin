defmodule Dextrin.Schema.CompileDocumentsTest do
  @moduledoc """
  What `Dextrin.Schema.compile/2` takes, and `compile_all/2` (part 3 of
  ASCO's proposal, design/network-safety-and-media-types.md): a `.dxns`
  document is a map of names to schemas; several compile into one
  registry.
  """

  use ExUnit.Case, async: true

  alias Dextrin.{Registry, Schema}

  doctest Dextrin.Schema, only: [compile_all: 2]

  defp decoded(text) do
    {:ok, doc} = Dextrin.decode(text)
    doc
  end

  describe "a document that is not a map" do
    # A struct and a tuple are maps to Elixir's `is_map/1`, and crashed the
    # compiler with a Protocol.UndefinedError.
    test "is refused when it is a struct, a tuple or a list" do
      for text <- [
            "%P{a: %schema{x: :integer}}",
            "{1 2}",
            "[1]",
            "@ordered %{a: %schema{x: :integer}}"
          ] do
        assert {:error, %Dextrin.Error{category: "schema/compile", message: message}} =
                 Schema.compile(decoded(text)),
               text

        assert message =~ "a .dxns document is a map"
      end
    end
  end

  describe "compile_all/2" do
    test "compiles every document into one registry, in order" do
      {:ok, registry} =
        Schema.compile_all([
          decoded("%{Address: %schema{city: :string}}"),
          decoded("%{Person: %schema{home: Address}}")
        ])

      assert {:ok, _, _} = Registry.fetch_struct_schema(registry, "Address")
      assert {:ok, _, _} = Registry.fetch_struct_schema(registry, "Person")
    end

    test "over a base registry" do
      {:ok, base} = Schema.compile(decoded("%{A: %schema{a: :integer}}"))
      {:ok, registry} = Schema.compile_all([decoded("%{B: %schema{b: :integer}}")], base)
      assert {:ok, _, _} = Registry.fetch_struct_schema(registry, "A")
    end

    test "and refuses the first one that does not compile, saying which" do
      assert {:error, %Dextrin.Error{category: "schema/compile", message: message}} =
               Schema.compile_all([decoded("%{A: %schema{a: :integer}}"), decoded("[1]")])

      assert message =~ "document 2"
    end
  end
end
