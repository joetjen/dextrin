defmodule Dextrin.Schema.Std do
  @moduledoc """
  dextrin's standard library of named types (`priv/schema/std.dxns`,
  DESIGN.md §4.4.1) — common refinements like `PositiveInteger` or
  `NonEmptyString`, so a schema author doesn't redefine them by hand.
  Opt-in: pass `Std.registry/1`'s result as `compile/3`'s
  `base_registry` to make these names available to your own document.

      {:ok, doc} = Dextrin.decode(my_dxns_source)
      {:ok, registry} = Dextrin.Schema.compile(doc, Dextrin.Schema.Std.registry())
  """

  @external_resource Path.join([__DIR__, "..", "..", "..", "priv", "schema", "std.dxns"])
  @source File.read!(@external_resource)

  @doc "The standard library's own `.dxns` source — the same file any dextrin-compatible reader in any language can load."
  @spec source() :: String.t()
  def source, do: @source

  @doc """
  Compiles the standard library into `base_registry` (a fresh
  `Dextrin.Registry.new/0` by default), returning its named types
  merged in alongside anything `base_registry` already had.
  """
  @spec registry(Dextrin.Registry.t()) :: Dextrin.Registry.t()
  def registry(base_registry \\ Dextrin.Registry.new()) do
    {:ok, doc} = Dextrin.decode(@source)
    {:ok, registry} = Dextrin.Schema.compile(doc, base_registry)
    registry
  end
end
