defmodule Dextrin.Schema.Reader do
  @moduledoc """
  Which schema a decoded struct is read with, given the version it was
  written with and the versions loaded (DXN.md §4.8). Shared by the text
  and binary decoders, so both answer every case the same way.

    * **No version, or the latest loaded:** read with the latest, exactly.
    * **Newer than anything loaded:** read against the latest. Text
      matches fields by name; binary assumes positions are unchanged,
      drops the items beyond the reader's own and leaves missing optional
      fields absent. A newer version that reordered or removed fields is
      misread, without an error whenever the types agree -- the
      documented risk of reading forward.
    * **Older and loaded:** read with that version's own schema and handed
      to the materializer, which upgrades it. Without a materializer it is
      refused, `schema/no-materializer`: reading old data as if it were
      the latest would be a guess.
    * **Older and not loaded:** refused, `schema/unknown-version`, even
      with a materializer, which would receive no field names.

  **What is built from the fields** (B4): the schema's materializer,
  when one is registered, is called for every struct of its schema,
  whatever the version, as `materializer.(name, version, fields)` --
  `version` being the one the fields were read with, `fields` a map
  keyed by field-name string. It upgrades, builds the application's own
  value, refines and validates; its result is checked against the latest
  schema, and a refusal or a result the latest schema rejects is
  `schema/materializer`. Without a materializer the latest version comes
  back as a `Dextrin.Struct` at that version, its fields in the schema's
  order, which is written back exactly as it was read. Nested structs
  are built first, so a materializer sees its fields' structs finished.
  """

  alias Dextrin.{Registry, Struct}
  alias Dextrin.Schema.{Compiled, Validated, Validator}

  @doc """
  `fields` of the struct `name`, written at `version` (nil when it says
  none), read against `registry`.

  Answers `{:ok, value, registry}`, `{:unknown, registry}` when `name`
  has no schema at all -- the struct stays opaque -- or `{:error, error}`
  with a `Dextrin.Error` carrying the DXN.md §5 category where there is
  one, or a message the caller wraps as a schema violation.
  """
  @spec read(Registry.t(), String.t(), pos_integer() | nil, Validator.fields()) ::
          {:ok, term(), Registry.t()}
          | {:unknown, Registry.t()}
          | {:error, Dextrin.Error.t() | String.t()}
  def read(%Registry{} = registry, name, version, fields) do
    case Registry.fetch_struct_schema(registry, name) do
      {:ok, %Compiled{} = latest, registry} -> by_version(registry, latest, version, fields)
      {:unknown, registry} -> {:unknown, registry}
    end
  end

  defp by_version(registry, %Compiled{version: latest} = compiled, version, fields)
       when version == nil or version == latest,
       do: materialized(registry, compiled, compiled, fields)

  defp by_version(registry, %Compiled{version: latest} = compiled, version, fields)
       when version > latest,
       do: materialized(registry, compiled, compiled, forward(compiled, fields))

  defp by_version(registry, %Compiled{name: name} = latest, version, fields) do
    case {Registry.fetch_struct_schema(registry, name, version), materializer(registry, name)} do
      {{:unknown, _registry}, _materializer} ->
        {:error,
         Dextrin.Error.action(
           "struct #{inspect(name)} was written with version #{version}, which is not loaded",
           "schema/unknown-version"
         )}

      {{:ok, _older, _registry}, nil} ->
        {:error,
         Dextrin.Error.action(
           "struct #{inspect(name)} was written with the older version #{version}, " <>
             "and no materializer is registered to upgrade it",
           "schema/no-materializer"
         )}

      {{:ok, older, _registry}, _materializer} ->
        materialized(registry, older, latest, fields)
    end
  end

  # A newer writer's positional items, read by the reader's own field
  # order: positions are assumed unchanged, items beyond the reader's
  # fields are dropped, and fields beyond the items are absent. Keyed
  # fields already carry their names.
  defp forward(%Compiled{} = compiled, {:positional, items}) do
    {:keyed, Enum.zip(Compiled.field_names(compiled), items)}
  end

  defp forward(_compiled, {:keyed, _pairs} = fields), do: fields

  # The fields read with `reading`, then built into a value: by the
  # materializer when there is one, checked against `latest`; as a
  # generic struct at `latest`'s version when there is none. Wrapped in
  # `Validated` so an outer schema's reference can tell where it came
  # from.
  defp materialized(registry, %Compiled{name: name} = reading, %Compiled{} = latest, fields) do
    with {:ok, pairs} <- Validator.resolve(reading, fields, registry),
         {:ok, value} <- built(registry, materializer(registry, name), reading, latest, pairs) do
      {:ok, %Validated{name: name, value: value}, registry}
    end
  end

  defp built(_registry, nil, _reading, %Compiled{name: name, version: version}, pairs),
    do: {:ok, Struct.keyed(name, pairs, version)}

  defp built(registry, materializer, %Compiled{name: name} = reading, latest, pairs) do
    case materializer.(name, reading.version, Map.new(pairs)) do
      {:ok, value} ->
        case Validator.validate_for_encode(latest, value, registry) do
          :ok ->
            {:ok, value}

          {:error, reason} ->
            materializer_error(
              name,
              "answered a value version #{latest.version} rejects: #{reason}"
            )
        end

      {:error, reason} ->
        materializer_error(name, "refused: #{inspect(reason)}")
    end
  end

  defp materializer_error(name, what) do
    {:error,
     Dextrin.Error.action("the materializer for #{inspect(name)} #{what}", "schema/materializer")}
  end

  defp materializer(registry, name) do
    case Registry.fetch_materializer(registry, name) do
      {:ok, fun} -> fun
      :error -> nil
    end
  end
end
