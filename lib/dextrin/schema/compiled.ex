defmodule Dextrin.Schema.Compiled do
  @moduledoc """
  The result of compiling one `%schema{}` entry from a `.dxns`
  document (`Dextrin.Schema.Compiler.compile/3`) — enough to both
  validate a decoded value and convert it both directions between
  `.dxnb`'s always-positional wire shape and a named field map.

  `fields` is ordered — that order is the canonical position ↔ name
  mapping `.dxnb`'s positional struct encoding needs, which is exactly
  why a schema's own `fields:` has to be an `@ordered %{...}` in the
  source document, not a plain map (`.dxn`'s `map` type makes no
  ordering guarantee, but field order here is semantically
  load-bearing, not incidental).
  """

  alias Dextrin.Schema.Field

  @type refine_fn :: (%{optional(atom()) => term()} -> :ok | {:error, term()})

  @type t :: %__MODULE__{
          name: String.t(),
          fields: [Field.t()],
          closed: boolean(),
          forbidden: [String.t()],
          refine_fn: refine_fn() | nil
        }

  defstruct [:name, fields: [], closed: false, forbidden: [], refine_fn: nil]

  @spec field_names(t()) :: [String.t()]
  def field_names(%__MODULE__{fields: fields}), do: Enum.map(fields, & &1.name)
end
