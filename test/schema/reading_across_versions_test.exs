defmodule Dextrin.Schema.ReadingAcrossVersionsTest do
  @moduledoc """
  B3 of `design/implementation-plan.md`: a struct is read according to
  the version it was written with, set against the versions loaded
  (DXN.md §4.8).
  """

  use ExUnit.Case, async: true

  alias Dextrin.{Registry, Schema, Struct}

  @v1 "%{User: %schema{name: :string}}"
  @v2 "%{User: %schema(2){name: :string, email?: :string}}"
  @v3 "%{User: %schema(3){name: :string, email?: :string, nick?: :string}}"

  defp loaded(sources) do
    Enum.reduce(sources, Registry.new(), fn source, registry ->
      {:ok, doc} = Dextrin.decode(source)
      {:ok, registry} = Schema.compile(doc, registry)
      registry
    end)
  end

  defp category({:error, %Dextrin.Error{category: category}}), do: category

  defp binary(struct) do
    {:ok, bytes} = Dextrin.encode_binary(struct)
    bytes
  end

  describe "the writer's version is the latest loaded" do
    test "is read with exactly that schema" do
      assert Dextrin.decode(~s|%User(3){name: "a"}|, registry: loaded([@v2, @v3])) ==
               {:ok, %{"name" => "a", "email" => nil, "nick" => nil}}
    end

    test "and its item count is exact" do
      assert {:error, _} = Dextrin.decode(~s|%User(3)["a"]|, registry: loaded([@v2, @v3]))
    end
  end

  describe "the writer's version is older than the latest loaded" do
    test "goes to the materializer, with the fields its own schema names" do
      registry =
        loaded([@v2, @v3])
        |> Registry.put_struct_materializer("User", fn fields -> {:ok, {:upgraded, fields}} end)

      assert Dextrin.decode(~s|%User(2){name: "a"}|, registry: registry) ==
               {:ok, {:upgraded, %{name: "a", email: nil}}}
    end

    test "and without one is refused, rather than read as if it were the latest" do
      result = Dextrin.decode(~s|%User(2){name: "a"}|, registry: loaded([@v2, @v3]))
      assert category(result) == "schema/no-materializer"
    end

    test "and the same goes for binary" do
      bytes = binary(Struct.positional("User", ["a", nil], 2))

      assert category(Dextrin.decode_binary(bytes, registry: loaded([@v2, @v3]))) ==
               "schema/no-materializer"
    end
  end

  describe "the writer's version is older and not loaded" do
    test "is refused, even with a materializer, which would have no field names to work with" do
      registry =
        loaded([@v2, @v3])
        |> Registry.put_struct_materializer("User", fn fields -> {:ok, fields} end)

      assert category(Dextrin.decode(~s|%User(1){name: "a"}|, registry: registry)) ==
               "schema/unknown-version"

      bytes = binary(Struct.positional("User", ["a"], 1))

      assert category(Dextrin.decode_binary(bytes, registry: registry)) ==
               "schema/unknown-version"
    end
  end

  describe "the writer's version is newer than anything loaded" do
    test "is read against the latest loaded, matching text by name" do
      assert Dextrin.decode(~s|%User(3){nick: "n", name: "a"}|, registry: loaded([@v1, @v2])) ==
               {:ok, %{"name" => "a", "email" => nil}}
    end

    test "and a field the latest requires must still be there" do
      assert {:error, _} = Dextrin.decode(~s|%User(3){email: "e"}|, registry: loaded([@v1, @v2]))
    end

    test "and binary assumes positions are unchanged, dropping the items beyond its own" do
      bytes = binary(Struct.positional("User", ["a", "e", "n"], 3))

      assert Dextrin.decode_binary(bytes, registry: loaded([@v1, @v2])) ==
               {:ok, %{"name" => "a", "email" => "e"}}
    end

    test "and fewer items leave the optional fields absent" do
      bytes = binary(Struct.positional("User", ["a"], 3))

      assert Dextrin.decode_binary(bytes, registry: loaded([@v1, @v2])) ==
               {:ok, %{"name" => "a", "email" => nil}}
    end

    # The documented risk: a newer version that reordered its fields is
    # read into the wrong ones, without an error, whenever the types agree.
    test "and a reordering is misread without an error when the types agree" do
      bytes = binary(Struct.positional("User", ["e", "a"], 3))

      assert Dextrin.decode_binary(bytes, registry: loaded([@v1, @v2])) ==
               {:ok, %{"name" => "e", "email" => "a"}}
    end
  end
end
