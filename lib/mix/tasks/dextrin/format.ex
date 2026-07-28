defmodule Mix.Tasks.Dextrin.Format do
  @shortdoc "Reformats a .dxn file (pretty multi-line, or condensed single-line)"

  @moduledoc """
      $ mix dextrin.format data.dxn --mode pretty
      $ mix dextrin.format data.dxn --mode condense
      $ mix dextrin.format data.dxn --mode pretty --in-place

  Defaults to `--mode pretty`. `--in-place` rewrites `PATH`; otherwise
  prints to stdout.

  Comments are always dropped, not "stripped by default" — `.dxn`'s
  lexer discards them as trivia before the parser (and therefore any
  value this formatter could reprint) ever sees them. There is no mode
  that preserves them; that would need a second, independent
  re-lexing pipeline this design doesn't have (DESIGN.md §12.4).
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: [mode: :string, in_place: :boolean])

    case args do
      [path] -> format(path, opts)
      _ -> Mix.raise("usage: mix dextrin.format PATH [--mode pretty|condense] [--in-place]")
    end
  end

  defp format(path, opts) do
    source = File.read!(path)
    mode = Keyword.get(opts, :mode, "pretty")

    case Dextrin.decode(source) do
      {:ok, value} ->
        text = render(mode, value)
        write_output(text, path, opts[:in_place])

      {:error, error} ->
        Mix.raise(format_error(error))
    end
  end

  defp render("pretty", value), do: Dextrin.Text.Formatter.pretty(value)

  defp render("condense", value) do
    case Dextrin.encode(value) do
      {:ok, text} -> text
      {:error, error} -> Mix.raise(format_error(error))
    end
  end

  defp render(other, _value), do: Mix.raise("unrecognized --mode #{inspect(other)} — expected \"pretty\" or \"condense\"")

  defp write_output(text, _path, in_place) when in_place != true, do: Mix.shell().info(text)
  defp write_output(text, path, true), do: File.write!(path, text <> "\n")

  defp format_error(errors) when is_list(errors), do: Enum.map_join(errors, "\n", &Dextrin.Error.format/1)
  defp format_error(error), do: Dextrin.Error.format(error)
end
