defmodule Dextrin.Schema.NamedTypeTest do
  @moduledoc """
  Named types (DESIGN.md §4.4.1): a `.dxns` entry that isn't a
  `%schema{}` defines a reusable name for a combination of the fixed
  type_expr vocabulary — purely `.dxns` data, no Elixir callback code,
  so any conformant reader in any language can resolve it the same way
  it already resolves `refine`/`list-of`/etc.
  """

  use ExUnit.Case, async: true

  @dxns """
  %{
    PositiveInt: {:refine :integer %{min: 1}}
    Percentage:  {:refine :float %{min: 0.0, max: 100.0}}
    Tag:         {:refine :string %{min-length: 1, max-length: 20}}

    Money: %schema{
      fields: @ordered %{
        amount:   PositiveInt
        discount: Percentage
        tags:     {:list-of Tag}
      }
    }
  }
  """

  setup do
    {:ok, schema_doc} = Dextrin.decode(@dxns)
    {:ok, registry} = Dextrin.Schema.compile(schema_doc)
    %{registry: registry}
  end

  test "a field using a named type accepts a value satisfying it", %{registry: registry} do
    assert {:ok, %{"amount" => 5, "discount" => 12.5, "tags" => ["a", "b"]}} =
             Dextrin.decode("%Money{amount: 5, discount: 12.5, tags: [\"a\", \"b\"]}", registry: registry)
  end

  test "a field using a named type rejects a value violating its refinement", %{registry: registry} do
    assert {:error, _} = Dextrin.decode("%Money{amount: 0, discount: 12.5, tags: []}", registry: registry)
    assert {:error, _} = Dextrin.decode("%Money{amount: 5, discount: 150.0, tags: []}", registry: registry)
  end

  test "a named type used inside another type_expr form (list-of) is enforced element-wise", %{registry: registry} do
    assert {:error, _} =
             Dextrin.decode(~s(%Money{amount: 5, discount: 1.0, tags: [""]}), registry: registry)

    assert {:error, _} =
             Dextrin.decode(~s(%Money{amount: 5, discount: 1.0, tags: ["#{String.duplicate("x", 21)}"]}),
               registry: registry
             )
  end

  test "named types are visible in Dextrin.Registry.type_aliases and resolvable directly", %{registry: registry} do
    assert {:ok, {:refine, {:primitive, "integer"}, %{"min" => 1}}} =
             Dextrin.Registry.fetch_type_alias(registry, "PositiveInt")

    assert :error = Dextrin.Registry.fetch_type_alias(registry, "NoSuchType")
  end

  test "a named type persists across separate compile/3 calls via base_registry" do
    {:ok, base_doc} = Dextrin.decode(~s(%{ Even: {:refine :integer %{multiple-of: 2}} }))
    {:ok, base_registry} = Dextrin.Schema.compile(base_doc)

    {:ok, doc} =
      Dextrin.decode("""
      %{
        Pair: %schema{
          fields: @ordered %{
            a: Even
            b: Even
          }
        }
      }
      """)

    {:ok, registry} = Dextrin.Schema.compile(doc, base_registry)

    assert {:ok, %{"a" => 2, "b" => 4}} = Dextrin.decode("%Pair{a: 2, b: 4}", registry: registry)
    assert {:error, _} = Dextrin.decode("%Pair{a: 3, b: 4}", registry: registry)
  end

  test "a malformed named-type entry (neither a valid schema nor a valid type_expr) is a clear compile error" do
    {:ok, doc} = Dextrin.decode(~s(%{ Broken: {:not-a-real-form 1 2} }))
    assert {:error, reason} = Dextrin.Schema.compile(doc)
    assert reason =~ "Broken"
  end

  test "a named type can't reference another named type declared in the same document (v1 boundary)" do
    {:ok, doc} =
      Dextrin.decode("""
      %{
        Base: :integer
        Derived: {:list-of Base}
      }
      """)

    {:ok, registry} = Dextrin.Schema.compile(doc)

    # Base isn't visible while Derived is being compiled (same-document,
    # no ordering guarantee to resolve it against) — the bare Symbol
    # falls back to an (opaque) struct-name reference instead, same as
    # any other unresolved identifier in a type_expr position.
    assert {:ok, {:list_of, {:reference, "Base"}}} = Dextrin.Registry.fetch_type_alias(registry, "Derived")
  end

  test "put_type_alias/3 seeds a registry by hand, without going through compile/3" do
    registry =
      Dextrin.Registry.new()
      |> Dextrin.Registry.put_type_alias("Even", {:refine, {:primitive, "integer"}, %{"multiple-of" => 2}})

    {:ok, doc} =
      Dextrin.decode("""
      %{
        Pair: %schema{
          fields: @ordered %{ a: Even }
        }
      }
      """)

    {:ok, compiled_registry} = Dextrin.Schema.compile(doc, registry)

    assert {:ok, %{"a" => 4}} = Dextrin.decode("%Pair{a: 4}", registry: compiled_registry)
    assert {:error, _} = Dextrin.decode("%Pair{a: 3}", registry: compiled_registry)
  end
end
