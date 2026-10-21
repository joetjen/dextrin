defmodule Dextrin.Schema.TypeExprTest do
  @moduledoc """
  Exercises every `type_expr` form and all 10 `refine` constraints,
  each with a passing and a failing value — coverage implemented in
  `Dextrin.Schema.TypeExpr`/`Compiler` but never actually exercised by
  a test until now.
  """

  use ExUnit.Case, async: true

  defp registry_for(type_expr_text) do
    dxns = """
    %{
      Other: %schema{ x: :integer }
      T: %schema{ v: #{type_expr_text} }
    }
    """

    {:ok, schema_doc} = Dextrin.decode(dxns)
    {:ok, registry} = Dextrin.Schema.compile(schema_doc)
    registry
  end

  defp field(registry, value_text),
    do:
      Dextrin.Test.Support.DecodedFields.of(
        Dextrin.decode("%T{v: #{value_text}}", registry: registry)
      )

  describe "type_expr forms" do
    test ":any matches anything" do
      r = registry_for(":any")
      assert {:ok, %{"v" => 1}} = field(r, "1")
      assert {:ok, %{"v" => "x"}} = field(r, ~s("x"))
      assert {:ok, %{"v" => nil}} = field(r, "nil")
    end

    test "primitive (:integer)" do
      r = registry_for(":integer")
      assert {:ok, %{"v" => 1}} = field(r, "1")
      assert {:error, %Dextrin.Error{}} = field(r, ~s("x"))
    end

    test "reference refuses any value that is not a struct -- a map is not a struct" do
      r = registry_for("Other")
      assert {:error, %Dextrin.Error{}} = field(r, "1")
      assert {:error, %Dextrin.Error{}} = field(r, ~s("anything"))
      assert {:error, %Dextrin.Error{}} = field(r, "%{x: 1}")
    end

    test "reference catches a wrong struct name on an opaque (unregistered) value" do
      # "Unregistered" has no compiled schema in this registry, so a
      # value written as %Unregistered[...] stays an opaque
      # Dextrin.Struct — its own `name` field is exactly what a
      # reference check against an opaque value *can* still verify.
      r = registry_for("Unregistered")
      assert {:ok, %{"v" => %Dextrin.Struct{name: "Unregistered"}}} = field(r, "%Unregistered[1]")
      assert {:error, %Dextrin.Error{}} = field(r, "%SomethingElse[1]")
    end

    test "{:list-of type}" do
      r = registry_for("{:list-of :integer}")
      assert {:ok, %{"v" => [1, 2, 3]}} = field(r, "[1, 2, 3]")
      assert {:error, %Dextrin.Error{}} = field(r, ~s(["a", "b"]))
    end

    test "{:set-of type}" do
      r = registry_for("{:set-of :integer}")
      assert {:ok, %{"v" => %MapSet{}}} = field(r, "@{1, 2, 3}")
      assert {:error, %Dextrin.Error{}} = field(r, ~s(@{"a"}))
    end

    test "{:tuple-of type...}" do
      r = registry_for("{:tuple-of :integer :string}")
      assert {:ok, %{"v" => %Dextrin.Tuple{items: [1, "a"]}}} = field(r, ~s({1, "a"}))
      assert {:error, %Dextrin.Error{}} = field(r, ~s({"a", 1}))
      assert {:error, %Dextrin.Error{}} = field(r, "{1}")
    end

    test "{:map-of key_type val_type}" do
      r = registry_for("{:map-of :string :integer}")
      assert {:ok, %{"v" => %{"a" => 1}}} = field(r, ~s(%{"a" => 1}))
      assert {:error, %Dextrin.Error{}} = field(r, ~s(%{"a" => "b"}))
    end

    test "{:enum literal...}" do
      r = registry_for("{:enum :a :b :c}")
      assert {:ok, %{"v" => %Dextrin.Keyword{name: "a"}}} = field(r, ":a")
      assert {:error, %Dextrin.Error{}} = field(r, ":d")
    end

    test "{:one-of type...}" do
      r = registry_for("{:one-of :integer :string}")
      assert {:ok, %{"v" => 1}} = field(r, "1")
      assert {:ok, %{"v" => "x"}} = field(r, ~s("x"))
      assert {:error, %Dextrin.Error{}} = field(r, "true")
    end

    # Jan, 2026-10-20: one-of means exactly one variant matches (JSON
    # Schema's oneOf); any-of, one or more (anyOf).
    test "{:one-of type...} refuses a value two variants match" do
      r = registry_for("{:one-of :integer {:refine :integer %{min: 0}}}")
      assert {:ok, %{"v" => -1}} = field(r, "-1")
      assert {:error, %Dextrin.Error{}} = field(r, "5")
    end

    test "{:any-of type...} takes a value one or more variants match" do
      r = registry_for("{:any-of :integer {:refine :integer %{min: 0}}}")
      assert {:ok, %{"v" => -1}} = field(r, "-1")
      assert {:ok, %{"v" => 5}} = field(r, "5")
      assert {:error, %Dextrin.Error{}} = field(r, ~s("x"))
    end

    test "{:not type} takes what the type refuses" do
      r = registry_for("{:not :string}")
      assert {:ok, %{"v" => 1}} = field(r, "1")
      assert {:error, %Dextrin.Error{}} = field(r, ~s("x"))
    end

    test ":never takes nothing at all" do
      r = registry_for(":never")
      assert {:error, %Dextrin.Error{}} = field(r, "1")
      assert {:error, %Dextrin.Error{}} = field(r, "nil")
    end

    test "they nest in each other and as element types" do
      r = registry_for("{:list-of {:one-of :string {:any-of :integer :decimal}}}")
      assert {:ok, %{"v" => ["a", 1]}} = field(r, ~s(["a" 1]))
      assert {:error, %Dextrin.Error{}} = field(r, "[true]")
    end

    test "{:array-of type}" do
      r = registry_for("{:array-of :integer}")
      assert {:ok, %{"v" => %Dextrin.Array{}}} = field(r, "@array[1 2]")
      assert {:error, %Dextrin.Error{}} = field(r, ~s(@array[1 "x"]))
      assert {:error, %Dextrin.Error{}} = field(r, "[1 2]")
    end

    test "{:ordered-map-of key value}" do
      r = registry_for("{:ordered-map-of :keyword :integer}")
      assert {:ok, %{"v" => %Dextrin.OrderedMap{}}} = field(r, "@ordered %{a: 1 b: 2}")
      assert {:error, %Dextrin.Error{}} = field(r, ~s(@ordered %{a: "x"}))
      assert {:error, %Dextrin.Error{}} = field(r, "%{a: 1}")
    end

    test "{:sorted-set-of type}" do
      r = registry_for("{:sorted-set-of :integer}")
      assert {:ok, %{"v" => %Dextrin.SortedSet{}}} = field(r, "@sorted-set @{2 1}")
      assert {:error, %Dextrin.Error{}} = field(r, ~s(@sorted-set @{1 "x"}))
      assert {:error, %Dextrin.Error{}} = field(r, "@{1 2}")
    end

    test "{:all-of type...}" do
      r = registry_for("{:all-of {:refine :integer %{min: 0}} {:refine :integer %{max: 100}}}")
      assert {:ok, %{"v" => 50}} = field(r, "50")
      assert {:error, %Dextrin.Error{}} = field(r, "-5")
      assert {:error, %Dextrin.Error{}} = field(r, "200")
    end

    test "{:nilable type}" do
      r = registry_for("{:nilable :string}")
      assert {:ok, %{"v" => nil}} = field(r, "nil")
      assert {:ok, %{"v" => "x"}} = field(r, ~s("x"))
      assert {:error, %Dextrin.Error{}} = field(r, "42")
    end

    test "{:refine type constraints}" do
      r = registry_for("{:refine :integer %{min: 0, max: 10}}")
      assert {:ok, %{"v" => 5}} = field(r, "5")
      assert {:error, %Dextrin.Error{}} = field(r, "-1")
      assert {:error, %Dextrin.Error{}} = field(r, "20")
    end

    test "struct (%schema{...} itself, exercised throughout schema_test.exs)" do
      assert {:ok, %Dextrin.Struct{name: "Other", fields: {:keyed, [{"x", 1}]}}} =
               Dextrin.decode("%Other{x: 1}", registry: registry_for(":any"))
    end
  end

  describe "refine constraints" do
    test "min" do
      r = registry_for("{:refine :integer %{min: 0}}")
      assert {:ok, _} = field(r, "0")
      assert {:error, %Dextrin.Error{}} = field(r, "-1")
    end

    test "max" do
      r = registry_for("{:refine :integer %{max: 10}}")
      assert {:ok, _} = field(r, "10")
      assert {:error, %Dextrin.Error{}} = field(r, "11")
    end

    test "exclusive-min" do
      r = registry_for("{:refine :integer %{exclusive-min: 0}}")
      assert {:ok, _} = field(r, "1")
      assert {:error, %Dextrin.Error{}} = field(r, "0")
    end

    test "exclusive-max" do
      r = registry_for("{:refine :integer %{exclusive-max: 10}}")
      assert {:ok, _} = field(r, "9")
      assert {:error, %Dextrin.Error{}} = field(r, "10")
    end

    test "multiple-of" do
      r = registry_for("{:refine :integer %{multiple-of: 5}}")
      assert {:ok, _} = field(r, "10")
      assert {:error, %Dextrin.Error{}} = field(r, "7")
    end

    test "min-length" do
      r = registry_for("{:refine :string %{min-length: 3}}")
      assert {:ok, _} = field(r, ~s("abc"))
      assert {:error, %Dextrin.Error{}} = field(r, ~s("ab"))
    end

    test "max-length" do
      r = registry_for("{:refine :string %{max-length: 3}}")
      assert {:ok, _} = field(r, ~s("abc"))
      assert {:error, %Dextrin.Error{}} = field(r, ~s("abcd"))
    end

    test "pattern" do
      r = registry_for(~s|{:refine :string %{pattern: @regex "^[a-z]+$"}}|)
      assert {:ok, _} = field(r, ~s("abc"))
      assert {:error, %Dextrin.Error{}} = field(r, ~s("ABC"))
    end

    test "min-count" do
      r = registry_for("{:refine :list %{min-count: 2}}")
      assert {:ok, _} = field(r, "[1, 2]")
      assert {:error, %Dextrin.Error{}} = field(r, "[1]")
    end

    test "max-count" do
      r = registry_for("{:refine :list %{max-count: 2}}")
      assert {:ok, _} = field(r, "[1, 2]")
      assert {:error, %Dextrin.Error{}} = field(r, "[1, 2, 3]")
    end

    test "min-count/max-count also work over tuple, set, and sorted-set" do
      r = registry_for("{:refine :tuple %{min-count: 2, max-count: 2}}")
      assert {:ok, _} = field(r, "{1, 2}")
      assert {:error, %Dextrin.Error{}} = field(r, "{1}")

      r = registry_for("{:refine :set %{min-count: 2}}")
      assert {:ok, _} = field(r, "@{1, 2}")
      assert {:error, %Dextrin.Error{}} = field(r, "@{1}")

      r = registry_for("{:refine :sorted-set %{max-count: 1}}")
      assert {:ok, _} = field(r, "@sorted-set @{1}")
      assert {:error, %Dextrin.Error{}} = field(r, "@sorted-set @{1, 2}")
    end

    test "min/max also work over decimal and rational, not just plain numbers" do
      r = registry_for("{:refine :decimal %{min: 1.0}}")
      assert {:ok, _} = field(r, "1.5M")
      assert {:error, %Dextrin.Error{}} = field(r, "0.5M")

      r = registry_for("{:refine :rational %{max: 1.0}}")
      assert {:ok, _} = field(r, "1/2")
      assert {:error, %Dextrin.Error{}} = field(r, "3/2")
    end

    test "multiple-of over a float uses the fmod fallback, not integer rem" do
      r = registry_for("{:refine :float %{multiple-of: 0.5}}")
      assert {:ok, _} = field(r, "1.5")
      assert {:error, %Dextrin.Error{}} = field(r, "1.3")
    end
  end

  describe "every primitive type name" do
    # One row per DXN.md §1.3 type, each with one value that matches
    # and one that doesn't -- primitive_matches?/2's own 24 clauses,
    # only ever exercised for :integer above (indirectly for a handful
    # of others through the type_expr tests, but never all 24 directly).
    for {type, good, bad} <- [
          {"nil", "nil", "1"},
          {"boolean", "true", "1"},
          {"integer", "1", ~s("x")},
          {"float", "1.5", ~s("x")},
          {"decimal", "1.5M", "1"},
          {"rational", "1/2", "1"},
          {"string", ~s("x"), "1"},
          {"char", "?a", "1"},
          {"symbol", "some-symbol", "1"},
          {"keyword", ":ok", "1"},
          {"list", "[1]", "1"},
          {"tuple", "{1}", "1"},
          {"map", "%{a: 1}", "1"},
          {"ordered-map", "@ordered %{a: 1}", "1"},
          {"set", "@{1}", "1"},
          {"sorted-set", "@sorted-set @{1}", "1"},
          {"array", "@array[1]", "1"},
          {"date", ~s|@date "2024-01-01"|, "1"},
          {"time", ~s|@time "12:00:00"|, "1"},
          {"local-datetime", ~s|@local-datetime "2024-01-01T00:00:00"|, "1"},
          {"timestamp", ~s|@datetime "2024-01-01T00:00:00Z"|, "1"},
          {"datetime", ~s(@datetime "2024-01-01T00:00:00+02:00"), "1"},
          {"duration", ~s(@duration "P1D"), "1"},
          {"uuid", ~s(@uuid "550e8400-e29b-41d4-a716-446655440000"), "1"},
          {"uri", ~s(@uri "https://example.com"), "1"},
          {"bytes", ~s(@bytes "aGk="), "1"},
          {"regex", ~s|@regex "abc"|, "1"}
        ] do
      test "#{type}" do
        r = registry_for(":#{unquote(type)}")
        assert {:ok, %{"v" => _}} = field(r, unquote(good))
        assert {:error, %Dextrin.Error{}} = field(r, unquote(bad))
      end
    end

    # One datetime type whatever its offset; :timestamp is a datetime in
    # UTC (Jan, 2026-10-20).
    test "timestamp takes a UTC datetime only; datetime takes any offset" do
      r = registry_for(":timestamp")
      assert {:ok, _} = field(r, ~s|@datetime "2024-01-01T00:00:00Z"|)
      assert {:error, %Dextrin.Error{}} = field(r, ~s(@datetime "2024-01-01T00:00:00+02:00"))

      r = registry_for(":datetime")
      assert {:ok, _} = field(r, ~s|@datetime "2024-01-01T00:00:00Z"|)
      assert {:ok, _} = field(r, ~s(@datetime "2024-01-01T00:00:00+02:00"))
    end

    test "finite refuses NaN and the infinities; a range refuses NaN" do
      r = registry_for("{:refine :float %{finite: true}}")
      assert {:ok, _} = field(r, "1.5")
      for bad <- ~w(NaN Infinity -Infinity), do: assert({:error, _} = field(r, bad))

      r = registry_for("{:refine :float %{min: 0}}")
      assert {:ok, _} = field(r, "Infinity")
      assert {:error, _} = field(r, "NaN")
      assert {:error, _} = field(r, "-Infinity")
    end
  end

  describe "{:reference, name} against a real (non-Dextrin.Struct) Elixir struct" do
    defmodule RealPoint do
      @moduledoc false
      defstruct [:x]
    end

    test "matches when the struct's own module is registered for that schema name" do
      dxns = "%{ Point: %schema{ x: :integer } }"
      {:ok, doc} = Dextrin.decode(dxns)
      {:ok, registry} = Dextrin.Schema.compile(doc)
      registry = Dextrin.Registry.put_struct_module(registry, "Point", RealPoint)

      assert Dextrin.Schema.TypeExpr.matches?({:reference, "Point"}, %RealPoint{x: 1}, registry)
    end

    test "rejects a real struct whose module doesn't match the name's own registered module" do
      dxns = """
      %{
        Point: %schema{ x: :integer }
        Other: %schema{ y: :integer }
      }
      """

      {:ok, doc} = Dextrin.decode(dxns)
      {:ok, registry} = Dextrin.Schema.compile(doc)
      registry = Dextrin.Registry.put_struct_module(registry, "Point", RealPoint)
      registry = Dextrin.Registry.put_struct_module(registry, "Other", Dextrin.Struct)

      refute Dextrin.Schema.TypeExpr.matches?({:reference, "Other"}, %RealPoint{x: 1}, registry)
    end

    test "an application struct does not match a name nothing is registered for" do
      dxns = "%{ Point: %schema{ x: :integer } }"
      {:ok, doc} = Dextrin.decode(dxns)
      {:ok, registry} = Dextrin.Schema.compile(doc)
      registry = Dextrin.Registry.put_struct_module(registry, "Point", RealPoint)

      refute Dextrin.Schema.TypeExpr.matches?(
               {:reference, "NeverRegistered"},
               %RealPoint{x: 1},
               registry
             )
    end

    test "an unregistered real struct is not the referenced one" do
      registry = Dextrin.Registry.new()
      refute Dextrin.Schema.TypeExpr.matches?({:reference, "Point"}, %RealPoint{x: 1}, registry)
    end
  end
end
