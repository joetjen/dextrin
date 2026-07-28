defmodule Dextrin.Value do
  @moduledoc """
  The union of every shape a decoded DXN value can take (DESIGN.md
  §4). A typespec aid only — no functions, no runtime behavior.
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
