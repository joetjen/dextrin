defmodule Dextrin.Test.JsonSchemaSuite do
  @moduledoc """
  Runs the official JSON-Schema-Test-Suite (test/fixtures/
  json-schema-test-suite) against the JSON Schema converter (T674): each
  case's schema converted to DXNS and compiled, each test's instance
  read as DXN and checked against the root. A reference to the suite's
  `http://localhost:1234/` is the file of that path in `remotes`, given
  to the converter beside the schema; nothing is fetched.
  """

  alias Dextrin.Convert.JsonSchema

  @root Path.expand("../fixtures/json-schema-test-suite", __DIR__)
  @drafts %{
    "draft4" => "04",
    "draft6" => "06",
    "draft7" => "07",
    "draft2019-09" => "2019-09",
    "draft2020-12" => "2020-12"
  }

  @doc "The draft directories the suite has, with the draft each is."
  def drafts, do: @drafts

  @doc "Every required test of `dir`: `{id, schema, instance, valid}`."
  def tests(dir) do
    Path.join([@root, "tests", dir, "*.json"])
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(fn file ->
      {:ok, cases} = JsonSchema.decode_json(File.read!(file))

      for c <- cases, t <- c["tests"] do
        id = "#{dir}/#{Path.basename(file, ".json")}: #{c["description"]}: #{t["description"]}"
        {id, c["schema"], t["data"], t["valid"]}
      end
    end)
  end

  @doc """
  What checking `instance` against `schema` answers: `{:ok, true | false}`,
  or `{:error, reason}` when the schema did not convert or compile.
  """
  def run(schema, instance, draft) do
    with {:ok, registry} <- compiled(schema, draft, []) do
      value = JsonSchema.json_value(instance)
      {:ok, Dextrin.Schema.check(value, registry, "Root") == :ok}
    end
  end

  defp compiled(schema, draft, remotes) do
    sources = [{"http://localhost:1234/root.json", schema} | remotes]

    case JsonSchema.to_dxns(sources, draft: draft, name: "Root") do
      {:ok, %{document: doc}} ->
        case Dextrin.Schema.compile(doc) do
          {:ok, registry} -> {:ok, registry}
          {:error, %Dextrin.Error{message: message}} -> {:error, "compile: #{message}"}
        end

      {:error, why} ->
        case Regex.run(~r{resolved: http://localhost:1234/([^#\s)]+)}, why) do
          [_, path] ->
            file = Path.join([@root, "remotes", path])

            if File.exists?(file) and not Enum.any?(remotes, &(elem(&1, 0) =~ path)) do
              {:ok, remote} = JsonSchema.decode_json(File.read!(file))
              compiled(schema, draft, remotes ++ [{"http://localhost:1234/" <> path, remote}])
            else
              {:error, why}
            end

          _ ->
            {:error, why}
        end
    end
  end
end
