defmodule Dextrin.Text.Actions do
  @moduledoc """
  `Ichor.Actions` implementation for `Dextrin.Text.Grammar` — turns
  the raw capture tree `Grammar.Native` produces while matching
  `priv/grammar/dxn.aether` into actual `Dextrin.Value.t()` values.
  `context` is a `Dextrin.Registry.t()` — text parsing only ever reads
  it (to resolve struct schemas and custom tags), never mutates it.

  `handle_token/3` covers every scalar (numbers via
  `String.to_integer`/`Float.parse`/`Decimal.new`/a manual rational
  split; strings/chars through the shared escape-decoding in
  `Dextrin.Text.Escapes` so string bodies and char literals never
  duplicate escape logic); `handle_rule/3` covers every collection and
  `tag_form` (a dispatch table: built-in tag names from `DXN.md` §1.3
  go to a hardcoded handler in `dispatch_tag/3`, anything else falls
  through to a `Dextrin.Registry` lookup, then to `Dextrin.CustomTag`
  as the last resort).
  """

  @behaviour Ichor.Actions

  alias Dextrin.Text.Escapes
  alias Ichor.Toolkit.Result

  alias Dextrin.{
    Array,
    Char,
    CustomTag,
    Keyword,
    OrderedMap,
    Rational,
    Registry,
    SortedSet,
    Struct,
    Symbol,
    Tuple,
    Uri,
    Uuid
  }

  # Elixir's own built-in `Duration` module (ISO 8601 parsing, referenced
  # bare below) is deliberately not aliased here — `Dextrin.Duration`
  # (this library's own value type) is used fully-qualified instead, to
  # avoid shadowing the stdlib one.

  # ---- tokens -------------------------------------------------------------

  @impl true
  def handle_token(:NIL, _text, _ctx), do: {:ok, nil}
  def handle_token(:TRUE, _text, _ctx), do: {:ok, true}
  def handle_token(:FALSE, _text, _ctx), do: {:ok, false}

  def handle_token(:INTEGER, text, _ctx), do: {:ok, String.to_integer(text)}

  def handle_token(:FLOAT, "NaN", _ctx), do: {:ok, :nan}
  def handle_token(:FLOAT, "Infinity", _ctx), do: {:ok, :positive_infinity}
  def handle_token(:FLOAT, "-Infinity", _ctx), do: {:ok, :negative_infinity}

  def handle_token(:FLOAT, text, _ctx) do
    case Float.parse(text) do
      {float, ""} -> {:ok, float}
      _ -> {:error, action_error("invalid float literal #{inspect(text)}")}
    end
  end

  def handle_token(:DECIMAL, text, _ctx) do
    {:ok, Decimal.new(String.trim_trailing(text, "M"))}
  end

  def handle_token(:RATIONAL, text, _ctx) do
    [num, den] = String.split(text, "/", parts: 2)
    denominator = String.to_integer(den)

    if denominator == 0 do
      {:error, action_error("rational denominator must not be zero, got #{inspect(text)}")}
    else
      {:ok, Rational.new(String.to_integer(num), denominator)}
    end
  end

  def handle_token(:STRING, text, _ctx) do
    body = text |> String.trim_leading("\"") |> String.trim_trailing("\"")

    case Escapes.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, action_error("invalid string literal: #{reason}")}
    end
  end

  def handle_token(:CHAR, text, _ctx) do
    body = String.trim_leading(text, "?")

    case body do
      "s" -> {:ok, Char.new(?\s)}
      "\\" <> _ = escape_source -> decode_char_escape(escape_source)
      <<cp::utf8>> -> {:ok, Char.new(cp)}
      _ -> {:error, action_error("invalid char literal #{inspect(text)}")}
    end
  end

  def handle_token(:KEYWORD, text, _ctx) do
    body = String.trim_leading(text, ":")

    case body do
      "\"" <> _ ->
        inner = body |> String.trim_leading("\"") |> String.trim_trailing("\"")

        case Escapes.decode(inner) do
          {:ok, decoded} -> {:ok, Keyword.new(decoded)}
          {:error, reason} -> {:error, action_error("invalid keyword literal: #{reason}")}
        end

      identifier ->
        {:ok, Keyword.new(identifier)}
    end
  end

  def handle_token(:MAP_KEY, text, _ctx) do
    {:ok, Keyword.new(String.trim_trailing(text, ":"))}
  end

  def handle_token(:DATE_SIGIL, text, _ctx) do
    inner = text |> String.trim_leading("~D[") |> String.trim_trailing("]")

    case Date.from_iso8601(inner) do
      {:ok, date} ->
        {:ok, date}

      {:error, reason} ->
        {:error, action_error("invalid date #{inspect(inner)}: #{inspect(reason)}")}
    end
  end

  def handle_token(:TIME_SIGIL, text, _ctx) do
    inner = text |> String.trim_leading("~T[") |> String.trim_trailing("]")

    case Time.from_iso8601(inner) do
      {:ok, time} ->
        {:ok, normalize_microsecond(time)}

      {:error, reason} ->
        {:error, action_error("invalid time #{inspect(inner)}: #{inspect(reason)}")}
    end
  end

  def handle_token(:INSTANT_SIGIL, text, _ctx) do
    inner = text |> String.trim_leading("~U[") |> String.trim_trailing("]")

    with [date_text, time_text] <- String.split(inner, " ", parts: 2),
         {:ok, date} <- Date.from_iso8601(date_text),
         {:ok, time} <- Time.from_iso8601(String.trim_trailing(time_text, "Z")),
         {:ok, datetime} <- DateTime.new(date, normalize_microsecond(time), "Etc/UTC") do
      {:ok, datetime}
    else
      _ -> {:error, action_error("invalid instant #{inspect(inner)}")}
    end
  end

  def handle_token(:REGEX_SIGIL, text, _ctx) do
    case Regex.run(~r/^~r\/(.*)\/([imsuxfr]*)$/s, text) do
      [_, pattern, flags] ->
        # Atom-list form, not `Regex.compile(pattern, flags)` — the
        # string form triggers a deprecation warning for "r" (Elixir
        # prefers /U), even though "r" is DXN.md's own valid flag letter.
        case Regex.compile(pattern, Dextrin.Binary.Tags.regex_flags_to_opts(flags)) do
          {:ok, regex} ->
            {:ok, regex}

          {:error, reason} ->
            {:error, action_error("invalid regex #{inspect(text)}: #{inspect(reason)}")}
        end

      nil ->
        {:error, action_error("malformed regex literal #{inspect(text)}")}
    end
  end

  def handle_token(_token, text, _ctx), do: {:ok, text}

  # ---- rules --------------------------------------------------------------

  @impl true
  def handle_rule(:symbol, %{IDENTIFIER: cap}, ctx) do
    with {:ok, name, ctx} <- cap.eval.(ctx), do: {:ok, Symbol.new(name), ctx}
  end

  def handle_rule(:document, captures, ctx) do
    with {:ok, ctx} <- eval_header(captures, ctx),
         {:ok, value, ctx} <- captures.value.eval.(ctx) do
      {:ok, value, ctx}
    end
  end

  def handle_rule(:value, captures, ctx) do
    with {:ok, ctx} <- eval_discards(Map.get(captures, :discard, []), ctx),
         {:ok, value, ctx} <- captures.value_body.eval.(ctx) do
      {:ok, value, ctx}
    end
  end

  def handle_rule(:discard, %{value: value_cap}, ctx) do
    with {:ok, _discarded, ctx} <- value_cap.eval.(ctx) do
      {:ok, :__dextrin_discard__, ctx}
    end
  end

  def handle_rule(:list, captures, ctx) do
    with {:ok, values, ctx} <- eval_list(Map.get(captures, :value, []), ctx) do
      {:ok, values, ctx}
    end
  end

  def handle_rule(:tuple, captures, ctx) do
    with {:ok, values, ctx} <- eval_list(Map.get(captures, :value, []), ctx) do
      {:ok, Tuple.new(values), ctx}
    end
  end

  def handle_rule(:set_lit, captures, ctx) do
    with {:ok, values, ctx} <- eval_list(Map.get(captures, :value, []), ctx) do
      {:ok, MapSet.new(values), ctx}
    end
  end

  def handle_rule(:map_lit, captures, ctx) do
    with {:ok, pairs, ctx} <- eval_list(Map.get(captures, :map_entry, []), ctx) do
      {:ok, Map.new(pairs), ctx}
    end
  end

  def handle_rule(:map_entry, %{short_key: key_cap, short_val: val_cap}, ctx) do
    with {:ok, key, ctx} <- key_cap.eval.(ctx),
         {:ok, val, ctx} <- val_cap.eval.(ctx) do
      {:ok, {key, val}, ctx}
    end
  end

  def handle_rule(:map_entry, %{arrow_key: key_cap, arrow_val: val_cap}, ctx) do
    with {:ok, key, ctx} <- key_cap.eval.(ctx),
         {:ok, val, ctx} <- val_cap.eval.(ctx) do
      {:ok, {key, val}, ctx}
    end
  end

  def handle_rule(:struct_lit, %{name: name_cap} = captures, ctx) do
    with {:ok, name, ctx} <- name_cap.eval.(ctx) do
      cond do
        Map.has_key?(captures, :keyed) ->
          with {:ok, {:keyed, pairs}, ctx} <- captures.keyed.eval.(ctx) do
            materialize_struct(name, {:keyed, pairs}, ctx)
          end

        Map.has_key?(captures, :positional) ->
          with {:ok, {:positional, items}, ctx} <- captures.positional.eval.(ctx) do
            materialize_struct(name, {:positional, items}, ctx)
          end
      end
    end
  end

  def handle_rule(:struct_keyed, captures, ctx) do
    with {:ok, pairs, ctx} <- eval_list(Map.get(captures, :map_entry, []), ctx),
         {:ok, named_pairs} <- struct_field_names(pairs) do
      {:ok, {:keyed, named_pairs}, ctx}
    end
  end

  def handle_rule(:struct_positional, captures, ctx) do
    with {:ok, items, ctx} <- eval_list(Map.get(captures, :value, []), ctx) do
      {:ok, {:positional, items}, ctx}
    end
  end

  def handle_rule(:tag_form, %{name: name_cap} = captures, ctx) do
    with {:ok, name, ctx} <- name_cap.eval.(ctx) do
      dispatch_tag(name, captures.value, ctx)
    end
  end

  # ---- helpers --------------------------------------------------------------

  defp eval_header(%{header: header_cap}, ctx) do
    with {:ok, _version, ctx} <- header_cap.eval.(ctx), do: {:ok, ctx}
  end

  defp eval_header(_captures, ctx), do: {:ok, ctx}

  defp eval_discards([], ctx), do: {:ok, ctx}

  defp eval_discards([discard_cap | rest], ctx) do
    with {:ok, _sentinel, ctx} <- discard_cap.eval.(ctx) do
      eval_discards(rest, ctx)
    end
  end

  defp eval_list(caps, ctx) when is_list(caps) do
    Result.map_ok(caps, ctx, fn cap, ctx -> cap.eval.(ctx) end)
  end

  # A single (non-list) capture can arrive unwrapped when its
  # repetition matched exactly once and normalize_repeatables wasn't
  # applied (relevant for the raw-node re-entry path in `dispatch_tag/3`
  # below) — handled defensively rather than relying on it never happening.
  defp eval_list(cap, ctx), do: eval_list([cap], ctx)

  defp struct_field_names(pairs) do
    Result.reduce_ok(pairs, [], fn {key, val}, acc ->
      case field_name(key) do
        {:ok, name} ->
          {:ok, [{name, val} | acc]}

        :error ->
          {:error,
           action_error("struct field name must be an identifier or string, got #{inspect(key)}")}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp field_name(%Keyword{name: name}), do: {:ok, name}
  defp field_name(%Symbol{name: name}), do: {:ok, name}
  defp field_name(name) when is_binary(name), do: {:ok, name}
  defp field_name(_), do: :error

  defp materialize_struct(name, fields, ctx) do
    case ctx do
      %Registry{} = registry ->
        case Registry.fetch_struct_schema(registry, name) do
          {:ok, compiled, registry} ->
            materializer =
              case Registry.fetch_materializer(registry, name) do
                {:ok, fun} -> fun
                :error -> nil
              end

            # Fail-fast, decode-time enforcement — a schema violation
            # is an ordinary decode error, same channel as bad syntax,
            # with no lenient escape hatch to get the value anyway.
            case Dextrin.Schema.Validator.materialize(compiled, fields, materializer, registry) do
              {:ok, materialized} ->
                {:ok, materialized, registry}

              {:error, reason} ->
                {:error, action_error("struct #{inspect(name)} violates its schema: #{reason}")}
            end

          {:unknown, registry} ->
            {:ok, opaque_struct(name, fields), registry}
        end

      _ ->
        {:ok, opaque_struct(name, fields), ctx}
    end
  end

  defp opaque_struct(name, {:keyed, pairs}), do: Struct.keyed(name, pairs)
  defp opaque_struct(name, {:positional, items}), do: Struct.positional(name, items)

  defp decode_char_escape("\\" <> rest) do
    case Escapes.decode_escape(rest) do
      {:ok, <<cp::utf8>>, ""} ->
        {:ok, Char.new(cp)}

      {:ok, _multi, ""} ->
        {:error, action_error("char escape must decode to exactly one codepoint")}

      {:ok, _, _leftover} ->
        {:error, action_error("trailing characters after char escape")}

      {:error, reason} ->
        {:error, action_error("invalid char escape: #{reason}")}
    end
  end

  # ---- built-in tag dispatch (DXN.md §1.3) -----------------------------------

  @built_in_tags ~w(ordered sorted-set array uuid uri bytes datetime duration)

  defp dispatch_tag("ordered", value_cap, ctx), do: eval_ordered_map(value_cap, ctx)

  defp dispatch_tag("sorted-set", value_cap, ctx) do
    with {:ok, set, ctx} <- value_cap.eval.(ctx) do
      {:ok, SortedSet.new(MapSet.to_list(set)), ctx}
    end
  end

  defp dispatch_tag("array", value_cap, ctx) do
    with {:ok, list, ctx} <- value_cap.eval.(ctx) do
      {:ok, Array.new(list), ctx}
    end
  end

  defp dispatch_tag("uuid", value_cap, ctx) do
    with {:ok, text, ctx} <- value_cap.eval.(ctx),
         {:ok, uuid} <- Uuid.parse(text) do
      {:ok, uuid, ctx}
    else
      {:error, :invalid_uuid} -> {:error, action_error("invalid uuid")}
      {:error, _} = err -> err
    end
  end

  defp dispatch_tag("uri", value_cap, ctx) do
    with {:ok, text, ctx} <- value_cap.eval.(ctx), do: {:ok, Uri.new(text), ctx}
  end

  defp dispatch_tag("bytes", value_cap, ctx) do
    with {:ok, text, ctx} <- value_cap.eval.(ctx) do
      case Base.decode64(text) do
        {:ok, bytes} -> {:ok, Dextrin.Bytes.new(bytes), ctx}
        :error -> {:error, action_error("invalid base64 in @bytes")}
      end
    end
  end

  defp dispatch_tag("datetime", value_cap, ctx) do
    with {:ok, text, ctx} <- value_cap.eval.(ctx),
         {:ok, datetime} <- parse_offset_datetime(text) do
      {:ok, datetime, ctx}
    else
      {:error, :invalid} -> {:error, action_error("invalid datetime")}
      {:error, _} = err -> err
    end
  end

  defp dispatch_tag("duration", value_cap, ctx) do
    with {:ok, text, ctx} <- value_cap.eval.(ctx),
         {:ok, duration} <- Duration.from_iso8601(text) do
      {:ok, from_elixir_duration(duration), ctx}
    else
      {:error, _reason} -> {:error, action_error("invalid duration")}
    end
  end

  defp dispatch_tag(name, value_cap, ctx) when name in @built_in_tags do
    dispatch_tag(name, value_cap, ctx)
  end

  defp dispatch_tag(name, value_cap, ctx) do
    case ctx do
      %Registry{} = registry ->
        with {:ok, decoder} <- Registry.fetch_tag(registry, name),
             {:ok, inner, ctx} <- value_cap.eval.(ctx),
             {:ok, decoded} <- decoder.(inner) do
          {:ok, decoded, ctx}
        else
          :error ->
            with {:ok, inner, ctx} <- value_cap.eval.(ctx),
                 do: {:ok, CustomTag.new(name, inner), ctx}

          {:error, _} = err ->
            err
        end

      _ ->
        with {:ok, inner, ctx} <- value_cap.eval.(ctx), do: {:ok, CustomTag.new(name, inner), ctx}
    end
  end

  # `@ordered %{...}` is the one case needing raw-node re-entry: plain
  # map_lit evaluation always collapses to a plain Map (losing write
  # order), which is correct for the common bare-`%{...}` case but
  # would destroy exactly the information `@ordered` exists to keep.
  # `Ichor.evaluate_node/3` lets us re-enter the parse tree for each
  # map_entry directly, bypassing map_lit's own (order-discarding)
  # handler, so pair order in the source text survives into
  # `Dextrin.OrderedMap.pairs`.
  defp eval_ordered_map(value_cap, ctx) do
    case value_cap.node do
      {:rule, :value,
       %{
         value_body:
           {:rule, :value_body, %{map_lit: {:rule, :map_lit, %{map_entry: raw_entries}}}}
       }} ->
        raw_entries
        |> List.wrap()
        |> Result.map_ok(ctx, fn raw_entry, ctx ->
          Ichor.evaluate_node(raw_entry, __MODULE__, ctx)
        end)
        |> case do
          {:ok, pairs, ctx} -> {:ok, OrderedMap.new(pairs), ctx}
          {:error, _} = err -> err
        end

      _ ->
        {:error, action_error("@ordered requires a map literal argument")}
    end
  end

  defp from_elixir_duration(%Duration{} = d) do
    {micro, precision} = d.microsecond || {0, 0}

    total_micro =
      if d.second == 0 and micro == 0 and precision == 0,
        do: nil,
        else: d.second * 1_000_000 + micro

    %Dextrin.Duration{
      years: zero_to_nil(d.year),
      months: zero_to_nil(d.month),
      weeks: zero_to_nil(d.week),
      days: zero_to_nil(d.day),
      hours: zero_to_nil(d.hour),
      minutes: zero_to_nil(d.minute),
      microseconds: total_micro
    }
  end

  defp zero_to_nil(0), do: nil
  defp zero_to_nil(n), do: n

  defp parse_offset_datetime(text) do
    with [date_part, time_and_offset] <- String.split(text, "T", parts: 2),
         {time_part, offset_str} <- split_offset(time_and_offset),
         {:ok, naive} <- NaiveDateTime.from_iso8601(date_part <> "T" <> time_part),
         {:ok, offset_seconds} <- parse_offset(offset_str) do
      {:ok, build_offset_datetime(naive, offset_seconds)}
    else
      _ -> {:error, :invalid}
    end
  end

  defp split_offset(text) do
    if String.ends_with?(text, "Z") do
      {String.trim_trailing(text, "Z"), "Z"}
    else
      case Regex.run(~r/^(.*?)([+-]\d{2}:\d{2})$/, text) do
        [_, time_part, offset] -> {time_part, offset}
        nil -> {text, nil}
      end
    end
  end

  defp parse_offset("Z"), do: {:ok, 0}
  defp parse_offset(nil), do: {:error, :invalid}

  defp parse_offset(<<sign, h1, h2, ":", m1, m2>>) when sign in [?+, ?-] do
    sign_mult = if sign == ?-, do: -1, else: 1
    hours = String.to_integer(<<h1, h2>>)
    minutes = String.to_integer(<<m1, m2>>)
    {:ok, sign_mult * (hours * 3600 + minutes * 60)}
  end

  defp parse_offset(_), do: {:error, :invalid}

  defp build_offset_datetime(%NaiveDateTime{} = naive, offset_seconds) do
    {microsecond, _precision} = naive.microsecond

    %DateTime{
      year: naive.year,
      month: naive.month,
      day: naive.day,
      hour: naive.hour,
      minute: naive.minute,
      second: naive.second,
      microsecond: {microsecond, 6},
      time_zone: "fixed",
      zone_abbr: format_offset(offset_seconds),
      utc_offset: offset_seconds,
      std_offset: 0
    }
  end

  # .dxnb is always integer-microsecond granularity (DXN.md §2.2) — a
  # value decoded from text must match that representation exactly, or
  # `12:00:00` (precision 0, an artifact of how many fractional digits
  # the *source text* happened to have) and its binary round-trip
  # (always precision 6) would compare unequal via `==` despite being
  # the same instant. Confirmed empirically via the round-trip test,
  # not anticipated in the original design.
  defp normalize_microsecond(%Time{microsecond: {value, _precision}} = time) do
    %{time | microsecond: {value, 6}}
  end

  defp format_offset(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    abs_s = abs(seconds)
    h = div(abs_s, 3600)
    m = div(rem(abs_s, 3600), 60)
    "#{sign}#{pad2(h)}:#{pad2(m)}"
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp action_error(message), do: Ichor.Error.new(message: message, stage: :action)
end
