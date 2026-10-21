defmodule Mix.Tasks.Dextrin.Docs do
  @moduledoc """
      $ mix dextrin.docs SCHEMAS [--out DIR] [--title TITLE]

  Reads every `.dxns` file under `SCHEMAS`, its subdirectories included,
  and writes their documentation to `DIR` (`doc/schemas` when not given):
  an `index.html`, a page for each namespace, and `style.css`. `TITLE`
  names the site; it is `SCHEMAS`'s directory name when not given. See
  `Dextrin.Schema.Docs`.
  """

  use Mix.Task

  @shortdoc "Writes HTML documentation for a directory of .dxns schemas"

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: [out: :string, title: :string])

    root =
      case args do
        [root] -> root
        _ -> Mix.raise("usage: mix dextrin.docs SCHEMAS [--out DIR] [--title TITLE]")
      end

    out = Keyword.get(opts, :out, "doc/schemas")
    site_opts = if opts[:title], do: [title: opts[:title]], else: []

    case Dextrin.Schema.Docs.write(root, out, site_opts) do
      {:ok, written} -> Mix.shell().info("wrote #{length(written)} files to #{out}")
      {:error, why} -> Mix.raise(why)
    end
  end
end
