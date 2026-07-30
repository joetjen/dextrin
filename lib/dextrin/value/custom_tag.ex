defmodule Dextrin.CustomTag do
  @moduledoc """
  Opaque DXN custom tag (`@tag value`), produced when no decoder is
  registered for its name (`Dextrin.Registry.put_tag/3`) — the open
  extension point DXN.md §1.2 reserves for any tag name that isn't one
  of the built-ins (`@uuid`, `@duration`, ...). Prefer a schema-backed
  `struct` over a custom tag for anything with real field structure;
  reserve custom tags for simple scalar-wrapping.
  """

  @type t :: %__MODULE__{name: String.t(), value: term()}

  defstruct [:name, :value]

  @spec new(String.t(), term()) :: t()
  def new(name, value) when is_binary(name), do: %__MODULE__{name: name, value: value}
end
