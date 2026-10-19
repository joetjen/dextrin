defmodule Dextrin.Schema.VersionedSchemaTest do
  @moduledoc """
  B1 of `design/implementation-plan.md`: each `.dxns` document describes
  one version of a schema, written `%schema(N){field: type, ...}` -- the
  body lists the fields in order, and that order is the positional order.
  Schemas are cached by name and version.
  """

  use ExUnit.Case, async: true

  alias Dextrin.{Registry, Schema}

  defp compiled!(text, registry \\ Registry.new()) do
    {:ok, doc} = Dextrin.decode(text)
    {:ok, registry} = Schema.compile(doc, registry)
    registry
  end

  defp compile(text, registry \\ Registry.new()) do
    {:ok, doc} = Dextrin.decode(text)
    Schema.compile(doc, registry)
  end

  defp field_names(registry, name, version) do
    {:ok, compiled, _} = Registry.fetch_struct_schema(registry, name, version)
    Enum.map(compiled.fields, & &1.name)
  end

  describe "the schema body" do
    test "lists the fields directly, in order" do
      registry = compiled!("%{User: %schema(3){name: :string, email: :string, id?: :uuid}}")
      assert field_names(registry, "User", 3) == ["name", "email", "id"]
    end

    test "with no header is version 1" do
      registry = compiled!("%{Point: %schema{x: :integer, y: :integer}}")
      assert {:ok, %{version: 1}, _} = Registry.fetch_struct_schema(registry, "Point", 1)
    end

    test "keeps a field's metadata in %field{}" do
      registry =
        compiled!(~s(%{P: %schema{x: %field{type: :integer, default: 0, description: "x"}}}))

      {:ok, compiled, _} = Registry.fetch_struct_schema(registry, "P", 1)
      assert [%{name: "x", default: 0, description: "x"}] = compiled.fields
    end

    test "refuses a field named twice" do
      assert {:error, %Dextrin.Error{category: "schema/compile"}} =
               compile("%{P: %schema{x: :integer, x: :string}}")
    end

    test "refuses the old fields: form, which is now a field of no known type" do
      assert {:error, %Dextrin.Error{category: "schema/compile"}} =
               compile("%{P: %schema{fields: @ordered %{x: :integer}}}")
    end
  end

  describe "versions" do
    test "load from separate documents and are kept apart" do
      registry =
        compiled!("%{User: %schema(1){name: :string}}")
        |> then(&compiled!("%{User: %schema(2){name: :string, email: :string}}", &1))

      assert field_names(registry, "User", 1) == ["name"]
      assert field_names(registry, "User", 2) == ["name", "email"]
    end

    test "without a version, the latest is answered" do
      registry =
        compiled!("%{User: %schema(2){name: :string, email: :string}}")
        |> then(&compiled!("%{User: %schema(1){name: :string}}", &1))

      assert {:ok, %{version: 2}, _} = Registry.fetch_struct_schema(registry, "User")
    end

    test "loading the same name and version twice is an error" do
      registry = compiled!("%{User: %schema(1){name: :string}}")

      assert {:error, %Dextrin.Error{category: "schema/duplicate-version"}} =
               compile("%{User: %schema(1){name: :string}}", registry)
    end

    test "replace swaps a loaded version" do
      registry = compiled!("%{User: %schema(1){name: :string}}")
      other = compiled!("%{User: %schema(1){name: :string, nick?: :string}}")
      {:ok, replacement, _} = Registry.fetch_struct_schema(other, "User", 1)

      assert {:ok, registry} = Registry.replace_struct_schema(registry, "User", replacement)
      assert field_names(registry, "User", 1) == ["name", "nick"]
    end

    test "and refuses a version that is not loaded, so a typo never adds one" do
      other = compiled!("%{User: %schema(4){name: :string}}")
      {:ok, replacement, _} = Registry.fetch_struct_schema(other, "User", 4)

      assert {:error, %Dextrin.Error{category: "schema/not-loaded"}} =
               Registry.replace_struct_schema(Registry.new(), "User", replacement)
    end
  end

  describe "a struct literal" do
    test "carries the version it was written with" do
      assert {:ok, %Dextrin.Struct{name: "P", version: 3}} = Dextrin.decode("%P(3){x: 1}")
      assert {:ok, %Dextrin.Struct{name: "P", version: 3}} = Dextrin.decode("%P(3)[1]")
    end

    test "has none when it was written without one" do
      assert {:ok, %Dextrin.Struct{version: nil}} = Dextrin.decode("%P{x: 1}")
    end

    test "is written back with its version" do
      {:ok, value} = Dextrin.decode("%P(3){x: 1}")
      assert Dextrin.encode(value) == {:ok, "%P(3){x:1}"}
      assert Dextrin.Canonical.print(value) == {:ok, "%P(3){x: 1}"}
    end

    test "refuses a version that is not a positive integer" do
      assert {:error, _} = Dextrin.decode("%P(0){x: 1}")
      assert {:error, _} = Dextrin.decode("%P(-1){x: 1}")
    end
  end
end
