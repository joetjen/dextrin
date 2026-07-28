defmodule Dextrin.Schema.TypeExprTest do
  @moduledoc """
  Exercises all 13 `type_expr` forms and all 10 `refine` constraints,
  each with a passing and a failing value — coverage implemented in
  `Dextrin.Schema.TypeExpr`/`Compiler` but never actually exercised by
  a test until now.
  """

  use ExUnit.Case, async: true

  defp registry_for(type_expr_text) do
    dxns = """
    %{
      Other: %schema{ fields: @ordered %{ x: :integer } }
      T: %schema{ fields: @ordered %{ v: #{type_expr_text} } }
    }
    """

    {:ok, schema_doc} = Dextrin.decode(dxns)
    {:ok, registry} = Dextrin.Schema.compile(schema_doc)
    registry
  end

  defp field(registry, value_text), do: Dextrin.decode("%T{v: #{value_text}}", registry: registry)

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

    test "reference trusts any non-struct value — no registry access, no provenance to check" do
      r = registry_for("Other")
      assert {:ok, %{"v" => 1}} = field(r, "1")
      assert {:ok, %{"v" => "anything"}} = field(r, ~s("anything"))
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
      assert {:ok, %{"x" => 1}} = Dextrin.decode("%Other{x: 1}", registry: registry_for(":any"))
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
      r = registry_for("{:refine :string %{pattern: ~r/^[a-z]+$/}}")
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
  end
end
