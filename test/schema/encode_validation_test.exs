defmodule Dextrin.Schema.EncodeValidationTest do
  @moduledoc """
  Encode-time schema validation: `Dextrin.encode/2`
  and `encode_binary/2`'s `schema:` opt, and the underlying
  `Dextrin.Schema.validate_encode/3` / `Validator.validate_for_encode/3`.
  Symmetric to decode-time enforcement, but for data on its way out —
  it never transforms `value`, only ever answers before encoding
  whether it conforms.
  """

  use ExUnit.Case, async: true

  defmodule TestAddress do
    @moduledoc false
    defstruct [:street]
  end

  defmodule TestCompany do
    @moduledoc false
    defstruct [:ein]
  end

  @dxns """
  %{
    Address: %schema{ fields: @ordered %{ street: :string } }
    Money: %schema{
      closed:    true
      forbidden: [legacy_amount_cents]
      fields: @ordered %{
        amount:   :decimal
        currency: {:enum :usd :eur :gbp}
        note?:    :string
      }
    }
    Person: %schema{ fields: @ordered %{ home: Address } }
  }
  """

  setup do
    {:ok, doc} = Dextrin.decode(@dxns)
    {:ok, registry} = Dextrin.Schema.compile(doc)
    %{registry: registry}
  end

  test "a Dextrin.Struct satisfying its schema encodes to named struct-literal wire syntax", %{
    registry: registry
  } do
    money =
      Dextrin.Struct.keyed("Money", [
        {"amount", Decimal.new("19.99")},
        {"currency", Dextrin.Keyword.new("usd")}
      ])

    assert {:ok, "%Money{amount:19.99M,currency::usd}"} =
             Dextrin.encode(money, registry: registry, schema: "Money")
  end

  test "a missing required field is rejected before encoding", %{registry: registry} do
    money = Dextrin.Struct.keyed("Money", [{"currency", Dextrin.Keyword.new("usd")}])

    assert {:error, %Dextrin.Error{message: message}} =
             Dextrin.encode(money, registry: registry, schema: "Money")

    assert message =~ "amount"
  end

  test "an enum violation is rejected before encoding", %{registry: registry} do
    money =
      Dextrin.Struct.keyed("Money", [
        {"amount", Decimal.new("1")},
        {"currency", Dextrin.Keyword.new("gbx")}
      ])

    assert {:error, %Dextrin.Error{}} = Dextrin.encode(money, registry: registry, schema: "Money")
  end

  test "a forbidden field is rejected even though nothing else is wrong", %{registry: registry} do
    money =
      Dextrin.Struct.keyed("Money", [
        {"amount", Decimal.new("1")},
        {"currency", Dextrin.Keyword.new("usd")},
        {"legacy_amount_cents", 100}
      ])

    assert {:error, %Dextrin.Error{}} = Dextrin.encode(money, registry: registry, schema: "Money")
  end

  test "a closed schema rejects an undeclared field", %{registry: registry} do
    money =
      Dextrin.Struct.keyed("Money", [
        {"amount", Decimal.new("1")},
        {"currency", Dextrin.Keyword.new("usd")},
        {"extra", 1}
      ])

    assert {:error, %Dextrin.Error{}} = Dextrin.encode(money, registry: registry, schema: "Money")
  end

  test "a plain string-keyed map is also accepted (no struct-literal wire form, but validated)",
       %{registry: registry} do
    assert {:ok, encoded} =
             Dextrin.encode(
               %{"amount" => Decimal.new("1"), "currency" => Dextrin.Keyword.new("usd")},
               registry: registry,
               schema: "Money"
             )

    refute encoded =~ "%Money"
  end

  test "encode_binary/2 supports the same schema: opt", %{registry: registry} do
    money =
      Dextrin.Struct.keyed("Money", [
        {"amount", Decimal.new("1")},
        {"currency", Dextrin.Keyword.new("usd")}
      ])

    assert {:ok, _bin} = Dextrin.encode_binary(money, registry: registry, schema: "Money")

    bad = Dextrin.Struct.keyed("Money", [{"currency", Dextrin.Keyword.new("usd")}])

    assert {:error, %Dextrin.Error{}} =
             Dextrin.encode_binary(bad, registry: registry, schema: "Money")
  end

  test "encode/2 and encode_binary/2 without a schema: opt are unaffected", %{registry: registry} do
    assert {:ok, _} = Dextrin.encode(%{"anything" => 1}, registry: registry)
    assert {:ok, _} = Dextrin.encode_binary(%{"anything" => 1})
  end

  describe "{:reference, name} checking at encode time (Dextrin.Registry.put_struct_module/3)" do
    test "a struct of the wrong module is rejected for a reference-typed field", %{
      registry: registry
    } do
      registry = Dextrin.Registry.put_struct_module(registry, "Address", TestAddress)

      wrong = %{"home" => struct(TestCompany, ein: "1")}

      assert {:error, %Dextrin.Error{message: message}} =
               Dextrin.encode(wrong, registry: registry, schema: "Person")

      assert message =~ "home"
    end

    test "a struct of the correct module is accepted", %{registry: registry} do
      registry = Dextrin.Registry.put_struct_module(registry, "Address", TestAddress)

      # validate_encode/3 directly, not the full Dextrin.encode/2 —
      # TestAddress has no tag_encoder registered, so the printer
      # itself has nothing to do with it (a separate, pre-existing
      # concern unrelated to schema validation).
      right = %{"home" => struct(TestAddress, street: "Main St")}
      assert :ok = Dextrin.Schema.validate_encode(right, registry, "Person")
    end

    test "without put_struct_module registered, a reference field can't be checked and is trusted",
         %{
           registry: registry
         } do
      wrong = %{"home" => struct(TestCompany, ein: "1")}
      assert :ok = Dextrin.Schema.validate_encode(wrong, registry, "Person")
    end

    test "a Dextrin.Struct checks its own name directly, with no put_struct_module needed", %{
      registry: registry
    } do
      right =
        Dextrin.Struct.keyed("Person", [
          {"home", Dextrin.Struct.keyed("Address", [{"street", "Main St"}])}
        ])

      assert {:ok, _} = Dextrin.encode(right, registry: registry, schema: "Person")

      wrong =
        Dextrin.Struct.keyed("Person", [
          {"home", Dextrin.Struct.keyed("NotAddress", [{"street", "Main St"}])}
        ])

      assert {:error, %Dextrin.Error{}} =
               Dextrin.encode(wrong, registry: registry, schema: "Person")
    end
  end
end
