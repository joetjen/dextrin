defmodule Dextrin.Schema.FileResolverTest do
  @moduledoc """
  `Dextrin.Schema.FileResolver` — one reasonable, swappable answer to
  "automatically resolve `Namespace/Name` to a file path", not a
  mandated convention. Convention under test:
  `Namespace/Name` -> `<path>/Namespace.dxns`, entry `Name`; a bare
  `Name` -> `<path>/Name.dxns`, entry `Name`.
  """

  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "resolves a namespaced reference to <namespace>.dxns", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "geo.dxns"), """
    %{ Point: %schema{ fields: @ordered %{ x: :integer, y: :integer } } }
    """)

    resolver = Dextrin.Schema.FileResolver.for_paths([dir])
    registry = Dextrin.Registry.new() |> Dextrin.Registry.put_resolver(resolver)

    assert {:ok, %{x: 1, y: 2}} =
             Dextrin.decode("%geo/Point{x: 1, y: 2}", registry: registry)
  end

  @tag :tmp_dir
  test "resolves a bare (non-namespaced) reference to <name>.dxns", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "Money.dxns"), """
    %{ Money: %schema{ fields: @ordered %{ amount: :decimal } } }
    """)

    resolver = Dextrin.Schema.FileResolver.for_paths([dir])
    registry = Dextrin.Registry.new() |> Dextrin.Registry.put_resolver(resolver)

    assert {:ok, %{amount: amount}} = Dextrin.decode("%Money{amount: 5M}", registry: registry)
    assert Decimal.equal?(amount, Decimal.new("5"))
  end

  @tag :tmp_dir
  test "a missing file falls back to opaque, never crashes", %{tmp_dir: dir} do
    resolver = Dextrin.Schema.FileResolver.for_paths([dir])
    registry = Dextrin.Registry.new() |> Dextrin.Registry.put_resolver(resolver)

    assert {:ok, %Dextrin.Struct{name: "nonexistent/Thing"}} =
             Dextrin.decode("%nonexistent/Thing[1]", registry: registry)
  end

  @tag :tmp_dir
  test "a file that exists but lacks the requested entry falls back to opaque", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "geo.dxns"), """
    %{ Point: %schema{ fields: @ordered %{ x: :integer, y: :integer } } }
    """)

    resolver = Dextrin.Schema.FileResolver.for_paths([dir])
    registry = Dextrin.Registry.new() |> Dextrin.Registry.put_resolver(resolver)

    assert {:ok, %Dextrin.Struct{name: "geo/Circle"}} =
             Dextrin.decode("%geo/Circle[1]", registry: registry)
  end

  @tag :tmp_dir
  test "searches multiple paths in order, first match wins", %{tmp_dir: dir} do
    first = Path.join(dir, "first")
    second = Path.join(dir, "second")
    File.mkdir_p!(first)
    File.mkdir_p!(second)

    File.write!(Path.join(second, "Money.dxns"), """
    %{ Money: %schema{ fields: @ordered %{ amount: :decimal } } }
    """)

    resolver = Dextrin.Schema.FileResolver.for_paths([first, second])
    registry = Dextrin.Registry.new() |> Dextrin.Registry.put_resolver(resolver)

    assert {:ok, %{amount: _}} = Dextrin.decode("%Money{amount: 5M}", registry: registry)
  end
end
