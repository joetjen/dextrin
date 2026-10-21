defmodule Dextrin.Nanos do
  @moduledoc """
  A `time`, `datetime` or `local-datetime` finer than a microsecond
  (DXN.md §1.3, Jan, 2026-10-20: dates and times carry nanoseconds).
  Elixir's own `Time`, `DateTime` and `NaiveDateTime` stop at the
  microsecond, so a value that needs more is held as the native value to
  the microsecond and the `nanosecond`s past it, 1 to 999. A value that
  fits a microsecond is the native one, as before.

      iex> {:ok, t} = Dextrin.decode(~s|@time "14:30:00.123456789"|)
      iex> {t.value, t.nanosecond}
      {~T[14:30:00.123456], 789}
  """

  @type t :: %__MODULE__{
          value: Time.t() | DateTime.t() | NaiveDateTime.t(),
          nanosecond: 1..999
        }

  @enforce_keys [:value, :nanosecond]
  defstruct [:value, :nanosecond]
end
