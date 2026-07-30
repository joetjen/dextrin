defmodule Dextrin.Schema.AutomaticEncodeValidationTest do
  @moduledoc """
  Automatic, name-driven encode-time validation (chosen explicitly
  over a `schema:`-opt-only design): every
  `Dextrin.Struct` or registered application struct anywhere in a
  value being encoded is checked against its own schema, wherever it
  turns out to be — not just what a single named schema's own field
  types happen to reach. `validate: false` opts out, for deliberately
  building non-conforming data (fixtures, pass-through/relay).
  """

  use ExUnit.Case, async: true

  defmodule TestBar do
    @moduledoc false
    defstruct [:baz]
  end

  @dxns """
  %{ Bar: %schema{ fields: @ordered %{ baz: :integer } } }
  """

  setup do
    {:ok, doc} = Dextrin.decode(@dxns)
    {:ok, registry} = Dextrin.Schema.compile(doc)
    %{registry: registry}
  end

  test "a top-level Dextrin.Struct is validated with no schema: opt at all", %{registry: registry} do
    bad = Dextrin.Struct.keyed("Bar", [{"baz", true}])
    assert {:error, %Dextrin.Error{message: message}} = Dextrin.encode(bad, registry: registry)
    assert message =~ "Bar"

    good = Dextrin.Struct.keyed("Bar", [{"baz", 1}])
    assert {:ok, "%Bar{baz:1}"} = Dextrin.encode(good, registry: registry)
  end

  test "a named struct nested inside an untyped (:any) field is still caught", %{
    registry: _registry
  } do
    {:ok, doc} =
      Dextrin.decode("""
      %{
        Bar: %schema{ fields: @ordered %{ baz: :integer } }
        Holder: %schema{ fields: @ordered %{ payload: :any } }
      }
      """)

    {:ok, registry} = Dextrin.Schema.compile(doc)

    bad =
      Dextrin.Struct.keyed("Holder", [{"payload", Dextrin.Struct.keyed("Bar", [{"baz", true}])}])

    assert {:error, %Dextrin.Error{message: message}} = Dextrin.encode(bad, registry: registry)
    assert message =~ "Bar"
  end

  test "a named struct nested inside a plain, undeclared list is still caught", %{
    registry: registry
  } do
    value = %{Dextrin.Keyword.new("items") => [Dextrin.Struct.keyed("Bar", [{"baz", true}])]}

    assert {:error, %Dextrin.Error{message: message}} =
             Dextrin.encode_binary(value, registry: registry)

    assert message =~ "Bar"
  end

  test "a registered application struct is validated automatically, no schema: needed", %{
    registry: registry
  } do
    registry = Dextrin.Registry.put_struct_module(registry, "Bar", TestBar)

    bad = struct(TestBar, baz: true)
    assert {:error, message} = Dextrin.Schema.validate_encode_tree(bad, registry)
    assert message =~ "Bar"

    good = struct(TestBar, baz: 1)
    assert :ok = Dextrin.Schema.validate_encode_tree(good, registry)
  end

  test "validate: false opts out, for deliberately building non-conforming data", %{
    registry: registry
  } do
    bad = Dextrin.Struct.keyed("Bar", [{"baz", true}])
    assert {:ok, "%Bar{baz:true}"} = Dextrin.encode(bad, registry: registry, validate: false)
    assert {:ok, _bin} = Dextrin.encode_binary(bad, registry: registry, validate: false)
  end

  test "a struct with no registered schema at all is untouched, not rejected", %{
    registry: registry
  } do
    opaque = Dextrin.Struct.keyed("Unregistered", [{"anything", 1}])
    assert {:ok, "%Unregistered{anything:1}"} = Dextrin.encode(opaque, registry: registry)
  end

  test "ordinary valid data still round-trips through encode/decode", %{registry: registry} do
    value = Dextrin.Struct.keyed("Bar", [{"baz", 42}])
    assert {:ok, text} = Dextrin.encode(value, registry: registry)
    assert {:ok, decoded} = Dextrin.decode(text, registry: registry)
    assert decoded == %{"baz" => 42}
  end
end
