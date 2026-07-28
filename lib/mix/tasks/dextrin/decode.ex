defmodule Mix.Tasks.Dextrin.Decode do
  @shortdoc "Decodes .dxnb binary to .dxn text"

  @moduledoc """
      $ mix dextrin.decode data.dxnb
      $ mix dextrin.decode data.dxnb --out data.dxn

  Prints through `Dextrin.Text.Formatter`'s pretty (multi-line) mode by
  default — a CLI decode is a human reading the result, so the
  encoder's own single-line default (correct for `Dextrin.encode/2`'s
  own API) isn't the right default here.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: [out: :string])

    case args do
      [path] -> decode(path, opts)
      _ -> Mix.raise("usage: mix dextrin.decode PATH [--out PATH]")
    end
  end

  defp decode(path, opts) do
    bytes = File.read!(path)

    case Dextrin.decode_binary(bytes) do
      {:ok, value} -> write_output(Dextrin.Text.Formatter.pretty(value), opts[:out])
      {:error, error} -> Mix.raise(Dextrin.Error.format(error))
    end
  end

  defp write_output(text, nil), do: Mix.shell().info(text)
  defp write_output(text, out_path), do: File.write!(out_path, text)
end
