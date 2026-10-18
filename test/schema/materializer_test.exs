defmodule Dextrin.Schema.MaterializerTest do
  @moduledoc """
  B4 of `design/implementation-plan.md`: one materializer per schema,
  `(schema_name, version, fields)` with string-keyed fields, called for
  every decoded struct of its schema whatever the version, its result
  validated against the latest schema (DXN.md §4.8). Without one, the
  latest version comes back as a generic `Dextrin.Struct`.
  """

  use ExUnit.Case, async: true

  alias Dextrin.{Registry, Schema, Struct}

  defmodule UserRecord do
    @moduledoc false
    defstruct [:name, :email]
  end

  @v1 "%{User: %schema{name: :string}}"
  @v2 "%{User: %schema(2){name: :string, email?: :string}}"
  @event "%{Event: %schema{kind: :keyword, user: User}}"

  defp loaded(sources) do
    Enum.reduce(sources, Registry.new(), fn source, registry ->
      {:ok, doc} = Dextrin.decode(source)
      {:ok, registry} = Schema.compile(doc, registry)
      registry
    end)
  end

  defp category({:error, %Dextrin.Error{category: category}}), do: category

  describe "without a materializer" do
    test "the latest version comes back as a generic struct, at the latest version" do
      assert Dextrin.decode(~s|%User{name: "a"}|, registry: loaded([@v1, @v2])) ==
               {:ok, Struct.keyed("User", [{"name", "a"}], 2)}
    end

    test "its fields are in the schema's order, and an absent optional field stays absent" do
      assert Dextrin.decode(~s|%User(2){email: "e", name: "a"}|, registry: loaded([@v2])) ==
               {:ok, Struct.keyed("User", [{"name", "a"}, {"email", "e"}], 2)}
    end

    test "and it is written back exactly as it was read" do
      registry = loaded([@v2])
      {:ok, user} = Dextrin.decode(~s|%User(2){name: "a", email: "e"}|, registry: registry)
      assert Dextrin.encode(user, registry: registry) == {:ok, ~s|%User(2){name:"a",email:"e"}|}
    end
  end

  describe "a materializer" do
    test "is called with the schema's name, the version and string-keyed fields" do
      registry =
        loaded([@v2])
        |> Registry.put_struct_materializer("User", fn name, version, fields ->
          send(self(), {:called, name, version, fields})
          {:ok, %{"name" => fields["name"]}}
        end)

      assert {:ok, %{"name" => "a"}} = Dextrin.decode(~s|%User(2){name: "a"}|, registry: registry)
      assert_received {:called, "User", 2, %{"name" => "a"}}
    end

    test "upgrades an older version, and is called for every version alike" do
      registry =
        loaded([@v1, @v2])
        |> Registry.put_struct_materializer("User", fn "User", version, fields ->
          {:ok, Map.put_new(fields, "email", "v#{version}@example.com")}
        end)

      assert Dextrin.decode(~s|%User(1){name: "a"}|, registry: registry) ==
               {:ok, %{"name" => "a", "email" => "v1@example.com"}}

      assert Dextrin.decode(~s|%User(2){name: "a"}|, registry: registry) ==
               {:ok, %{"name" => "a", "email" => "v2@example.com"}}
    end

    test "has its result validated against the latest schema" do
      registry =
        loaded([@v1, @v2])
        |> Registry.put_struct_materializer("User", fn _name, _version, _fields ->
          {:ok, %{"email" => "e"}}
        end)

      assert category(Dextrin.decode(~s|%User(1){name: "a"}|, registry: registry)) ==
               "schema/materializer"
    end

    test "that refuses makes the decode refuse" do
      registry =
        loaded([@v2])
        |> Registry.put_struct_materializer("User", fn _name, _version, _fields ->
          {:error, "not today"}
        end)

      assert category(Dextrin.decode(~s|%User(2){name: "a"}|, registry: registry)) ==
               "schema/materializer"
    end

    test "runs bottom-up: an outer struct's materializer sees the inner one already built" do
      registry =
        loaded([@v2, @event])
        |> Registry.put_struct_module("User", UserRecord)
        |> Registry.put_struct_materializer("User", fn "User", _version, fields ->
          {:ok, %UserRecord{name: fields["name"], email: fields["email"]}}
        end)
        |> Registry.put_struct_materializer("Event", fn "Event", _version, fields ->
          send(self(), {:event_user, fields["user"]})
          {:ok, fields}
        end)

      assert {:ok, _} =
               Dextrin.decode(~s|%Event{kind: :login, user: %User(2){name: "a", email: "e"}}|,
                 registry: registry
               )

      assert_received {:event_user, %UserRecord{name: "a", email: "e"}}
    end

    test "works the same from binary" do
      registry =
        loaded([@v2])
        |> Registry.put_struct_materializer("User", fn "User", 2, fields -> {:ok, fields} end)

      {:ok, bytes} = Dextrin.encode_binary(Struct.positional("User", ["a", "e"], 2))

      assert Dextrin.decode_binary(bytes, registry: registry) ==
               {:ok, %{"name" => "a", "email" => "e"}}
    end
  end
end
