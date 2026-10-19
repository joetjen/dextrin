defmodule Dextrin.Document.Formatter do
  @moduledoc """
  A document's syntax tree laid out the way `Dextrin.Text.Formatter`
  lays out a value -- every non-empty collection over lines, one entry
  per line, indented -- with every comment kept beside the entry it
  belongs to (`design/comment-retention.md`, "The rules").

  **Layout only.** Every token is written exactly as it was -- a
  literal's spelling, a key's form, an escape -- and only the space
  between tokens changes: indentation, line breaks, commas, and blank
  lines, of which at most one is kept wherever the source had any
  between entries. A document with no comments therefore comes out as
  the pretty printer writes its value.

  **Where a comment goes**, by lines alone: a comment on the line of the
  token or entry before it trails that, and so does every comment line
  straight after it, aligned under its `#`; any other block of comment
  lines goes above the next entry, or at the end of its collection when
  none follows. A comment between a key or a tag and its value stays
  between them, and the value moves to the next line.
  """

  alias Ichor.Syntax.{Node, Token}

  @doc """
  The text of the document `tree`, laid out. `:indent` is the spaces per
  level (2).

  It ends with a newline exactly when the source did: a formatter run on
  save keeps a file's last newline, and a comment-free document without
  one comes out exactly as `Dextrin.encode(value, pretty: true)` writes
  its value.
  """
  @spec format(Node.t(), keyword()) :: String.t()
  def format(%Node{rule: :document, children: children} = tree, opts \\ []) do
    step = String.duplicate(" ", Keyword.get(opts, :indent, 2))
    {header, rest} = Enum.split_with(children, &match?(%Node{rule: :header}, &1))

    head = Enum.map(header, &(header_text(&1) <> "\n"))
    slots = slots(rest, false)
    ending = if String.ends_with?(Ichor.Syntax.text(tree), "\n"), do: "\n", else: ""

    IO.iodata_to_binary([
      head,
      lines(slots, "", step, fn node -> value(node, "", step) end),
      ending
    ])
  end

  # The header, `@dxn "1.0"`: its tokens as written, one space between
  # them however they were spaced.
  defp header_text(%Node{children: children}) do
    children
    |> Enum.reject(&match?(%Token{trivia: true}, &1))
    |> Enum.map_join(" ", fn
      %Token{text: text} -> text
      %Node{} = node -> tokens_text(node)
    end)
  end

  # ---- slots: which comment belongs where -----------------------------------

  # A container's children, as what is laid out: each entry with the
  # comment blocks above it and the block trailing it, the blocks at the
  # end, and the block trailing whatever opened the container when
  # `on_line?` -- a comment straight after `[` stays beside it.
  defp slots(children, on_line?) do
    initial = %{
      entries: [],
      open: [],
      pending: [],
      blank?: false,
      newlines: 0,
      on_line?: on_line?,
      target: :open,
      trailing?: false
    }

    final =
      Enum.reduce(children, initial, fn
        %Token{trivia: true, text: text}, state -> Enum.reduce(events(text), state, &event/2)
        %Node{} = node, state -> entry(state, node)
        %Token{}, state -> state
      end)

    %{entries: Enum.reverse(final.entries), open: final.open, terminal: blocks_of(final)}
  end

  defp events(text), do: Regex.scan(~r/#[^\n]*|\n/, text) |> List.flatten()

  defp event("\n", state),
    do: %{state | on_line?: false, newlines: state.newlines + 1}

  defp event(comment, state) do
    comment = String.trim_trailing(comment)

    cond do
      state.on_line? or (state.trailing? and state.newlines == 1) ->
        %{trailing(state, comment) | trailing?: true, newlines: 0}

      true ->
        blank? = state.newlines >= 2 and state.target != :open

        pending =
          case state.pending do
            [] ->
              [{blank?, [comment]}]

            [{b, block} | done] when not blank? and state.newlines <= 1 ->
              [{b, [comment | block]} | done]

            done ->
              [{blank?, [comment]} | done]
          end

        %{state | pending: pending, trailing?: false, newlines: 0}
    end
  end

  defp trailing(%{target: :open} = state, comment), do: %{state | open: state.open ++ [comment]}

  defp trailing(%{entries: [{node, above, blank?, trailing} | done]} = state, comment),
    do: %{state | entries: [{node, above, blank?, trailing ++ [comment]} | done]}

  defp entry(state, node) do
    # A blank line straight before the entry: after its comments, or,
    # with none, after the entry before it -- never right after an
    # opening bracket.
    blank? = state.newlines >= 2 and (state.pending != [] or state.target != :open)

    %{
      state
      | entries: [{node, blocks_of(state), blank?, []} | state.entries],
        pending: [],
        newlines: 0,
        on_line?: true,
        target: node,
        trailing?: false
    }
  end

  defp blocks_of(%{pending: pending}),
    do:
      pending
      |> Enum.reverse()
      |> Enum.map(fn {blank?, block} -> {blank?, Enum.reverse(block)} end)

  # ---- lines --------------------------------------------------------------

  # A container's entries and comments, one line each at `indent`.
  defp lines(%{entries: entries, terminal: terminal}, indent, _step, render) do
    body =
      Enum.map(entries, fn {node, above, blank?, trailing} ->
        [
          above_lines(above, indent),
          blank_line(blank?),
          trailed(indent <> render.(node), trailing),
          "\n"
        ]
      end)

    text = IO.iodata_to_binary([body, above_lines(terminal, indent)])
    String.trim_trailing(text, "\n")
  end

  defp blank_line(true), do: "\n"
  defp blank_line(false), do: ""

  defp above_lines(blocks, indent) do
    Enum.map(blocks, fn {blank?, block} ->
      [blank_line(blank?), Enum.map(block, &[indent, &1, "\n"])]
    end)
  end

  # `text` with its trailing comments: the first two spaces after its
  # last line, the rest aligned under it.
  defp trailed(text, []), do: text

  defp trailed(text, [first | more]) do
    last_line = text |> String.split("\n") |> List.last()
    pad = String.duplicate(" ", String.length(last_line) + 2)
    Enum.join([text <> "  " <> first | Enum.map(more, &(pad <> &1))], "\n")
  end

  # ---- values -------------------------------------------------------------

  defp value(%Node{rule: :value, children: children}, indent, step) do
    children
    |> Enum.reject(&match?(%Token{trivia: true}, &1))
    |> Enum.map_join(" ", fn
      %Node{rule: :discard, children: discard} ->
        "@_ " <> value(Enum.find(discard, &match?(%Node{rule: :value}, &1)), indent, step)

      %Node{rule: :value_body, children: [body]} ->
        body(body, indent, step)
    end)
  end

  defp body(%Node{rule: rule} = node, indent, step)
       when rule in [:list, :tuple, :set_lit, :map_lit],
       do: collection(node, "", indent, step)

  defp body(%Node{rule: :struct_lit, children: children}, indent, step) do
    {head, [body | _]} = Enum.split_while(children, &(not match?(%Node{}, &1)))
    collection(body, tokens_text(%Node{children: head}), indent, step)
  end

  # A tag and its value. Written together, `@array[1 2]` -- the spec's
  # own spelling -- they stay together; with anything between them, one
  # space does.
  defp body(%Node{rule: :tag_form, children: children}, indent, step) do
    {tag, [inner]} = Enum.split_with(children, &(not match?(%Node{rule: :value}, &1)))
    name = tokens_text(%Node{children: tag})

    if Enum.any?(tag, &match?(%Token{trivia: true}, &1)),
      do:
        between(name, comments_in(tag), fn deeper -> value(inner, deeper, step) end, indent, step),
      else: name <> value(inner, indent, step)
  end

  defp body(node, _indent, _step), do: Ichor.Syntax.text(node)

  # A collection: its opening tokens after `head`, its entries one per
  # line a level deeper, its closing token -- or `[]` when it holds
  # nothing, not even a comment.
  defp collection(%Node{children: children}, head, indent, step) do
    {before_close, [close]} = Enum.split(children, -1)
    {opening, inner} = Enum.split_while(before_close, &match?(%Token{trivia: false}, &1))
    open = head <> tokens_text(%Node{children: opening})
    slots = slots(inner, true)

    if slots.entries == [] and slots.open == [] and slots.terminal == [] do
      open <> Ichor.Syntax.text(close)
    else
      deeper = indent <> step
      entries = lines(slots, deeper, step, &item(&1, deeper, step))
      trailed(open, slots.open) <> "\n" <> entries <> "\n" <> indent <> Ichor.Syntax.text(close)
    end
  end

  defp item(%Node{rule: :map_entry, children: children}, indent, step) do
    case Enum.reject(children, &match?(%Token{trivia: true}, &1)) do
      [%Token{name: :MAP_KEY, text: key}, value] ->
        between(
          key,
          comments_in(children),
          fn deeper -> value(value, deeper, step) end,
          indent,
          step
        )

      [key, _arrow, value] ->
        between(
          value(key, indent, step) <> " =>",
          comments_in(children),
          fn deeper -> value(value, deeper, step) end,
          indent,
          step
        )
    end
  end

  defp item(%Node{rule: :value} = node, indent, step), do: value(node, indent, step)

  # `prefix` and the value after it: on one line, or, with a comment
  # between them, the comment beside the prefix and the value on the
  # next line, a level deeper.
  defp between(prefix, [], render, indent, _step), do: prefix <> " " <> render.(indent)

  defp between(prefix, comments, render, indent, step) do
    deeper = indent <> step
    trailed(prefix, comments) <> "\n" <> deeper <> render.(deeper)
  end

  defp comments_in(children) do
    for %Token{trivia: true, text: text} <- children,
        comment <- events(text),
        comment != "\n",
        do: String.trim_trailing(comment)
  end

  defp tokens_text(%Node{children: children}) do
    children
    |> Enum.reject(&match?(%Token{trivia: true}, &1))
    |> Enum.map_join(fn
      %Token{text: text} -> text
      %Node{} = node -> tokens_text(node)
    end)
  end
end
