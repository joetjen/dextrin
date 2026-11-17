defmodule Mix.Tasks.Dextrin.FromJsonSchema do
  @moduledoc """
  Converts JSON Schema to DXNS (`Dextrin.Convert.JsonSchema`,
  design/json-schema.md): drafts 04, 06, 07, 2019-09 and 2020-12, and
  MongoDB's `$jsonSchema` with `bsonType`.

      $ mix dextrin.from_json_schema order.json --out order.dxns
      $ mix dextrin.from_json_schema api.json --schemas schemas/ --name Api

  The first file is the root. A `$ref` to another document is resolved
  among the files given and those under `--schemas DIR`, by `$id` or by
  relative path; nothing is fetched.

  Options:

    * `--out FILE` -- write the DXNS there instead of to standard output;
    * `--name NAME` -- the root's name (otherwise its `title`, otherwise
      `Root`);
    * `--draft D` -- `04`, `06`, `07`, `2019-09` or `2020-12`, for a schema
      with no `$schema` (default 2020-12);
    * `--mongo` -- read it as MongoDB's (also when `bsonType` appears);
    * `--structs` -- write named object schemas as `%schema`, not `%shape`;
    * `--assert-formats` -- check `format` and the content keywords in
      2019-09 and 2020-12 too, where they are annotations;
    * `--strict` -- fail when anything is not exact.

  Whatever is not exact is printed as `inexact: PATH: why`, and kept in
  the type's `meta` where it applies.
  """

  use Mix.Task

  alias Dextrin.Convert.JsonSchema

  @shortdoc "Converts JSON Schema (and MongoDB's $jsonSchema) to DXNS"

  @switches [
    out: :string,
    name: :string,
    draft: :string,
    schemas: :string,
    mongo: :boolean,
    structs: :boolean,
    assert_formats: :boolean,
    strict: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, files, _} = OptionParser.parse(argv, strict: @switches)

    if files == [],
      do: Mix.raise("usage: mix dextrin.from_json_schema SCHEMA... [--out FILE] [options]")

    sources = Enum.map(files ++ under(opts[:schemas], files), &{&1, read!(&1)})

    convert_opts =
      opts
      |> Elixir.Keyword.take([:name, :draft, :mongo, :structs, :assert_formats])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case JsonSchema.to_dxns(sources, convert_opts) do
      {:ok, %{document: document, inexact: inexact}} ->
        Enum.each(inexact, &Mix.shell().error("inexact: #{&1.path}: #{&1.why}"))

        if opts[:strict] && inexact != [],
          do: Mix.raise("#{length(inexact)} place(s) not exact, and --strict")

        {:ok, text} = Dextrin.encode(document, pretty: true)
        write(opts[:out], text <> "\n")

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  # Every .json file under `dir`, but those given already.
  defp under(nil, _given), do: []

  defp under(dir, given) do
    Path.join(dir, "**/*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reject(&(&1 in given))
  end

  defp read!(path) do
    case File.read(path) do
      {:ok, text} -> text
      {:error, why} -> Mix.raise("#{path}: #{:file.format_error(why)}")
    end
  end

  defp write(nil, text), do: IO.write(text)

  defp write(path, text) do
    File.write!(path, text)
    Mix.shell().info("wrote #{path}")
  end
end
