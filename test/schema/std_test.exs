defmodule Dextrin.Schema.StdTest do
  @moduledoc """
  `Dextrin.Schema.Std` — the standard library of common named types
  (`priv/schema/std.dxns`), opt-in via `Std.registry/1` as
  `compile/3`'s `base_registry`.
  """

  use ExUnit.Case, async: true

  setup do
    {:ok, doc} =
      Dextrin.decode("""
      %{
        Widget: %schema{
          fields: @ordered %{
            count: PositiveInteger
            name:  NonEmptyString
            ratio: Percentage
            tags:  NonEmptyList
          }
        }
      }
      """)

    {:ok, registry} = Dextrin.Schema.compile(doc, Dextrin.Schema.Std.registry())
    %{registry: registry}
  end

  test "a value satisfying every standard type decodes cleanly", %{registry: registry} do
    assert {:ok, %{"count" => 3, "name" => "x", "ratio" => 50.0, "tags" => [1]}} =
             Dextrin.decode(~s(%Widget{count: 3, name: "x", ratio: 50.0, tags: [1]}),
               registry: registry
             )
  end

  test "PositiveInteger rejects zero and negative integers", %{registry: registry} do
    assert {:error, _} =
             Dextrin.decode(~s(%Widget{count: 0, name: "x", ratio: 1.0, tags: [1]}),
               registry: registry
             )

    assert {:error, _} =
             Dextrin.decode(~s(%Widget{count: -1, name: "x", ratio: 1.0, tags: [1]}),
               registry: registry
             )
  end

  test "NonEmptyString rejects the empty string", %{registry: registry} do
    assert {:error, _} =
             Dextrin.decode(~s(%Widget{count: 1, name: "", ratio: 1.0, tags: [1]}),
               registry: registry
             )
  end

  test "Percentage rejects values outside 0.0..100.0", %{registry: registry} do
    assert {:error, _} =
             Dextrin.decode(~s(%Widget{count: 1, name: "x", ratio: -0.1, tags: [1]}),
               registry: registry
             )

    assert {:error, _} =
             Dextrin.decode(~s(%Widget{count: 1, name: "x", ratio: 100.1, tags: [1]}),
               registry: registry
             )

    assert {:ok, _} =
             Dextrin.decode(~s(%Widget{count: 1, name: "x", ratio: 0.0, tags: [1]}),
               registry: registry
             )

    assert {:ok, _} =
             Dextrin.decode(~s(%Widget{count: 1, name: "x", ratio: 100.0, tags: [1]}),
               registry: registry
             )
  end

  test "NonEmptyList rejects an empty list", %{registry: registry} do
    assert {:error, _} =
             Dextrin.decode(~s(%Widget{count: 1, name: "x", ratio: 1.0, tags: []}),
               registry: registry
             )
  end

  test "the remaining standard types are registered and behave as documented" do
    registry = Dextrin.Schema.Std.registry()

    assert {:ok, {:refine, {:primitive, "integer"}, %{"min" => 0}}} =
             Dextrin.Registry.fetch_type_alias(registry, "NonNegativeInteger")

    assert {:ok, {:refine, {:primitive, "integer"}, %{"max" => -1}}} =
             Dextrin.Registry.fetch_type_alias(registry, "NegativeInteger")

    assert {:ok, {:refine, {:primitive, "integer"}, %{"max" => 0}}} =
             Dextrin.Registry.fetch_type_alias(registry, "NonPositiveInteger")

    assert {:ok, {:refine, {:primitive, "float"}, %{"exclusive-min" => min}}} =
             Dextrin.Registry.fetch_type_alias(registry, "PositiveFloat")

    assert min == 0.0

    assert {:ok, {:refine, {:primitive, "float"}, %{"min" => min}}} =
             Dextrin.Registry.fetch_type_alias(registry, "NonNegativeFloat")

    assert min == 0.0

    assert {:ok, {:refine, {:primitive, "set"}, %{"min-count" => 1}}} =
             Dextrin.Registry.fetch_type_alias(registry, "NonEmptySet")
  end

  test "registry/1 merges into an existing base_registry instead of replacing it" do
    base = Dextrin.Registry.new() |> Dextrin.Registry.put_type_alias("MyOwnType", :any)

    merged = Dextrin.Schema.Std.registry(base)

    assert {:ok, :any} = Dextrin.Registry.fetch_type_alias(merged, "MyOwnType")
    assert {:ok, _} = Dextrin.Registry.fetch_type_alias(merged, "PositiveInteger")
  end

  test "source/0 returns the checked-in .dxns text" do
    assert Dextrin.Schema.Std.source() =~ "PositiveInteger"
  end
end
