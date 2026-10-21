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

  alias Dextrin.Temporal
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

  @behaviour Ichor.Actions

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

  def handle_token(:KEYWORD, text, ctx) do
    body = String.trim_leading(text, ":")

    case body do
      "\"" <> _ ->
        inner = body |> String.trim_leading("\"") |> String.trim_trailing("\"")

        case Escapes.decode(inner) do
          {:ok, decoded} -> {:ok, keyword_value(decoded, ctx)}
          {:error, reason} -> {:error, action_error("invalid keyword literal: #{reason}")}
        end

      identifier ->
        {:ok, keyword_value(identifier, ctx)}
    end
  end

  def handle_token(:MAP_KEY, text, ctx) do
    {:ok, keyword_value(String.trim_trailing(text, ":"), ctx)}
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
         :ok <- allowed_key(key, key_cap),
         {:ok, val, ctx} <- val_cap.eval.(ctx) do
      {:ok, {key, val}, ctx}
    end
  end

  def handle_rule(:struct_lit, %{name: name_cap} = captures, ctx) do
    with {:ok, name, ctx} <- name_cap.eval.(ctx),
         {:ok, version, ctx} <- struct_version(captures, ctx) do
      cond do
        Map.has_key?(captures, :keyed) ->
          with {:ok, {:keyed, pairs, extra}, ctx} <- captures.keyed.eval.(ctx) do
            materialize_struct(name, {:keyed, pairs}, version, extra, ctx)
          end

        Map.has_key?(captures, :positional) ->
          with {:ok, {:positional, items, extra}, ctx} <- captures.positional.eval.(ctx) do
            materialize_struct(name, {:positional, items}, version, extra, ctx)
          end
      end
    end
  end

  # A keyed struct's entries: those keyed by a name are its fields, any
  # other map key (DXN.md §1.6) an extra field.
  def handle_rule(:struct_keyed, captures, ctx) do
    with {:ok, pairs, ctx} <- eval_list(Map.get(captures, :map_entry, []), ctx) do
      {named, extra} = Enum.split_with(pairs, fn {key, _value} -> field_name(key) != :error end)

      {:ok,
       {:keyed, Enum.map(named, fn {key, value} -> {Struct.extra_key(key), value} end), extra},
       ctx}
    end
  end

  # A positional struct's items, then its extra fields as entries.
  def handle_rule(:struct_positional, captures, ctx) do
    with {:ok, items, ctx} <- eval_list(Map.get(captures, :value, []), ctx),
         {:ok, entries, ctx} <- eval_list(Map.get(captures, :map_entry, []), ctx) do
      extra = Enum.map(entries, fn {key, value} -> {Struct.extra_key(key), value} end)
      {:ok, {:positional, items, extra}, ctx}
    end
  end

  # `@regex(im) "..."`: a header carries a regex's flags, and stands on
  # no other tag (DXN.md §1.2).
  def handle_rule(:tag_form, %{name: name_cap, flags: flags_cap} = captures, ctx) do
    with {:ok, name, ctx} <- name_cap.eval.(ctx),
         {:ok, flags, ctx} <- flags_cap.eval.(ctx) do
      if name == "regex",
        do: regex_tag(flags, captures.value, ctx),
        else: {:error, action_error("@#{name} takes no (...) header; only @regex(flags) does")}
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

  defp field_name(%Keyword{name: name}), do: {:ok, name}
  defp field_name(%Symbol{name: name}), do: {:ok, name}
  defp field_name(name) when is_binary(name), do: {:ok, name}

  # A struct field's shorthand key (`x:`) goes through the same
  # `keyword_value/2` `Registry.t()`-driven choice as any other
  # keyword-shaped key — trusted decodes it as a real atom.
  # `Dextrin.Struct.keyed/2` always wants the plain string name either
  # way, regardless of which the caller's `trusted:` setting produced.
  defp field_name(name) when is_atom(name) and name not in [nil, true, false],
    do: {:ok, Atom.to_string(name)}

  defp field_name(_), do: :error

  # `%Name(3){...}`: the schema version, a positive integer (DXN.md §4.8).
  defp struct_version(%{version: version_cap}, ctx) do
    with {:ok, version, ctx} <- version_cap.eval.(ctx) do
      if version > 0,
        do: {:ok, version, ctx},
        else: {:error, action_error("a struct version is a positive integer, got #{version}")}
    end
  end

  defp struct_version(_captures, ctx), do: {:ok, nil, ctx}

  defp materialize_struct(name, fields, version, extra, ctx) do
    case ctx do
      %Registry{} = registry ->
        # Fail-fast, decode-time enforcement — a schema violation is an
        # ordinary decode error, same channel as bad syntax, with no
        # lenient escape hatch to get the value anyway. Which schema it
        # is read with depends on its version (Dextrin.Schema.Reader).
        case Dextrin.Schema.Reader.read(registry, name, version, fields, extra) do
          {:ok, materialized, registry} ->
            {:ok, materialized, registry}

          {:unknown, registry} ->
            {:ok, opaque_struct(name, fields, version, extra), registry}

          {:error, %Dextrin.Error{} = error} ->
            {:error, carried(error)}
        end

      _ ->
        {:ok, opaque_struct(name, fields, version, extra), ctx}
    end
  end

  defp opaque_struct(name, {:keyed, pairs}, version, extra),
    do: Struct.keyed(name, pairs, version, extra)

  defp opaque_struct(name, {:positional, items}, version, extra),
    do: Struct.positional(name, items, version, extra)

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

  @built_in_tags ~w(ordered sorted-set array uuid objectid ip uri bytes date time datetime local-datetime duration regex)

  @doc false
  # The tags DXN.md §1.3 builds in: no custom tag has one of their names.
  # `@bits` is one, read by a clause of its own rather than through the
  # list.
  @spec built_in_tags() :: [String.t()]
  def built_in_tags, do: ["bits" | @built_in_tags]

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

  defp dispatch_tag("objectid", value_cap, ctx) do
    with {:ok, text, ctx} <- value_cap.eval.(ctx) do
      case is_binary(text) && Dextrin.ObjectId.parse(text) do
        {:ok, id} -> {:ok, id, ctx}
        _ -> {:error, action_error("invalid objectid #{inspect(text)}")}
      end
    end
  end

  defp dispatch_tag("ip", value_cap, ctx) do
    with {:ok, text, ctx} <- value_cap.eval.(ctx) do
      case is_binary(text) && Dextrin.Ip.parse(text) do
        {:ok, ip} -> {:ok, ip, ctx}
        _ -> {:error, action_error("invalid ip #{inspect(text)}")}
      end
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

  # `@bits {"..." n}` (DXN.md §1.4): base64 and a bit count. A whole
  # number of bytes reads as bytes, which is what it is.
  defp dispatch_tag("bits", value_cap, ctx) do
    with {:ok, value, ctx} <- value_cap.eval.(ctx) do
      with %Dextrin.Tuple{items: [text, count]} when is_binary(text) <- value,
           {:ok, data} <- Base.decode64(text),
           {:ok, bits} <- Dextrin.Bits.from_parts(data, count) do
        {:ok, Dextrin.Bytes.new(bits), ctx}
      else
        _ ->
          {:error,
           action_error(~s|@bits takes {"base64" bit-count}, the count matching the bytes|)}
      end
    end
  end

  # Dates and times are ISO 8601 strings under their tag (DXN.md §1.2,
  # Jan, 2026-10-20), read by Dextrin.Temporal.
  defp dispatch_tag("date", value_cap, ctx),
    do: temporal(value_cap, ctx, "date", &Temporal.parse_date/1)

  defp dispatch_tag("time", value_cap, ctx),
    do: temporal(value_cap, ctx, "time", &Temporal.parse_time/1)

  defp dispatch_tag("datetime", value_cap, ctx),
    do: temporal(value_cap, ctx, "datetime", &Temporal.parse_datetime/1)

  defp dispatch_tag("local-datetime", value_cap, ctx),
    do: temporal(value_cap, ctx, "local-datetime", &Temporal.parse_local/1)

  defp dispatch_tag("duration", value_cap, ctx),
    do: temporal(value_cap, ctx, "duration", &Temporal.parse_duration/1)

  defp dispatch_tag("regex", value_cap, ctx), do: regex_tag("", value_cap, ctx)

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

          {:error, reason} ->
            {:error, action_error("tag #{inspect(name)} decoder failed: #{inspect(reason)}")}
        end

      _ ->
        with {:ok, inner, ctx} <- value_cap.eval.(ctx), do: {:ok, CustomTag.new(name, inner), ctx}
    end
  end

  # `@ordered %{...}` is the one case needing raw-node re-entry: plain
  # map_lit evaluation always collapses to a plain Map (losing write
  # order), which is correct for the common bare-`%{...}` case but
  # would destroy exactly the information `@ordered` exists to keep.
  # `Ichor.Actions.evaluate_node/3` lets us re-enter the parse tree for
  # each map_entry directly, bypassing map_lit's own (order-discarding)
  # handler, so pair order in the source text survives into
  # `Dextrin.OrderedMap.pairs`.
  defp temporal(value_cap, ctx, tag, parse) do
    with {:ok, text, ctx} <- value_cap.eval.(ctx) do
      case is_binary(text) && parse.(text) do
        {:ok, value} -> {:ok, value, ctx}
        _ -> {:error, action_error("invalid #{tag} #{inspect(text)}")}
      end
    end
  end

  # A regex: its pattern a string, its flags the header's letters, each
  # once (DXN.md §1.2).
  defp regex_tag(flags, value_cap, ctx) do
    with {:ok, pattern, ctx} <- value_cap.eval.(ctx) do
      letters = String.graphemes(flags)

      cond do
        not is_binary(pattern) ->
          {:error, action_error("@regex takes its pattern as a string")}

        not Enum.all?(letters, &(&1 in ~w(i m s u x f r))) or
            length(Enum.uniq(letters)) != length(letters) ->
          {:error, action_error("@regex(#{flags}): the flags are i m s u x f r, each once")}

        true ->
          # Atom-list form, not `Regex.compile(pattern, flags)` — the
          # string form triggers a deprecation warning for "r" (Elixir
          # prefers /U), even though "r" is DXN.md's own valid flag letter.
          case Regex.compile(pattern, Dextrin.Binary.Tags.regex_flags_to_opts(flags)) do
            {:ok, regex} ->
              {:ok, regex, ctx}

            {:error, reason} ->
              {:error, action_error("invalid regex #{inspect(pattern)}: #{inspect(reason)}")}
          end
      end
    end
  end

  defp eval_ordered_map(value_cap, ctx) do
    # Raw capture nodes are now an ordered `[{name, value}]` list rather
    # than a map (ichor_runtime 0.2), so each nested capture is fetched
    # by key via `Elixir.Keyword` — `Keyword` in this module is
    # `Dextrin.Keyword`, hence the fully-qualified calls below.
    with {:rule, :value, value_caps} <- value_cap.node,
         {:ok, {:rule, :value_body, value_body_caps}} <-
           Elixir.Keyword.fetch(value_caps, :value_body),
         {:ok, {:rule, :map_lit, map_lit_captures}} <-
           Elixir.Keyword.fetch(value_body_caps, :map_lit) do
      # `Elixir.Keyword.get(..., :map_entry, [])`, not a required-key
      # fetch — an empty `%{}` has no `:map_entry` capture at all (same
      # reason the ordinary, non-`@ordered` `map_lit` handler below needs
      # the same default), so requiring the key present rejected
      # `@ordered %{}` outright as if it weren't a map literal, instead
      # of an ordered map with zero pairs.
      map_lit_captures
      |> Elixir.Keyword.get(:map_entry, [])
      |> List.wrap()
      |> Result.map_ok(ctx, fn raw_entry, ctx ->
        Ichor.Actions.evaluate_node(raw_entry, __MODULE__, ctx)
      end)
      |> case do
        {:ok, pairs, ctx} -> {:ok, OrderedMap.new(pairs), ctx}
        {:error, _} = err -> err
      end
    else
      _ -> {:error, action_error("@ordered requires a map literal argument")}
    end
  end

  # `Dextrin.Registry.put_trusted/2`'s own doc has the full reasoning:
  # trusted decodes a real atom, `DXN.md` §1.3's own natural mapping;
  # untrusted (the default) wraps in `Dextrin.Keyword` instead. `symbol`
  # deliberately has no equivalent — see that doc.
  defp keyword_value(name, %Registry{trusted: true}), do: Keyword.trusted(name)
  defp keyword_value(name, _ctx), do: Keyword.new(name)

  # DXN.md §1.6: an arrow entry's key must be one of the eight allowed
  # types. A float key written as `NaN` or `Infinity` decodes to the
  # same atom a keyword of that name does, so it is refused by the token
  # it was written as -- the one thing the value cannot say.
  defp allowed_key(key, key_cap) do
    if key in [:nan, :positive_infinity, :negative_infinity] and float_token?(key_cap.node) do
      {:error, carried(Dextrin.MapKey.refusal(key))}
    else
      case Dextrin.MapKey.check(key) do
        :ok -> :ok
        {:error, error} -> {:error, carried(error)}
      end
    end
  end

  defp float_token?({:token, :FLOAT, _text}), do: true
  defp float_token?({:rule, _name, captures}), do: Enum.any?(captures, &captured_float?/1)
  defp float_token?(_node), do: false

  defp captured_float?({_name, node}) when is_tuple(node), do: float_token?(node)
  defp captured_float?({_name, nodes}) when is_list(nodes), do: Enum.any?(nodes, &float_token?/1)
  defp captured_float?(_other), do: false

  defp action_error(message), do: Ichor.Error.new(message: message, stage: :action)

  # An error of Dextrin's own -- one with a DXN.md §5 category the parser
  # cannot know, such as `key/not-allowed` or a schema violation --
  # handed through Ichor in its `data`, which `Dextrin.Error.from_ichor/1`
  # takes back out, now with the position Ichor adds.
  defp carried(%Dextrin.Error{message: message} = error),
    do: Ichor.Error.new(message: message, stage: :action, data: error)
end
