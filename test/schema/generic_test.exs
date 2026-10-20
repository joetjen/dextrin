defmodule Dextrin.Schema.GenericTest do
  @moduledoc """
  Generic named types (Jan, 2026-10-20): `{:generic [t ...] body}`
  declares a named type with parameters, and `{:of Name type ...}` uses
  it, the arguments standing wherever the parameters stand.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Schema

  @schemas """
  %{
    Page: {:generic [t] %shape{
      items: {:list-of t}
      next?: :string
    }}

    Pair: {:generic [a b] {:tuple-of a b}}

    List: {:generic [t] {:any-of :nil %shape{head: t, tail: {:of List t}}}}

    Orders: {:of Page Order}
    Order: %schema{id: :integer}

    Feed: %schema{page: {:of Page :string}, pair: {:of Pair :integer :string}}
  }
  """

  defp registry do
    {:ok, doc} = Dextrin.decode(@schemas)
    {:ok, registry} = Schema.compile(doc)
    registry
  end

  defp compiled(text) do
    {:ok, doc} = Dextrin.decode(text)
    Schema.compile(doc)
  end

  defp category({:error, %Dextrin.Error{category: category}}), do: category
  defp category(other), do: other

  test "a generic's arguments stand where its parameters stand" do
    r = registry()
    assert {:error, _} = Schema.check(%{items: ["a", "b"]}, r, "Orders")
    assert {:ok, _} = Dextrin.decode(~s|%Feed{page: %{items: ["a"]}, pair: {1 "x"}}|, registry: r)

    assert category(Dextrin.decode(~s|%Feed{page: %{items: [1]}, pair: {1 "x"}}|, registry: r)) ==
             "schema/type-mismatch"

    assert category(Dextrin.decode(~s|%Feed{page: %{items: ["a"]}, pair: {1 2}}|, registry: r)) ==
             "schema/type-mismatch"
  end

  test "a named type may be one use of a generic" do
    {:ok, order} = Dextrin.decode("%Order{id: 1}", registry: registry())
    assert :ok = Schema.check(%{items: [order]}, registry(), "Orders")
    assert {:error, _} = Schema.check(%{items: [1]}, registry(), "Orders")
  end

  test "a generic may use itself, guarded" do
    r = registry()
    list = %{head: 1, tail: %{head: 2, tail: nil}}
    assert :ok = check_of(r, "List", [{:primitive, "integer"}], list)

    assert :error =
             check_of(r, "List", [{:primitive, "integer"}], %{
               head: 1,
               tail: %{head: "x", tail: nil}
             })
  end

  test "the wrong number of arguments, or :of on a type that is not generic, is refused" do
    assert category(compiled("%{P: {:generic [t] {:list-of t}}, Q: {:of P :integer :string}}")) ==
             "schema/compile"

    assert category(compiled("%{P: :integer, Q: {:of P :integer}}")) == "schema/compile"

    assert category(compiled("%{P: {:generic [t] {:list-of t}}, Q: %schema{v: P}}")) ==
             "schema/compile"
  end

  # A struct goes on the wire under its one name, so `Envelope` of one
  # payload could not be told from `Envelope` of another.
  test "a struct schema cannot be generic, though it may use one" do
    assert {:error, %Dextrin.Error{category: "schema/compile", message: message}} =
             compiled("%{E: {:generic [p] %schema{payload: p}}}")

    assert message =~ "%shape"
  end

  test "a generic that uses itself unguarded is refused" do
    assert category(compiled("%{L: {:generic [t] {:nilable {:of L t}}}}")) == "schema/compile"
  end

  defp check_of(registry, name, args, value) do
    case Dextrin.Schema.TypeExpr.conform(
           {:apply, name, args},
           value,
           Dextrin.Schema.TypeExpr.context(registry)
         ) do
      {:ok, _} -> :ok
      :error -> :error
    end
  end
end
