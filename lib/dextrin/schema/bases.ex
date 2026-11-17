defmodule Dextrin.Schema.Bases do
  @moduledoc """
  The fields of a schema or shape built from others (DXNS.md §4b, Jan,
  2026-11-17): its bases' fields merged with its own body.

  The order is the bases', in the order the head names them, each
  base's in its own order. A field that arrives again keeps its first
  place, an override stays where it is, and the body's own fields come
  last. The same field from two bases is one field when both are
  identical; two that differ are refused unless the body overrides or
  drops that field.

  The bases themselves -- which schema or shape a name means, at which
  version -- are found by `Dextrin.Schema.Compiler`; this module only
  merges what it is handed.
  """

  alias Dextrin.Schema.Field

  @typedoc "One base, found: how it is named in the head, and its fields."
  @type base :: %{kind: :extends | :includes, name: String.t(), fields: [Field.t()]}

  @doc """
  `own` and `drops` merged onto `bases`' fields: `{:ok, fields}` or
  `{:error, reason}`, a reason in words.

      iex> alias Dextrin.Schema.Field
      iex> base = %{kind: :extends, name: "P", fields: [%Field{name: "a"}, %Field{name: "b", required: false}]}
      iex> {:ok, fields} = Dextrin.Schema.Bases.merge([base], [%Field{name: "c"}], ["b"])
      iex> Enum.map(fields, & &1.name)
      ["a", "c"]
  """
  #
  # `same?` tells whether two fields of one name from two bases are the
  # same field; the compiler compares them with their types in place.
  @spec merge([base()], [Field.t()], [String.t()], (Field.t(), Field.t() -> boolean())) ::
          {:ok, [Field.t()]} | {:error, String.t()}
  def merge(bases, own, drops, same? \\ &==/2) do
    own_names = MapSet.new(own, & &1.name)

    with :ok <- distinct_drops(drops),
         {:ok, inherited} <-
           inherited(bases, MapSet.union(own_names, MapSet.new(drops)), same?),
         :ok <- drops_inherited(drops, inherited, own_names),
         :ok <- drops_optional(drops, bases) do
      kept = Enum.reject(inherited, &(&1.name in drops))
      by_name = Map.new(own, &{&1.name, &1})
      overridden = Enum.map(kept, &Map.get(by_name, &1.name, &1))
      placed = MapSet.new(kept, & &1.name)
      {:ok, overridden ++ Enum.reject(own, &MapSet.member?(placed, &1.name))}
    end
  end

  # Every base's fields in turn, each name once, its first place kept.
  # Two different fields of one name are refused unless `settled` -- the
  # body overrides or drops it.
  defp inherited(bases, settled, same?) do
    bases
    |> Enum.flat_map(fn base -> Enum.map(base.fields, &{base.name, &1}) end)
    |> Enum.reduce_while({:ok, [], %{}}, fn {from, field}, {:ok, fields, seen} ->
      case Map.fetch(seen, field.name) do
        :error ->
          {:cont, {:ok, [field | fields], Map.put(seen, field.name, {from, field})}}

        {:ok, {_first, other}} ->
          if same?.(other, field) or MapSet.member?(settled, field.name),
            do: {:cont, {:ok, fields, seen}},
            else:
              {:halt,
               {:error,
                "field #{inspect(field.name)} differs between its bases; override it, or drop it"}}
      end
    end)
    |> case do
      {:ok, fields, _seen} -> {:ok, Enum.reverse(fields)}
      {:error, _} = error -> error
    end
  end

  defp distinct_drops(drops) do
    case drops |> Enum.frequencies() |> Enum.find(fn {_, n} -> n > 1 end) do
      nil -> :ok
      {name, _} -> {:error, "field #{inspect(name)} is dropped twice"}
    end
  end

  defp drops_inherited(drops, inherited, own_names) do
    names = MapSet.new(inherited, & &1.name)

    cond do
      missing = Enum.find(drops, &(not MapSet.member?(names, &1))) ->
        {:error, "- #{missing} drops a field no base has"}

      declared = Enum.find(drops, &MapSet.member?(own_names, &1)) ->
        {:error, "field #{inspect(declared)} is both dropped and declared"}

      true ->
        :ok
    end
  end

  # No value without a required field of an `extends` base could pass as
  # that base; `includes` is for leaving one out.
  defp drops_optional(drops, bases) do
    case Enum.find_value(bases, fn
           %{kind: :extends, name: base, fields: fields} ->
             Enum.find_value(fields, fn field ->
               field.required and field.name in drops and {base, field.name}
             end)

           _includes ->
             nil
         end) do
      nil ->
        :ok

      {base, field} ->
        {:error,
         "- #{field} drops a required field of #{base}, which this schema extends; " <>
           "include #{base} instead"}
    end
  end
end
