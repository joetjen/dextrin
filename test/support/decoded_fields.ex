defmodule Dextrin.Test.Support.DecodedFields do
  @moduledoc """
  A decode result's struct, as its field map -- for tests about what a
  schema accepts, which care about the checked fields and not about the
  generic `Dextrin.Struct` a schema with no materializer decodes to
  (DXNS.md §8).
  """

  @doc """
  `{:ok, %Dextrin.Struct{fields: {:keyed, pairs}}}` as `{:ok, map}`; any
  other result unchanged.
  """
  @spec of(term()) :: term()
  def of({:ok, %Dextrin.Struct{fields: {:keyed, pairs}}}), do: {:ok, Map.new(pairs)}
  def of(other), do: other
end
