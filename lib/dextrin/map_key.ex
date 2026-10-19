defmodule Dextrin.MapKey do
  @moduledoc """
  Which values may be map keys (`DXN.md` §1.6): a `string`, `keyword`,
  `integer`, `uuid`, `date`, `bytes`, `symbol` or `char`. Anything else is
  refused as `key/not-allowed` -- in text, in binary and when encoding.

  The allowed types are those whose identity is exact and obvious in
  every language: two keys are the same exactly when their canonical
  forms are. Floats, decimals and rationals are not (`1` against `1.0`,
  `0.0` against `-0.0`, `1.0M` against `1.00M`); neither are times, URIs
  or collections; `nil` and the booleans collide with other keys in some
  languages and are rare as keys anyway.

  **Judged by value, with one thing a value cannot say.** `NaN` and the
  infinities are the atoms `:nan`, `:positive_infinity` and
  `:negative_infinity` here, which is also what the keywords of those
  names decode to. So an atom is allowed as a keyword, and the readers
  refuse a float key by what it was written as: the text decoder by its
  token, the binary decoder by its CBOR major type.
  """

  @doc """
  `:ok` when `key` may be a map key, or a `key/not-allowed` error naming
  it.

      Dextrin.MapKey.check("a")   #=> :ok
      Dextrin.MapKey.check(1.5)   #=> {:error, %Dextrin.Error{category: "key/not-allowed", ...}}
  """
  @spec check(term()) :: :ok | {:error, Dextrin.Error.t()}
  def check(key) do
    if allowed?(key), do: :ok, else: {:error, refusal(key)}
  end

  @doc "The error for a key that is not allowed, naming it."
  @spec refusal(term()) :: Dextrin.Error.t()
  def refusal(key) do
    Dextrin.Error.action(
      "#{inspect(key)} cannot be a map key: a key is a string, keyword, integer, uuid, date, bytes, symbol or char",
      "key/not-allowed"
    )
  end

  @doc "`:ok` when every key of `pairs` may be a map key, or the first refusal."
  @spec check_pairs([{term(), term()}]) :: :ok | {:error, Dextrin.Error.t()}
  def check_pairs(pairs) do
    Enum.find_value(pairs, :ok, fn {key, _value} ->
      case check(key) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp allowed?(key) when is_binary(key), do: true
  defp allowed?(key) when is_integer(key), do: true
  defp allowed?(key) when is_atom(key), do: key not in [nil, true, false]
  defp allowed?(%Dextrin.Keyword{}), do: true
  defp allowed?(%Dextrin.Uuid{}), do: true
  defp allowed?(%Date{}), do: true
  # Bytes are a key; bits that are not whole bytes are not (DXN.md §1.6).
  defp allowed?(%Dextrin.Bytes{data: data}), do: is_binary(data)
  defp allowed?(%Dextrin.Symbol{}), do: true
  defp allowed?(%Dextrin.Char{}), do: true
  defp allowed?(_other), do: false
end
