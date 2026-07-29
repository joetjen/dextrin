defmodule Dextrin.Text.Formatter do
  @moduledoc """
  Multi-line, indented `.dxn` rendering — `mix dextrin.format`'s
  `--mode pretty` and `mix dextrin.decode`'s default output (a CLI
  decode is a human reading the result, so `Dextrin.encode/2`'s own
  single-line default isn't the right default there). `--mode condense`
  needs no separate implementation at all: it's exactly what
  `Dextrin.encode/2`/`Dextrin.Text.Printer` already produce.

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

  @indent "  "

  @spec pretty(term(), keyword()) :: String.t()
  def pretty(value, opts \\ []), do: render(value, 0, opts)

  defp render(list, depth, opts) when is_list(list) and list != [] do
    bracketed("[", list, "]", depth, opts, &render/3)
  end

  defp render(%Dextrin.Tuple{items: items}, depth, opts) when items != [] do
    bracketed("{", items, "}", depth, opts, &render/3)
  end

  defp render(%MapSet{} = set, depth, opts) do
    case MapSet.to_list(set) do
      [] -> "@{}"
      items -> bracketed("@{", items, "}", depth, opts, &render/3)
    end
  end

  defp render(%SortedSet{items: []}, _depth, _opts), do: "@sorted-set @{}"

  defp render(%SortedSet{items: items}, depth, opts) do
    "@sorted-set " <> bracketed("@{", items, "}", depth, opts, &render/3)
  end

  defp render(%Array{items: {}}, _depth, _opts), do: "@array[]"

  defp render(%Array{items: items}, depth, opts) do
    "@array" <> bracketed("[", Tuple.to_list(items), "]", depth, opts, &render/3)
  end

  defp render(%OrderedMap{pairs: []}, _depth, _opts), do: "@ordered %{}"

  defp render(%OrderedMap{pairs: pairs}, depth, opts) do
    "@ordered " <> render_entries("%{", pairs, "}", depth, opts)
  end

  defp render(%{} = map, depth, opts) when not is_struct(map) and map_size(map) > 0 do
    render_entries("%{", Map.to_list(map), "}", depth, opts)
  end

  defp render(%Struct{name: name, fields: {:keyed, pairs}}, depth, opts) when pairs != [] do
    "%" <> name <> render_entries("{", pairs, "}", depth, opts)
  end

  defp render(%Struct{name: name, fields: {:positional, items}}, depth, opts) when items != [] do
    "%" <> name <> bracketed("[", items, "]", depth, opts, &render/3)
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
  # scalar/`print!` path below unchanged.
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
        print!(value, opts)
    end
  end

  # Anything left — scalars, and every empty-collection case that
  # doesn't need multi-line treatment at all — the single-line printer
  # already handles correctly.
  defp render(value, _depth, opts), do: print!(value, opts)

  defp bracketed(open, items, close, depth, opts, render_item) do
    inner_depth = depth + 1
    inner_indent = String.duplicate(@indent, inner_depth)
    outer_indent = String.duplicate(@indent, depth)

    body =
      Enum.map_join(items, "\n", fn item ->
        inner_indent <> render_item.(item, inner_depth, opts)
      end)

    open <> "\n" <> body <> "\n" <> outer_indent <> close
  end

  defp render_entries(open, pairs, close, depth, opts) do
    inner_depth = depth + 1
    inner_indent = String.duplicate(@indent, inner_depth)
    outer_indent = String.duplicate(@indent, depth)

    body =
      Enum.map_join(pairs, "\n", fn {key, value} ->
        inner_indent <> render_entry(key, value, inner_depth, opts)
      end)

    open <> "\n" <> body <> "\n" <> outer_indent <> close
  end

  defp render_entry(%Dextrin.Keyword{name: name}, value, depth, opts),
    do: "#{name}: #{render(value, depth, opts)}"

  # Struct-keyed pairs use plain string names, not Keyword-wrapped
  # (Dextrin.Struct.keyed/2's own shape) — distinct from a map's keys.
  defp render_entry(name, value, depth, opts) when is_binary(name),
    do: "#{name}: #{render(value, depth, opts)}"

  defp render_entry(key, value, depth, opts),
    do: "#{print!(key, opts)} => #{render(value, depth, opts)}"

  # `Printer.print/2` returns `{:ok, _} | {:error, _}`; `pretty/2` keeps
  # its own contract as a bare `String.t()`, so it unwraps here instead,
  # raising for an unencodable value the same way it always effectively
  # did before `print/2` gained an explicit error return.
  defp print!(value, opts) do
    case Printer.print(value, opts) do
      {:ok, printed} -> printed
      {:error, %Dextrin.Error{} = error} -> raise ArgumentError, Dextrin.Error.format(error)
    end
  end
end
