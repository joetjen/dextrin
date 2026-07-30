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

  def print(%Bytes{data: data}, _opts),
    do: {:ok, tag_form("bytes", quote_string(Base.encode64(data)))}

  def print(%Char{codepoint: cp}, _opts), do: {:ok, "?" <> print_char_body(cp)}

  def print(%Symbol{name: name}, _opts), do: {:ok, name}
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
      {:ok, tag_form("array", "[" <> Enum.join(printed, " ") <> "]")}
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
    with {:ok, entries} <- print_entries(pairs, opts),
         do: {:ok, tag_form("ordered", "%{" <> entries <> "}")}
  end

  def print(%{} = map, opts) when not is_struct(map) do
    with {:ok, entries} <- print_entries(Map.to_list(map), opts),
         do: {:ok, "%{" <> entries <> "}"}
  end

  def print(%Struct{name: name, fields: {:keyed, pairs}}, opts) do
    keyed = Enum.map(pairs, fn {k, v} -> {Dextrin.Keyword.new(k), v} end)

    with {:ok, entries} <- print_entries(keyed, opts),
         do: {:ok, "%" <> name <> "{" <> entries <> "}"}
  end

  def print(%Struct{name: name, fields: {:positional, items}}, opts) do
    with {:ok, printed} <- print_all(items, opts),
         do: {:ok, "%" <> name <> "[" <> Enum.join(printed, ",") <> "]"}
  end

  def print(%Date{} = date, _opts), do: {:ok, "~D[" <> Date.to_iso8601(date) <> "]"}
  def print(%Time{} = time, _opts), do: {:ok, "~T[" <> Time.to_iso8601(time) <> "]"}

  def print(%DateTime{utc_offset: 0, std_offset: 0} = dt, _opts) do
    {:ok,
     "~U[" <>
       Date.to_iso8601(DateTime.to_date(dt)) <>
       " " <> Time.to_iso8601(DateTime.to_time(dt)) <> "Z]"}
  end

  def print(%DateTime{} = dt, _opts),
    do: {:ok, tag_form("datetime", quote_string(DateTime.to_iso8601(dt)))}

  def print(%Dextrin.Duration{} = d, _opts) do
    fields = Tags.duration_bits() |> Enum.map(&Map.get(d, &1))
    elixir_duration = build_elixir_duration(Tags.duration_bits(), fields)
    {:ok, tag_form("duration", quote_string(Duration.to_iso8601(elixir_duration)))}
  end

  def print(%Uuid{} = uuid, _opts), do: {:ok, tag_form("uuid", quote_string(Uuid.format(uuid)))}
  def print(%Uri{value: value}, _opts), do: {:ok, tag_form("uri", quote_string(value))}

  def print(%Regex{source: source, opts: re_opts}, _opts) do
    {:ok, "~r/" <> source <> "/" <> Tags.regex_opts_to_flags(re_opts)}
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
        print(Struct.keyed(name, Compiled.field_values(compiled, other)), opts)

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
     Dextrin.Error.action("cannot encode value with no DXN representation: #{inspect(other)}")}
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
           Dextrin.Error.action("tag encoder for #{inspect(module)} failed: #{inspect(reason)}")}
      end
    else
      _ ->
        {:error,
         Dextrin.Error.action("cannot encode value with no DXN representation: #{inspect(other)}")}
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

  # `Dextrin.Duration`'s plural field names (`:years`, `:months`, ...)
  # don't match Elixir's built-in `Duration` struct's singular ones
  # (`:year`, `:month`, ...) — mapped explicitly rather than assumed.
  defp build_elixir_duration(fields, values) do
    Enum.zip(fields, values)
    |> Enum.reduce(%Duration{}, fn
      {_field, nil}, acc ->
        acc

      {:years, v}, acc ->
        %{acc | year: v}

      {:months, v}, acc ->
        %{acc | month: v}

      {:weeks, v}, acc ->
        %{acc | week: v}

      {:days, v}, acc ->
        %{acc | day: v}

      {:hours, v}, acc ->
        %{acc | hour: v}

      {:minutes, v}, acc ->
        %{acc | minute: v}

      {:microseconds, micro}, acc ->
        %{acc | second: div(micro, 1_000_000), microsecond: {rem(micro, 1_000_000), 6}}
    end)
  end
end
