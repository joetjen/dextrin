defmodule Dextrin.Schema.ExtraFieldsTest do
  @moduledoc """
  B5 of `design/implementation-plan.md`: a struct guarantees its declared
  fields and may carry more (DXN.md §1.2, §2.3, §4.7). Extra fields are
  entries in text -- after the items of a positional struct -- and one
  trailing tag-215 map in binary. An extra never shadows a declared
  field, its key follows the map-key rule, and `strict: true` refuses
  extras on a schema-backed struct.
  """

  use ExUnit.Case, async: true

  alias Dextrin.{Registry, Schema, Struct}

  @user "%{User: %schema(2){name: :string, email?: :string}}"

  defp loaded(source) do
    {:ok, doc} = Dextrin.decode(source)
    {:ok, registry} = Schema.compile(doc, Registry.new())
    registry
  end

  defp category({:error, %Dextrin.Error{category: category}}), do: category

  defp round_trip_binary(value, opts \\ []) do
    {:ok, bytes} = Dextrin.encode_binary(value, opts)
    Dextrin.decode_binary(bytes, opts)
  end

  describe "a struct with no schema" do
    test "keeps the entries after a positional struct's items as extra fields" do
      assert {:ok,
              %Struct{
                fields: {:positional, [1, 2]},
                extra: [{"nick", "b"}, {3, %Dextrin.Keyword{name: "x"}}]
              }} =
               Dextrin.decode(~s|%P[1 2 nick: "b" 3 => :x]|)
    end

    test "keeps a keyed entry whose key is not a name as an extra field" do
      assert {:ok,
              %Struct{fields: {:keyed, [{"x", 1}]}, extra: [{3, %Dextrin.Keyword{name: "x"}}]}} =
               Dextrin.decode("%P{x: 1, 3 => :x}")
    end

    test "is written back with its extra fields, in text" do
      {:ok, value} = Dextrin.decode(~s|%P[1 2 nick: "b" 3 => :x]|)
      assert Dextrin.encode(value) == {:ok, ~s|%P[1,2,nick:"b",3=>:x]|}
      assert Dextrin.Canonical.print(value) == {:ok, ~s|%P[1 2 nick: "b" 3 => :x]|}
    end

    test "and in binary, as one trailing tag-215 map" do
      value = Struct.positional("P", [1], nil, [{"nick", "b"}])
      assert round_trip_binary(value) == {:ok, value}
    end

    test "refuses an item after an entry" do
      assert category(Dextrin.decode(~s|%P[1 nick: "b" 2]|)) == "syntax"
    end

    test "refuses an extra field whose key is not a map key" do
      assert category(Dextrin.decode("%P[1 1.5 => 2]")) == "key/not-allowed"
    end
  end

  describe "a struct with a schema" do
    test "keeps a named field its schema does not declare as an extra field" do
      assert Dextrin.decode(~s|%User(2){name: "a", nick: "b"}|, registry: loaded(@user)) ==
               {:ok, Struct.keyed("User", [{"name", "a"}], 2, [{"nick", "b"}])}
    end

    test "and the entries after a positional struct's items" do
      assert Dextrin.decode(~s|%User(2)["a" "e" nick: "b"]|, registry: loaded(@user)) ==
               {:ok, Struct.keyed("User", [{"name", "a"}, {"email", "e"}], 2, [{"nick", "b"}])}
    end

    test "hands its extra fields to the materializer with the declared ones" do
      registry =
        loaded(@user)
        |> Registry.put_struct_materializer("User", fn "User", 2, fields -> {:ok, fields} end)

      assert Dextrin.decode(~s|%User(2){name: "a", nick: "b"}|, registry: registry) ==
               {:ok, %{"name" => "a", "nick" => "b"}}
    end

    test "carries them through binary in the tag-215 item" do
      registry = loaded(@user)
      value = Struct.keyed("User", [{"name", "a"}, {"email", "e"}], 2, [{"nick", "b"}])
      assert round_trip_binary(value, registry: registry) == {:ok, value}
    end

    test "refuses an extra field that shadows a declared one, in text" do
      assert category(
               Dextrin.decode(~s|%User(2){name: "a", "name" => "b"}|, registry: loaded(@user))
             ) ==
               "schema/shadowed-field"
    end

    test "and in binary" do
      {:ok, bytes} =
        Dextrin.encode_binary(Struct.positional("User", ["a", "e"], 2, [{"name", "b"}]))

      assert category(Dextrin.decode_binary(bytes, registry: loaded(@user))) ==
               "schema/shadowed-field"
    end

    test "and on the way out" do
      shadowing = Struct.keyed("User", [{"name", "a"}], 2, [{"name", "b"}])
      assert {:error, %Dextrin.Error{}} = Dextrin.encode(shadowing, registry: loaded(@user))
    end

    test "refuses every extra field when the decode is strict" do
      assert category(
               Dextrin.decode(~s|%User(2){name: "a", nick: "b"}|,
                 registry: loaded(@user),
                 strict: true
               )
             ) == "schema/undeclared-field"

      assert {:ok, _} =
               Dextrin.decode(~s|%User(2){name: "a"}|, registry: loaded(@user), strict: true)
    end
  end
end
