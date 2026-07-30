defmodule Dextrin.Text.Formatter do
  @moduledoc """
  Multi-line, indented `.dxn` rendering — `Dextrin.encode/2`'s
  `pretty: true` opt, `mix dextrin.format`'s `--mode pretty`, and `mix
  dextrin.decode`'s default output (a CLI decode is a human reading
  the result, so `encode/2`'s own single-line default isn't the right
  default there). `--mode condense` needs no separate implementation
  at all: it's exactly what `Dextrin.encode/2`/`Dextrin.Text.Printer`
  already produce with `pretty: false` (the default).

  Comments cannot be preserved here, or by any formatter built on this
  library's decode-then-reprint approach: `Dextrin.Text.Grammar`'s
  lexer folds `#`-comments into the same auto-spliced trivia as
  whitespace and discards them before the parser (and therefore any
  value) ever exists. There is no comment text left to put back by the
  time a value reaches this module. A genuine comment-preserving
  formatter would need a second, independent re-lexing pipeline that
  never goes through the value-producing parse at all — real,
  separate work, not a flag on this one.
  """

  alias Dextrin.{Array, OrderedMap, SortedSet, Struct}
  alias Dextrin.Text.Printer

  @default_indent 2

  @doc """
  Renders `value` as multi-line, indented `.dxn` text. Returns
  `{:ok, _} | {:error, _}`, matching `Dextrin.Text.Printer.print/2` —
  the only way this can fail is the same as `print/2`'s: a struct with
  no `tag_encoder`/schema module registered (or one that itself
  returns `{:error, _}`).

  `opts[:indent]` sets the number of spaces per nesting level (default
  #{@default_indent}); every other opt (`registry:`, ...) is the same
  as `print/2`'s.
  """
  @spec pretty(term(), keyword()) :: {:ok, String.t()} | {:error, Dextrin.Error.t()}
  def pretty(value, opts \\ []), do: render(value, 0, opts)

  defp render(list, depth, opts) when is_list(list) and list != [] do
    bracketed("[", list, "]", depth, opts, &render/3)
  end

  defp render(%Dextrin.Tuple{items: items}, depth, opts) when items != [] do
    bracketed("{", items, "}", depth, opts, &render/3)
  end

  defp render(%MapSet{} = set, depth, opts) do
    case MapSet.to_list(set) do
      [] -> {:ok, "@{}"}
      items -> bracketed("@{", items, "}", depth, opts, &render/3)
    end
  end

  defp render(%SortedSet{items: []}, _depth, _opts), do: {:ok, "@sorted-set @{}"}

  defp render(%SortedSet{items: items}, depth, opts) do
    with {:ok, body} <- bracketed("@{", items, "}", depth, opts, &render/3) do
      {:ok, "@sorted-set " <> body}
    end
  end

  defp render(%Array{items: {}}, _depth, _opts), do: {:ok, "@array[]"}

  defp render(%Array{items: items}, depth, opts) do
    with {:ok, body} <- bracketed("[", Tuple.to_list(items), "]", depth, opts, &render/3) do
      {:ok, "@array" <> body}
    end
  end

  defp render(%OrderedMap{pairs: []}, _depth, _opts), do: {:ok, "@ordered %{}"}

  defp render(%OrderedMap{pairs: pairs}, depth, opts) do
    with {:ok, body} <- render_entries("%{", pairs, "}", depth, opts) do
      {:ok, "@ordered " <> body}
    end
  end

  defp render(%{} = map, depth, opts) when not is_struct(map) and map_size(map) > 0 do
    render_entries("%{", Map.to_list(map), "}", depth, opts)
  end

  defp render(%Struct{name: name, fields: {:keyed, pairs}}, depth, opts) when pairs != [] do
    with {:ok, body} <- render_entries("{", pairs, "}", depth, opts) do
      {:ok, "%" <> name <> body}
    end
  end

  defp render(%Struct{name: name, fields: {:positional, items}}, depth, opts) when items != [] do
    with {:ok, body} <- bracketed("[", items, "]", depth, opts, &render/3) do
      {:ok, "%" <> name <> body}
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
  defp render(%module{} = value, depth, opts) do
    registry = Keyword.get(opts, :registry, Dextrin.Registry.new())

    case Dextrin.Registry.fetch_schema_name_for_module(registry, module) do
      {:ok, name} ->
        {:ok, compiled, _registry} = Dextrin.Registry.fetch_struct_schema(registry, name)

        render(
          Struct.keyed(name, Dextrin.Schema.Compiled.field_values(compiled, value)),
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
  defp render(value, _depth, opts), do: Printer.print(value, opts)

  defp indent_unit(opts), do: String.duplicate(" ", Keyword.get(opts, :indent, @default_indent))

  defp bracketed(open, items, close, depth, opts, render_item) do
    inner_depth = depth + 1
    unit = indent_unit(opts)
    inner_indent = String.duplicate(unit, inner_depth)
    outer_indent = String.duplicate(unit, depth)

    with {:ok, rendered_items} <- render_all(items, inner_depth, opts, render_item) do
      body = Enum.map_join(rendered_items, "\n", &(inner_indent <> &1))
      {:ok, open <> "\n" <> body <> "\n" <> outer_indent <> close}
    end
  end

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
      body = Enum.map_join(rendered_pairs, "\n", &(inner_indent <> &1))
      {:ok, open <> "\n" <> body <> "\n" <> outer_indent <> close}
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
    if Printer.bare_identifier?(name) do
      with {:ok, rendered} <- render(value, depth, opts), do: {:ok, "#{name}: #{rendered}"}
    else
      with {:ok, printed_key} <- Printer.print(Dextrin.Keyword.new(name), opts),
           {:ok, rendered} <- render(value, depth, opts) do
        {:ok, "#{printed_key} => #{rendered}"}
      end
    end
  end

  # Struct-keyed pairs use plain string names, not Keyword-wrapped
  # (Dextrin.Struct.keyed/2's own shape) — distinct from a map's keys,
  # but `%Name{ ... }`'s body is the same `map_entry` grammar (`DXN.md`
  # §1.2), so the same colon-shorthand-vs-arrow rule applies here too.
  defp render_entry(name, value, depth, opts) when is_binary(name) do
    if Printer.bare_identifier?(name) do
      with {:ok, rendered} <- render(value, depth, opts), do: {:ok, "#{name}: #{rendered}"}
    else
      with {:ok, printed_key} <- Printer.print(Dextrin.Keyword.new(name), opts),
           {:ok, rendered} <- render(value, depth, opts) do
        {:ok, "#{printed_key} => #{rendered}"}
      end
    end
  end

  defp render_entry(key, value, depth, opts) do
    with {:ok, rendered_key} <- Printer.print(key, opts),
         {:ok, rendered_value} <- render(value, depth, opts) do
      {:ok, "#{rendered_key} => #{rendered_value}"}
    end
  end
end
