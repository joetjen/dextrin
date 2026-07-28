defmodule Dextrin.Text.Formatter do
  @moduledoc """
  Multi-line, indented `.dxn` rendering — `mix dextrin.format`'s
  `--mode pretty` and `mix dextrin.decode`'s default output (DESIGN.md
  §12.4). `--mode condense` needs no separate implementation at all:
  it's exactly what `Dextrin.encode/2`/`Dextrin.Text.Printer` already
  produce.

  Comments cannot be preserved here or anywhere else in this design —
  `Dextrin.Text.Grammar`'s lexer discards them as trivia before the
  parser (and therefore any value) ever exists (DESIGN.md §12.4). This
  formatter only ever prints what survived decoding.
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

  # Anything left — scalars, and every empty-collection case that
  # doesn't need multi-line treatment at all — the single-line printer
  # already handles correctly (including its own registry-consulting
  # fallback for an unrecognized application struct).
  defp render(value, _depth, opts), do: print!(value, opts)

  defp bracketed(open, items, close, depth, opts, render_item) do
    inner_depth = depth + 1
    inner_indent = String.duplicate(@indent, inner_depth)
    outer_indent = String.duplicate(@indent, depth)

    body = Enum.map_join(items, "\n", fn item -> inner_indent <> render_item.(item, inner_depth, opts) end)

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

  defp render_entry(%Dextrin.Keyword{name: name}, value, depth, opts), do: "#{name}: #{render(value, depth, opts)}"
  # Struct-keyed pairs use plain string names, not Keyword-wrapped
  # (Dextrin.Struct.keyed/2's own shape) — distinct from a map's keys.
  defp render_entry(name, value, depth, opts) when is_binary(name), do: "#{name}: #{render(value, depth, opts)}"
  defp render_entry(key, value, depth, opts), do: "#{print!(key, opts)} => #{render(value, depth, opts)}"

  # `Printer.print/2` returns `{:ok, _} | {:error, _}` (DESIGN.md
  # §10); `pretty/2`'s own contract is unchanged (a bare `String.t()`,
  # not part of what was asked when that changed) — so unwrap here,
  # raising same as it always effectively did for an unencodable value.
  defp print!(value, opts) do
    case Printer.print(value, opts) do
      {:ok, printed} -> printed
      {:error, %Dextrin.Error{} = error} -> raise ArgumentError, Dextrin.Error.format(error)
    end
  end
end
