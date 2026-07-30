defmodule Mix.Tasks.Dextrin.Gen.Unicode do
  @moduledoc """
  Fetches the latest Unicode Character Database `DerivedCoreProperties.txt`,
  compares its version against the one last processed
  (`priv/unicode/VERSION`), and — if newer — regenerates the
  `IDENT_START`/`IDENT_CONT`/`IDENTIFIER` ranges spliced into
  `priv/grammar/dxn.aether` (see `Dextrin.Unicode.RangeGenerator` for
  the pure text-processing logic this task wraps with file/network I/O).

  This is a deliberate, reviewed action, never run automatically at
  build time or gated on by CI — a human invokes this task and reviews
  the resulting diff to `priv/grammar/dxn.aether` before committing,
  same as any other dependency version bump.

      $ mix dextrin.gen.unicode
      $ mix dextrin.gen.unicode --file /path/to/DerivedCoreProperties.txt
      $ mix dextrin.gen.unicode --force

  ## Options

    * `--file PATH` — read UCD data from a local file instead of
      fetching it from unicode.org (offline use, or testing against a
      specific file).
    * `--force` — regenerate even if the version hasn't changed.
  """

  use Mix.Task

  alias Dextrin.Unicode.RangeGenerator

  @shortdoc "Updates the generated Unicode identifier ranges from the latest UCD data"

  @ucd_url ~c"https://unicode.org/Public/UCD/latest/ucd/DerivedCoreProperties.txt"

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [file: :string, force: :boolean])

    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    ucd_text = fetch_ucd_text(opts[:file])
    new_version = RangeGenerator.version(ucd_text)
    last_version = last_processed_version()
    force? = Keyword.get(opts, :force, false)

    if new_version == last_version and not force? do
      Mix.shell().info("Already up to date (Unicode #{new_version}).")
    else
      update!(ucd_text, new_version, last_version)
    end
  end

  defp fetch_ucd_text(nil) do
    Mix.shell().info("Fetching #{@ucd_url}...")

    http_opts = [ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]]

    case :httpc.request(:get, {@ucd_url, []}, http_opts, body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        body

      {:ok, {{_, status, _}, _headers, _body}} ->
        Mix.raise("Fetching UCD data failed: HTTP #{status}")

      {:error, reason} ->
        Mix.raise("Fetching UCD data failed: #{inspect(reason)}")
    end
  end

  defp fetch_ucd_text(path) do
    case File.read(path) do
      {:ok, text} -> text
      {:error, reason} -> Mix.raise("Could not read #{path}: #{:file.format_error(reason)}")
    end
  end

  defp last_processed_version do
    case File.read(version_path()) do
      {:ok, text} -> String.trim(text)
      {:error, :enoent} -> nil
    end
  end

  defp update!(ucd_text, new_version, last_version) do
    generated = RangeGenerator.generated_block(ucd_text)
    {start_count, cont_count} = RangeGenerator.range_counts(ucd_text)

    grammar_source =
      case File.read(grammar_path()) do
        {:ok, source} -> source
        {:error, :enoent} -> Mix.raise("#{grammar_path()} does not exist")
      end

    File.write!(grammar_path(), RangeGenerator.splice(grammar_source, generated))
    File.write!(ucd_data_path(), ucd_text)
    File.write!(version_path(), new_version <> "\n")

    from = last_version || "none"

    Mix.shell().info(
      "Updated Unicode #{from} -> #{new_version}: #{start_count} XID_Start ranges, " <>
        "#{cont_count} XID_Continue ranges.\n" <>
        "Review the diff to #{grammar_path()} before committing."
    )
  end

  defp grammar_path, do: Path.join([File.cwd!(), "priv", "grammar", "dxn.aether"])
  defp ucd_data_path, do: Path.join([File.cwd!(), "priv", "unicode", "DerivedCoreProperties.txt"])
  defp version_path, do: Path.join([File.cwd!(), "priv", "unicode", "VERSION"])
end
