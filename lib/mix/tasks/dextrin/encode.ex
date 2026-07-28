defmodule Mix.Tasks.Dextrin.Encode do
  @shortdoc "Encodes .dxn text to .dxnb binary"

  @moduledoc """
      $ mix dextrin.encode data.dxn
      $ mix dextrin.encode data.dxn --out data.dxnb
      $ mix dextrin.encode data.dxn --share

  Writes to stdout by default (DESIGN.md §12.2). `--share` opts into
  DXN.md §2.5's general value-sharing extension (CBOR tags 28/29) —
  only genuinely repeated compound values get wrapped, never a
  one-off value or a bare scalar (DESIGN.md §7.3.1).
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: [out: :string, share: :boolean])

    case args do
      [path] -> encode(path, opts)
      _ -> Mix.raise("usage: mix dextrin.encode PATH [--out PATH] [--share]")
    end
  end

  defp encode(path, opts) do
    source = File.read!(path)
    encode_opts = if opts[:share], do: [share: true], else: []

    with {:ok, value} <- Dextrin.decode(source),
         {:ok, bytes} <- Dextrin.encode_binary(value, encode_opts) do
      write_output(bytes, opts[:out])
    else
      {:error, error} -> Mix.raise(format_error(error))
    end
  end

  defp write_output(bytes, nil), do: IO.binwrite(bytes)
  defp write_output(bytes, out_path), do: File.write!(out_path, bytes)

  defp format_error(errors) when is_list(errors), do: Enum.map_join(errors, "\n", &Dextrin.Error.format/1)
  defp format_error(error), do: Dextrin.Error.format(error)
end
