defmodule Dextrin.Schema.SugarTest do
  @moduledoc """
  Sugar, the superset's group 9 (design/schema-superset.md, Jan,
  2026-10-20): protobuf's and MongoDB's sized numbers, `:number`,
  `{:const v}` and `{:if I T E}`. Each says nothing a longer form does
  not; DXNS.md §1 gives the form each stands for.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Schema

  defp compiled(type) do
    {:ok, doc} = Dextrin.decode("%{T: #{type}}")
    Schema.compile(doc)
  end

  defp takes?(type, text) do
    {:ok, registry} = compiled(type)
    {:ok, value} = Dextrin.decode(text)
    Schema.check(value, registry, "T") == :ok
  end

  test "the sized integers are their ranges" do
    assert takes?(":int32", "-2147483648")
    refute takes?(":int32", "2147483648")
    assert takes?(":int64", "9223372036854775807")
    refute takes?(":int64", "-9223372036854775809")
    assert takes?(":uint32", "4294967295")
    refute takes?(":uint32", "-1")
    assert takes?(":uint64", "18446744073709551615")
    refute takes?(":uint64", "18446744073709551616")
    refute takes?(":int32", "1.0")
  end

  test ":float32 is a float single precision holds" do
    assert takes?(":float32", "1.5")
    refute takes?(":float32", "0.1")
    refute takes?(":float32", "1")
  end

  test ":number is any number" do
    for text <- ["1", "1.5", "1.5M", "1/3", "NaN"], do: assert(takes?(":number", text), text)
    refute takes?(":number", ~s|"1"|)
  end

  test "{:const v} is the one value v" do
    assert takes?(~s|{:const "v1"}|, ~s|"v1"|)
    refute takes?(~s|{:const "v1"}|, ~s|"v2"|)
    assert takes?("{:const %{a: 1}}", "%{a: 1}")
  end

  test "{:if I T E}: a value that is an I is checked as a T, any other as an E" do
    type = "{:if :integer {:refine :integer %{min: 0}} :string}"
    assert takes?(type, "5")
    refute takes?(type, "-5")
    assert takes?(type, ~s|"x"|)
    refute takes?(type, "1.5")
  end

  test "{:if I T} leaves a value that is no I alone" do
    type = "{:if :integer {:refine :integer %{min: 0}}}"
    assert takes?(type, "1.5")
    refute takes?(type, "-5")
  end

  test "{:if} is no guard: it checks the same value" do
    {:ok, doc} = Dextrin.decode("%{A: {:if :integer A :string}}")
    assert {:error, %Dextrin.Error{category: "schema/compile"}} = Schema.compile(doc)
  end
end
