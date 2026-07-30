defmodule Dextrin.Value do
  @moduledoc """
  The union of every shape a decoded DXN value can take. A typespec
  aid only — no functions, no runtime behavior.

  One Elixir shape per DXN type, preferring a native Elixir/stdlib
  type and falling back to a small `Dextrin` struct only where nothing
  native fits without losing information (see each value module under
  `Dextrin.Value` — really the modules aliased below — for why a given
  type needed a wrapper: `Dextrin.Symbol`/`Dextrin.Keyword`/
  `Dextrin.Tuple`/`Dextrin.Char`/`Dextrin.Bytes`/`Dextrin.Uri` each
  document their own reason). Two shapes are worth calling out here
  because they aren't obvious from the type union alone:

    * `float()` only ever holds a *finite* IEEE-754 double — the BEAM
      cannot construct a NaN/Infinity `float()` term under any
      circumstance (not even via `:erlang.binary_to_term/1`, which
      rejects the bit pattern outright). `NaN`/`Infinity`/`-Infinity`
      are therefore the atoms `:nan`/`:positive_infinity`/
      `:negative_infinity` instead of another wrapper struct — a
      closed three-value union, not worth a struct since the finite
      case is overwhelmingly the common one.
    * `Dextrin.Rational.t()` stores its numerator/denominator exactly
      as parsed, never auto-reduced — `22/7` and `44/14` are distinct
      values unless a caller explicitly calls `Dextrin.Rational.reduce/1`.
  """

  @type t ::
          nil
          | boolean()
          | integer()
          | float()
          | Decimal.t()
          | Dextrin.Rational.t()
          | String.t()
          | Dextrin.Char.t()
          | Dextrin.Symbol.t()
          | Dextrin.Keyword.t()
          | [t()]
          | Dextrin.Tuple.t()
          | %{optional(t()) => t()}
          | Dextrin.OrderedMap.t()
          | MapSet.t()
          | Dextrin.SortedSet.t()
          | Dextrin.Struct.t()
          | struct()
          | Dextrin.Array.t()
          | Date.t()
          | Time.t()
          | DateTime.t()
          | Dextrin.Duration.t()
          | Dextrin.Uuid.t()
          | Dextrin.Uri.t()
          | binary()
          | Regex.t()
          | Dextrin.CustomTag.t()
end
