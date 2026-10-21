defmodule Dextrin.Binary.Float do
  @moduledoc false
  # CBOR's half- and single-precision floats (RFC 8949 §3.3, Appendix D),
  # which `.dxnb` writes when they hold a value exactly -- the smallest
  # representation (DXN.md §2.2). NaN and the infinities are DXN's atoms.

  import Bitwise

  @doc "A half-precision float's bits as DXN's value."
  @spec from_half(non_neg_integer()) :: float() | :nan | :positive_infinity | :negative_infinity
  def from_half(bits) do
    sign = if bits >>> 15 == 1, do: -1.0, else: 1.0
    exponent = bits >>> 10 &&& 0x1F
    fraction = bits &&& 0x3FF

    cond do
      exponent == 31 and fraction != 0 -> :nan
      exponent == 31 -> if sign < 0, do: :negative_infinity, else: :positive_infinity
      exponent == 0 -> sign * fraction * :math.pow(2, -24)
      true -> sign * (1024 + fraction) * :math.pow(2, exponent - 25)
    end
  end

  @doc "A single-precision float's bits as DXN's value."
  @spec from_single(non_neg_integer()) :: float() | :nan | :positive_infinity | :negative_infinity
  def from_single(bits) do
    case {bits >>> 23 &&& 0xFF, bits &&& 0x7FFFFF} do
      {255, 0} ->
        if bits >>> 31 == 1, do: :negative_infinity, else: :positive_infinity

      {255, _} ->
        :nan

      _ ->
        <<f::float-32>> = <<bits::32>>
        f
    end
  end

  @doc """
  Whether single precision holds `f` exactly. Past single's range it
  would be an infinity, which is no float.
  """
  @spec single?(float()) :: boolean()
  def single?(f) do
    <<bits::32>> = <<f::float-32>>
    back = from_single(bits)
    is_float(back) and <<back::float>> == <<f::float>>
  rescue
    ArgumentError -> false
  end

  @doc "`f`'s half-precision bits, when half precision holds it exactly."
  @spec half(float()) :: {:ok, non_neg_integer()} | :error
  def half(f) do
    <<negative::1, _::63>> = <<f::float>>
    sign = negative <<< 15
    a = abs(f)

    bits =
      cond do
        a == 0.0 -> sign
        a < :math.pow(2, -14) -> subnormal(a, sign)
        a <= 65_504.0 -> normal(a, sign)
        true -> nil
      end

    if bits && same?(from_half(bits), f), do: {:ok, bits}, else: :error
  end

  defp subnormal(a, sign) do
    fraction = a * :math.pow(2, 24)
    if fraction == Float.round(fraction), do: sign ||| trunc(fraction)
  end

  defp normal(a, sign) do
    exponent = a |> :math.log2() |> Float.floor() |> trunc()
    exponent = if :math.pow(2, exponent) > a, do: exponent - 1, else: exponent
    fraction = (a / :math.pow(2, exponent) - 1) * 1024

    if exponent >= -14 and exponent <= 15 and fraction == Float.round(fraction),
      do: sign ||| (exponent + 15) <<< 10 ||| trunc(fraction)
  end

  # The same float, the sign of a zero included.
  defp same?(back, f) when is_float(back), do: <<back::float>> == <<f::float>>
  defp same?(_back, _f), do: false
end
