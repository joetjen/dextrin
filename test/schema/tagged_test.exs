defmodule Dextrin.Schema.TaggedTest do
  @moduledoc """
  `{:tagged name T}`, the superset's group 7 (design/schema-superset.md,
  Jan, 2026-10-20): a custom tag of that name whose value is a `T` --
  YAML's local tags, MessagePack's ext types, CBOR's tags.
  """

  use ExUnit.Case, async: true

  alias Dextrin.{Registry, Schema}

  defmodule Money do
    @moduledoc false
    defstruct [:amount, :currency]
  end

  @schemas "%{Price: {:tagged acme.money {:tuple-of :decimal :string}}}"

  defp registry do
    {:ok, doc} = Dextrin.decode(@schemas)
    {:ok, registry} = Schema.compile(doc)
    registry
  end

  defp check(text, registry \\ registry()) do
    {:ok, value} = Dextrin.decode(text)
    Schema.check(value, registry, "Price")
  end

  test "a custom tag of that name whose value is a T" do
    assert check(~s|@acme.money {9.99M "EUR"}|) == :ok
    assert {:error, _} = check(~s|@acme.money {"9.99" "EUR"}|)
    assert {:error, _} = check(~s|@acme.cost {9.99M "EUR"}|)
    assert {:error, _} = check(~s|{9.99M "EUR"}|)
  end

  test "the name may be written as a symbol, a keyword or a string" do
    for name <- ["acme.money", ":acme.money", ~s|"acme.money"|] do
      {:ok, doc} = Dextrin.decode("%{Price: {:tagged #{name} :any}}")
      {:ok, r} = Schema.compile(doc)
      assert check(~s|@acme.money 1|, r) == :ok, name
    end
  end

  test "an application's value is checked as its registered tag encoder writes it" do
    r =
      registry()
      |> Registry.put_tag_encoder(Money, "acme.money", fn %Money{amount: a, currency: c} ->
        {:ok, Dextrin.Tuple.new([a, c])}
      end)

    assert Schema.check(%Money{amount: Decimal.new("9.99"), currency: "EUR"}, r, "Price") == :ok
    assert {:error, _} = Schema.check(%Money{amount: 9.99, currency: "EUR"}, r, "Price")

    assert {:error, _} =
             Schema.check(%Money{amount: Decimal.new("1"), currency: "EUR"}, registry(), "Price")
  end

  test "a built-in tag's name is no custom tag's" do
    {:error, %Dextrin.Error{category: "schema/compile", message: message}} =
      Dextrin.decode("%{T: {:tagged uuid :string}}") |> elem(1) |> Schema.compile()

    assert message =~ "uuid"
  end

  test "it guards a named type's recursion" do
    {:ok, doc} = Dextrin.decode("%{Node: {:tagged acme.node {:list-of Node}}}")
    assert {:ok, _} = Schema.compile(doc)
  end
end
