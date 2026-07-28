defmodule Dextrin.SchemaTest.TestPointStruct do
  @moduledoc false
  defstruct [:x, :y]
end

defmodule Dextrin.SchemaTest do
  @moduledoc """
  End-to-end schema tests: compile a `.dxns` document,
  then decode `.dxn`/`.dxnb` struct values against it, both the happy
  path and every documented violation (required/closed/forbidden).
  """

  use ExUnit.Case, async: true

  @dxns """
  %{
    Point: %schema{
      fields: @ordered %{
        x: :integer
        y: :integer
      }
    }
    Money: %schema{
      closed:    true
      forbidden: [legacy_amount_cents]
      fields: @ordered %{
        amount:   :decimal
        currency: {:enum :usd :eur :gbp}
        note?:    :string
      }
    }
  }
  """

  setup do
    {:ok, schema_doc} = Dextrin.decode(@dxns)
    {:ok, registry} = Dextrin.Schema.compile(schema_doc)
    %{registry: registry}
  end

  test "a keyed struct matching its schema decodes to a field map", %{registry: registry} do
    assert {:ok, %{"x" => 1, "y" => 2}} = Dextrin.decode("%Point{x: 1, y: 2}", registry: registry)
  end

  test "a positional struct matching its schema decodes using field order", %{registry: registry} do
    assert {:ok, %{"x" => 1, "y" => 2}} = Dextrin.decode("%Point[1, 2]", registry: registry)
  end

  test "keyed fields may be written in any order — names resolve them, not position", %{
    registry: registry
  } do
    assert {:ok, %{"x" => 1, "y" => 2}} = Dextrin.decode("%Point{y: 2, x: 1}", registry: registry)
  end

  test "a struct with no compiled schema still falls back to opaque", %{registry: registry} do
    assert {:ok, %Dextrin.Struct{name: "Other", fields: {:positional, [1]}}} =
             Dextrin.decode("%Other[1]", registry: registry)
  end

  test "missing required field is a decode-time error", %{registry: registry} do
    assert {:error, %Dextrin.Error{}} = Dextrin.decode("%Point{x: 1}", registry: registry)
  end

  test "optional field may be absent", %{registry: registry} do
    assert {:ok, %{"note" => nil}} =
             Dextrin.decode(~s(%Money{amount: 19.99M, currency: :usd}), registry: registry)
             |> then(fn {:ok, m} -> {:ok, Map.take(m, ["note"])} end)
  end

  test "optional field may be present", %{registry: registry} do
    assert {:ok, %{"note" => "a gift"}} =
             Dextrin.decode(~s(%Money{amount: 19.99M, currency: :usd, note: "a gift"}),
               registry: registry
             )
  end

  test "closed schema rejects an undeclared field", %{registry: registry} do
    assert {:error, %Dextrin.Error{}} =
             Dextrin.decode(~s(%Money{amount: 19.99M, currency: :usd, extra: 1}),
               registry: registry
             )
  end

  test "forbidden field is rejected even though the schema is closed with no such declared field",
       %{
         registry: registry
       } do
    assert {:error, %Dextrin.Error{}} =
             Dextrin.decode(~s(%Money{amount: 19.99M, currency: :usd, legacy_amount_cents: 1999}),
               registry: registry
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
    assert {:ok, %{"x" => 1, "y" => 2}} = Dextrin.decode_binary(encoded, registry: registry)
  end

  test "Dextrin.Schema.validate/3 checks an already-decoded opaque struct", %{registry: registry} do
    opaque = Dextrin.Struct.keyed("Point", [{"x", 1}, {"y", 2}])
    assert :ok = Dextrin.Schema.validate(opaque, registry, "Point")

    bad = Dextrin.Struct.keyed("Point", [{"x", 1}])
    assert {:error, _reason} = Dextrin.Schema.validate(bad, registry, "Point")
  end

  test "a registered materializer produces a nicer decoded shape instead of the generic field map",
       %{
         registry: registry
       } do
    registry =
      Dextrin.Registry.put_struct_materializer(registry, "Point", fn %{x: x, y: y} ->
        {:ok, %Dextrin.SchemaTest.TestPointStruct{x: x, y: y}}
      end)

    assert {:ok, %Dextrin.SchemaTest.TestPointStruct{x: 1, y: 2}} =
             Dextrin.decode("%Point{x: 1, y: 2}", registry: registry)
  end
end
