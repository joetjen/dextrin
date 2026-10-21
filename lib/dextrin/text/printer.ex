defmodule Dextrin.Text.Printer do
  @moduledoc """
  `.dxn` printer — the reverse of `Dextrin.Text.Actions`. Single-line,
  minimal-whitespace output: a printer, not a formatter (no
  line-wrapping or indentation policy is specified anywhere in
  `DXN.md`) — `Dextrin.Text.Formatter.pretty/2` owns multi-line,
  human-readable rendering, built on top of this module.

  Returns `{:ok, _} | {:error, _}` rather than raising, matching
  `Dextrin.Binary.Encoder`'s equivalent path — the only way this can
  fail is a struct with no `tag_encoder` registered (or one that
  itself returns `{:error, _}`), never any of the built-in DXN value
  types.
  """

  alias Dextrin.{
    Array,
    Bytes,
    Char,
    CustomTag,
    OrderedMap,
    Rational,
    Registry,
    SortedSet,
    Struct,
    Symbol,
    Uri,
    Uuid
  }

  alias Dextrin.Binary.Tags
  alias Dextrin.Schema.Compiled
  alias Ichor.Toolkit.Result

  # `Dextrin.Keyword` deliberately not aliased to the bare name
  # `Keyword` — the built-in `Keyword` module (`Keyword.get/3`, used
  # below for `opts`) needs that name instead, same fix as
  # `Dextrin.Text.Actions`'s `Duration` collision and
  # `Dextrin.Binary.Encoder`'s `Tuple` collision.

  @spec print(term(), keyword()) :: {:ok, String.t()} | {:error, Dextrin.Error.t()}
  def print(value, opts \\ [])

  def print(nil, _opts), do: {:ok, "nil"}
  def print(true, _opts), do: {:ok, "true"}
  def print(false, _opts), do: {:ok, "false"}

  def print(:nan, _opts), do: {:ok, "NaN"}
  def print(:positive_infinity, _opts), do: {:ok, "Infinity"}
  def print(:negative_infinity, _opts), do: {:ok, "-Infinity"}

  # `DXN.md` §1.3's own type table lists `keyword`'s natural Elixir
  # type as "Elixir atom" — `Dextrin.Keyword` only exists as the wire
  # -shape decode produces (never an atom, so untrusted input can't
  # exhaust the atom table); nothing about that decode-side safety
  # concern applies to an atom the caller's own code already created,
  # so encode accepts a bare atom exactly as if it were
  # `Dextrin.Keyword.new(Atom.to_string(atom))`.
  def print(atom, _opts) when is_atom(atom) and atom not in [nil, true, false] do
    {:ok, ":" <> keyword_name(Atom.to_string(atom))}
  end

  def print(i, _opts) when is_integer(i), do: {:ok, Integer.to_string(i)}
  def print(f, _opts) when is_float(f), do: {:ok, Float.to_string(f)}

  def print(%Decimal{} = d, _opts), do: {:ok, Decimal.to_string(d, :normal) <> "M"}
  def print(%Rational{numerator: n, denominator: d}, _opts), do: {:ok, "#{n}/#{d}"}

  def print(s, _opts) when is_binary(s), do: {:ok, quote_string(s)}

  # A bitstring that is not a binary can be no string: it is bits.
  def print(bits, opts) when is_bitstring(bits), do: print(Bytes.new(bits), opts)

  def print(%Bytes{data: data}, _opts) when is_binary(data),
    do: {:ok, tag_form("bytes", quote_string(Base.encode64(data)))}

  def print(%Bytes{data: bits}, _opts), do: {:ok, bits_form(bits)}

  def print(%Char{codepoint: cp}, _opts), do: {:ok, "?" <> print_char_body(cp)}

  # A symbol is an identifier (DXN.md §1.1); a name that is not one has
  # no text form, and writing it verbatim would read back as something
  # else, or as nothing.
  def print(%Symbol{name: name}, _opts) do
    if bare_identifier?(name),
      do: {:ok, name},
      else:
        {:error,
         Dextrin.Error.action(
           "a symbol named #{inspect(name)} has no text form: its name is not an identifier",
           "encode/unsupported"
         )}
  end

  def print(%Dextrin.Keyword{name: name}, _opts), do: {:ok, ":" <> keyword_name(name)}

  def print(list, opts) when is_list(list) do
    with {:ok, printed} <- print_all(list, opts), do: {:ok, "[" <> Enum.join(printed, " ") <> "]"}
  end

  def print(%Dextrin.Tuple{items: items}, opts) do
    with {:ok, printed} <- print_all(items, opts),
         do: {:ok, "{" <> Enum.join(printed, " ") <> "}"}
  end

  def print(%Array{items: items}, opts) do
    with {:ok, printed} <- items |> Tuple.to_list() |> print_all(opts) do
      # `@array[`, the bracket against the tag, is the preferred spelling
      # (Jan, 2026-10-20); `@array [` still reads.
      {:ok, "@array[" <> Enum.join(printed, " ") <> "]"}
    end
  end

  def print(%MapSet{} = set, opts) do
    with {:ok, printed} <- set |> MapSet.to_list() |> print_all(opts) do
      {:ok, "@{" <> Enum.join(printed, " ") <> "}"}
    end
  end

  def print(%SortedSet{items: items}, opts) do
    with {:ok, printed} <- print_all(items, opts) do
      {:ok, tag_form("sorted-set", "@{" <> Enum.join(printed, " ") <> "}")}
    end
  end

  def print(%OrderedMap{pairs: pairs}, opts) do
    with :ok <- Dextrin.MapKey.check_pairs(pairs),
         {:ok, entries} <- print_entries(pairs, opts),
         do: {:ok, tag_form("ordered", "%{" <> entries <> "}")}
  end

  def print(%{} = map, opts) when not is_struct(map) do
    with :ok <- Dextrin.MapKey.check_pairs(Map.to_list(map)),
         {:ok, entries} <- print_entries(Map.to_list(map), opts),
         do: {:ok, "%{" <> entries <> "}"}
  end

  def print(%Struct{name: name, fields: {:keyed, pairs}} = struct, opts) do
    keyed = Enum.map(pairs, fn {k, v} -> {Dextrin.Keyword.new(k), v} end)

    with {:ok, entries} <- print_entries(keyed ++ extra_entries(struct), opts),
         do: {:ok, Struct.head(name, written_version(struct, opts)) <> "{" <> entries <> "}"}
  end

  # A positional struct's items, then its extra fields as entries
  # (DXN.md §1.2).
  def print(%Struct{name: name, fields: {:positional, items}} = struct, opts) do
    with {:ok, printed} <- print_all(items, opts),
         {:ok, extra} <- print_entries(extra_entries(struct), opts) do
      body = Enum.reject([Enum.join(printed, ","), extra], &(&1 == "")) |> Enum.join(",")
      {:ok, Struct.head(name, written_version(struct, opts)) <> "[" <> body <> "]"}
    end
  end

  # Dates and times are ISO 8601 strings under their tag (DXN.md §1.2,
  # Jan, 2026-10-20), written by Dextrin.Temporal.
  def print(value, _opts)
      when is_struct(value, Date) or is_struct(value, Time) or is_struct(value, DateTime) or
             is_struct(value, NaiveDateTime) or is_struct(value, Dextrin.Nanos) or
             is_struct(value, Dextrin.Duration) do
    {:ok, tag, text} = Dextrin.Temporal.tagged(value)
    {:ok, tag_form(tag, quote_string(text))}
  end

  def print(%Uuid{} = uuid, _opts), do: {:ok, tag_form("uuid", quote_string(Uuid.format(uuid)))}

  def print(%Dextrin.ObjectId{} = id, _opts),
    do: {:ok, tag_form("objectid", quote_string(Dextrin.ObjectId.format(id)))}

  def print(%Dextrin.Ip{} = ip, _opts),
    do: {:ok, tag_form("ip", quote_string(Dextrin.Ip.format(ip)))}

  def print(%Uri{value: value}, _opts), do: {:ok, tag_form("uri", quote_string(value))}

  # `@regex "pattern"`, its flags in a header when it has any (DXN.md §1.2).
  def print(%Regex{source: source, opts: re_opts}, _opts) do
    {:ok, regex_form(Tags.regex_opts_to_flags(re_opts), quote_string(source))}
  end

  def print(%CustomTag{name: name, value: value}, opts) do
    with {:ok, printed} <- print(value, opts), do: {:ok, tag_form(name, printed)}
  end

  # Reached only for a struct none of the clauses above recognized —
  # i.e. a genuine application struct. Two independent extension
  # points, checked in order: a schema-registered struct
  # (`put_struct_module/3`) is rebuilt as the equivalent keyed
  # `Dextrin.Struct` and re-printed through that existing clause above
  # (reusing its recursive field printing rather than duplicating it);
  # only if no schema module matches does this fall through to
  # `put_tag_encoder/4`, the custom-tag-style escape hatch for
  # anything without real field structure.
  def print(%module{} = other, opts) do
    registry = Keyword.get(opts, :registry, Registry.new())

    case Registry.fetch_schema_name_for_module(registry, module) do
      {:ok, name} ->
        {:ok, compiled, _registry} = Registry.fetch_struct_schema(registry, name)

        print(
          Struct.keyed(
            name,
            Compiled.field_values(compiled, other),
            nil,
            Struct.runtime_extra(other)
          ),
          opts
        )

      :error ->
        print_via_tag_encoder(other, module, opts)
    end
  end

  # A true catch-all — every DXN-representable Elixir shape has its
  # own clause above; whatever reaches here (a PID, a port, a
  # reference, a function, a raw Elixir tuple that isn't
  # `Dextrin.Tuple`, ...) has no DXN representation at all. `encode/2`
  # promises `{:ok, _} | {:error, _}` in its own typespec, never a
  # raised exception, so this returns a clean error instead of letting
  # the lack of a matching clause crash with `FunctionClauseError`.
  def print(other, _opts) do
    {:error,
     Dextrin.Error.action(
       "cannot encode value with no DXN representation: #{inspect(other)}",
       "encode/unsupported"
     )}
  end

  defp print_via_tag_encoder(other, module, opts) do
    with %Registry{} = registry <- Keyword.get(opts, :registry, :none),
         {:ok, {name, encoder}} <- Registry.fetch_tag_encoder(registry, module) do
      with {:ok, inner_value} <- encoder.(other),
           {:ok, printed} <- print(inner_value, opts) do
        {:ok, tag_form(name, printed)}
      else
        {:error, reason} ->
          {:error,
           Dextrin.Error.action(
             "tag encoder for #{inspect(module)} failed: #{inspect(reason)}",
             "encode/unsupported"
           )}
      end
    else
      _ ->
        {:error,
         Dextrin.Error.action(
           "cannot encode value with no DXN representation: #{inspect(other)}",
           "encode/unsupported"
         )}
    end
  end

  # ---- helpers --------------------------------------------------------------

  defp tag_form(name, printed_value), do: "@" <> name <> " " <> printed_value

  defp print_all(values, opts) do
    Result.reduce_ok(values, [], fn value, acc ->
      case print(value, opts) do
        {:ok, printed} -> {:ok, [printed | acc]}
        {:error, _} = err -> err
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  # `map_entry`'s colon-shorthand (`DXN.md` §1.2) is `identifier ":"
  # value` specifically — an `identifier`, never a quoted string, so
  # it's only reachable for a `Dextrin.Keyword` whose name is already a
  # bare identifier. Any other name (empty, containing spaces, a
  # leading digit, ...) has no colon-shorthand form at all and MUST
  # fall back to the arrow form instead, printing the keyword as an
  # ordinary value (`:"name"`) on the key side — `quote_string(name) <>
  # ":"` looks superficially plausible but is simply not valid
  # `map_entry` syntax (a genuine bug this once produced: `%{"":0}`
  # for an empty-name keyword, which fails to parse back at all).
  defp print_entries(pairs, opts) do
    Result.reduce_ok(pairs, [], fn
      {%Dextrin.Keyword{name: name}, value}, acc ->
        print_keyword_entry(name, value, opts, acc)

      # A bare atom key (`nil`/`true`/`false` excluded — those are
      # `boolean`/`nil` values, not stand-ins for a `keyword` name) is
      # accepted the same way a bare atom value is (see `print/2`):
      # `DXN.md` §1.3 documents `keyword` as "Elixir atom" in the
      # first place, so `%{x: 1}` (atom key) and
      # `%{Dextrin.Keyword.new("x") => 1}` print identically.
      {atom, value}, acc when is_atom(atom) and atom not in [nil, true, false] ->
        print_keyword_entry(Atom.to_string(atom), value, opts, acc)

      {key, value}, acc ->
        with {:ok, printed_key} <- print(key, opts),
             {:ok, printed_value} <- print(value, opts) do
          {:ok, [printed_key <> "=>" <> printed_value | acc]}
        end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.join(Enum.reverse(acc), ",")}
      {:error, _} = err -> err
    end
  end

  defp print_keyword_entry(name, value, opts, acc) do
    if bare_identifier?(name) do
      case print(value, opts) do
        {:ok, printed} -> {:ok, [name <> ":" <> printed | acc]}
        {:error, _} = err -> err
      end
    else
      with {:ok, printed_value} <- print(value, opts) do
        {:ok, [":" <> quote_string(name) <> "=>" <> printed_value | acc]}
      end
    end
  end

  defp keyword_name(name) do
    if bare_identifier?(name), do: name, else: quote_string(name)
  end

  @doc """
  Whether `name` is a valid bare `identifier` (`DXN.md` §1.1) on its
  own — the one thing that decides whether a `Dextrin.Keyword` can use
  `map_entry`'s colon-shorthand (`identifier ":" value`) at all, or
  must fall back to the arrow form instead. Public so
  `Dextrin.Text.Formatter` can apply the same rule rather than
  duplicating this check (or, worse, not checking at all — the bug
  this once was: an empty or space-containing keyword name printed as
  `"": 0` / a bare `: 0`, neither of which parses back).
  """
  @spec bare_identifier?(String.t()) :: boolean()
  def bare_identifier?(name) do
    case Dextrin.Text.Grammar.tokenize(name) do
      {:ok, [%{name: :IDENTIFIER, text: ^name}]} -> true
      _ -> false
    end
  end

  defp print_char_body(cp) when cp == ?\s, do: "s"

  defp print_char_body(cp) do
    case cp do
      ?\n -> "\\n"
      ?\t -> "\\t"
      ?\r -> "\\r"
      ?\" -> "\\\""
      ?\\ -> "\\\\"
      _ when cp < 0x20 -> "\\x{#{Integer.to_string(cp, 16)}}"
      _ -> <<cp::utf8>>
    end
  end

  defp quote_string(s) do
    "\"" <>
      (s
       |> String.to_charlist()
       |> Enum.map_join(&escape_char/1)) <> "\""
  end

  defp escape_char(?\"), do: "\\\""
  defp escape_char(?\\), do: "\\\\"
  defp escape_char(?\n), do: "\\n"
  defp escape_char(?\t), do: "\\t"
  defp escape_char(?\r), do: "\\r"
  defp escape_char(cp) when cp < 0x20, do: "\\x{#{Integer.to_string(cp, 16)}}"
  defp escape_char(cp), do: <<cp::utf8>>

  # The version a struct is written with: the latest loaded version of
  # its schema, or its own when there is no schema (DXN.md §4.8).
  @doc false
  @spec written_version(Struct.t(), keyword()) :: pos_integer() | nil
  def written_version(struct, opts),
    do: Registry.as_written(Keyword.get(opts, :registry), struct).version

  # A struct's extra fields as entries: a name is written like a field
  # name, any other map key as itself (DXN.md §1.2).
  @doc false
  @spec extra_entries(Struct.t()) :: [{term(), term()}]
  def extra_entries(%Struct{extra: extra}) do
    Enum.map(extra, fn
      {key, value} when is_binary(key) -> {Dextrin.Keyword.new(key), value}
      pair -> pair
    end)
  end

  @doc false
  # `@bits {"..." n}` (DXN.md §1.5): the bytes in base64, the unused bits
  # zero, and the count. Shared with the canonical form.
  @spec bits_form(bitstring()) :: String.t()
  def bits_form(bits) do
    {data, count} = Dextrin.Bits.parts(bits)

    tag_form(
      "bits",
      "{" <> quote_string(Base.encode64(data)) <> " " <> Integer.to_string(count) <> "}"
    )
  end

  @doc false
  # `@regex "pattern"`, or `@regex(flags) "pattern"` (DXN.md §1.2).
  def regex_form("", pattern), do: "@regex " <> pattern
  def regex_form(flags, pattern), do: "@regex(" <> flags <> ") " <> pattern
end
