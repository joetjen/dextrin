defmodule Dextrin.Schema.StructReferenceTest do
  @moduledoc """
  B6 of `design/implementation-plan.md`: a value matches only its
  declared type, and nothing is converted to make it match (DXN.md §4.7).
  A field typed `User` accepts only a `User` struct; a map is not a
  struct.
  """

  use ExUnit.Case, async: true

  alias Dextrin.{Registry, Schema, Struct}

  defmodule UserRecord do
    @moduledoc false
    defstruct [:name]
  end

  defmodule Other do
    @moduledoc false
    defstruct [:name]
  end

  @schemas "%{User: %schema{name: :string}, Order: %schema{id: :integer, user: User}}"

  defp loaded do
    {:ok, doc} = Dextrin.decode(@schemas)
    {:ok, registry} = Schema.compile(doc, Registry.new())
    registry
  end

  describe "decoding" do
    test "a struct of the referenced name is accepted" do
      assert {:ok, _} =
               Dextrin.decode(~s|%Order{id: 1, user: %User{name: "a"}}|, registry: loaded())
    end

    test "a struct of the referenced name with no schema of its own is accepted" do
      {:ok, doc} = Dextrin.decode("%{Order: %schema{id: :integer, user: User}}")
      {:ok, registry} = Schema.compile(doc, Registry.new())

      assert {:ok, _} =
               Dextrin.decode(~s|%Order{id: 1, user: %User{name: "a"}}|, registry: registry)
    end

    test "a map is refused, however much it looks like the struct" do
      assert {:error, _} =
               Dextrin.decode(~s|%Order{id: 1, user: %{name: "a"}}|, registry: loaded())
    end

    test "and so is any other value" do
      assert {:error, _} = Dextrin.decode(~s|%Order{id: 1, user: "a"}|, registry: loaded())

      assert {:error, _} =
               Dextrin.decode(~s|%Order{id: 1, user: %Other{name: "a"}}|, registry: loaded())
    end
  end

  describe "encoding" do
    test "the registered application struct is accepted" do
      registry = Registry.put_struct_module(loaded(), "User", UserRecord)
      order = Struct.keyed("Order", [{"id", 1}, {"user", %UserRecord{name: "a"}}])
      assert {:ok, _} = Dextrin.encode(order, registry: registry)
    end

    test "a map is refused" do
      order = Struct.keyed("Order", [{"id", 1}, {"user", %{"name" => "a"}}])
      assert {:error, _} = Dextrin.encode(order, registry: loaded())
    end

    test "and so is an application struct registered for no schema, or for another" do
      registry = Registry.put_struct_module(loaded(), "User", UserRecord)
      order = Struct.keyed("Order", [{"id", 1}, {"user", %Other{name: "a"}}])
      assert {:error, _} = Dextrin.encode(order, registry: registry)
    end
  end
end
