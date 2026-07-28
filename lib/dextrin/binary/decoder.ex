defmodule Dextrin.Binary.Decoder do
  @moduledoc """
  `.dxnb` decoder — the mirror image of `Dextrin.Binary.Encoder`.
  Envelope (`magic` `version` `cbor_item`) checked once at the top;
  everything below that is a single recursive `decode_item/2`, keyed
  on CBOR major type first, then on tag — matching `DXN.md` §2.2's
  table row order the same way the encoder does.
  """

  alias Dextrin.Binary.Tags

  alias Dextrin.{
    Array,
    Bytes,
    CustomTag,
    OrderedMap,
    Rational,
    Registry,
    SortedSet,
    Struct,
    Tuple,
    Uri,
    Uuid
  }

  @magic "DX"
  @version 1
  @epoch ~D[1970-01-01]

  @spec decode(binary(), keyword()) :: {:ok, term()} | {:error, Dextrin.Error.t()}
  def decode(bin, opts \\ [])

  def decode(<<@magic, @version, rest::binary>>, opts) do
    # Scoped to this one call (initialized here, torn down in `after`)
    # — see the matching note on `Dextrin.Binary.Encoder.encode/2` for
    # why the process dictionary, not a threaded accumulator.
    Process.put(:dextrin_shared_items, %{})

    try do
      with {:ok, value, <<>>} <- decode_item(rest, opts) do
        {:ok, Dextrin.Schema.Validated.strip(value)}
      else
        {:ok, _value, leftover} ->
          {:error,
           Dextrin.Error.binary(
             "trailing bytes after top-level value (#{byte_size(leftover)} left over)"
           )}

        {:error, _} = err ->
          err
      end
    after
      Process.delete(:dextrin_shared_items)
    end
  end

  def decode(bin, _opts) when is_binary(bin) do
    {:error,
     Dextrin.Error.binary(
       "missing or invalid .dxnb envelope (expected magic \"DX\" + version #{@version})"
     )}
  end

  # ---- item reader ------------------------------------------------------------
  #
  # Major 7 is special-cased here, ahead of the generic `read_head` /
  # `decode_by_major` split every other major type goes through — for
  # majors 0-6, the additional-info field (24/25/26/27) only ever means
  # "how many extra bytes encode this number," and the decoded integer
  # is all that matters afterward. Major 7 breaks that: the info value
  # itself (20/21/22 vs 25/26/27) is what distinguishes booleans/nil
  # from a 16/32/64-bit float, not an encoding-length detail — feeding
  # it through the generic path collapses that distinction into just
  # "some integer," which made floats undecodable from any producer
  # using the standard single-byte header (see the encoder's
  # `float_head/0` comment for how this was actually found).
  defp decode_item(<<7::3, 20::5, rest::binary>>, _opts), do: {:ok, false, rest}
  defp decode_item(<<7::3, 21::5, rest::binary>>, _opts), do: {:ok, true, rest}
  defp decode_item(<<7::3, 22::5, rest::binary>>, _opts), do: {:ok, nil, rest}

  defp decode_item(<<7::3, 25::5, _bits::16, _rest::binary>>, _opts) do
    {:error, Dextrin.Error.binary("half-precision (16-bit) CBOR floats are not supported")}
  end

  defp decode_item(<<7::3, 26::5, bits::32, rest::binary>>, _opts) do
    <<f::float-32>> = <<bits::32>>
    {:ok, f, rest}
  end

  defp decode_item(<<7::3, 27::5, bits::64, rest::binary>>, _opts) do
    {:ok, decode_float(bits), rest}
  end

  defp decode_item(bin, opts) do
    with {:ok, major, arg, rest} <- read_head(bin) do
      decode_by_major(major, arg, rest, opts)
    end
  end

  defp decode_by_major(0, arg, rest, _opts), do: {:ok, arg, rest}
  defp decode_by_major(1, arg, rest, _opts), do: {:ok, -1 - arg, rest}

  defp decode_by_major(2, len, rest, _opts) do
    with {:ok, bin, rest2} <- take(rest, len), do: {:ok, Bytes.new(bin), rest2}
  end

  defp decode_by_major(3, len, rest, _opts) do
    with {:ok, bin, rest2} <- take(rest, len) do
      if String.valid?(bin) do
        {:ok, bin, rest2}
      else
        {:error, Dextrin.Error.binary("invalid UTF-8 in text item")}
      end
    end
  end

  defp decode_by_major(4, count, rest, opts), do: decode_n_items(rest, count, opts)

  defp decode_by_major(5, pair_count, rest, opts) do
    with {:ok, pairs, rest2} <- decode_map_pairs(pair_count, rest, opts) do
      {:ok, Map.new(pairs), rest2}
    end
  end

  # (`decode_by_major(6, ...)`'s `t_ordered` special case below calls
  # `decode_map_pairs/3` directly, bypassing this clause entirely, so
  # it never gets collapsed to a plain Map in the first place.)

  # `@ordered %{...}` needs the raw pair *list* (order intact), not a
  # plain Map — the same order-preservation requirement
  # `Dextrin.OrderedMap` exists for on the text side: reads the major-5
  # payload directly rather than going through `decode_by_major(5,
  # ...)`'s own Map-collapsing path, which would destroy the order
  # this tag exists to keep.
  defp decode_by_major(6, tag_number, rest, opts) do
    cond do
      tag_number == Tags.t_ordered() ->
        with {:ok, 5, pair_count, rest2} <- read_head(rest),
             {:ok, pairs, rest3} <- decode_map_pairs(pair_count, rest2, opts) do
          {:ok, OrderedMap.new(pairs), rest3}
        else
          {:ok, _major, _arg, _rest} ->
            {:error,
             Dextrin.Error.binary("@ordered (tag #{Tags.t_ordered()}) requires a map payload")}

          {:error, _} = err ->
            err
        end

      tag_number == Tags.t_shareable() ->
        decode_shareable(rest, opts)

      tag_number == Tags.t_shared_ref() ->
        decode_shared_ref(rest, opts)

      true ->
        decode_tagged(tag_number, rest, opts)
    end
  end

  # Major 7's simple-value/float forms are all handled directly in
  # `decode_item/2`, above `read_head` entirely — nothing reaches here
  # for major 7 except a genuinely unrecognized additional-info value
  # (e.g. 24's rare 1-byte-simple extension, or the reserved 28-30
  # range), which is correctly an error, not a missing case.

  defp decode_by_major(major, arg, _rest, _opts) do
    {:error, Dextrin.Error.binary("unsupported CBOR item (major #{major}, arg #{arg})")}
  end

  # ---- value sharing (DXN.md §2.5) -------------------------------------------
  #
  # Decode-side support is spec-mandatory ("a conforming decoder MUST
  # accept it") regardless of whether *this* encoder produced the
  # bytes. Indices are assigned in decode-completion order (post-order
  # — a tag-28 item registers itself only after its own children, if
  # any, have finished decoding), matching the encoder's own order —
  # which also means a tag-29 reference can only ever point at an
  # already-decoded item: cycles are structurally impossible here, not
  # separately detected.
  defp decode_shareable(rest, opts) do
    with {:ok, value, rest2} <- decode_item(rest, opts) do
      shared = Process.get(:dextrin_shared_items, %{})
      index = map_size(shared)
      Process.put(:dextrin_shared_items, Map.put(shared, index, value))
      {:ok, value, rest2}
    end
  end

  defp decode_shared_ref(rest, opts) do
    with {:ok, index, rest2} <- decode_item(rest, opts) do
      if is_integer(index) do
        case Map.fetch(Process.get(:dextrin_shared_items, %{}), index) do
          {:ok, value} ->
            {:ok, value, rest2}

          :error ->
            {:error,
             Dextrin.Error.binary(
               "shared value reference (tag #{Tags.t_shared_ref()}) index #{index} refers to a not-yet-seen item"
             )}
        end
      else
        {:error,
         Dextrin.Error.binary(
           "shared value reference (tag #{Tags.t_shared_ref()}) payload must be an integer index, got #{inspect(index)}"
         )}
      end
    end
  end

  # ---- tag dispatch (DXN.md §2.2/§2.3) ---------------------------------------

  defp decode_tagged(tag, rest, opts) do
    with {:ok, item_bin, rest2} <- decode_item_raw(rest, opts) do
      case build_tagged(tag, item_bin, opts) do
        {:ok, value} -> {:ok, value, rest2}
        {:error, _} = err -> err
      end
    end
  end

  # Decodes exactly one item and hands back both its already-decoded
  # value and the leftover bytes — tag handlers need the decoded value,
  # not raw bytes, since a tag's payload is itself a real CBOR item.
  defp decode_item_raw(bin, opts), do: decode_item(bin, opts)

  defp build_tagged(tag, value, opts) do
    cond do
      tag == Tags.t_bignum_pos() ->
        with %Bytes{data: raw} <- value, do: {:ok, :binary.decode_unsigned(raw)}

      tag == Tags.t_bignum_neg() ->
        with %Bytes{data: raw} <- value, do: {:ok, -1 - :binary.decode_unsigned(raw)}

      tag == Tags.t_decimal() ->
        build_decimal(value)

      tag == Tags.t_timestamp() ->
        {:ok, DateTime.from_unix!(value, :microsecond)}

      tag == Tags.t_rational() ->
        build_rational(value)

      tag == Tags.t_uri() ->
        {:ok, Uri.new(value)}

      tag == Tags.t_uuid() ->
        with %Bytes{data: raw} <- value, do: {:ok, Uuid.new(raw)}

      tag == Tags.t_char() ->
        {:ok, Dextrin.Char.new(value)}

      tag == Tags.t_symbol() ->
        {:ok, Dextrin.Symbol.new(value)}

      tag == Tags.t_keyword() ->
        {:ok, Dextrin.Keyword.new(value)}

      tag == Tags.t_tuple() ->
        {:ok, Tuple.new(value)}

      tag == Tags.t_array() ->
        {:ok, Array.new(value)}

      # t_ordered is intercepted earlier, in decode_by_major(6, ...) —
      # never reaches build_tagged (it needs the raw pair list before
      # Map-collapsing, see the comment there).
      tag == Tags.t_set() ->
        {:ok, MapSet.new(value)}

      tag == Tags.t_sorted_set() ->
        {:ok, SortedSet.new(value)}

      tag == Tags.t_struct() ->
        build_struct(value, opts)

      tag == Tags.t_date() ->
        {:ok, Date.add(@epoch, value)}

      tag == Tags.t_time() ->
        {:ok, build_time(value)}

      tag == Tags.t_datetime_offset() ->
        build_datetime_offset(value)

      tag == Tags.t_duration() ->
        build_duration(value)

      tag == Tags.t_regex() ->
        build_regex(value)

      tag == Tags.t_custom() ->
        build_custom(value, opts)

      true ->
        {:error, Dextrin.Error.binary("unrecognized CBOR tag #{tag}")}
    end
  end

  defp build_decimal([exponent, mantissa]) when is_integer(exponent) and is_integer(mantissa) do
    sign = if mantissa < 0, do: -1, else: 1
    {:ok, Decimal.new(sign, abs(mantissa), exponent)}
  end

  defp build_decimal(_), do: {:error, Dextrin.Error.binary("malformed decimal (tag 4) payload")}

  defp build_rational([num, den]) when is_integer(num) and is_integer(den) and den > 0 do
    {:ok, Rational.new(num, den)}
  end

  defp build_rational(_),
    do: {:error, Dextrin.Error.binary("malformed rational (tag 30) payload")}

  defp build_struct([name | fields], opts) when is_binary(name) do
    case Keyword.get(opts, :registry) do
      %Registry{} = registry ->
        case Registry.fetch_struct_schema(registry, name) do
          {:ok, compiled, _registry} ->
            materializer =
              case Registry.fetch_materializer(registry, name) do
                {:ok, fun} -> fun
                :error -> nil
              end

            # Same fail-fast, decode-time enforcement as the text
            # pipeline — .dxnb structs are always positional (`DXN.md`
            # §2.1), so this is the only shape possible here.
            case Dextrin.Schema.Validator.materialize(
                   compiled,
                   {:positional, fields},
                   materializer,
                   registry
                 ) do
              {:ok, materialized} ->
                {:ok, materialized}

              {:error, reason} ->
                {:error,
                 Dextrin.Error.binary("struct #{inspect(name)} violates its schema: #{reason}")}
            end

          {:unknown, _registry} ->
            {:ok, Struct.positional(name, fields)}
        end

      _ ->
        {:ok, Struct.positional(name, fields)}
    end
  end

  defp build_struct(_, _opts),
    do: {:error, Dextrin.Error.binary("malformed struct (tag #{Tags.t_struct()}) payload")}

  defp build_time(total_micro) when is_integer(total_micro) and total_micro >= 0 do
    {microsecond, rem1} = {rem(total_micro, 1_000_000), div(total_micro, 1_000_000)}
    {second, rem2} = {rem(rem1, 60), div(rem1, 60)}
    {minute, hour} = {rem(rem2, 60), div(rem2, 60)}
    %Time{hour: hour, minute: minute, second: second, microsecond: {microsecond, 6}}
  end

  defp build_datetime_offset([epoch_micros, offset_minutes])
       when is_integer(epoch_micros) and is_integer(offset_minutes) do
    offset_seconds = offset_minutes * 60
    utc = DateTime.from_unix!(epoch_micros, :microsecond)
    local = DateTime.add(utc, offset_seconds, :second)

    {:ok,
     %DateTime{
       year: local.year,
       month: local.month,
       day: local.day,
       hour: local.hour,
       minute: local.minute,
       second: local.second,
       microsecond: local.microsecond,
       time_zone: "fixed",
       zone_abbr: format_offset(offset_seconds),
       utc_offset: offset_seconds,
       std_offset: 0
     }}
  end

  defp build_datetime_offset(_),
    do:
      {:error,
       Dextrin.Error.binary("malformed datetime (tag #{Tags.t_datetime_offset()}) payload")}

  defp build_duration([bitmask | field_values]) when is_integer(bitmask) do
    fields = Tags.duration_bits() |> Enum.filter(fn field -> bit_set?(bitmask, field) end)

    if length(fields) == length(field_values) do
      base = %Dextrin.Duration{}

      {:ok,
       Enum.zip(fields, field_values)
       |> Enum.reduce(base, fn {field, value}, acc -> Map.put(acc, field, value) end)}
    else
      {:error, Dextrin.Error.binary("duration bitmask doesn't match field count")}
    end
  end

  defp build_duration(_),
    do: {:error, Dextrin.Error.binary("malformed duration (tag #{Tags.t_duration()}) payload")}

  defp build_regex([source, flags_byte]) when is_binary(source) and is_integer(flags_byte) do
    case Regex.compile(source, Tags.regex_byte_to_opts(flags_byte)) do
      {:ok, regex} ->
        {:ok, regex}

      {:error, reason} ->
        {:error, Dextrin.Error.binary("invalid regex in .dxnb: #{inspect(reason)}")}
    end
  end

  defp build_regex(_),
    do: {:error, Dextrin.Error.binary("malformed regex (tag #{Tags.t_regex()}) payload")}

  defp build_custom([name, value], opts) when is_binary(name) do
    case Keyword.get(opts, :registry) do
      %Registry{} = registry ->
        case Registry.fetch_tag(registry, name) do
          {:ok, decoder} -> with {:ok, decoded} <- decoder.(value), do: {:ok, decoded}
          :error -> {:ok, CustomTag.new(name, value)}
        end

      _ ->
        {:ok, CustomTag.new(name, value)}
    end
  end

  defp build_custom(_, _opts),
    do: {:error, Dextrin.Error.binary("malformed custom tag (tag #{Tags.t_custom()}) payload")}

  defp bit_set?(bitmask, field) do
    index = Enum.find_index(Tags.duration_bits(), &(&1 == field))
    Bitwise.band(bitmask, Bitwise.bsl(1, index)) != 0
  end

  defp format_offset(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    abs_s = abs(seconds)
    h = div(abs_s, 3600)
    m = div(rem(abs_s, 3600), 60)

    "#{sign}#{String.pad_leading(Integer.to_string(h), 2, "0")}:#{String.pad_leading(Integer.to_string(m), 2, "0")}"
  end

  # ---- shared helpers ---------------------------------------------------------

  defp decode_map_pairs(pair_count, bin, opts) do
    with {:ok, items, rest} <- decode_n_items(bin, pair_count * 2, opts) do
      {:ok, pairs_from_flat(items), rest}
    end
  end

  defp decode_n_items(bin, count, opts), do: decode_n_items(bin, count, opts, [])

  defp decode_n_items(bin, 0, _opts, acc), do: {:ok, Enum.reverse(acc), bin}

  defp decode_n_items(bin, n, opts, acc) do
    with {:ok, value, rest} <- decode_item(bin, opts) do
      decode_n_items(rest, n - 1, opts, [value | acc])
    end
  end

  defp pairs_from_flat(items) do
    items
    |> Enum.chunk_every(2)
    |> Enum.map(fn [k, v] -> {k, v} end)
  end

  defp decode_float(bits) do
    <<sign::1, exponent::11, mantissa::52>> = <<bits::64>>

    cond do
      exponent == 0x7FF and mantissa != 0 ->
        :nan

      exponent == 0x7FF and sign == 0 ->
        :positive_infinity

      exponent == 0x7FF and sign == 1 ->
        :negative_infinity

      true ->
        <<f::float>> = <<bits::64>>
        f
    end
  end

  defp read_head(<<major::3, info::5, rest::binary>>) when info < 24, do: {:ok, major, info, rest}
  defp read_head(<<major::3, 24::5, n::8, rest::binary>>), do: {:ok, major, n, rest}
  defp read_head(<<major::3, 25::5, n::16, rest::binary>>), do: {:ok, major, n, rest}
  defp read_head(<<major::3, 26::5, n::32, rest::binary>>), do: {:ok, major, n, rest}
  defp read_head(<<major::3, 27::5, n::64, rest::binary>>), do: {:ok, major, n, rest}
  defp read_head(<<>>), do: {:error, Dextrin.Error.binary("unexpected end of input")}
  defp read_head(_), do: {:error, Dextrin.Error.binary("malformed CBOR item header")}

  defp take(bin, len) when byte_size(bin) >= len do
    <<taken::binary-size(len), rest::binary>> = bin
    {:ok, taken, rest}
  end

  defp take(_bin, _len),
    do: {:error, Dextrin.Error.binary("unexpected end of input (truncated item)")}
end
