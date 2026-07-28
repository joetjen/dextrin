defmodule Dextrin.Binary.Tags do
  @moduledoc """
  Pure constants — CBOR tag numbers and bit-layout tables, mirroring
  `DXN.md` §2.3 verbatim. No behavior lives here.
  """

  # ---- registered CBOR tags used (RFC 8949 + the extensions DXN.md §2 cites) --
  def t_bignum_pos, do: 2
  def t_bignum_neg, do: 3
  def t_decimal, do: 4
  def t_timestamp, do: 1
  def t_rational, do: 30
  def t_uri, do: 32
  def t_uuid, do: 37
  def t_stringref_namespace, do: 256
  def t_stringref, do: 25
  def t_shareable, do: 28
  def t_shared_ref, do: 29

  # ---- private tag block, DXN.md §2.3 (200-214) --------------------------
  def t_char, do: 200
  def t_symbol, do: 201
  def t_keyword, do: 202
  def t_tuple, do: 203
  def t_array, do: 204
  def t_ordered, do: 205
  def t_set, do: 206
  def t_sorted_set, do: 207
  def t_struct, do: 208
  def t_date, do: 209
  def t_time, do: 210
  def t_datetime_offset, do: 211
  def t_duration, do: 212
  def t_regex, do: 213
  def t_custom, do: 214

  @doc "Duration bitmask field order, low bit first (DXN.md §2.3)."
  @spec duration_bits() :: [atom()]
  def duration_bits, do: [:years, :months, :weeks, :days, :hours, :minutes, :microseconds]

  @doc "Regex flags byte bit order, low bit first (DXN.md §2.3)."
  @spec regex_bits() :: [{non_neg_integer(), String.t()}]
  def regex_bits, do: [{0, "i"}, {1, "m"}, {2, "s"}, {3, "u"}, {4, "x"}, {5, "f"}, {6, "r"}]

  @flag_to_opt %{"i" => :caseless, "m" => :multiline, "s" => :dotall, "u" => :unicode, "x" => :extended, "f" => :firstline, "r" => :ungreedy}

  @doc """
  Flag letters to `Regex.compile/2` option atoms — deliberately not a
  flag *string* (`Regex.compile(pattern, "r")` triggers an Elixir
  deprecation warning for `/r`; the equivalent atom list doesn't).
  """
  @spec regex_flags_to_opts(String.t()) :: [atom()]
  def regex_flags_to_opts(flags) do
    flags |> String.graphemes() |> Enum.map(&Map.fetch!(@flag_to_opt, &1))
  end

  @doc "Reverse of `regex_flags_to_opts/1` — a compiled Regex's `opts` list back to DXN's flag-letter string, in bitmask order."
  @spec regex_opts_to_flags([atom()]) :: String.t()
  def regex_opts_to_flags(opts) do
    regex_bits()
    |> Enum.filter(fn {_bit, flag} -> Map.fetch!(@flag_to_opt, flag) in opts end)
    |> Enum.map_join(fn {_bit, flag} -> flag end)
  end

  @doc "Regex flags byte, one bit per present flag (DXN.md §2.3)."
  @spec regex_opts_to_byte([atom()]) :: non_neg_integer()
  def regex_opts_to_byte(opts) do
    Enum.reduce(regex_bits(), 0, fn {bit, flag}, acc ->
      if Map.fetch!(@flag_to_opt, flag) in opts, do: Bitwise.bor(acc, Bitwise.bsl(1, bit)), else: acc
    end)
  end

  @doc "Regex flags byte back to `Regex.compile/2` option atoms."
  @spec regex_byte_to_opts(non_neg_integer()) :: [atom()]
  def regex_byte_to_opts(byte) do
    regex_bits()
    |> Enum.filter(fn {bit, _flag} -> Bitwise.band(byte, Bitwise.bsl(1, bit)) != 0 end)
    |> Enum.map(fn {_bit, flag} -> Map.fetch!(@flag_to_opt, flag) end)
  end

  @doc "Flag string used in `.dxn` text (`~r/.../imsuxfr`) to the wire's flags byte."
  @spec regex_flags_to_byte(String.t()) :: non_neg_integer()
  def regex_flags_to_byte(flags), do: flags |> regex_flags_to_opts() |> regex_opts_to_byte()
end
