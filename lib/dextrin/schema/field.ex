defmodule Dextrin.Schema.Field do
  @moduledoc """
  One compiled field spec inside a `Dextrin.Schema.Compiled` struct.
  `required` comes from the `?`-suffixed key convention (a field key
  ending in `?` is optional; no separate flag exists in `.dxns` itself
  — reusing DXN's own identifier grammar rather than adding one);
  `default`/`description` only ever come from the `%field{...}` escape
  hatch, since optionality is already fully covered by the key suffix.
  """

  alias Dextrin.Schema.TypeExpr

  @type t :: %__MODULE__{
          name: String.t(),
          required: boolean(),
          type: TypeExpr.t(),
          default: term() | :none,
          description: String.t() | nil
        }

  defstruct [:name, required: true, type: :any, default: :none, description: nil]
end
