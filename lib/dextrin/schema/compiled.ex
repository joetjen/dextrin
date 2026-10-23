defmodule Dextrin.Schema.Compiled do
  @moduledoc """
  One version of one schema, compiled from a `%schema(N){...}` entry of a
  `.dxns` document (`Dextrin.Schema.Compiler.compile/2`) -- enough to both
  validate a decoded value and convert it both directions between
  `.dxnb`'s always-positional wire shape and a named field map.

  `fields` is ordered, and that order is the canonical position <-> name
  mapping `.dxnb`'s positional struct encoding needs: the order the
  fields are written in the schema's body. `version` is the schema's
  version, `1` when its entry has no header (DXNS.md §8).
  """

  alias Dextrin.Schema.Field

  @type t :: %__MODULE__{
          name: String.t(),
          version: pos_integer(),
          fields: [Field.t()],
          annotations: %{optional(String.t()) => term()}
        }

  # `annotations` are what a `{:doc %schema{...} %{...}}` around the
  # entry says about it (DXNS.md §1b).
  defstruct [:name, version: 1, fields: [], annotations: %{}]

  @spec field_names(t()) :: [String.t()]
  def field_names(%__MODULE__{fields: fields}), do: Enum.map(fields, & &1.name)

  @doc """
  Reads `application_struct`'s fields (an arbitrary Elixir struct — not
  a `Dextrin.Struct`) out in this schema's own canonical field order —
  the same order `.dxnb`'s positional wire encoding needs. A field this
  schema declares but `application_struct` doesn't have is `nil`, same
  as any other absent field; extra struct fields the schema doesn't
  know about are simply not included.

  What lets `Dextrin.Text.Printer`/`Dextrin.Binary.Encoder` serialize a
  struct registered via `Dextrin.Registry.put_struct_module/3` directly
  — without a caller needing to hand-build a `Dextrin.Struct`
  themselves first, closing the loop `Dextrin.Schema.Reader.read/5`
  already closes on the way in.
  """
  @spec field_values(t(), struct()) :: [{String.t(), term()}]
  def field_values(%__MODULE__{} = compiled, application_struct)
      when is_struct(application_struct) do
    field_map =
      application_struct |> Map.from_struct() |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

    Enum.map(field_names(compiled), fn name -> {name, Map.get(field_map, name)} end)
  end
end
