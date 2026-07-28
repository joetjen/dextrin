defmodule Dextrin.Schema.MultiDocumentTest do
  @moduledoc """
  Verifies functionality that was designed and implemented early
  (DESIGN.md §4.3's "loaded up front vs. on demand is a per-system
  choice") but never actually exercised by a test until now: composing
  more than one `.dxns` document into a single registry, and the lazy
  resolver hook for on-demand schema loading.

  This also directly informs DESIGN.md §4.4.6/§10's "cross-file schema
  references" open item — the part of that problem which is just
  "combine multiple compiled schemas into one registry" already works
  today via plain API composition (`compile/3`'s `base_registry`
  parameter, or a resolver). What's still genuinely undesigned is only
  the *automatic* file-path resolution for a bare `Namespace/Name`
  reference — a real policy decision, not an implementation gap.
  """

  use ExUnit.Case, async: true

  @point_dxns ~s(%{ Point: %schema{ fields: @ordered %{ x: :integer, y: :integer } } })
  @money_dxns ~s(%{ Money: %schema{ fields: @ordered %{ amount: :decimal } } })

  test "compile/3's base_registry composes multiple documents into one registry" do
    {:ok, point_doc} = Dextrin.decode(@point_dxns)
    {:ok, money_doc} = Dextrin.decode(@money_dxns)

    {:ok, registry} = Dextrin.Schema.compile(point_doc)
    {:ok, registry} = Dextrin.Schema.compile(money_doc, registry)

    assert {:ok, %{"x" => 1, "y" => 2}} = Dextrin.decode("%Point{x: 1, y: 2}", registry: registry)
    assert {:ok, %{"amount" => amount}} = Dextrin.decode("%Money{amount: 19.99M}", registry: registry)
    assert Decimal.equal?(amount, Decimal.new("19.99"))
  end

  test "a lazy resolver loads a schema on first encounter" do
    {:ok, point_doc} = Dextrin.decode(@point_dxns)

    resolver = fn "Point" ->
      {:ok, registry} = Dextrin.Schema.compile(point_doc)
      {:ok, compiled, _registry} = Dextrin.Registry.fetch_struct_schema(registry, "Point")
      {:ok, compiled}
    end

    registry = Dextrin.Registry.new() |> Dextrin.Registry.put_resolver(resolver)

    assert {:ok, %{"x" => 1, "y" => 2}} = Dextrin.decode("%Point{x: 1, y: 2}", registry: registry)
  end

  test "an unresolvable schema name falls back to opaque, never crashes" do
    resolver = fn _name -> :unknown end
    registry = Dextrin.Registry.new() |> Dextrin.Registry.put_resolver(resolver)

    assert {:ok, %Dextrin.Struct{name: "Nonexistent", fields: {:positional, [1]}}} =
             Dextrin.decode("%Nonexistent[1]", registry: registry)
  end

  test "a resolved schema is memoized — the resolver runs once, not once per occurrence" do
    {:ok, point_doc} = Dextrin.decode(@point_dxns)
    counter = :counters.new(1, [])

    resolver = fn "Point" ->
      :counters.add(counter, 1, 1)
      {:ok, registry} = Dextrin.Schema.compile(point_doc)
      {:ok, compiled, _registry} = Dextrin.Registry.fetch_struct_schema(registry, "Point")
      {:ok, compiled}
    end

    registry = Dextrin.Registry.new() |> Dextrin.Registry.put_resolver(resolver)

    assert {:ok, [%{"x" => 1, "y" => 1}, %{"x" => 2, "y" => 2}]} =
             Dextrin.decode("[%Point{x: 1, y: 1} %Point{x: 2, y: 2}]", registry: registry)

    assert :counters.get(counter, 1) == 1
  end
end
