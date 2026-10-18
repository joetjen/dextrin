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
  """

  alias Dextrin.Registry
  alias Dextrin.Schema.{Compiled, Validator}

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
       do: materialized(registry, compiled, fields)

  defp by_version(registry, %Compiled{version: latest} = compiled, version, fields)
       when version > latest,
       do: materialized(registry, compiled, forward(compiled, fields))

  defp by_version(registry, %Compiled{name: name}, version, fields) do
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
        materialized(registry, older, fields)
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

  defp materialized(registry, %Compiled{name: name} = compiled, fields) do
    case Validator.materialize(compiled, fields, materializer(registry, name), registry) do
      {:ok, value} -> {:ok, value, registry}
      {:error, _} = error -> error
    end
  end

  defp materializer(registry, name) do
    case Registry.fetch_materializer(registry, name) do
      {:ok, fun} -> fun
      :error -> nil
    end
  end
end
