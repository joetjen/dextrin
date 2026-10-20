defmodule Dextrin.Schema.ShapeTest do
  @moduledoc """
  `%shape{...}` and `{:case field %{...}}` (design/shapes-and-case.md,
  Jan, 2026-10-20): a shape is a named, unversioned map type that fills
  its defaults; a case chooses a field's type by a sibling field's
  value; named types see their siblings; `check/3` and `conform/3`
  check a value without decoding it.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Keyword
  alias Dextrin.Schema

  @events """
  %{
    Envelope: %schema{
      type: :string
      payload: {:case type %{
        "placed"    => OrderPlaced
        "cancelled" => OrderCancelled
        :else       => :any
      }}
    }

    Strict: %schema{type: :string, payload: {:case type %{"placed" => OrderPlaced}}}

    Nested: %schema{
      type: :string
      payloads: {:list-of {:nilable {:case type %{"placed" => OrderPlaced}}}}
    }

    Holder: %schema{v: OrderPlaced}

    OrderPlaced: %shape{
      order_id: :integer
      currency: %field{type: :string, default: "EUR"}
      gift?: :boolean
    }

    OrderCancelled: %shape{
      reason: CancelReason
      email?: :never
    }

    CancelReason: {:enum :customer_request :out_of_stock}
  }
  """

  defp registry(text \\ @events) do
    {:ok, doc} = Dextrin.decode(text)
    {:ok, registry} = Schema.compile(doc)
    registry
  end

  defp compiled(text) do
    {:ok, doc} = Dextrin.decode(text)
    Schema.compile(doc)
  end

  # A decode's struct fields, every map key by its name, so a test reads
  # the same whether keys came back as atoms or as `Dextrin.Keyword`s.
  defp decoded(text, opts \\ []) do
    case Dextrin.decode(text, Elixir.Keyword.merge([registry: registry()], opts)) do
      {:ok, %Dextrin.Struct{fields: {:keyed, pairs}}} -> {:ok, named(Map.new(pairs))}
      other -> other
    end
  end

  defp named(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {name_of(k), named(v)} end)

  defp named(list) when is_list(list), do: Enum.map(list, &named/1)
  defp named(other), do: other

  defp name_of(%Keyword{name: name}), do: name
  defp name_of(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp name_of(other), do: other

  defp category({:error, %Dextrin.Error{category: category}}), do: category
  defp category(other), do: other

  describe "a shape-typed field" do
    test "takes a plain map whose fields match" do
      assert {:ok, %{"v" => %{"order_id" => 1, "currency" => "USD"}}} =
               decoded(~s|%Holder{v: %{order_id: 1, currency: "USD"}}|)
    end

    test "fills a missing field's default" do
      assert {:ok, %{"v" => %{"order_id" => 1, "currency" => "EUR"}}} =
               decoded("%Holder{v: %{order_id: 1}}")
    end

    test "leaves a missing optional field without a default absent" do
      assert {:ok, %{"v" => v}} = decoded("%Holder{v: %{order_id: 1}}")
      refute Map.has_key?(v, "gift")
    end

    test "refuses a map missing a required field" do
      assert category(decoded(~s|%Holder{v: %{currency: "USD"}}|)) == "schema/type-mismatch"
    end

    test "refuses a field of the wrong type" do
      assert category(decoded(~s|%Holder{v: %{order_id: "1"}}|)) == "schema/type-mismatch"
    end

    test "matches a field by any spelling of its name, and refuses it given twice" do
      assert {:ok, %{"v" => %{"order_id" => 1}}} = decoded(~s|%Holder{v: %{"order_id" => 1}}|)

      assert category(decoded(~s|%Holder{v: %{order_id: 1, "order_id" => 2}}|)) ==
               "schema/type-mismatch"
    end

    test "keeps an extra key, and a strict decode refuses it" do
      assert {:ok, %{"v" => %{"note" => "x"}}} =
               decoded(~s|%Holder{v: %{order_id: 1, note: "x"}}|)

      assert category(decoded(~s|%Holder{v: %{order_id: 1, note: "x"}}|, strict: true)) ==
               "schema/type-mismatch"
    end

    test "refuses a struct, however much it looks like the map" do
      assert category(decoded("%Holder{v: %OrderPlaced{order_id: 1}}")) == "schema/type-mismatch"
    end

    test "an optional field typed :never must stay absent" do
      assert {:ok, _} =
               decoded("%Envelope{type: \"cancelled\", payload: %{reason: :out_of_stock}}")

      assert category(
               decoded(
                 ~s|%Envelope{type: "cancelled", payload: %{reason: :out_of_stock, email: "a"}}|
               )
             ) == "schema/type-mismatch"
    end
  end

  describe "{:case field %{...}}" do
    test "chooses the type by the sibling field's value" do
      assert {:ok, %{"payload" => %{"currency" => "EUR"}}} =
               decoded(~s|%Envelope{type: "placed", payload: %{order_id: 1}}|)

      assert category(decoded(~s|%Envelope{type: "placed", payload: %{reason: :out_of_stock}}|)) ==
               "schema/type-mismatch"
    end

    test "takes :else for any other value, and leaves that value as it is" do
      assert {:ok, %{"payload" => 42}} = decoded(~s|%Envelope{type: "other", payload: 42}|)
    end

    test "refuses a value no key and no :else takes" do
      assert category(decoded(~s|%Strict{type: "other", payload: %{order_id: 1}}|)) ==
               "schema/type-mismatch"
    end

    test "works anywhere in a field's type" do
      assert {:ok, %{"payloads" => [%{"currency" => "EUR"}, nil]}} =
               decoded(~s|%Nested{type: "placed", payloads: [%{order_id: 1} nil]}|)
    end

    test "naming no field of its schema is a compile error" do
      assert category(compiled("%{S: %schema{a: :string, b: {:case c %{1 => :any}}}}")) ==
               "schema/compile"
    end
  end

  describe "compiling" do
    test "a shape has no version and lists its fields by name" do
      assert category(compiled("%{S: %shape(2){a: :string}}")) == "schema/compile"
      assert category(compiled("%{S: %shape[:string]}")) == "schema/compile"
    end

    test "a named type may refer to a sibling, whatever the order" do
      assert {:ok, _} = compiled("%{A: {:list-of B}, B: {:list-of C}, C: :integer}")
    end

    test "a named type that refers to itself is refused" do
      assert category(compiled("%{A: {:list-of B}, B: {:nilable A}}")) == "schema/compile"
    end
  end

  describe "check/3 and conform/3" do
    test "check answers whether a value matches, and never changes it" do
      assert :ok = Schema.check(%{order_id: 1}, registry(), "OrderPlaced")

      assert {:error, %Dextrin.Error{category: "schema/type-mismatch"}} =
               Schema.check(%{currency: "EUR"}, registry(), "OrderPlaced")
    end

    test "conform answers the value with its defaults filled" do
      assert {:ok, value} = Schema.conform(%{order_id: 1}, registry(), "OrderPlaced")
      assert named(value) == %{"order_id" => 1, "currency" => "EUR"}
    end

    test "both work for a named type and for a struct schema" do
      assert :ok = Schema.check(:out_of_stock, registry(), "CancelReason")
      assert {:error, _} = Schema.check(:other, registry(), "CancelReason")

      {:ok, holder} = Dextrin.decode("%Holder{v: %{order_id: 1}}", registry: registry())
      assert :ok = Schema.check(holder, registry(), "Holder")
    end

    test "an unknown name is an error" do
      assert {:error, %Dextrin.Error{}} = Schema.check(1, registry(), "Nothing")
    end
  end
end
