defmodule Dextrin.Schema.Field do
  @moduledoc """
  One compiled field spec inside a `Dextrin.Schema.Compiled` struct
  (DESIGN.md §4.4.2). `required` comes from the `?`-suffixed key
  convention (no separate flag in `.dxns` itself); `default`/
  `description` only ever come from the `%field{...}` escape hatch.
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
