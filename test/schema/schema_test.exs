defmodule Dextrin.SchemaTest.TestPointStruct do
  @moduledoc false
  defstruct [:x, :y]
end

defmodule Dextrin.SchemaTest do
  @moduledoc """
  End-to-end schema tests: compile a `.dxns` document,
  then decode `.dxn`/`.dxnb` struct values against it, both the happy
  path and every documented violation (required fields, declared types).
  """

  use ExUnit.Case, async: true

  alias Dextrin.Test.Support.DecodedFields

  @dxns """
  %{
    Point: %schema{
        x: :integer
        y: :integer
      }
    Money: %schema{
        amount:   :decimal
        currency: {:enum :usd :eur :gbp}
        note?:    :string
      }
  }
  """

  setup do
    {:ok, schema_doc} = Dextrin.decode(@dxns)
    {:ok, registry} = Dextrin.Schema.compile(schema_doc)
    %{registry: registry}
  end

  test "a keyed struct matching its schema decodes to a generic struct at its schema's version",
       %{registry: registry} do
    assert Dextrin.decode("%Point{x: 1, y: 2}", registry: registry) ==
             {:ok,
              %Dextrin.Struct{name: "Point", version: 1, fields: {:keyed, [{"x", 1}, {"y", 2}]}}}
  end

  test "a positional struct matching its schema decodes using field order", %{registry: registry} do
    assert {:ok, %{"x" => 1, "y" => 2}} =
             DecodedFields.of(Dextrin.decode("%Point[1, 2]", registry: registry))
  end

  test "keyed fields may be written in any order — names resolve them, not position", %{
    registry: registry
  } do
    assert {:ok, %{"x" => 1, "y" => 2}} =
             DecodedFields.of(Dextrin.decode("%Point{y: 2, x: 1}", registry: registry))
  end

  test "a struct with no compiled schema still falls back to opaque", %{registry: registry} do
    assert {:ok, %Dextrin.Struct{name: "Other", fields: {:positional, [1]}}} =
             Dextrin.decode("%Other[1]", registry: registry)
  end

  test "missing required field is a decode-time error", %{registry: registry} do
    assert {:error, %Dextrin.Error{}} = Dextrin.decode("%Point{x: 1}", registry: registry)
  end

  test "optional field may be absent, and then stays absent", %{registry: registry} do
    {:ok, fields} =
      DecodedFields.of(
        Dextrin.decode(~s(%Money{amount: 19.99M, currency: :usd}), registry: registry)
      )

    refute Map.has_key?(fields, "note")
  end

  test "optional field may be present", %{registry: registry} do
    assert {:ok, %{"note" => "a gift"}} =
             DecodedFields.of(
               Dextrin.decode(~s(%Money{amount: 19.99M, currency: :usd, note: "a gift"}),
                 registry: registry
               )
             )
  end

  test "enum constraint rejects a value outside the given literals", %{registry: registry} do
    assert {:error, %Dextrin.Error{}} =
             Dextrin.decode(~s(%Money{amount: 19.99M, currency: :gbx}), registry: registry)
  end

  test "wrong field type is rejected", %{registry: registry} do
    assert {:error, %Dextrin.Error{}} =
             Dextrin.decode(~s(%Point{x: "1", y: 2}), registry: registry)
  end

  test "wrong positional field count is rejected", %{registry: registry} do
    assert {:error, %Dextrin.Error{}} = Dextrin.decode("%Point[1, 2, 3]", registry: registry)
  end

  test "schema enforcement also applies to .dxnb", %{registry: registry} do
    {:ok, value} = Dextrin.decode("%Point{x: 1, y: 2}", registry: registry)
    assert {:ok, encoded} = Dextrin.encode_binary(value)

    assert {:ok, %{"x" => 1, "y" => 2}} =
             DecodedFields.of(Dextrin.decode_binary(encoded, registry: registry))
  end

  test "Dextrin.Schema.validate/3 checks an already-decoded opaque struct", %{registry: registry} do
    opaque = Dextrin.Struct.keyed("Point", [{"x", 1}, {"y", 2}])
    assert :ok = Dextrin.Schema.validate(opaque, registry, "Point")

    bad = Dextrin.Struct.keyed("Point", [{"x", 1}])
    assert {:error, _reason} = Dextrin.Schema.validate(bad, registry, "Point")
  end

  test "validate/3 rejects anything that isn't a Dextrin.Struct named after the schema", %{
    registry: registry
  } do
    assert {:error, %Dextrin.Error{message: message, category: "schema/type-mismatch"}} =
             Dextrin.Schema.validate(%{"x" => 1}, registry, "Point")

    assert message =~ "expected a Dextrin.Struct named"

    wrong_name = Dextrin.Struct.keyed("NotPoint", [{"x", 1}, {"y", 2}])
    assert {:error, _} = Dextrin.Schema.validate(wrong_name, registry, "Point")
  end

  test "validate/3 and validate_encode/3 both report an unregistered schema name clearly", %{
    registry: registry
  } do
    opaque = Dextrin.Struct.keyed("Ghost", [{"x", 1}])

    assert {:error, %Dextrin.Error{message: message}} =
             Dextrin.Schema.validate(opaque, registry, "Ghost")

    assert message =~ "no compiled schema registered"

    assert {:error, %Dextrin.Error{message: message}} =
             Dextrin.Schema.validate_encode(%{"x" => 1}, registry, "Ghost")

    assert message =~ "no compiled schema registered"
  end

  test "a registered materializer produces a nicer decoded shape instead of the generic field map",
       %{
         registry: registry
       } do
    registry =
      Dextrin.Registry.put_struct_materializer(registry, "Point", fn "Point",
                                                                     1,
                                                                     %{"x" => x, "y" => y} ->
        {:ok, %Dextrin.SchemaTest.TestPointStruct{x: x, y: y}}
      end)

    assert {:ok, %Dextrin.SchemaTest.TestPointStruct{x: 1, y: 2}} =
             Dextrin.decode("%Point{x: 1, y: 2}", registry: registry)
  end

  describe "the %field{...} escape hatch" do
    test "default: supplies a value when the (optional) field is absent" do
      dxns = """
      %{
        Widget: %schema{
            count?: %field{type: :integer, default: 0, description: "how many"}
          }
      }
      """

      {:ok, doc} = Dextrin.decode(dxns)
      {:ok, registry} = Dextrin.Schema.compile(doc)

      assert {:ok, %{"count" => 0}} =
               DecodedFields.of(Dextrin.decode("%Widget{}", registry: registry))

      assert {:ok, %{"count" => 5}} =
               DecodedFields.of(Dextrin.decode("%Widget{count: 5}", registry: registry))
    end

    test "%field{} with no explicit type: defaults to :any" do
      dxns = """
      %{ Widget: %schema{ value: %field{description: "whatever"} } }
      """

      {:ok, doc} = Dextrin.decode(dxns)
      {:ok, registry} = Dextrin.Schema.compile(doc)

      assert {:ok, %{"value" => 1}} =
               DecodedFields.of(Dextrin.decode("%Widget{value: 1}", registry: registry))

      assert {:ok, %{"value" => "x"}} =
               DecodedFields.of(Dextrin.decode(~s(%Widget{value: "x"}), registry: registry))
    end
  end

  test "a %schema{} entry given positionally (not keyed) fails to compile with a clear error" do
    {:ok, doc} = Dextrin.decode("%{ Point: %schema[1, 2] }")

    assert {:error, %Dextrin.Error{category: "schema/compile", message: message}} =
             Dextrin.Schema.compile(doc)

    assert message =~ "lists its fields by name"
  end

  test "an unrecognized type expression nested inside {:one-of ...} fails to compile", %{
    registry: registry
  } do
    dxns = """
    %{ Bad: %schema{ v: {:one-of :integer :not-a-real-type} } }
    """

    {:ok, doc} = Dextrin.decode(dxns)
    assert {:error, %Dextrin.Error{message: message}} = Dextrin.Schema.compile(doc, registry)
    assert message =~ "unrecognized type expression"
  end

  describe "a .dxns document's entry name may come from any map-key form" do
    test "a bare symbol key (arrow form)" do
      {:ok, doc} = Dextrin.decode("%{ sym => %schema{ x: :integer } }")
      assert {:ok, registry} = Dextrin.Schema.compile(doc)

      assert {:ok, %Dextrin.Schema.Compiled{name: "sym"}, _registry} =
               Dextrin.Registry.fetch_struct_schema(registry, "sym")
    end

    test "a string key (arrow form)" do
      {:ok, doc} =
        Dextrin.decode(~s(%{ "Point" => %schema{ x: :integer } }))

      assert {:ok, registry} = Dextrin.Schema.compile(doc)

      assert {:ok, %Dextrin.Schema.Compiled{name: "Point"}, _registry} =
               Dextrin.Registry.fetch_struct_schema(registry, "Point")
    end
  end
end
