defmodule Dextrin.Schema.TreeTest do
  @moduledoc """
  `Dextrin.Schema.Tree` (Jan, 2026-10-20): a directory of `.dxns` files
  read as one tree -- every entry named from its file's path (DXN.md
  §4.6), the files compiled in the order their references need, and
  every problem reported with its file and line: syntax, compiling,
  layout, and names that resolve to nothing.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Schema.Tree

  defp tree(files) do
    root = Path.join(System.tmp_dir!(), "dextrin-tree-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)

    for {path, source} <- files do
      full = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, source)
    end

    root
  end

  defp messages({:error, problems}), do: Enum.map(problems, & &1.message)

  @good %{
    "acme.common.dxns" => """
    %{
      Money: %shape{amount: :decimal, currency: Currency}
      Currency: {:enum "EUR" "USD"}
      Percentage: {:refine :decimal %{min: 0, max: 100}}
    }
    """,
    "acme/shop/Order-v2.dxns" => """
    %{
      Order: %schema(2){
        total: acme.common/Money
        discount?: acme.common/Percentage
        lines: {:list-of Line}
      }
      Line: %shape{sku: :string}
    }
    """,
    "HealthCheck.dxns" => "%{HealthCheck: %schema{ok: :boolean}}"
  }

  describe "a tree that is in order" do
    test "loads, every entry under its full name" do
      assert {:ok, registry, summary} = Tree.load([tree(@good)])
      assert summary == %{files: 3, definitions: 6}

      assert {:ok, _, _} = Dextrin.Registry.fetch_struct_schema(registry, "acme.shop/Order")
      assert {:ok, _, _} = Dextrin.Registry.fetch_struct_schema(registry, "HealthCheck")
      assert Map.has_key?(registry.type_aliases, "acme.common/Money")
    end

    test "resolves another file's named types, whatever order the files sort in" do
      {:ok, registry, _} = Tree.load([tree(@good)])

      assert {:ok, _} =
               Dextrin.decode(
                 ~s|%acme.shop/Order(2){total: %{amount: 1.50M, currency: "EUR"}, discount: 10.0M, lines: [%{sku: "a"}]}|,
                 registry: registry
               )

      assert {:error, %Dextrin.Error{category: "schema/type-mismatch"}} =
               Dextrin.decode(
                 ~s|%acme.shop/Order(2){total: %{amount: 1.50M, currency: "GBP"}, lines: []}|,
                 registry: registry
               )
    end
  end

  describe "the file resolver" do
    # Until 2026-10-20 it compiled a file on its own, so a field naming
    # another file's named type (a shape, an enum) named a struct that
    # never came.
    test "resolves another file's named types" do
      root = tree(@good)

      registry =
        Dextrin.Registry.put_resolver(
          Dextrin.Registry.new(),
          Dextrin.Schema.FileResolver.for_paths([root])
        )

      assert {:ok, _} =
               Dextrin.decode(
                 ~s|%acme.shop/Order(2){total: %{amount: 1.50M, currency: "EUR"}, discount: 10.0M, lines: []}|,
                 registry: registry
               )

      assert {:error, %Dextrin.Error{category: "schema/type-mismatch"}} =
               Dextrin.decode(
                 ~s|%acme.shop/Order(2){total: %{amount: 1.50M, currency: "GBP"}, lines: []}|,
                 registry: registry
               )
    end
  end

  describe "problems" do
    # The line is the parser's: today the document's start, where its
    # parse failed as a whole, not the bracket that broke it.
    test "a syntax error, with the line its parser gives" do
      root = tree(%{"a.dxns" => "%{\n  A: :integer\n  B: [\n}\n"})
      assert {:error, [%{file: "a.dxns", line: line, message: message}]} = Tree.load([root])
      assert is_integer(line) and line >= 1
      assert message =~ "does not match"
    end

    test "a definition that does not compile, with its line" do
      root = tree(%{"a.dxns" => "%{\n  A: :integer\n  B: {:wibble :integer}\n}\n"})
      assert {:error, [%{file: "a.dxns", line: 3}]} = Tree.load([root])
    end

    test "a name that resolves to nothing" do
      root = tree(%{"a.dxns" => "%{A: %schema{m: acme.comon/Money, n: Nowhere}}"})
      assert {:error, problems} = Tree.load([root])
      assert Enum.any?(messages({:error, problems}), &(&1 =~ "acme.comon/Money"))
      assert Enum.any?(messages({:error, problems}), &(&1 =~ "Nowhere"))
    end

    test "unless its namespace is declared extern" do
      root = tree(%{"a.dxns" => "%{A: %schema{m: other/Thing}}"})
      assert {:error, _} = Tree.load([root])
      assert {:ok, _, _} = Tree.load([root], extern: ["other"])
    end

    test "a versioned file holding another version" do
      root = tree(%{"Customer-v2.dxns" => "%{Customer: %schema(3){name: :string}}"})
      assert {:error, [%{file: "Customer-v2.dxns", message: message}]} = Tree.load([root])
      assert message =~ "version"
    end

    test "one version found in two files" do
      root =
        tree(%{
          "Customer-v2.dxns" => "%{Customer: %schema(2){name: :string}}",
          "Customer/v2.dxns" => "%{Customer: %schema(2){name: :string}}"
        })

      assert {:error, [%{message: message}]} = Tree.load([root])
      assert message =~ "two files"
    end

    test "every file's problems, not just the first" do
      root =
        tree(%{
          "a.dxns" => "%{A: {:wibble :integer}}",
          "b.dxns" => "%{B: [}"
        })

      assert {:error, problems} = Tree.load([root])
      assert Enum.map(problems, & &1.file) |> Enum.sort() == ["a.dxns", "b.dxns"]
    end

    test "files that need each other" do
      root =
        tree(%{
          "a.dxns" => "%{A: {:list-of b/B}}",
          "b.dxns" => "%{B: {:list-of a/A}}"
        })

      assert {:error, [%{message: message}]} = Tree.load([root])
      assert message =~ "a.dxns" and message =~ "b.dxns"
    end
  end
end
