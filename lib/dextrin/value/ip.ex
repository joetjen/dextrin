defmodule Dextrin.Ip do
  @moduledoc """
  DXN `ip` (`@ip "..."`, Jan, 2026-10-20): an IPv4 or IPv6 address, or a
  prefix -- an address and a length. `address` holds the raw bytes, 4 or
  16; `prefix` is the length, or nil for an address. A prefix's host bits
  are zero (RFC 9164). In `.dxnb` it is CBOR's tag 52 or 54, raw bytes.

      iex> {:ok, ip} = Dextrin.Ip.parse("2001:DB8:0:0::/32")
      iex> Dextrin.Ip.format(ip)
      "2001:db8::/32"
  """

  import Bitwise

  @type t :: %__MODULE__{address: binary(), prefix: nil | non_neg_integer()}

  defstruct [:address, :prefix]

  @doc "Parses an address, or `address/length`."
  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid_ip}
  def parse(text) when is_binary(text) do
    case String.split(text, "/") do
      [address] ->
        with {:ok, bytes} <- address_bytes(address), do: {:ok, %__MODULE__{address: bytes}}

      [address, length] ->
        prefix(address, length)

      _ ->
        {:error, :invalid_ip}
    end
  end

  defp prefix(address, length) do
    with {:ok, bytes} <- address_bytes(address),
         true <- Regex.match?(~r/^(0|[1-9][0-9]{0,2})$/, length) || {:error, :invalid_ip},
         n = String.to_integer(length),
         true <- (n <= bit_size(bytes) and host_bits_zero?(bytes, n)) || {:error, :invalid_ip} do
      {:ok, %__MODULE__{address: bytes, prefix: n}}
    end
  end

  @doc "A value from raw `address` bytes and an optional `prefix` length, checked."
  @spec new(binary(), nil | non_neg_integer()) :: {:ok, t()} | {:error, :invalid_ip}
  def new(address, prefix \\ nil)

  def new(address, nil) when byte_size(address) in [4, 16],
    do: {:ok, %__MODULE__{address: address}}

  def new(address, prefix)
      when byte_size(address) in [4, 16] and is_integer(prefix) and prefix >= 0 and
             prefix <= bit_size(address) do
    if host_bits_zero?(address, prefix),
      do: {:ok, %__MODULE__{address: address, prefix: prefix}},
      else: {:error, :invalid_ip}
  end

  def new(_address, _prefix), do: {:error, :invalid_ip}

  @doc "IPv4 in dotted decimal, IPv6 as RFC 5952 writes it, then `/length` for a prefix."
  @spec format(t()) :: String.t()
  def format(%__MODULE__{address: address, prefix: prefix}) do
    text = address |> tuple_of() |> :inet.ntoa() |> to_string()
    if prefix, do: text <> "/" <> Integer.to_string(prefix), else: text
  end

  @doc "4 or 6."
  @spec version(t()) :: 4 | 6
  def version(%__MODULE__{address: address}), do: if(byte_size(address) == 4, do: 4, else: 6)

  defp address_bytes(text) do
    # Strict: no IPv4 shorthand ("10.1"), no zone ("%eth0").
    with {:ok, tuple} <- :inet.parse_strict_address(String.to_charlist(text)),
         false <- String.contains?(text, "%") do
      {:ok, bytes_of(tuple)}
    else
      _ -> {:error, :invalid_ip}
    end
  end

  defp bytes_of({a, b, c, d}), do: <<a, b, c, d>>

  defp bytes_of(groups) when tuple_size(groups) == 8,
    do: for(g <- Tuple.to_list(groups), into: <<>>, do: <<g::16>>)

  defp tuple_of(<<a, b, c, d>>), do: {a, b, c, d}
  defp tuple_of(<<_::128>> = bytes), do: List.to_tuple(for <<g::16 <- bytes>>, do: g)

  defp host_bits_zero?(bytes, length) do
    total = bit_size(bytes)
    <<n::size(total)>> = bytes
    band(n, (1 <<< (total - length)) - 1) == 0
  end
end
