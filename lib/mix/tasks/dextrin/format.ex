defmodule Mix.Tasks.Dextrin.Format do
  @moduledoc """
      $ mix dextrin.format data.dxn --mode pretty
      $ mix dextrin.format data.dxn --mode condense
      $ mix dextrin.format data.dxn --mode pretty --in-place

  Defaults to `--mode pretty`. `--in-place` rewrites `PATH`; otherwise
  prints to stdout.

  **`--mode pretty` keeps every comment** beside the entry it belongs to
  (`Dextrin.Document.format/2`): it changes layout only, so every token is
  written as it was. **`--mode condense` drops them**: a comment ends its
  line, and condensed output is one line -- it reprints the value
  (`Dextrin.encode/2`).
  """

  use Mix.Task

  @shortdoc "Reformats a .dxn file (pretty multi-line, or condensed single-line)"

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

    case Dextrin.Document.parse(source) do
      {:ok, doc} ->
        write_output(render(Keyword.get(opts, :mode, "pretty"), doc), path, opts[:in_place])

      {:error, error} ->
        Mix.raise(format_error(error))
    end
  end

  defp render("pretty", doc), do: Dextrin.Document.format(doc)

  defp render("condense", doc) do
    case Dextrin.encode(Dextrin.Document.to_value(doc)) do
      {:ok, text} -> text
      {:error, error} -> Mix.raise(format_error(error))
    end
  end

  defp render(other, _doc),
    do: Mix.raise("unrecognized --mode #{inspect(other)} — expected \"pretty\" or \"condense\"")

  # A file written in place ends with one newline, and printed output
  # with none of its own, whether or not the formatted text kept the
  # source's (`Dextrin.Document.format/2` does; condensed text does not).
  defp write_output(text, _path, in_place) when in_place != true,
    do: Mix.shell().info(String.trim_trailing(text, "\n"))

  defp write_output(text, path, true),
    do: File.write!(path, String.trim_trailing(text, "\n") <> "\n")

  defp format_error(errors) when is_list(errors),
    do: Enum.map_join(errors, "\n", &Dextrin.Error.format/1)

  defp format_error(error), do: Dextrin.Error.format(error)
end
