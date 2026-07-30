defmodule Dextrin.Generators do
  @moduledoc """
  Shared `StreamData` generators for property-based tests.

  `dxn_value/0`'s scalar pool is deliberately restricted to the subset
  of DXN-representable values already confirmed (by manual round-trip
  auditing) to survive `encode/2`/`decode/2` and
  `encode_binary/2`/`decode_binary/2` unchanged. A few types are
  deliberately left out, each for a specific, already-understood
  reason rather than an oversight:

    * `DateTime` — `.dxnb`/`@datetime` normalize to a fixed
      integer-microsecond precision, so a literal built at a lower
      display precision doesn't structurally `==` what comes back.
    * `Dextrin.Duration` — the text path can't distinguish an
      explicit `0` field from an absent one (Elixir's own ISO8601
      `Duration` collapses both), so `0` becomes `nil` on the way back.
    * A keyed `Dextrin.Struct` with no registered schema — `.dxnb`
      structs are always positional (`DXN.md` §2.1), so only the
      positional constructor is used here.
    * `Regex` — not reliably `==`-comparable across separate compiles
      even in plain Elixir, independent of Dextrin.
    * A `Decimal` with a positive exponent — `DXN.md`'s `decimal`
      grammar (§1.1) has no exponent notation at all (unlike `float`),
      only fixed `digits[.digits]M` — so one can't be *spelled* in
      text without expanding it to trailing zeros, which changes its
      exact coefficient/exponent shape (its numeric value survives,
      its precise representation doesn't). `decimal/0` only generates
      `exponent <= 0`, which fixed notation always covers exactly.
    * A `Decimal` with a zero coefficient and negative sign (`-0M`) —
      `.dxnb`'s wire encoding is `[exponent, sign * coefficient]`
      (`DXN.md` §2.2), and `-1 * 0` and `1 * 0` are the same integer,
      so the sign of a zero coefficient never survives `encode_binary`
      /`decode_binary` at all. This is a real, still-open gap in the
      wire format itself (fixing it would mean encoding sign
      separately from coefficient, a breaking `.dxnb` change) rather
      than something a property test firing here would be telling you
      anything new about — `decimal/0` forces `sign: 1` whenever
      `coef: 0` to avoid manufacturing an already-known failure on
      every run.

  Including any of these would turn "a property failed" into "a
  known asymmetry fired," which is worse than not testing them via
  a property at all — they already have their own targeted unit
  tests elsewhere.
  """

  use ExUnitProperties

  import StreamData

  @reserved ~w(nil true false NaN Infinity)

  @doc "A valid bare `identifier` (`DXN.md` §1.1) — safe for a `Dextrin.Symbol` name or a struct/type name, both printed unquoted, unlike a keyword's."
  def identifier do
    first_chars = Enum.map(?a..?z, &<<&1>>) ++ Enum.map(?A..?Z, &<<&1>>) ++ ["_"]
    rest_chars = first_chars ++ Enum.map(?0..?9, &<<&1>>) ++ ["-"]

    gen all(
          first <- member_of(first_chars),
          rest <- list_of(member_of(rest_chars), max_length: 8),
          name = Enum.join([first | rest]),
          name not in @reserved
        ) do
      name
    end
  end

  @doc "An exact-ratio `Decimal` — never reduced, so equal-value but differently-shaped decimals stay distinct on purpose. See the moduledoc for why `exponent` is capped at 0 and `sign` is forced positive when `coefficient` is 0."
  def decimal do
    gen all(
          coef <- non_negative_integer(),
          sign <- if(coef == 0, do: constant(1), else: member_of([1, -1])),
          exp <- integer(-8..0)
        ) do
      Decimal.new(sign, coef, exp)
    end
  end

  @doc "A `Dextrin.Rational` — never silently reduced (`22/7` and `44/14` are distinct values), matching `Dextrin.Rational`'s own contract."
  def rational do
    gen all(
          numerator <- integer(),
          denominator <- positive_integer()
        ) do
      Dextrin.Rational.new(numerator, denominator)
    end
  end

  @doc "A `Dextrin.Char` from a small, curated codepoint set — avoids surrogate-range edge cases while still covering ASCII, the space special-case (`?s`), and non-ASCII."
  def char do
    ["a", "Z", "0", " ", "!", "_", "é", "🎉"]
    |> Enum.map(fn <<cp::utf8>> -> cp end)
    |> member_of()
    |> map(&Dextrin.Char.new/1)
  end

  def bytes, do: map(binary(max_length: 12), &Dextrin.Bytes.new/1)

  def symbol, do: map(identifier(), &Dextrin.Symbol.new/1)

  @doc "A `Dextrin.Keyword` from an arbitrary string — safe even when not identifier-shaped, since the printer quotes non-identifier keyword names automatically."
  def keyword, do: map(string(:utf8, max_length: 15), &Dextrin.Keyword.new/1)

  def uuid, do: map(binary(length: 16), &Dextrin.Uuid.new/1)

  @doc "A bare atom, safe for `Dextrin.encode/2`'s atom-as-keyword support (`DXN.md` §1.3) — `nil`/`true`/`false` filtered out, since those stay their own literals rather than becoming a keyword named `nil`/`true`/`false`."
  def atom do
    filter(StreamData.atom(:alphanumeric), &(&1 not in [nil, true, false]))
  end

  def uri, do: map(string(:utf8, max_length: 20), &Dextrin.Uri.new/1)

  def date do
    gen all(days <- integer(-40_000..40_000)) do
      Date.add(~D[1970-01-01], days)
    end
  end

  @built_in_tags ~w(ordered sorted-set array uuid uri bytes datetime duration)

  @doc """
  A valid custom-tag name — an `identifier` (tags are printed
  unquoted, like a symbol/struct name) that isn't one of the built-in
  tag names, so it stays a `Dextrin.CustomTag` on the way back instead
  of being interpreted as a built-in. Also excludes every name
  starting with `_`: `priv/grammar/dxn.aether`'s `AT_DISCARD := "@_"`
  is a fixed 2-char token that wins over the longer `IDENTIFIER` match
  at every `@_...` position (its own comment: "a custom tag can never
  be named `_...`") — `@_foo` always tokenizes as discard `@_` +
  symbol `foo`, never as a custom tag literally named `_foo`.
  """
  def custom_tag_name do
    filter(identifier(), &(&1 not in @built_in_tags and not String.starts_with?(&1, "_")))
  end

  def custom_tag do
    gen all(
          name <- custom_tag_name(),
          value <- scalar()
        ) do
      Dextrin.CustomTag.new(name, value)
    end
  end

  def dextrin_tuple, do: map(list_of(scalar(), max_length: 4), &Dextrin.Tuple.new/1)
  def dextrin_array, do: map(list_of(scalar(), max_length: 4), &Dextrin.Array.new/1)
  def set, do: map(list_of(scalar(), max_length: 4), &MapSet.new/1)

  def plain_map, do: map(list_of(tuple({keyword(), scalar()}), max_length: 4), &Map.new/1)

  def ordered_map do
    map(list_of(tuple({keyword(), scalar()}), max_length: 4), &Dextrin.OrderedMap.new/1)
  end

  @doc "A positional `Dextrin.Struct` — the only struct shape `.dxnb` can represent at all (`DXN.md` §2.1), so this is the one used for binary round-trip properties; a keyed, unregistered struct is excluded from the generator entirely (see the moduledoc)."
  def positional_struct do
    gen all(
          name <- identifier(),
          fields <- list_of(scalar(), max_length: 4)
        ) do
      Dextrin.Struct.positional(name, fields)
    end
  end

  def sorted_set, do: map(list_of(integer(), max_length: 6), &Dextrin.SortedSet.new/1)

  def scalar do
    one_of([
      integer(),
      float(),
      string(:utf8, max_length: 20),
      boolean(),
      constant(nil),
      decimal(),
      rational(),
      char(),
      bytes(),
      symbol(),
      keyword(),
      uuid()
    ])
  end

  @doc """
  A recursive DXN value: scalars (see `scalar/0`) nested inside
  lists, tuples, arrays, sorted sets, and keyword-keyed plain maps.
  Scaled down so runs stay fast and shrinking stays legible — this is
  a correctness check, not a stress test (see `Dextrin.Binary.FuzzTest`
  for adversarial/malformed input instead).
  """
  def dxn_value do
    scale(
      tree(scalar(), fn child ->
        one_of([
          list_of(child, max_length: 4),
          map(list_of(child, max_length: 4), &Dextrin.Tuple.new/1),
          map(list_of(child, max_length: 4), &Dextrin.Array.new/1),
          map(list_of(tuple({keyword(), child}), max_length: 4), &Map.new/1),
          sorted_set()
        ])
      end),
      &min(&1, 8)
    )
  end
end
