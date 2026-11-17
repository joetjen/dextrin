defmodule Dextrin.Convert.JsonSchemaSuiteTest do
  @moduledoc """
  The parity test of the JSON Schema converter (T674, design/json-schema.md
  Q7): every required test of the official JSON-Schema-Test-Suite, for
  drafts 4, 6, 7, 2019-09 and 2020-12, passes once converted to DXNS --
  except those listed, by reason, in test/fixtures/json-schema-exceptions.txt.
  A listed test that passes fails this too, so the list stays true.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Test.JsonSchemaSuite

  @exceptions "test/fixtures/json-schema-exceptions.txt"
              |> File.read!()
              |> String.split("\n")
              |> Enum.filter(&String.starts_with?(&1, "draft"))
              |> MapSet.new()

  for {dir, draft} <- JsonSchemaSuite.drafts() do
    @tag timeout: 300_000
    test "the #{dir} suite passes, but for the listed exceptions" do
      outcomes =
        for {id, schema, data, valid} <- JsonSchemaSuite.tests(unquote(dir)) do
          passed =
            case JsonSchemaSuite.run(schema, data, unquote(draft)) do
              {:ok, ^valid} -> true
              _ -> false
            end

          {id, passed}
        end

      failing = for {id, false} <- outcomes, not MapSet.member?(@exceptions, id), do: id
      fixed = for {id, true} <- outcomes, MapSet.member?(@exceptions, id), do: id

      assert failing == [], "failing, not listed:\n" <> Enum.join(failing, "\n")
      assert fixed == [], "listed, but passing now:\n" <> Enum.join(fixed, "\n")
    end
  end
end
