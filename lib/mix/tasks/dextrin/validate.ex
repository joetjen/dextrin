defmodule Mix.Tasks.Dextrin.Validate do
  @moduledoc """
  Decodes `PATH` (format sniffed from its extension, or forced with
  `--format text|binary`), reporting success or a rendered
  `Dextrin.Error` — non-zero exit on failure, so this is meant for CI
  as much as interactive use.

      $ mix dextrin.validate data.dxn
      $ mix dextrin.validate data.dxnb --format binary
      $ mix dextrin.validate data.dxn --schema money.dxns --as Money
  """

  use Mix.Task

  @shortdoc "Validates a .dxn/.dxnb file, optionally against a compiled .dxns schema"

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} =
      OptionParser.parse(argv, strict: [schema: :string, as: :string, format: :string])

    case args do
      [path] ->
        validate(path, opts)

      _ ->
        Mix.raise(
          "usage: mix dextrin.validate PATH [--format text|binary] [--schema SCHEMA.dxns --as NAME]"
        )
    end
  end

  defp validate(path, opts) do
    source = File.read!(path)
    registry = build_registry(opts[:schema])
    format = detect_format(path, opts[:format])

    case decode(format, source, registry) do
      {:ok, value} -> report_success(path, format, value, registry, opts[:as])
      {:error, error} -> Mix.raise("#{path}: " <> format_error(error))
    end
  end

  defp build_registry(nil), do: Dextrin.Registry.new()

  defp build_registry(schema_path) do
    {:ok, schema_doc} = Dextrin.decode(File.read!(schema_path))

    case Dextrin.Schema.compile(schema_doc) do
      {:ok, registry} -> registry
      {:error, reason} -> Mix.raise("failed to compile schema #{schema_path}: #{inspect(reason)}")
    end
  end

  defp decode(:text, source, registry), do: Dextrin.decode(source, registry: registry)
  defp decode(:binary, source, registry), do: Dextrin.decode_binary(source, registry: registry)

  defp report_success(path, format, _value, _registry, nil) do
    Mix.shell().info("OK: #{path} is valid .dxn#{if format == :binary, do: "b"}")
  end

  # Deliberately validate_encode/3, not validate/3: `value` here has
  # already gone through decode/2's own automatic, registry-driven
  # validation and materialization -- by the time it reaches this
  # function it's whatever shape the schema's materializer (or the
  # default plain-map fallback) produced, never a bare, unmaterialized
  # Dextrin.Struct. validate/3 only ever accepts the latter (it exists
  # for checking an *opaque* struct against a schema that wasn't
  # available at decode time); validate_encode/3 accepts any shape --
  # struct, materialized map, or real Elixir struct -- which is what
  # "does this decoded value satisfy schema NAME" actually needs here.
  defp report_success(path, format, value, registry, schema_name) do
    case Dextrin.Schema.validate_encode(value, registry, schema_name) do
      :ok ->
        Mix.shell().info(
          "OK: #{path} is valid .dxn#{if format == :binary, do: "b"} and satisfies schema #{schema_name}"
        )

      {:error, reason} ->
        Mix.raise("#{path} does not satisfy schema #{schema_name}: #{inspect(reason)}")
    end
  end

  defp detect_format(_path, "text"), do: :text
  defp detect_format(_path, "binary"), do: :binary

  defp detect_format(path, nil),
    do: if(String.ends_with?(path, ".dxnb"), do: :binary, else: :text)

  defp format_error(errors) when is_list(errors),
    do: Enum.map_join(errors, "\n", &Dextrin.Error.format/1)

  defp format_error(error), do: Dextrin.Error.format(error)
end
