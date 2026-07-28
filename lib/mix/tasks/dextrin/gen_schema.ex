defmodule Mix.Tasks.Dextrin.Gen.Schema do
  @shortdoc "Generates a .dxns scaffold from an already-compiled Elixir struct module"

  @moduledoc """
      $ mix dextrin.gen.schema MyApp.Point
      $ mix dextrin.gen.schema MyApp.Point --out point.dxns --name Point

  Introspects `Module`'s field list (always available for any compiled
  struct) and guesses each field's DXN type from its **default
  value**'s runtime type — not from `@type t()` typespecs. Typespec
  extraction (via Erlang/Elixir's typespec debug-info chunk API) needs
  a `:debug_info` chunk that isn't guaranteed present for every compiled module
  (dependencies built for production commonly strip it), so it can't
  be relied on as the primary source; a field whose default is `nil`,
  or that has no confident mapping, becomes `:any` rather than a guess
  either way.

  This is explicitly a starting point to review and tighten by hand,
  not a claim that struct → `.dxns` translation is lossless.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: [out: :string, name: :string])

    case args do
      [module_name] -> generate(module_name, opts)
      _ -> Mix.raise("usage: mix dextrin.gen.schema Module [--out PATH] [--name NAME]")
    end
  end

  defp generate(module_name, opts) do
    module = Module.concat([module_name])
    Code.ensure_loaded!(module)

    unless function_exported?(module, :__struct__, 0) do
      Mix.raise("#{module_name} is not a struct module (no __struct__/0)")
    end

    schema_name = Keyword.get(opts, :name, module |> Module.split() |> List.last())

    fields =
      module.__struct__() |> Map.from_struct() |> Map.to_list() |> Enum.sort_by(&elem(&1, 0))

    text = render_schema(schema_name, fields)
    write_output(text, opts[:out])
  end

  defp render_schema(schema_name, fields) do
    field_lines =
      Enum.map_join(fields, "\n", fn {name, default} ->
        "      #{name}?: #{guess_type(default)}"
      end)

    """
    %{
      #{schema_name}: %schema{
        fields: @ordered %{
    #{field_lines}
        }
      }
    }
    """
  end

  # Every generated field is optional (`?`) — a default value tells us
  # nothing about whether the field is actually required in practice,
  # and guessing "required" would be the riskier wrong default.
  defp guess_type(nil), do: ":any"
  defp guess_type(v) when is_boolean(v), do: ":boolean"
  defp guess_type(v) when is_integer(v), do: ":integer"
  defp guess_type(v) when is_float(v), do: ":float"
  defp guess_type(v) when is_binary(v), do: ":string"
  defp guess_type(v) when is_list(v), do: "{:list-of :any}"
  defp guess_type(v) when is_map(v) and not is_struct(v), do: "{:map-of :any :any}"
  defp guess_type(_v), do: ":any"

  defp write_output(text, nil), do: Mix.shell().info(text)
  defp write_output(text, out_path), do: File.write!(out_path, text)
end
