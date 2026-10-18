defmodule Dextrin.Canonical do
  @moduledoc """
  The canonical form of a value (`DXN.md` §1.5): one `.dxn` rendering,
  fixed down to the byte, so that values from different implementations
  can be compared as text.

      Dextrin.Canonical.print(%{b: 2, a: 1, "z" => 3})
      #=> {:ok, ~s(%{"z" => 3 a: 1 b: 2})}

  **Not `Dextrin.encode/2`.** The ordinary printer chooses what reads
  best; this one chooses nothing. One space between items, maps and
  sets in canonical order (by code point of each canonical form), floats
  by one exact algorithm, strings with one fixed set of escapes — the
  same rules every DXN implementation follows, which is what lets the
  Dextrin Conformance Suite compare two strings instead of two values.

  Keyed structs and ordered maps keep the order they hold: in a
  `%schema` body the order of entries is the order of the fields.
  """

  alias Dextrin.{
    Array,
    Bytes,
    Char,
    CustomTag,
    OrderedMap,
    Rational,
    SortedSet,
    Struct,
    Symbol,
    Uri,
    Uuid
  }

  @doc """
  The canonical form of `value`, or an `encode/unsupported` error for a
  value with no DXN meaning.
  """
  @spec print(term()) :: {:ok, String.t()} | {:error, Dextrin.Error.t()}
  def print(value) do
    {:ok, text(value)}
  catch
    {:unsupported, other} ->
      {:error,
       Dextrin.Error.action(
         "no canonical form for a value with no DXN meaning: #{inspect(other)}",
         "encode/unsupported"
       )}
  end

  # ---- per type (DXN.md §1.5's table, in its order) ------------------------

  defp text(nil), do: "nil"
  defp text(true), do: "true"
  defp text(false), do: "false"
  defp text(:nan), do: "NaN"
  defp text(:positive_infinity), do: "Infinity"
  defp text(:negative_infinity), do: "-Infinity"
  defp text(atom) when is_atom(atom), do: keyword(Atom.to_string(atom))
  defp text(i) when is_integer(i), do: Integer.to_string(i)
  defp text(f) when is_float(f), do: float(f)
  defp text(%Decimal{} = d), do: decimal(d)
  defp text(%Rational{numerator: n, denominator: d}), do: "#{n}/#{d}"
  defp text(s) when is_binary(s), do: string(s)
  defp text(%Char{codepoint: cp}), do: "?" <> char_body(cp)
  defp text(%Symbol{name: name}), do: name
  defp text(%Dextrin.Keyword{name: name}), do: keyword(name)
  defp text(list) when is_list(list), do: "[" <> items(list) <> "]"
  defp text(%Dextrin.Tuple{items: items}), do: "{" <> items(items) <> "}"
  defp text(%Array{items: items}), do: "@array[" <> items(Tuple.to_list(items)) <> "]"
  defp text(%MapSet{} = set), do: "@{" <> sorted_items(MapSet.to_list(set)) <> "}"
  defp text(%SortedSet{items: items}), do: "@sorted-set @{" <> sorted_items(items) <> "}"
  defp text(%OrderedMap{pairs: pairs}), do: "@ordered %{" <> entries(pairs) <> "}"

  defp text(%Struct{name: name, fields: {:keyed, pairs}}),
    do: "%" <> name <> "{" <> field_entries(pairs) <> "}"

  defp text(%Struct{name: name, fields: {:positional, values}}),
    do: "%" <> name <> "[" <> items(values) <> "]"

  defp text(%Date{} = date), do: "~D[" <> Date.to_iso8601(date) <> "]"
  defp text(%Time{} = time), do: "~T[" <> time(time) <> "]"

  defp text(%DateTime{utc_offset: 0, std_offset: 0} = dt),
    do:
      "~U[" <> Date.to_iso8601(DateTime.to_date(dt)) <> " " <> time(DateTime.to_time(dt)) <> "Z]"

  defp text(%DateTime{} = dt) do
    "@datetime " <>
      string(
        Date.to_iso8601(DateTime.to_date(dt)) <>
          "T" <> time(DateTime.to_time(dt)) <> offset(dt.utc_offset + dt.std_offset)
      )
  end

  defp text(%Dextrin.Duration{} = d) do
    {:ok, printed} = Dextrin.Text.Printer.print(d)
    printed
  end

  defp text(%Uuid{} = uuid), do: "@uuid " <> string(String.downcase(Uuid.format(uuid)))
  defp text(%Uri{value: value}), do: "@uri " <> string(value)
  defp text(%Bytes{data: data}), do: "@bytes " <> string(Base.encode64(data))

  defp text(%Regex{source: source, opts: opts}) do
    flags = opts |> Dextrin.Binary.Tags.regex_opts_to_flags() |> String.graphemes() |> Enum.sort()
    "~r/" <> source <> "/" <> Enum.join(flags)
  end

  defp text(%CustomTag{name: name, value: value}), do: "@" <> name <> " " <> text(value)

  defp text(%{} = map) when not is_struct(map),
    do: "%{" <> entries(Map.to_list(map), :sorted) <> "}"

  defp text(other), do: throw({:unsupported, other})

  # ---- collections -----------------------------------------------------------

  defp items(values), do: Enum.map_join(values, " ", &text/1)

  defp sorted_items(values), do: values |> Enum.map(&text/1) |> Enum.sort() |> Enum.join(" ")

  # A map's entries in canonical order of their keys; an ordered map's
  # in the order it holds.
  defp entries(pairs, order \\ :held) do
    pairs
    |> Enum.map(fn {key, value} -> {text(key), key, value} end)
    |> then(fn rows -> if order == :sorted, do: Enum.sort_by(rows, &elem(&1, 0)), else: rows end)
    |> Enum.map_join(" ", fn {key_text, key, value} -> entry(key_text, key, value) end)
  end

  # A keyword whose name is an identifier is written as shorthand;
  # every other key with the arrow.
  defp entry(key_text, key, value) do
    case shorthand_name(key) do
      {:ok, name} -> name <> ": " <> text(value)
      :error -> key_text <> " => " <> text(value)
    end
  end

  defp shorthand_name(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: identifier(Atom.to_string(atom))

  defp shorthand_name(%Dextrin.Keyword{name: name}), do: identifier(name)
  defp shorthand_name(_), do: :error

  # A keyed struct's entries: a field name is written as shorthand when
  # it is an identifier, and every entry keeps its place.
  defp field_entries(pairs) do
    Enum.map_join(pairs, " ", fn
      {name, value} when is_binary(name) ->
        case identifier(name) do
          {:ok, name} -> name <> ": " <> text(value)
          :error -> string(name) <> " => " <> text(value)
        end

      {key, value} ->
        entry(text(key), key, value)
    end)
  end

  defp identifier(name) do
    if Dextrin.Text.Printer.bare_identifier?(name), do: {:ok, name}, else: :error
  end

  defp keyword(name) do
    case identifier(name) do
      {:ok, name} -> ":" <> name
      :error -> ":" <> string(name)
    end
  end

  # ---- numbers ----------------------------------------------------------------

  # DXN.md §1.5: the shortest digits that read back exactly, laid out
  # with ECMAScript's thresholds, `.0` on whole numbers, no `+` in an
  # exponent, and the sign of negative zero kept.
  defp float(f) do
    <<sign::1, _::63>> = <<f::float>>
    {digits, exponent} = shortest(abs(f))
    if sign == 1, do: "-" <> layout(digits, exponent), else: layout(digits, exponent)
  end

  # The shortest digit string d1..dk and the exponent n with
  # value = 0.d1..dk × 10^n, from Erlang's shortest round-trip printing.
  defp shortest(+0.0), do: {"0", 1}

  defp shortest(f) do
    {mantissa, exponent} =
      case String.split(Float.to_string(f), "e") do
        [m, e] -> {m, String.to_integer(e)}
        [m] -> {m, 0}
      end

    [whole, fraction] = String.split(mantissa, ".")
    all = whole <> fraction
    leading = String.length(all) - String.length(String.trim_leading(all, "0"))
    digits = all |> String.trim_leading("0") |> String.trim_trailing("0")
    {digits, String.length(whole) + exponent - leading}
  end

  defp layout(digits, n) do
    k = String.length(digits)

    cond do
      k <= n and n <= 21 ->
        digits <> String.duplicate("0", n - k) <> ".0"

      0 < n and n < k ->
        String.slice(digits, 0, n) <> "." <> String.slice(digits, n..-1//1)

      -6 < n and n <= 0 ->
        "0." <> String.duplicate("0", -n) <> digits

      true ->
        rest = if k == 1, do: "0", else: String.slice(digits, 1..-1//1)
        String.first(digits) <> "." <> rest <> "e" <> Integer.to_string(n - 1)
    end
  end

  # DXN.md §1.5: as it was given -- the coefficient with exactly
  # `scale` fractional digits and its sign, negative zero included; only
  # a positive exponent, which text cannot write, is spelled out.
  defp decimal(%Decimal{coef: coef, exp: exp, sign: sign}) do
    digits = Integer.to_string(coef)

    body =
      cond do
        exp >= 0 ->
          digits <> String.duplicate("0", exp)

        true ->
          scale = -exp
          padded = String.pad_leading(digits, scale + 1, "0")
          {whole, fraction} = String.split_at(padded, String.length(padded) - scale)
          whole <> "." <> fraction
      end

    if sign == -1, do: "-" <> body <> "M", else: body <> "M"
  end

  # ---- text ---------------------------------------------------------------------

  defp string(s), do: "\"" <> (s |> String.to_charlist() |> Enum.map_join(&escape/1)) <> "\""

  defp escape(?"), do: "\\\""
  defp escape(?\\), do: "\\\\"
  defp escape(?\n), do: "\\n"
  defp escape(?\t), do: "\\t"
  defp escape(?\r), do: "\\r"
  defp escape(cp) when cp < 0x20 or cp == 0x7F, do: hex_escape(cp)
  defp escape(cp), do: <<cp::utf8>>

  defp hex_escape(cp), do: "\\x{" <> String.downcase(Integer.to_string(cp, 16)) <> "}"

  defp char_body(?\s), do: "s"
  defp char_body(?\\), do: "\\\\"
  defp char_body(?\n), do: "\\n"
  defp char_body(?\t), do: "\\t"
  defp char_body(?\r), do: "\\r"

  defp char_body(cp) do
    if cp < 0x20 or cp == 0x7F or whitespace?(cp), do: hex_escape(cp), else: <<cp::utf8>>
  end

  defp whitespace?(cp), do: String.match?(<<cp::utf8>>, ~r/^\s$/u)

  # ---- time -----------------------------------------------------------------------

  # HH:MM:SS, then the fraction with trailing zeros removed, or nothing
  # when it is zero.
  defp time(%Time{} = time) do
    case String.split(Time.to_iso8601(time), ".") do
      [seconds] ->
        seconds

      [seconds, fraction] ->
        case String.trim_trailing(fraction, "0") do
          "" -> seconds
          kept -> seconds <> "." <> kept
        end
    end
  end

  defp offset(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    minutes = div(abs(seconds), 60)
    sign <> pad2(div(minutes, 60)) <> ":" <> pad2(rem(minutes, 60))
  end

  defp pad2(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
end
