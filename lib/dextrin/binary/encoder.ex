defmodule Dextrin.Binary.Encoder do
  @moduledoc """
  `.dxnb` encoder — a recursive walk over CBOR's major types plus a
  fixed tag dispatch table, matching `DXN.md` §2.2's table row order.

  Hand-rolled rather than built on a generic CBOR library, because
  `.dxnb` needs several things no such library is likely to get right
  by default — each one an integrity concern `DXN.md` §2.2 calls out
  explicitly: bignums past 64 bits *must* use tag 2/3's two's-complement
  byte form (a generic encoder more easily defaults to a float, or
  refuses arbitrary-precision integers outright); timestamps/datetimes
  *must* use tag 1's integer form, never the float form, which loses
  microsecond precision at scale; and the private tag block (200–214)
  plus the value-sharing extension (tags 28/29) aren't things a generic
  library has any built-in concept of. Given both directions need
  writing regardless, a direct recursive encoder/decoder pair working
  over CBOR's major types (0–7) plus a fixed tag table is less code,
  and less risk, than adapting a general-purpose library to every one
  of these constraints.

  Envelope (`magic` `version` `cbor_item`, `DXN.md` §2.1) is written
  once, at `encode/2` itself; everything below that is `encode_item/2`,
  one recursive function keyed on the Elixir value's own shape.

  Determinism is explicitly not a goal: `DXN.md` doesn't require
  canonical/deterministic CBOR (no sorted map keys, no shortest-form
  mandate), and map key order isn't semantically meaningful for DXN's
  own `map` type either. So this encoder makes reasonable choices
  (shortest integer form, no forced key sorting) but two encodings of
  an equal value aren't guaranteed byte-identical —
  `decode(encode(v)) == v` is the contract, not byte-for-byte
  reproducibility across runs.
  """

  alias Dextrin.Binary.Tags
  alias Dextrin.{Array, Bytes, CustomTag, OrderedMap, Rational, SortedSet, Struct, Uri, Uuid}
  alias Dextrin.Schema.Compiled
  alias Ichor.Toolkit.Result

  # `Dextrin.Tuple` is deliberately not aliased to the bare name `Tuple`
  # — the built-in `Tuple` module (`Tuple.to_list/1`) is used below for
  # `Dextrin.Array`'s own Elixir-tuple-backed `items`.
  import Bitwise

  @magic "DX"
  @version 1

  @epoch ~D[1970-01-01]

  @spec encode(term(), keyword()) :: {:ok, binary()} | {:error, Dextrin.Error.t()}
  def encode(value, opts \\ []) do
    if Keyword.get(opts, :share, false) do
      # Two passes, deliberately — a single pass can't know in advance
      # whether a value will repeat, so it would have to wrap *every*
      # compound value's first occurrence in tag 28 speculatively,
      # paying a few bytes of overhead on every one-off value just in
      # case it turns out to recur (confirmed as a real, measurable
      # regression while testing this: `share: true` was strictly
      # larger than `share: false` for input with no repeats at all).
      # Counting occurrences first means only genuinely-repeated
      # subtrees (count >= 2) ever get wrapped at all.
      Process.put(:dextrin_share_counts, count_occurrences(value, %{}))
      Process.put(:dextrin_share_seen, %{})
      Process.put(:dextrin_share_next_index, 0)
    end

    try do
      with {:ok, item} <- encode_item(value, opts) do
        {:ok, @magic <> <<@version>> <> item}
      end
    after
      Process.delete(:dextrin_share_counts)
      Process.delete(:dextrin_share_seen)
      Process.delete(:dextrin_share_next_index)
    end
  end

  # ---- value sharing (DXN.md §2.5) -------------------------------------------
  #
  # `share: true` opts in; off by default — a "share: true" and a
  # "share: false" encoding of the same value are both conformant, just
  # different sizes, so leaving it off keeps the default encode path a
  # single straightforward recursive walk with no counting pass.
  #
  # Whether a *given* repeated value is worth sharing is fully
  # calculable, not a heuristic or a guess: tag 28's header is always
  # exactly 2 bytes (tag number 28 needs CBOR's "1 extra byte" form),
  # and a tag-29 reference costs 2 bytes plus however many bytes the
  # index itself needs. So for a value encoding to `item_size` bytes
  # appearing `count` times, sharing wins exactly when
  # `(item_size + 2) + (count - 1) * (2 + index_size)` is less than
  # `count * item_size` — every quantity in that comparison is known
  # at encode time, nothing here depends on guessing what real
  # documents look like (`worth_sharing?/3` does the actual check;
  # `shareable?/1` only excludes `nil`/booleans, which are always
  # exactly 1 byte and so provably can never clear that bar regardless
  # of count — kept as a cheap skip, not a correctness boundary). This
  # also means a long, frequently-repeated *string* is correctly
  # shareable too — nothing here excludes strings by type — which is
  # what lets this one mechanism subsume `DXN.md` §2.4's narrower
  # string-only sharing: there's no real case where you'd want that
  # narrower form but not this general one.
  #
  # Uses the process dictionary to thread the occurrence counts and
  # "have I seen this value before, and at what index" through the
  # recursive encode without changing every function's signature to
  # carry an accumulator — scoped to one top-level `encode/2` call
  # (initialized and torn down there), never visible outside it. A
  # deliberate pragmatic choice, not the "purest" design, for a
  # single-threaded, synchronous walk.
  defp encode_item(value, opts) do
    if Keyword.get(opts, :share, false) and shareable?(value) do
      encode_maybe_shared(value, opts)
    else
      encode_item_dispatch(value, opts)
    end
  end

  defp shareable?(nil), do: false
  defp shareable?(b) when is_boolean(b), do: false
  defp shareable?(_), do: true

  defp count_occurrences(value, counts) do
    counts = if shareable?(value), do: Map.update(counts, value, 1, &(&1 + 1)), else: counts
    Enum.reduce(shareable_children(value), counts, &count_occurrences/2)
  end

  defp shareable_children(list) when is_list(list), do: list
  defp shareable_children(%Dextrin.Tuple{items: items}), do: items
  defp shareable_children(%Array{items: items}), do: Tuple.to_list(items)

  defp shareable_children(%OrderedMap{pairs: pairs}),
    do: Enum.flat_map(pairs, fn {k, v} -> [k, v] end)

  defp shareable_children(%MapSet{} = set), do: MapSet.to_list(set)
  defp shareable_children(%SortedSet{items: items}), do: items

  defp shareable_children(%Struct{fields: {:keyed, pairs}}),
    do: Enum.map(pairs, fn {_k, v} -> v end)

  defp shareable_children(%Struct{fields: {:positional, items}}), do: items
  defp shareable_children(%CustomTag{value: value}), do: [value]

  defp shareable_children(%{} = map) when not is_struct(map),
    do: Enum.flat_map(map, fn {k, v} -> [k, v] end)

  defp shareable_children(_), do: []

  defp encode_maybe_shared(value, opts) do
    seen = Process.get(:dextrin_share_seen)

    case Map.fetch(seen, value) do
      {:ok, index} ->
        {:ok, tag(Tags.t_shared_ref(), encode_integer(index))}

      :error ->
        with {:ok, item} <- encode_item_dispatch(value, opts) do
          count = Map.get(Process.get(:dextrin_share_counts, %{}), value, 1)
          index = Process.get(:dextrin_share_next_index)
          item_size = item |> IO.iodata_to_binary() |> byte_size()

          if count >= 2 and worth_sharing?(count, item_size, index) do
            Process.put(:dextrin_share_seen, Map.put(seen, value, index))
            Process.put(:dextrin_share_next_index, index + 1)
            {:ok, tag(Tags.t_shareable(), item)}
          else
            {:ok, item}
          end
        end
    end
  end

  defp worth_sharing?(count, item_size, index) do
    index_size = byte_size(head(0, index))
    shared_cost = item_size + 2 + (count - 1) * (2 + index_size)
    unshared_cost = count * item_size
    shared_cost < unshared_cost
  end

  # ---- scalars --------------------------------------------------------------

  defp encode_item_dispatch(nil, _opts), do: {:ok, head(7, 22)}
  defp encode_item_dispatch(false, _opts), do: {:ok, head(7, 20)}
  defp encode_item_dispatch(true, _opts), do: {:ok, head(7, 21)}

  defp encode_item_dispatch(:nan, _opts), do: {:ok, float_head() <> <<0x7FF8000000000000::64>>}

  defp encode_item_dispatch(:positive_infinity, _opts),
    do: {:ok, float_head() <> <<0x7FF0000000000000::64>>}

  defp encode_item_dispatch(:negative_infinity, _opts),
    do: {:ok, float_head() <> <<0xFFF0000000000000::64>>}

  defp encode_item_dispatch(i, _opts) when is_integer(i), do: {:ok, encode_integer(i)}
  defp encode_item_dispatch(f, _opts) when is_float(f), do: {:ok, float_head() <> <<f::float>>}

  defp encode_item_dispatch(%Decimal{sign: sign, coef: coef, exp: exp}, opts) do
    with {:ok, exponent} <- encode_item(exp, opts),
         {:ok, mantissa} <- encode_item(sign * coef, opts) do
      {:ok, tag(Tags.t_decimal(), array_of([exponent, mantissa]))}
    end
  end

  defp encode_item_dispatch(%Rational{numerator: n, denominator: d}, opts) do
    with {:ok, num} <- encode_item(n, opts), {:ok, den} <- encode_item(d, opts) do
      {:ok, tag(Tags.t_rational(), array_of([num, den]))}
    end
  end

  defp encode_item_dispatch(s, _opts) when is_binary(s), do: {:ok, text(s)}
  defp encode_item_dispatch(%Bytes{data: data}, _opts), do: {:ok, bytes(data)}

  defp encode_item_dispatch(%Dextrin.Char{codepoint: cp}, opts) do
    with {:ok, item} <- encode_item(cp, opts), do: {:ok, tag(Tags.t_char(), item)}
  end

  defp encode_item_dispatch(%Dextrin.Symbol{name: name}, _opts),
    do: {:ok, tag(Tags.t_symbol(), text(name))}

  defp encode_item_dispatch(%Dextrin.Keyword{name: name}, _opts),
    do: {:ok, tag(Tags.t_keyword(), text(name))}

  # ---- collections ------------------------------------------------------------

  defp encode_item_dispatch(list, opts) when is_list(list) do
    with {:ok, items} <- encode_all(list, opts), do: {:ok, array_of(items)}
  end

  defp encode_item_dispatch(%Dextrin.Tuple{items: items}, opts) do
    with {:ok, encoded} <- encode_all(items, opts),
         do: {:ok, tag(Tags.t_tuple(), array_of(encoded))}
  end

  defp encode_item_dispatch(%Array{items: items}, opts) do
    with {:ok, encoded} <- encode_all(Tuple.to_list(items), opts),
         do: {:ok, tag(Tags.t_array(), array_of(encoded))}
  end

  defp encode_item_dispatch(%{} = map, opts) when not is_struct(map), do: encode_map(map, opts)

  defp encode_item_dispatch(%OrderedMap{pairs: pairs}, opts) do
    with {:ok, encoded_pairs} <- encode_pairs(pairs, opts) do
      {:ok, tag(Tags.t_ordered(), map_of(encoded_pairs))}
    end
  end

  defp encode_item_dispatch(%MapSet{} = set, opts) do
    with {:ok, items} <- encode_all(MapSet.to_list(set), opts),
         do: {:ok, tag(Tags.t_set(), array_of(items))}
  end

  defp encode_item_dispatch(%SortedSet{items: items}, opts) do
    with {:ok, encoded} <- encode_all(items, opts),
         do: {:ok, tag(Tags.t_sorted_set(), array_of(encoded))}
  end

  # ---- struct (opaque only, for now — schema-driven encoding lands with Dextrin.Schema) ----

  defp encode_item_dispatch(%Struct{name: name, fields: {:positional, items}}, opts) do
    encode_struct(name, items, opts)
  end

  defp encode_item_dispatch(%Struct{name: name, fields: {:keyed, pairs}}, opts) do
    # No schema registered for `name` — falls back to the keyed pairs'
    # own iteration order. A real, unavoidable limitation: an opaque
    # struct with no schema can't be encoded to .dxnb losslessly
    # regardless, since the positional wire form has no field names to
    # consult in the first place (see `Dextrin.Struct`'s own moduledoc).
    encode_struct(name, Enum.map(pairs, fn {_k, v} -> v end), opts)
  end

  # ---- temporal ---------------------------------------------------------------

  defp encode_item_dispatch(%Date{} = date, opts) do
    with {:ok, item} <- encode_item(Date.diff(date, @epoch), opts),
         do: {:ok, tag(Tags.t_date(), item)}
  end

  defp encode_item_dispatch(%Time{} = time, opts) do
    {micro, _precision} = time.microsecond
    total = time.hour * 3_600_000_000 + time.minute * 60_000_000 + time.second * 1_000_000 + micro
    with {:ok, item} <- encode_item(total, opts), do: {:ok, tag(Tags.t_time(), item)}
  end

  defp encode_item_dispatch(%DateTime{utc_offset: 0, std_offset: 0} = dt, opts) do
    with {:ok, item} <- encode_item(DateTime.to_unix(dt, :microsecond), opts) do
      {:ok, tag(Tags.t_timestamp(), item)}
    end
  end

  defp encode_item_dispatch(%DateTime{} = dt, opts) do
    epoch_micros = DateTime.to_unix(dt, :microsecond)
    offset_minutes = div(dt.utc_offset + dt.std_offset, 60)

    with {:ok, micros_item} <- encode_item(epoch_micros, opts),
         {:ok, offset_item} <- encode_item(offset_minutes, opts) do
      {:ok, tag(Tags.t_datetime_offset(), array_of([micros_item, offset_item]))}
    end
  end

  defp encode_item_dispatch(%Dextrin.Duration{} = d, opts) do
    fields = Enum.reject(Tags.duration_bits(), fn field -> Map.get(d, field) == nil end)
    bitmask = Enum.reduce(fields, 0, fn field, acc -> acc ||| bit_for(field) end)

    # The whole payload is one well-formed CBOR array — bitmask as a
    # plain integer first element, not a raw byte spliced in ahead of
    # separate item bytes (that earlier version wasn't valid CBOR: a
    # tag's payload has to be a single item, not several concatenated
    # ones with no wrapper).
    with {:ok, bitmask_item} <- encode_item(bitmask, opts),
         {:ok, field_items} <- encode_all(Enum.map(fields, &Map.get(d, &1)), opts) do
      {:ok, tag(Tags.t_duration(), array_of([bitmask_item | field_items]))}
    end
  end

  # ---- extended -----------------------------------------------------------

  defp encode_item_dispatch(%Uuid{bytes: raw}, _opts), do: {:ok, tag(Tags.t_uuid(), bytes(raw))}
  defp encode_item_dispatch(%Uri{value: value}, _opts), do: {:ok, tag(Tags.t_uri(), text(value))}

  defp encode_item_dispatch(%Regex{source: source, opts: re_opts}, opts) do
    flags_byte = Tags.regex_opts_to_byte(re_opts)

    with {:ok, flags_item} <- encode_item(flags_byte, opts) do
      {:ok, tag(Tags.t_regex(), array_of([text(source), flags_item]))}
    end
  end

  defp encode_item_dispatch(%CustomTag{name: name, value: value}, opts) do
    with {:ok, item} <- encode_item(value, opts) do
      {:ok, tag(Tags.t_custom(), array_of([text(name), item]))}
    end
  end

  # Reached only for a struct none of the clauses above recognized —
  # i.e. a genuine application struct. Two independent extension
  # points, checked in order: a schema-registered struct
  # (`put_struct_module/3`) is rebuilt as the equivalent positional
  # `Dextrin.Struct` (`.dxnb` structs are always positional, §2.1) and
  # re-encoded through that existing clause above, reusing its
  # recursive field encoding rather than duplicating it; only if no
  # schema module matches does this fall through to `put_tag_encoder/4`,
  # the custom-tag-style escape hatch for anything without real field
  # structure.
  defp encode_item_dispatch(%module{} = other, opts) do
    registry = Keyword.get(opts, :registry, Dextrin.Registry.new())

    case Dextrin.Registry.fetch_schema_name_for_module(registry, module) do
      {:ok, name} ->
        {:ok, compiled, _registry} = Dextrin.Registry.fetch_struct_schema(registry, name)

        values =
          compiled |> Compiled.field_values(other) |> Enum.map(fn {_name, value} -> value end)

        encode_item(Struct.positional(name, values), opts)

      :error ->
        encode_via_tag_encoder(other, module, opts)
    end
  end

  defp encode_item_dispatch(other, _opts) do
    {:error,
     Dextrin.Error.binary("cannot encode value with no DXN representation: #{inspect(other)}")}
  end

  # ---- helpers -------------------------------------------------------------

  defp encode_via_tag_encoder(other, module, opts) do
    with %Dextrin.Registry{} = registry <- Keyword.get(opts, :registry, :none),
         {:ok, {name, encoder}} <- Dextrin.Registry.fetch_tag_encoder(registry, module) do
      with {:ok, inner_value} <- encoder.(other),
           {:ok, item} <- encode_item(inner_value, opts) do
        {:ok, tag(Tags.t_custom(), array_of([text(name), item]))}
      else
        {:error, reason} ->
          {:error,
           Dextrin.Error.binary(
             "tag encoder for #{inspect(module)} (#{name}) failed: #{inspect(reason)}"
           )}
      end
    else
      _ ->
        {:error,
         Dextrin.Error.binary("cannot encode value with no DXN representation: #{inspect(other)}")}
    end
  end

  defp encode_struct(name, values, opts) do
    with {:ok, name_item} <- encode_item(name, opts),
         {:ok, value_items} <- encode_all(values, opts) do
      {:ok, tag(Tags.t_struct(), array_of([name_item | value_items]))}
    end
  end

  defp encode_all(values, opts) do
    Result.reduce_ok(values, [], fn value, acc ->
      case encode_item(value, opts) do
        {:ok, item} -> {:ok, [item | acc]}
        {:error, _} = err -> err
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp encode_pairs(pairs, opts) do
    Result.reduce_ok(pairs, [], fn {k, v}, acc ->
      with {:ok, key_item} <- encode_item(k, opts),
           {:ok, val_item} <- encode_item(v, opts) do
        {:ok, [{key_item, val_item} | acc]}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp encode_map(map, opts) do
    with {:ok, pairs} <- encode_pairs(Map.to_list(map), opts), do: {:ok, map_of(pairs)}
  end

  defp bit_for(:years), do: 1 <<< 0
  defp bit_for(:months), do: 1 <<< 1
  defp bit_for(:weeks), do: 1 <<< 2
  defp bit_for(:days), do: 1 <<< 3
  defp bit_for(:hours), do: 1 <<< 4
  defp bit_for(:minutes), do: 1 <<< 5
  defp bit_for(:microseconds), do: 1 <<< 6

  import Bitwise

  # ---- raw CBOR item builders -----------------------------------------------

  defp head(major, n) when n < 24, do: <<major::3, n::5>>
  defp head(major, n) when n < 256, do: <<major::3, 24::5, n::8>>
  defp head(major, n) when n < 65_536, do: <<major::3, 25::5, n::16>>
  defp head(major, n) when n < 4_294_967_296, do: <<major::3, 26::5, n::32>>
  defp head(major, n), do: <<major::3, 27::5, n::64>>

  # NOT `head(7, 27)` — for every *other* major type, `head/2`'s job is
  # "encode this integer value using the fewest bytes CBOR allows,"
  # and 24-27 in the additional-info field are just an implementation
  # detail of *how* a value gets encoded, invisible to the decoded
  # result either way. Major 7 breaks that: the additional-info value
  # itself is what distinguishes "boolean/nil" from "16/32/64-bit
  # float," not a length-of-encoding detail — so 27 here has to mean
  # literally "double-precision float follows," emitted directly, not
  # "the number 27, encoded however many bytes that takes." Using
  # `head/2` for this was a real bug: it can produce a non-canonical,
  # oversized encoding that a spec-conformant CBOR reader (including,
  # it turned out, `Dextrin.Binary.Decoder` itself) doesn't recognize
  # as a float header at all. Found via `curl`-verifying the tag
  # registry for an unrelated open question, then hand-testing this
  # decoder against a standards-conformant hand-built float — not
  # something the original round-trip tests caught, since they only
  # ever exercised this encoder decoding its own (equally wrong) output.
  defp float_head, do: <<7::3, 27::5>>

  defp tag(number, item_iodata), do: head(6, number) <> IO.iodata_to_binary(item_iodata)

  defp array_of(items), do: head(4, length(items)) <> IO.iodata_to_binary(items)

  defp map_of(pairs) do
    head(5, length(pairs)) <> IO.iodata_to_binary(Enum.flat_map(pairs, fn {k, v} -> [k, v] end))
  end

  defp text(s), do: head(3, byte_size(s)) <> s
  defp bytes(b), do: head(2, byte_size(b)) <> b

  @bignum_max 18_446_744_073_709_551_615
  @bignum_min -18_446_744_073_709_551_616

  defp encode_integer(i) when i >= 0 and i <= @bignum_max, do: head(0, i)
  defp encode_integer(i) when i < 0 and i >= @bignum_min, do: head(1, -1 - i)

  defp encode_integer(i) when i >= 0,
    do: tag(Tags.t_bignum_pos(), bytes(:binary.encode_unsigned(i)))

  defp encode_integer(i), do: tag(Tags.t_bignum_neg(), bytes(:binary.encode_unsigned(-1 - i)))
end
