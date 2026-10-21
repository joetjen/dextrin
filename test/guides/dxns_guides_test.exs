defmodule Dextrin.Guides.DxnsGuidesTest do
  @moduledoc """
  The DXNS tutorial, examples and cheatsheet (guides/dxns/) say only what
  is true: every ```dxns block compiles, and every ```dxn block that
  begins `# good: Name` or `# bad: Name` is, or is not, a `Name` under
  the schema block before it.
  """

  use ExUnit.Case, async: true

  @guides ~w(TUTORIAL.md DXNS_EXAMPLES.md DXNS_CHEATSHEET.md)

  # The fenced blocks of a Markdown file: {language, line, text}.
  defp blocks(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], nil}, fn
      {"```" <> lang, line}, {acc, nil} when lang != "" ->
        {acc, {lang, line, []}}

      {"```", _line}, {acc, {lang, line, lines}} ->
        {[{lang, line, Enum.join(Enum.reverse(lines), "\n")} | acc], nil}

      {text, _line}, {acc, {lang, line, lines}} ->
        {acc, {lang, line, [text | lines]}}

      _, state ->
        state
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp compile(text) do
    with {:ok, doc} <- Dextrin.decode(text), do: Dextrin.Schema.compile(doc)
  end

  # Whether `text` is a `name` under `registry`: a struct decodes against
  # its schema; any other value is checked against the named type.
  defp takes?(registry, name, text) do
    case Dextrin.decode(text, registry: registry) do
      {:error, _} ->
        false

      {:ok, value} ->
        not Map.has_key?(registry.type_aliases, name) or
          Dextrin.Schema.check(value, registry, name) == :ok
    end
  end

  for guide <- @guides do
    test "every block of #{guide} says what is true" do
      path = Path.join(["guides", "dxns", unquote(guide)])

      problems =
        path
        |> blocks()
        |> Enum.reduce({nil, []}, fn
          {"dxns", line, text}, {_registry, problems} ->
            case compile(text) do
              {:ok, registry} ->
                {registry, problems}

              {:error, error} ->
                {nil,
                 [
                   "line #{line}: the schema does not compile: #{Exception.message(error)}"
                   | problems
                 ]}
            end

          {"dxn", line, text}, {registry, problems} ->
            case Regex.run(~r/^# (good|bad): (\S+)/, text) do
              nil ->
                {registry, problems}

              [_, verdict, name] when registry != nil ->
                if takes?(registry, name, text) == (verdict == "good"),
                  do: {registry, problems},
                  else: {registry, ["line #{line}: meant #{verdict} as #{name}" | problems]}

              _ ->
                {registry, ["line #{line}: data with no schema before it" | problems]}
            end

          _other, acc ->
            acc
        end)
        |> elem(1)
        |> Enum.reverse()

      assert problems == [], Enum.join(problems, "\n")
    end
  end
end
