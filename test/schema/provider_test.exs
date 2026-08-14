defmodule Dextrin.Schema.ProviderTest do
  @moduledoc """
  `Dextrin.Schema.Provider` + `Dextrin.Schema.register_provider/2`: lets
  a struct's own library ship a DXN schema for it (as a small,
  separately-compiled companion module) without depending on `dextrin`
  itself — see `Dextrin.Schema.Provider`'s own moduledoc for the full
  pattern this is meant to support.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Test.Support.{
    ProviderPoint,
    ProviderPointNoMaterializer,
    ProviderWithWrongName
  }

  test "registers a provider's schema, struct module, and materializer in one call" do
    {:ok, registry} = Dextrin.Schema.register_provider(Dextrin.Registry.new(), ProviderPoint.DXN)

    assert {:ok, %ProviderPoint{x: 1, y: 2}} =
             Dextrin.decode(~s(%Point{x: 1, y: 2}), registry: registry)
  end

  test "folds in named types the provider's document defines alongside its own schema" do
    {:ok, registry} = Dextrin.Schema.register_provider(Dextrin.Registry.new(), ProviderPoint.DXN)

    assert {:error, %Dextrin.Error{}} =
             Dextrin.decode(~s(%Point{x: 0, y: 2}), registry: registry)
  end

  test "an application struct registered via dxn_struct/0 encodes directly, with no manual Dextrin.Struct wrapping" do
    {:ok, registry} = Dextrin.Schema.register_provider(Dextrin.Registry.new(), ProviderPoint.DXN)

    good = %ProviderPoint{x: 1, y: 2}
    assert {:ok, "%Point{x:1,y:2}"} = Dextrin.encode(good, registry: registry)
    assert {:ok, ^good} = Dextrin.decode("%Point{x: 1, y: 2}", registry: registry)

    bad = %ProviderPoint{x: 0, y: 2}
    assert {:error, %Dextrin.Error{}} = Dextrin.encode(bad, registry: registry)
  end

  test "an application struct registered via dxn_struct/0 round-trips through .dxnb directly" do
    {:ok, registry} = Dextrin.Schema.register_provider(Dextrin.Registry.new(), ProviderPoint.DXN)

    good = %ProviderPoint{x: 1, y: 2}
    assert {:ok, bytes} = Dextrin.encode_binary(good, registry: registry)
    assert {:ok, ^good} = Dextrin.decode_binary(bytes, registry: registry)
  end

  test "a provider with no dxn_materialize/1 falls back to the default plain field map" do
    {:ok, registry} =
      Dextrin.Schema.register_provider(Dextrin.Registry.new(), ProviderPointNoMaterializer)

    assert {:ok, %{a: 1}} = Dextrin.decode(~s(%Plain{a: 1}), registry: registry)
  end

  test "a provider whose dxn_schema_name/0 doesn't match anything in its own document is a clear error" do
    assert {:error, message} =
             Dextrin.Schema.register_provider(Dextrin.Registry.new(), ProviderWithWrongName)

    assert message =~ "TypoedName"
    assert message =~ "no such schema entry"
  end

  test "composes with an already-populated registry, same as compile/3's base_registry" do
    {:ok, base} =
      Dextrin.Schema.register_provider(Dextrin.Registry.new(), ProviderPointNoMaterializer)

    {:ok, registry} = Dextrin.Schema.register_provider(base, ProviderPoint.DXN)

    assert {:ok, %{a: 1}} = Dextrin.decode(~s(%Plain{a: 1}), registry: registry)

    assert {:ok, %ProviderPoint{x: 1, y: 2}} =
             Dextrin.decode(~s(%Point{x: 1, y: 2}), registry: registry)
  end
end
