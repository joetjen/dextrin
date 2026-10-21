defmodule Dextrin.Schema.Docs.Comments do
  @moduledoc """
  Which comment belongs to which definition, in a `.dxns` document's
  lossless tree (Jan, 2026-10-20):

  - **the block of comment lines directly above an entry** belongs to it,
    when no blank line separates the block from the entry;
  - **a comment on the entry's own line**, after it, belongs to it too,
    and so does every comment line straight below that one.

  A block a blank line cuts off from what follows belongs to nothing
  there; before a document's value, it is the document's own
  description. A comment's text is its line without the `#` and the one
  space after it, and a bare `#` is a blank line, which separates
  paragraphs.
  """

  alias Ichor.Syntax.{Node, Token}

  @typedoc "An entry's comment lines: those above it, then those after it."
  @type attached :: %{above: [String.t()], after: [String.t()]}

  @doc """
  The comments before a document's value -- what it says about itself --
  as text: a blank line between them, like a bare `#`, separates
  paragraphs.
  """
  @spec leading([Node.t() | Token.t()]) :: String.t()
  def leading(children) do
    children
    |> Enum.take_while(&(not match?(%Node{rule: :value}, &1)))
    |> Enum.map_join("\n", fn
      %Token{trivia: true, text: text} -> text
      _header -> "\n"
    end)
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn
      "#" <> _ = line -> [comment_text(line)]
      "" -> [""]
      _other -> []
    end)
    |> Enum.chunk_by(&(&1 == ""))
    |> Enum.map_join("\n", fn
      ["" | _] -> ""
      lines -> Enum.join(lines, "\n")
    end)
    |> String.trim()
  end

  @doc """
  For each `:map_entry` among a container's `children`, in order, the
  comment lines attached to it.
  """
  @spec attached([Node.t() | Token.t()]) :: [attached()]
  def attached(children) do
    initial = %{done: [], current: nil, block: [], newlines: 0, on_line?: false}

    final =
      Enum.reduce(children, initial, fn
        %Token{trivia: true, text: text}, state -> Enum.reduce(events(text), state, &event/2)
        %Node{rule: :map_entry}, state -> entry(state)
        _other, state -> state
      end)

    final |> close() |> Map.fetch!(:done) |> Enum.reverse()
  end

  defp events(text), do: Regex.scan(~r/#[^\n]*|\n/, text) |> List.flatten()

  defp event("\n", state), do: %{state | newlines: state.newlines + 1, on_line?: false}

  defp event(comment, %{on_line?: true, current: %{} = current} = state),
    do: %{state | current: %{current | after: current.after ++ [comment_text(comment)]}}

  # A comment straight below an entry's trailing comment continues it.
  defp event(comment, %{current: %{after: [_ | _]} = current, newlines: 1, block: []} = state),
    do: %{
      state
      | current: %{current | after: current.after ++ [comment_text(comment)]},
        newlines: 0
    }

  defp event(comment, state) do
    block = if state.newlines >= 2, do: [], else: state.block
    %{state | block: block ++ [comment_text(comment)], newlines: 0}
  end

  defp entry(state) do
    above = if state.newlines <= 1, do: state.block, else: []
    state = close(state)
    %{state | current: %{above: above, after: []}, block: [], newlines: 0, on_line?: true}
  end

  defp close(%{current: nil} = state), do: state

  defp close(%{current: current} = state),
    do: %{state | done: [current | state.done], current: nil}

  @doc """
  A comment's text: without its `#` and the one space after it.

      iex> Dextrin.Schema.Docs.Comments.comment_text("# a comment")
      "a comment"

      iex> Dextrin.Schema.Docs.Comments.comment_text("#")
      ""
  """
  @spec comment_text(String.t()) :: String.t()
  def comment_text(comment) do
    comment
    |> String.trim_trailing()
    |> String.replace_prefix("#", "")
    |> String.replace_prefix(" ", "")
  end
end
