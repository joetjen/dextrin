defmodule Dextrin.Schema.FileResolverTest do
  @moduledoc """
  `Dextrin.Schema.FileResolver` — one reasonable, swappable answer to
  "automatically resolve `Namespace/Name` to a file path", not a
  mandated convention. Convention under test:
  `Namespace/Name` -> `<path>/Namespace.dxns`, entry `Name`; a bare
  `Name` -> `<path>/Name.dxns`, entry `Name`.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Test.Support.DecodedFields

  @tag :tmp_dir
  test "resolves a namespaced reference to <namespace>.dxns", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "geo.dxns"), """
    %{ Point: %schema{ x: :integer, y: :integer } }
    """)

    resolver = Dextrin.Schema.FileResolver.for_paths([dir])
    registry = Dextrin.Registry.new() |> Dextrin.Registry.put_resolver(resolver)

    assert {:ok, %{"x" => 1, "y" => 2}} =
             DecodedFields.of(Dextrin.decode("%geo/Point{x: 1, y: 2}", registry: registry))
  end

  @tag :tmp_dir
  test "resolves a bare (non-namespaced) reference to <name>.dxns", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "Money.dxns"), """
    %{ Money: %schema{ amount: :decimal } }
    """)

    resolver = Dextrin.Schema.FileResolver.for_paths([dir])
    registry = Dextrin.Registry.new() |> Dextrin.Registry.put_resolver(resolver)

    assert {:ok, %{"amount" => amount}} =
             DecodedFields.of(Dextrin.decode("%Money{amount: 5M}", registry: registry))

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
    %{ Point: %schema{ x: :integer, y: :integer } }
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
    %{ Money: %schema{ amount: :decimal } }
    """)

    resolver = Dextrin.Schema.FileResolver.for_paths([first, second])
    registry = Dextrin.Registry.new() |> Dextrin.Registry.put_resolver(resolver)

    assert {:ok, %{"amount" => _}} =
             DecodedFields.of(Dextrin.decode("%Money{amount: 5M}", registry: registry))
  end

  # --- DXN.md §4.6: versions, and dotted names --------------------------

  defp write(dir, relative, source) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
  end

  defp resolved(dir, text) do
    registry =
      Dextrin.Registry.new()
      |> Dextrin.Registry.put_resolver(Dextrin.Schema.FileResolver.for_paths([dir]))

    Dextrin.decode(text, registry: registry)
  end

  defp category({:error, %Dextrin.Error{category: category}}), do: category

  @tag :tmp_dir
  test "a dotted, namespaced name is a directory of versioned files", %{tmp_dir: dir} do
    write(dir, "Foo/Bar/Baz-v1.dxns", "%{Baz: %schema{a: :integer}}")
    write(dir, "Foo/Bar/Baz-v2.dxns", "%{Baz: %schema(2){a: :integer, b?: :string}}")

    assert {:ok, %Dextrin.Struct{name: "Foo.Bar/Baz", version: 2}} =
             resolved(dir, "%Foo.Bar/Baz(2){a: 1}")
  end

  @tag :tmp_dir
  test "version 1's -v1 is optional", %{tmp_dir: dir} do
    write(dir, "Foo/Bar/Baz.dxns", "%{Baz: %schema{a: :integer}}")
    assert {:ok, %Dextrin.Struct{version: 1}} = resolved(dir, "%Foo.Bar/Baz{a: 1}")
  end

  @tag :tmp_dir
  test "a directory per name holds its versions", %{tmp_dir: dir} do
    write(dir, "Foo/Bar/Baz/v1.dxns", "%{Baz: %schema{a: :integer}}")
    write(dir, "Foo/Bar/Baz/v3.dxns", "%{Baz: %schema(3){a: :integer}}")
    assert {:ok, %Dextrin.Struct{version: 3}} = resolved(dir, "%Foo.Bar/Baz{a: 1}")
  end

  @tag :tmp_dir
  test "and a flat directory names them with dots", %{tmp_dir: dir} do
    write(dir, "Foo.Bar.Baz-v2.dxns", "%{Baz: %schema(2){a: :integer}}")
    assert {:ok, %Dextrin.Struct{version: 2}} = resolved(dir, "%Foo.Bar/Baz{a: 1}")
  end

  # Every version found is loaded, so an older struct reaches the
  # materializer rather than being read as the latest (DXN.md §4.8).
  @tag :tmp_dir
  test "every version is loaded, so an older struct reaches the materializer", %{tmp_dir: dir} do
    write(dir, "Foo/Bar/Baz-v1.dxns", "%{Baz: %schema{a: :integer}}")
    write(dir, "Foo/Bar/Baz-v2.dxns", "%{Baz: %schema(2){a: :integer, b?: :string}}")
    assert category(resolved(dir, "%Foo.Bar/Baz(1){a: 1}")) == "schema/no-materializer"
  end

  @tag :tmp_dir
  test "a file whose schema is not the version its name says is refused", %{tmp_dir: dir} do
    write(dir, "Foo/Bar/Baz-v2.dxns", "%{Baz: %schema(3){a: :integer}}")
    assert category(resolved(dir, "%Foo.Bar/Baz{a: 1}")) == "schema/compile"
  end

  @tag :tmp_dir
  test "one version found in two files is refused, naming both", %{tmp_dir: dir} do
    write(dir, "Foo/Bar/Baz-v2.dxns", "%{Baz: %schema(2){a: :integer}}")
    write(dir, "Foo/Bar/Baz/v2.dxns", "%{Baz: %schema(2){a: :integer}}")

    assert {:error, %Dextrin.Error{category: "schema/compile", message: message}} =
             resolved(dir, "%Foo.Bar/Baz{a: 1}")

    assert message =~ "Baz-v2.dxns"
    assert message =~ "v2.dxns"
  end

  @tag :tmp_dir
  test "and so is a versioned file beside the namespace file holding the same version", %{
    tmp_dir: dir
  } do
    write(dir, "Foo.Bar.dxns", "%{Baz: %schema(2){a: :integer}}")
    write(dir, "Foo/Bar/Baz-v2.dxns", "%{Baz: %schema(2){a: :integer}}")
    assert category(resolved(dir, "%Foo.Bar/Baz{a: 1}")) == "schema/compile"
  end

  @tag :tmp_dir
  test "the namespace file keeps working with dotted namespaces", %{tmp_dir: dir} do
    write(dir, "Foo.Bar.dxns", "%{Baz: %schema(2){a: :integer}}")
    assert {:ok, %Dextrin.Struct{version: 2}} = resolved(dir, "%Foo.Bar/Baz{a: 1}")
  end
end
