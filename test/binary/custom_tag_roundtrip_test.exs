defmodule Dextrin.CustomTagRoundtripTest do
  @moduledoc """
  `Dextrin.Registry.put_tag_encoder/4` closes the custom-tag
  encode-side gap `put_tag/3` alone leaves open: a value decoded via
  `put_tag/3` into an application struct now has a defined way back to
  `@name value`, symmetric across both the text
  (`Dextrin.encode/2`, `Dextrin.Text.Formatter.pretty/2`) and binary
  (`Dextrin.encode_binary/2`) pipelines.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Test.Support.Money

  setup do
    registry =
      Dextrin.Registry.new()
      |> Dextrin.Registry.put_tag("my-app/money", fn %Dextrin.Tuple{items: [amount, currency]} ->
        {:ok, struct(Money, amount: amount, currency: currency)}
      end)
      |> Dextrin.Registry.put_tag_encoder(Money, "my-app/money", fn %Money{amount: a, currency: c} ->
        {:ok, Dextrin.Tuple.new([a, c])}
      end)

    {:ok, decoded} = Dextrin.decode(~s(@my-app/money {19.99M, :usd}), registry: registry)
    %{registry: registry, decoded: decoded}
  end

  test "decodes into the registered application struct", %{decoded: decoded} do
    assert %Money{currency: %Dextrin.Keyword{name: "usd"}} = decoded
  end

  test "encode/2 re-emits the custom tag form", %{registry: registry, decoded: decoded} do
    assert {:ok, "@my-app/money {19.99M :usd}"} = Dextrin.encode(decoded, registry: registry)
  end

  test "text round-trips to an equal value", %{registry: registry, decoded: decoded} do
    {:ok, text} = Dextrin.encode(decoded, registry: registry)
    assert {:ok, ^decoded} = Dextrin.decode(text, registry: registry)
  end

  test "binary round-trips to an equal value", %{registry: registry, decoded: decoded} do
    assert {:ok, bin} = Dextrin.encode_binary(decoded, registry: registry)
    assert {:ok, ^decoded} = Dextrin.decode_binary(bin, registry: registry)
  end

  test "Dextrin.Text.Formatter.pretty/2 also consults the registry", %{
    registry: registry,
    decoded: decoded
  } do
    assert Dextrin.Text.Formatter.pretty(decoded, registry: registry) ==
             "@my-app/money {19.99M :usd}"
  end

  test "encode_binary/2 without a registry fails clearly instead of crashing", %{decoded: decoded} do
    assert {:error, %Dextrin.Error{}} = Dextrin.encode_binary(decoded)
  end

  test "encode/2 without a registry fails clearly instead of crashing", %{decoded: decoded} do
    assert {:error, %Dextrin.Error{message: message}} = Dextrin.encode(decoded)
    assert message =~ "cannot encode value with no DXN representation"
  end

  test "a tag encoder returning {:error, reason} is surfaced, not swallowed" do
    registry =
      Dextrin.Registry.new()
      |> Dextrin.Registry.put_tag_encoder(Money, "my-app/money", fn _money -> {:error, :nope} end)

    money = struct(Money, amount: 1, currency: :usd)
    assert {:error, %Dextrin.Error{}} = Dextrin.encode_binary(money, registry: registry)
  end

  test "encode/2 (text) surfaces a failing tag encoder the same way, not swallowed" do
    registry =
      Dextrin.Registry.new()
      |> Dextrin.Registry.put_tag_encoder(Money, "my-app/money", fn _money -> {:error, :nope} end)

    money = struct(Money, amount: 1, currency: :usd)
    assert {:error, %Dextrin.Error{message: message}} = Dextrin.encode(money, registry: registry)
    assert message =~ "tag encoder for"
  end
end
