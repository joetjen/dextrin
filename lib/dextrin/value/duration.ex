defmodule Dextrin.Duration do
  @moduledoc """
  DXN `duration` (`@duration "P..."`). Each field is
  `integer() | nil` — only fields actually present in the source set
  a bit in `.dxnb`'s bitmask (DXN.md §2.3). `years`/`months` are
  calendar-relative (variable length) and not reducible to a single
  elapsed-time scalar, so all seven fields are tracked independently
  rather than folded into one (DXN.md §1.4).
  """

  @type t :: %__MODULE__{
          years: integer() | nil,
          months: integer() | nil,
          weeks: integer() | nil,
          days: integer() | nil,
          hours: integer() | nil,
          minutes: integer() | nil,
          microseconds: integer() | nil
        }

  defstruct [:years, :months, :weeks, :days, :hours, :minutes, :microseconds]

  @spec new(keyword()) :: t()
  def new(fields \\ []) when is_list(fields), do: struct!(__MODULE__, fields)
end
