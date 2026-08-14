defmodule Dextrin.Schema.ReferenceTypeTest do
  @moduledoc """
  `{:reference, name}` type-checking: a field typed as a struct
  reference must reject a value that's a *different*, otherwise-valid
  struct — even when that struct has its own registered schema and
  materializes successfully on its own terms. Enforced via
  `Dextrin.Schema.Validated`, an internal provenance wrapper
  `Dextrin.Schema.Validator.materialize/4` produces and
  `Validated.strip/1` removes before any value reaches a caller. The
  same wrapper is also what lets encode-time validation fully recurse
  into a referenced value's own schema, not just confirm its type.
  """

  use ExUnit.Case, async: true

  defmodule NamedAddress do
    @moduledoc false
    defstruct [:street]
  end

  @dxns """
  %{
    Address: %schema{ fields: @ordered %{ street: :string } }
    Company: %schema{ fields: @ordered %{ ein: :string } }
    Person: %schema{
      fields: @ordered %{
        home:  Address
        homes: {:list-of Address}
      }
    }
  }
  """

  setup do
    {:ok, doc} = Dextrin.decode(@dxns)
    {:ok, registry} = Dextrin.Schema.compile(doc)
    %{registry: registry}
  end

  test "a struct with its own registered schema is rejected where a different struct is required",
       %{
         registry: registry
       } do
    assert {:error, %Dextrin.Error{}} =
             Dextrin.decode(~s(%Person{home: %Company{ein: "1"}, homes: []}), registry: registry)
  end

  test "the correct struct is still accepted", %{registry: registry} do
    assert {:ok, %{home: %{street: "Main St"}, homes: []}} =
             Dextrin.decode(~s(%Person{home: %Address{street: "Main St"}, homes: []}),
               registry: registry
             )
  end

  test "an unregistered (opaque) struct is still rejected by its own name, as before", %{
    registry: registry
  } do
    assert {:error, %Dextrin.Error{}} =
             Dextrin.decode(~s(%Person{home: %SomeOtherThing{x: 1}, homes: []}),
               registry: registry
             )
  end

  test "the wrong struct nested inside a list-of reference is also rejected", %{
    registry: registry
  } do
    assert {:error, %Dextrin.Error{}} =
             Dextrin.decode(
               ~s(%Person{home: %Address{street: "A"}, homes: [%Address{street: "A"}, %Company{ein: "1"}]}),
               registry: registry
             )
  end

  test "a list-of reference with every element correct still succeeds", %{registry: registry} do
    assert {:ok, %{homes: [%{street: "A"}, %{street: "B"}]}} =
             Dextrin.decode(
               ~s(%Person{home: %Address{street: "A"}, homes: [%Address{street: "A"}, %Address{street: "B"}]}),
               registry: registry
             )
  end

  test "schema enforcement for references also applies to .dxnb" do
    {:ok, doc} = Dextrin.decode(@dxns)
    {:ok, registry} = Dextrin.Schema.compile(doc)

    wrong =
      %Dextrin.Struct{
        name: "Person",
        fields:
          {:positional, [%Dextrin.Struct{name: "Company", fields: {:positional, ["1"]}}, []]}
      }

    # validate: false -- deliberately building invalid wire bytes here
    # to exercise the *decode*-side check below; encode's own
    # automatic validation would otherwise catch this exact mismatch
    # before it ever became bytes.
    assert {:ok, bin} = Dextrin.encode_binary(wrong, registry: registry, validate: false)
    assert {:error, %Dextrin.Error{}} = Dextrin.decode_binary(bin, registry: registry)
  end

  test "a materializer producing a real Elixir struct never leaks the internal provenance wrapper" do
    {:ok, doc} = Dextrin.decode(@dxns)

    registry =
      Dextrin.Registry.new()
      |> Dextrin.Registry.put_struct_materializer("Address", fn %{street: s} ->
        {:ok, %NamedAddress{street: s}}
      end)

    {:ok, registry} = Dextrin.Schema.compile(doc, registry)

    assert {:ok, %NamedAddress{street: "A"}} =
             Dextrin.decode(~s(%Address{street: "A"}), registry: registry)

    assert {:ok, %{home: %NamedAddress{street: "A"}, homes: [%NamedAddress{street: "B"}]}} =
             Dextrin.decode(
               ~s(%Person{home: %Address{street: "A"}, homes: [%Address{street: "B"}]}),
               registry: registry
             )
  end

  test "a struct at the document root with no enclosing schema at all is still stripped cleanly",
       %{
         registry: registry
       } do
    assert {:ok, [%{street: "A"}, %{ein: "1"}]} =
             Dextrin.decode(~s([%Address{street: "A"}, %Company{ein: "1"}]), registry: registry)

    assert {:ok, %{street: "A"}} =
             Dextrin.decode(~s(%Address{street: "A"}), registry: registry)
  end

  test "encode-time reference checking now recurses fully into the referenced value's own schema",
       %{
         registry: registry
       } do
    right =
      Dextrin.Struct.keyed("Person", [
        {"home", Dextrin.Struct.keyed("Address", [{"street", "A"}])},
        {"homes", []}
      ])

    assert {:ok, _} = Dextrin.encode(right, registry: registry)

    wrong_name =
      Dextrin.Struct.keyed("Person", [
        {"home", Dextrin.Struct.keyed("Company", [{"ein", "1"}])},
        {"homes", []}
      ])

    assert {:error, %Dextrin.Error{}} = Dextrin.encode(wrong_name, registry: registry)

    # right name, but Address's own field is the wrong type -- this
    # used to be undetectable at encode time (shape-only checking);
    # now it's caught, same as decode already would.
    internally_invalid =
      Dextrin.Struct.keyed("Person", [
        {"home", Dextrin.Struct.keyed("Address", [{"street", 123}])},
        {"homes", []}
      ])

    assert {:error, %Dextrin.Error{message: message}} =
             Dextrin.encode(internally_invalid, registry: registry)

    assert message =~ "Address"
  end
end
