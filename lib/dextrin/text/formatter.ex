defmodule Dextrin.Text.Formatter do
  @moduledoc """
  Multi-line, indented `.dxn` rendering — `Dextrin.encode/2`'s
  `pretty: true` opt, `mix dextrin.format`'s `--mode pretty`, and `mix
  dextrin.decode`'s default output (a CLI decode is a human reading
  the result, so `encode/2`'s own single-line default isn't the right
  default there). `--mode condense` needs no separate implementation
  at all: it's exactly what `Dextrin.encode/2`/`Dextrin.Text.Printer`
  already produce with `pretty: false` (the default).

  **The layout** (Jan, 2026-10-20): the top-level collection always
  breaks, one entry per line, however short it is. A nested collection
  is written on one line, its entries single-space separated, when that
  line -- its indent and its key included -- fits the width (`:width`,
  80); otherwise it breaks too, and what it holds is laid out again
  by the same rule.

  A value has no comments, so this formatter has none to keep. To lay
  out a document and keep its comments, parse it as a
  `Dextrin.Document` and use `Dextrin.Document.format/2`, which lays a
  comment-free document out exactly as this module lays out its value.
  """

  alias Dextrin.{Array, OrderedMap, SortedSet, Struct}
  alias Dextrin.Text.Printer

  @default_indent 2
  @default_width 80

  @doc """
  Renders `value` as multi-line, indented `.dxn` text. Returns
  `{:ok, _} | {:error, _}`, matching `Dextrin.Text.Printer.print/2` —
  the only way this can fail is the same as `print/2`'s: a struct with
  no `tag_encoder`/schema module registered (or one that itself
  returns `{:error, _}`).

  `opts[:indent]` sets the number of spaces per nesting level (default
  #{@default_indent}), and `opts[:width]` the columns a nested
  collection's one line must fit in (default #{@default_width}); every
  other opt (`registry:`, ...) is the same as `print/2`'s.
  """
  @spec pretty(term(), keyword()) :: {:ok, String.t()} | {:error, Dextrin.Error.t()}
  def pretty(value, opts \\ []), do: layout(value, 0, opts)

  # A nested value on one line when that fits the room its line leaves
  # it, and laid out over lines otherwise. The top level (depth 0) and a
  # value inside a one-line one go straight to `layout/3`.
  defp render(value, depth, opts) do
    if depth > 0 and not Keyword.get(opts, :"$flat", false) do
      with {:ok, one_line} <- layout(value, depth, Keyword.put(opts, :"$flat", true)) do
        if String.length(one_line) <= room(opts),
          do: {:ok, one_line},
          else: layout(value, depth, opts)
      end
    else
      layout(value, depth, opts)
    end
  end

  # The columns left for a value after its line's indent and key, as the
  # entry or item rendering it said; the whole width when nothing did.
  defp room(opts), do: Keyword.get(opts, :"$room", width(opts))

  defp width(opts), do: Keyword.get(opts, :width, @default_width)

  defp with_room(opts, used), do: Keyword.put(opts, :"$room", width(opts) - used)

  defp layout(list, depth, opts) when is_list(list) and list != [] do
    bracketed("[", list, "]", depth, opts, &render/3)
  end

  defp layout(%Dextrin.Tuple{items: items}, depth, opts) when items != [] do
    bracketed("{", items, "}", depth, opts, &render/3)
  end

  defp layout(%MapSet{} = set, depth, opts) do
    case MapSet.to_list(set) do
      [] -> {:ok, "@{}"}
      items -> bracketed("@{", items, "}", depth, opts, &render/3)
    end
  end

  defp layout(%SortedSet{items: []}, _depth, _opts), do: {:ok, "@sorted-set @{}"}

  defp layout(%SortedSet{items: items}, depth, opts) do
    with {:ok, body} <- bracketed("@{", items, "}", depth, opts, &render/3) do
      {:ok, "@sorted-set " <> body}
    end
  end

  defp layout(%Array{items: {}}, _depth, _opts), do: {:ok, "@array[]"}

  defp layout(%Array{items: items}, depth, opts) do
    with {:ok, body} <- bracketed("[", Tuple.to_list(items), "]", depth, opts, &render/3) do
      {:ok, "@array" <> body}
    end
  end

  defp layout(%OrderedMap{pairs: []}, _depth, _opts), do: {:ok, "@ordered %{}"}

  defp layout(%OrderedMap{pairs: pairs}, depth, opts) do
    with :ok <- Dextrin.MapKey.check_pairs(pairs),
         {:ok, body} <- render_entries("%{", pairs, "}", depth, opts) do
      {:ok, "@ordered " <> body}
    end
  end

  defp layout(%{} = map, depth, opts) when not is_struct(map) and map_size(map) > 0 do
    with :ok <- Dextrin.MapKey.check_pairs(Map.to_list(map)),
         do: render_entries("%{", Map.to_list(map), "}", depth, opts)
  end

  defp layout(%Struct{name: name, fields: {:keyed, pairs}} = struct, depth, opts)
       when pairs != [] do
    # Wrapped as Dextrin.Keyword before reaching render_entries/5, same
    # as Dextrin.Text.Printer.print/2's own struct clause — struct
    # field names are always keyword-shaped per DXN.md §1.2's map_entry
    # grammar, and render_entry/4 needs that distinction made here,
    # up front, rather than trying to guess from a bare binary string
    # alone whether it's a field name or a genuine string-typed map key
    # (see render_entry/4's own doc for why that guess used to be wrong).
    keyed = Enum.map(pairs, fn {k, v} -> {Dextrin.Keyword.new(k), v} end)
    entries = keyed ++ Printer.extra_entries(struct)

    with {:ok, body} <- render_entries("{", entries, "}", depth, opts) do
      {:ok, Struct.head(name, Dextrin.Text.Printer.written_version(struct, opts)) <> body}
    end
  end

  # A positional struct's items, then its extra fields as entries, one
  # per line like the items (DXN.md §1.2).
  defp layout(%Struct{name: name, fields: {:positional, items}} = struct, depth, opts)
       when items != [] do
    lines = items ++ Enum.map(Printer.extra_entries(struct), &{:"$dextrin_entry", &1})

    with {:ok, body} <- bracketed("[", lines, "]", depth, opts, &render_item_or_entry/3) do
      {:ok, Struct.head(name, Dextrin.Text.Printer.written_version(struct, opts)) <> body}
    end
  end

  # A struct none of the clauses above recognized — could be a genuine
  # application struct registered via `put_struct_module/3`, or one of
  # the many built-in scalar/extended structs `Dextrin.Text.Printer`
  # already handles directly (`Regex`, `Date`, `Decimal`, `Dextrin.Uuid`,
  # ...). Mirrors `Dextrin.Text.Printer`/`Dextrin.Binary.Encoder`'s own
  # struct-module fallback: only a schema-registered module gets
  # rebuilt as the equivalent keyed `Dextrin.Struct` and re-rendered
  # through that existing clause above — so it gets exactly the same
  # multi-line treatment as an opaque `Dextrin.Struct` with the same
  # shape, rather than inconsistently squashing to single-line just
  # because a materializer happens to be registered for this one name.
  # Everything else (no module match at all) falls through to the
  # scalar/`print/2` path below unchanged.
  defp layout(%module{} = value, depth, opts) do
    registry = Keyword.get(opts, :registry, Dextrin.Registry.new())

    case Dextrin.Registry.fetch_schema_name_for_module(registry, module) do
      {:ok, name} ->
        {:ok, compiled, _registry} = Dextrin.Registry.fetch_struct_schema(registry, name)

        render(
          Struct.keyed(
            name,
            Dextrin.Schema.Compiled.field_values(compiled, value),
            nil,
            Struct.runtime_extra(value)
          ),
          depth,
          opts
        )

      :error ->
        Printer.print(value, opts)
    end
  end

  # Anything left — scalars, and every empty-collection case that
  # doesn't need multi-line treatment at all — the single-line printer
  # already handles correctly.
  defp layout(value, _depth, opts), do: Printer.print(value, opts)

  defp indent_unit(opts), do: String.duplicate(" ", Keyword.get(opts, :indent, @default_indent))

  defp bracketed(open, items, close, depth, opts, render_item) do
    inner_depth = depth + 1
    unit = indent_unit(opts)
    inner_indent = String.duplicate(unit, inner_depth)
    outer_indent = String.duplicate(unit, depth)
    item_opts = with_room(opts, String.length(inner_indent))

    with {:ok, rendered_items} <- render_all(items, inner_depth, item_opts, render_item) do
      {:ok, joined(open, rendered_items, close, inner_indent, outer_indent, opts)}
    end
  end

  # The rendered entries between `open` and `close`: single-space
  # separated on one line, or one per line, indented.
  defp joined(open, rendered, close, inner_indent, outer_indent, opts) do
    if Keyword.get(opts, :"$flat", false) do
      open <> Enum.join(rendered, " ") <> close
    else
      body = Enum.map_join(rendered, "\n", &(inner_indent <> &1))
      open <> "\n" <> body <> "\n" <> outer_indent <> close
    end
  end

  defp render_item_or_entry({:"$dextrin_entry", {key, value}}, depth, opts),
    do: render_entry(key, value, depth, opts)

  defp render_item_or_entry(item, depth, opts), do: render(item, depth, opts)

  defp render_all(items, depth, opts, render_item) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case render_item.(item, depth, opts) do
        {:ok, rendered} -> {:cont, {:ok, [rendered | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp render_entries(open, pairs, close, depth, opts) do
    inner_depth = depth + 1
    unit = indent_unit(opts)
    inner_indent = String.duplicate(unit, inner_depth)
    outer_indent = String.duplicate(unit, depth)

    with {:ok, rendered_pairs} <- render_all_entries(pairs, inner_depth, opts) do
      {:ok, joined(open, rendered_pairs, close, inner_indent, outer_indent, opts)}
    end
  end

  defp render_all_entries(pairs, depth, opts) do
    Enum.reduce_while(pairs, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case render_entry(key, value, depth, opts) do
        {:ok, rendered} -> {:cont, {:ok, [rendered | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  # Same colon-shorthand-vs-arrow-form rule as `Printer.print_entries/2`
  # — the shorthand only exists for a bare `identifier` (`DXN.md`
  # §1.2's `map_entry`); any other name has no colon form at all and
  # must render as an ordinary keyword value on the arrow's left side.
  defp render_entry(%Dextrin.Keyword{name: name}, value, depth, opts) do
    render_keyword_entry(name, value, depth, opts)
  end

  # A bare atom key (`nil`/`true`/`false` excluded — those are
  # `boolean`/`nil` values, not stand-ins for a `keyword` name) is a
  # keyword too, same as `Printer.print_entries/2`'s own atom-key
  # clause: `DXN.md` §1.3 documents `keyword` as "Elixir atom."
  #
  # This has to be its own clause, not left to fall through to the
  # generic `Printer.print/2` delegate below — printing an atom as a
  # *value* and printing it as a *keyword key* are different concerns
  # that happen to collide for `:nan`/`:positive_infinity`/
  # `:negative_infinity`, which `Printer.print/2` deliberately renders
  # as the `NaN`/`Infinity`/`-Infinity` float sigils in value position.
  # Falling through here rendered a map/struct entry keyed by one of
  # those three atoms as e.g. `Infinity => Infinity` instead of
  # `positive_infinity: Infinity` — same bug class fixed below for a
  # string key that happens to look like a bare identifier.
  defp render_entry(atom, value, depth, opts)
       when is_atom(atom) and atom not in [nil, true, false] do
    render_keyword_entry(Atom.to_string(atom), value, depth, opts)
  end

  defp render_entry(key, value, depth, opts) do
    with {:ok, rendered_key} <- Printer.print(key, opts),
         {:ok, rendered_value} <-
           render(value, depth, keyed_room(opts, depth, rendered_key <> " => ")) do
      {:ok, "#{rendered_key} => #{rendered_value}"}
    end
  end

  # `opts` with the room a value has after `prefix` on a line indented
  # `depth` levels.
  defp keyed_room(opts, depth, prefix),
    do: with_room(opts, String.length(String.duplicate(indent_unit(opts), depth) <> prefix))

  defp render_keyword_entry(name, value, depth, opts) do
    if Printer.bare_identifier?(name) do
      with {:ok, rendered} <- render(value, depth, keyed_room(opts, depth, name <> ": ")),
           do: {:ok, "#{name}: #{rendered}"}
    else
      with {:ok, printed_key} <- Printer.print(Dextrin.Keyword.new(name), opts),
           {:ok, rendered} <-
             render(value, depth, keyed_room(opts, depth, printed_key <> " => ")) do
        {:ok, "#{printed_key} => #{rendered}"}
      end
    end
  end
end
