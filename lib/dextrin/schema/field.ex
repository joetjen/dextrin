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

  @doc """
  The value a missing field takes: its default, or for a computed one
  (`%field{computed: :now}`, G8 of design/typespec.md) the value
  computed now. A computed default is `{:computed, "now", kind}`, `kind`
  the temporal type it fills: `"date"`, `"time"`, `"datetime"` or
  `"local-datetime"`, all of them in UTC.
  """
  @spec default_value(t()) :: term() | :none
  def default_value(%__MODULE__{default: default}), do: filled(default)

  @doc "A field's `default` as the value it fills: computed now, or as written."
  @spec filled(term()) :: term()
  def filled({:computed, "now", kind}), do: now(kind)
  def filled(default), do: default

  defp now("date"), do: Date.utc_today()
  defp now("time"), do: Time.utc_now()
  defp now("datetime"), do: DateTime.utc_now()
  defp now("local-datetime"), do: NaiveDateTime.utc_now()
end
