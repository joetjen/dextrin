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
    assert {:ok, %{x: 1, y: 2}} = Dextrin.decode("%Point{x: 1, y: 2}", registry: registry)
  end

  test "the default (no-materializer) field map is atom-keyed regardless of the payload's own trusted: setting",
       %{registry: registry} do
    # Field names come from the compiled schema, a fixed vocabulary the
    # developer wrote down — never the untrusted payload being decoded
    # — so atomizing them is safe (see resolve_fields/3) and produces
    # the same key shape a materializer's own input already has,
    # independent of trusted:.
    assert {:ok, %{x: 1, y: 2}} = Dextrin.decode("%Point{x: 1, y: 2}", registry: registry)

    assert {:ok, %{x: 1, y: 2}} =
             Dextrin.decode("%Point{x: 1, y: 2}", registry: registry, trusted: false)
  end

  test "a positional struct matching its schema decodes using field order", %{registry: registry} do
    assert {:ok, %{x: 1, y: 2}} = Dextrin.decode("%Point[1, 2]", registry: registry)
  end

  test "keyed fields may be written in any order — names resolve them, not position", %{
    registry: registry
  } do
    assert {:ok, %{x: 1, y: 2}} = Dextrin.decode("%Point{y: 2, x: 1}", registry: registry)
  end

  test "a struct with no compiled schema still falls back to opaque", %{registry: registry} do
    assert {:ok, %Dextrin.Struct{name: "Other", fields: {:positional, [1]}}} =
             Dextrin.decode("%Other[1]", registry: registry)
  end

  test "missing required field is a decode-time error", %{registry: registry} do
    assert {:error, %Dextrin.Error{}} = Dextrin.decode("%Point{x: 1}", registry: registry)
  end

  test "optional field may be absent", %{registry: registry} do
    assert {:ok, %{note: nil}} =
             Dextrin.decode(~s(%Money{amount: 19.99M, currency: :usd}), registry: registry)
             |> then(fn {:ok, m} -> {:ok, Map.take(m, [:note])} end)
  end

  test "optional field may be present", %{registry: registry} do
    assert {:ok, %{note: "a gift"}} =
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
    assert {:ok, %{x: 1, y: 2}} = Dextrin.decode_binary(encoded, registry: registry)
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
    assert {:error, message} = Dextrin.Schema.validate(%{"x" => 1}, registry, "Point")
    assert message =~ "expected a Dextrin.Struct named"

    wrong_name = Dextrin.Struct.keyed("NotPoint", [{"x", 1}, {"y", 2}])
    assert {:error, _} = Dextrin.Schema.validate(wrong_name, registry, "Point")
  end

  test "validate/3 and validate_encode/3 both report an unregistered schema name clearly", %{
    registry: registry
  } do
    opaque = Dextrin.Struct.keyed("Ghost", [{"x", 1}])
    assert {:error, message} = Dextrin.Schema.validate(opaque, registry, "Ghost")
    assert message =~ "no compiled schema registered"

    assert {:error, message} = Dextrin.Schema.validate_encode(%{"x" => 1}, registry, "Ghost")
    assert message =~ "no compiled schema registered"
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

  describe "the %field{...} escape hatch" do
    test "default: supplies a value when the (optional) field is absent" do
      dxns = """
      %{
        Widget: %schema{
          fields: @ordered %{
            count?: %field{type: :integer, default: 0, description: "how many"}
          }
        }
      }
      """

      {:ok, doc} = Dextrin.decode(dxns)
      {:ok, registry} = Dextrin.Schema.compile(doc)

      assert {:ok, %{count: 0}} = Dextrin.decode("%Widget{}", registry: registry)
      assert {:ok, %{count: 5}} = Dextrin.decode("%Widget{count: 5}", registry: registry)
    end

    test "%field{} with no explicit type: defaults to :any" do
      dxns = """
      %{ Widget: %schema{ fields: @ordered %{ value: %field{description: "whatever"} } } }
      """

      {:ok, doc} = Dextrin.decode(dxns)
      {:ok, registry} = Dextrin.Schema.compile(doc)

      assert {:ok, %{value: 1}} = Dextrin.decode("%Widget{value: 1}", registry: registry)

      assert {:ok, %{value: "x"}} =
               Dextrin.decode(~s(%Widget{value: "x"}), registry: registry)
    end
  end

  describe "refine-fn: cross-field validation" do
    @range_dxns """
    %{
      DateRange: %schema{
        refine-fn: date-range/valid
        fields: @ordered %{ starts: :date, ends: :date }
      }
    }
    """

    test "a passing predicate lets a value through" do
      predicates = %{
        "date-range/valid" => fn %{starts: s, ends: e} ->
          if Date.compare(s, e) != :gt, do: :ok, else: {:error, "starts must not be after ends"}
        end
      }

      {:ok, doc} = Dextrin.decode(@range_dxns)
      {:ok, registry} = Dextrin.Schema.compile(doc, Dextrin.Registry.new(), predicates)

      assert {:ok, %{starts: _, ends: _}} =
               Dextrin.decode(~s(%DateRange{starts: ~D[2024-01-01], ends: ~D[2024-06-01]}),
                 registry: registry
               )
    end

    test "a failing predicate rejects the value with its own message" do
      predicates = %{
        "date-range/valid" => fn %{starts: s, ends: e} ->
          if Date.compare(s, e) != :gt, do: :ok, else: {:error, "starts must not be after ends"}
        end
      }

      {:ok, doc} = Dextrin.decode(@range_dxns)
      {:ok, registry} = Dextrin.Schema.compile(doc, Dextrin.Registry.new(), predicates)

      assert {:error, %Dextrin.Error{message: message}} =
               Dextrin.decode(~s(%DateRange{starts: ~D[2024-06-01], ends: ~D[2024-01-01]}),
                 registry: registry
               )

      assert message =~ "starts must not be after ends"
    end

    test "an unresolvable refine-fn name fails to compile with a clear error" do
      assert {:error, message} = Dextrin.Schema.compile(elem(Dextrin.decode(@range_dxns), 1))
      assert message =~ "date-range/valid"
      assert message =~ "not found"
    end
  end

  test "a schema whose fields: isn't an @ordered map fails to compile with a clear error" do
    {:ok, doc} = Dextrin.decode("%{ Broken: %schema{ fields: %{ x: :integer } } }")
    assert {:error, message} = Dextrin.Schema.compile(doc)
    assert message =~ "@ordered"
  end

  test "a %schema{} entry given positionally (not keyed) fails to compile with a clear error" do
    {:ok, doc} = Dextrin.decode("%{ Point: %schema[1, 2] }")
    assert {:error, message} = Dextrin.Schema.compile(doc)
    assert message =~ "expected a %schema{} entry"
  end

  test "an unrecognized type expression nested inside {:one-of ...} fails to compile", %{
    registry: registry
  } do
    dxns = """
    %{ Bad: %schema{ fields: @ordered %{ v: {:one-of :integer :not-a-real-type} } } }
    """

    {:ok, doc} = Dextrin.decode(dxns)
    assert {:error, message} = Dextrin.Schema.compile(doc, registry)
    assert message =~ "unrecognized type expression"
  end

  test "forbidden: accepts keyword-literal entries too, not just bare symbols", %{
    registry: registry
  } do
    dxns = """
    %{ Legacy: %schema{ forbidden: [:legacy_amount_cents], fields: @ordered %{ x: :integer } } }
    """

    {:ok, doc} = Dextrin.decode(dxns)
    assert {:ok, _registry} = Dextrin.Schema.compile(doc, registry)
  end

  describe "a .dxns document's entry name may come from any map-key form" do
    test "a bare symbol key (arrow form)" do
      {:ok, doc} = Dextrin.decode("%{ sym => %schema{ fields: @ordered %{ x: :integer } } }")
      assert {:ok, registry} = Dextrin.Schema.compile(doc)

      assert {:ok, %Dextrin.Schema.Compiled{name: "sym"}, _registry} =
               Dextrin.Registry.fetch_struct_schema(registry, "sym")
    end

    test "a string key (arrow form)" do
      {:ok, doc} =
        Dextrin.decode(~s(%{ "Point" => %schema{ fields: @ordered %{ x: :integer } } }))

      assert {:ok, registry} = Dextrin.Schema.compile(doc)

      assert {:ok, %Dextrin.Schema.Compiled{name: "Point"}, _registry} =
               Dextrin.Registry.fetch_struct_schema(registry, "Point")
    end
  end
end
