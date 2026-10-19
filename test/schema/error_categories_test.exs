defmodule Dextrin.Schema.ErrorCategoriesTest do
  @moduledoc """
  B9 of `design/implementation-plan.md`: every schema violation carries
  its `DXN.md` §5 category -- decoding text, decoding binary and
  encoding alike -- instead of the `syntax` or `binary` of whatever
  channel it travelled on, or none at all.
  """

  use ExUnit.Case, async: true

  alias Dextrin.{Registry, Schema, Struct}

  @user "%{User: %schema(2){name: :string, email?: :string}}"

  defp loaded(sources \\ [@user]) do
    Enum.reduce(sources, Registry.new(), fn source, registry ->
      {:ok, doc} = Dextrin.decode(source)
      {:ok, registry} = Schema.compile(doc, registry)
      registry
    end)
  end

  defp category({:error, %Dextrin.Error{category: category}}), do: category

  describe "decoding text" do
    test "a missing required field is schema/missing-field" do
      assert category(Dextrin.decode(~s|%User{email: "a"}|, registry: loaded())) ==
               "schema/missing-field"
    end

    test "and so it is when a newer version is read against the latest" do
      assert category(Dextrin.decode(~s|%User(3){email: "a"}|, registry: loaded())) ==
               "schema/missing-field"
    end

    test "a value of the wrong type is schema/type-mismatch" do
      assert category(Dextrin.decode(~s|%User{name: 1}|, registry: loaded())) ==
               "schema/type-mismatch"
    end

    test "and so it is inside another value" do
      assert category(Dextrin.decode(~s|[%User{name: 1}]|, registry: loaded())) ==
               "schema/type-mismatch"
    end

    test "a positional struct with the wrong item count is schema/field-count" do
      assert category(Dextrin.decode(~s|%User(2)["a"]|, registry: loaded())) ==
               "schema/field-count"
    end
  end

  describe "decoding binary" do
    test "a value of the wrong type is schema/type-mismatch" do
      {:ok, bytes} = Dextrin.encode_binary(Struct.positional("User", [1, "a"]))

      assert category(Dextrin.decode_binary(bytes, registry: loaded())) ==
               "schema/type-mismatch"
    end

    test "a struct with the wrong item count is schema/field-count" do
      {:ok, bytes} = Dextrin.encode_binary(Struct.positional("User", ["a"], 2))

      assert category(Dextrin.decode_binary(bytes, registry: loaded())) ==
               "schema/field-count"
    end
  end

  describe "encoding" do
    test "a value of the wrong type is schema/type-mismatch" do
      user = Struct.keyed("User", [{"name", 1}])
      assert category(Dextrin.encode(user, registry: loaded())) == "schema/type-mismatch"
      assert category(Dextrin.encode_binary(user, registry: loaded())) == "schema/type-mismatch"
    end

    test "a missing required field is schema/missing-field" do
      user = Struct.keyed("User", [{"email", "a"}])
      assert category(Dextrin.encode(user, registry: loaded())) == "schema/missing-field"
    end

    test "a positional struct with the wrong item count is schema/field-count" do
      user = Struct.positional("User", ["a"])
      assert category(Dextrin.encode(user, registry: loaded())) == "schema/field-count"
    end

    test "an extra field shadowing a declared one is schema/shadowed-field" do
      user = Struct.positional("User", ["a", "b"], nil, [{"name", "c"}])
      assert category(Dextrin.encode(user, registry: loaded())) == "schema/shadowed-field"
    end

    test "against a named schema, too" do
      assert category(Dextrin.encode(%{"name" => 1}, registry: loaded(), schema: "User")) ==
               "schema/type-mismatch"
    end
  end

  describe "encoding binary, which fills every position" do
    # nil in an optional field stays strict (Jan, 2026-10-19): a reader
    # refuses it unless the type is nilable, so a writer never puts one
    # where a field is merely absent.
    test "an absent optional field with no default is schema/missing-field" do
      {:ok, user} = Dextrin.decode(~s|%User{name: "a"}|, registry: loaded())
      assert category(Dextrin.encode_binary(user, registry: loaded())) == "schema/missing-field"
    end

    test "text leaves it out, so text has nothing to refuse" do
      {:ok, user} = Dextrin.decode(~s|%User{name: "a"}|, registry: loaded())
      assert {:ok, ~s|%User(2){name:"a"}|} = Dextrin.encode(user, registry: loaded())
    end

    test "an absent field with a default is written as its default" do
      registry =
        loaded([
          "%{User: %schema{name: :string, role?: %field{type: :string, default: \"guest\"}}}"
        ])

      user = Struct.keyed("User", [{"name", "a"}], 1)
      {:ok, bytes} = Dextrin.encode_binary(user, registry: registry)

      assert {:ok, %Struct{fields: {:keyed, [{"name", "a"}, {"role", "guest"}]}}} =
               Dextrin.decode_binary(bytes, registry: registry)
    end

    test "a nilable field written as nil reads back" do
      registry = loaded(["%{User: %schema{name: :string, email?: {:nilable :string}}}"])
      user = Struct.keyed("User", [{"name", "a"}, {"email", nil}], 1)
      {:ok, bytes} = Dextrin.encode_binary(user, registry: registry)

      assert {:ok, %Struct{fields: {:keyed, [{"name", "a"}, {"email", nil}]}}} =
               Dextrin.decode_binary(bytes, registry: registry)
    end
  end

  test "a materializer's rejected value is schema/materializer, whatever was wrong with it" do
    registry =
      Registry.put_struct_materializer(loaded(), "User", fn _name, _version, _fields ->
        {:ok, Struct.keyed("User", [{"name", 1}])}
      end)

    assert category(Dextrin.decode(~s|%User{name: "a"}|, registry: registry)) ==
             "schema/materializer"
  end
end
