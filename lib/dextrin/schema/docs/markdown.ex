defmodule Dextrin.Schema.Docs.Markdown do
  @moduledoc """
  The Markdown a schema's comments are written in, as HTML -- a small,
  fixed subset, so that every implementation renders a comment the same:

  - **blocks**: paragraphs, separated by a blank line; a bullet list,
    each item a line starting `- `; a numbered list, each item a line
    starting `1. ` (any number). An item continues on the lines below it
    that are indented.
  - **inline**: `` `code` ``, `**strong**`, `*emphasis*`, and
    `[text](https://...)` links.

  A code span that names a definition the documentation knows becomes a
  link to it; `link` answers the address for a name, or `nil`. Everything
  else is escaped and kept as written.
  """

  @doc """
  `text` as HTML, `link` resolving a code span to an address.

      iex> Dextrin.Schema.Docs.Markdown.to_html("An **exact** `amount`.", fn _ -> nil end)
      "<p>An <strong>exact</strong> <code>amount</code>.</p>"
  """
  @spec to_html(String.t(), (String.t() -> String.t() | nil)) :: String.t()
  def to_html(text, link) do
    text
    |> String.split("\n")
    |> Enum.chunk_by(&(String.trim(&1) == ""))
    |> Enum.reject(fn [line | _] -> String.trim(line) == "" end)
    |> Enum.map_join("\n", &block(&1, link))
  end

  defp block([first | _] = lines, link) do
    cond do
      String.starts_with?(first, "- ") -> list("ul", items(lines, ~r/^- /), link)
      Regex.match?(~r/^\d+\. /, first) -> list("ol", items(lines, ~r/^\d+\. /), link)
      true -> "<p>" <> inline(Enum.map_join(lines, " ", &String.trim/1), link) <> "</p>"
    end
  end

  # The items of a list: each line the marker starts begins one, and an
  # indented line below it continues it.
  defp items(lines, marker) do
    lines
    |> Enum.reduce([], fn line, acc ->
      if Regex.match?(marker, line),
        do: [Regex.replace(marker, line, "", global: false) | acc],
        else: List.update_at(acc, 0, &(&1 <> " " <> String.trim(line)))
    end)
    |> Enum.reverse()
  end

  defp list(tag, items, link),
    do:
      "<#{tag}>" <>
        Enum.map_join(items, "", &("<li>" <> inline(&1, link) <> "</li>")) <> "</#{tag}>"

  @doc """
  One line of text with its inline markup as HTML.

      iex> Dextrin.Schema.Docs.Markdown.inline("[guide](https://example.com) *now*", fn _ -> nil end)
      ~s(<a href="https://example.com">guide</a> <em>now</em>)
  """
  @spec inline(String.t(), (String.t() -> String.t() | nil)) :: String.t()
  def inline(text, link) do
    # Code spans first, so nothing inside one is read as markup.
    ~r/`([^`]+)`/
    |> Regex.split(text, include_captures: true)
    |> Enum.map_join(fn part ->
      case Regex.run(~r/^`([^`]+)`$/, part) do
        [_, code] -> code_span(code, link)
        nil -> markup(escape(part))
      end
    end)
  end

  defp code_span(code, link) do
    case link.(code) do
      nil -> "<code>" <> escape(code) <> "</code>"
      href -> ~s(<a class="ref" href="#{escape(href)}"><code>#{escape(code)}</code></a>)
    end
  end

  defp markup(text) do
    text
    |> then(
      &Regex.replace(~r/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/, &1, ~s(<a href="\\2">\\1</a>))
    )
    |> then(&Regex.replace(~r/\*\*([^*]+)\*\*/, &1, "<strong>\\1</strong>"))
    |> then(&Regex.replace(~r/\*([^*]+)\*/, &1, "<em>\\1</em>"))
  end

  @doc """
  `text` with the characters HTML gives a meaning to escaped.

      iex> Dextrin.Schema.Docs.Markdown.escape(~s(<a & "b">))
      "&lt;a &amp; &quot;b&quot;&gt;"
  """
  @spec escape(String.t()) :: String.t()
  def escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
