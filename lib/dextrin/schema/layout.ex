defmodule Dextrin.Schema.Layout do
  @moduledoc """
  The names a `.dxns` file's entries have, from where the file lies under
  its root (DXNS.md §6) -- one rule for every reader of a tree: the
  docs generator, `Dextrin.Schema.Tree` and the file resolver.

  - **A file named like one entry holds that entry**: `acme/shop/
    Customer-v2.dxns`, `acme/shop/Order/v1.dxns` and `acme.shop.Product.dxns`
    hold `acme.shop/Customer`, `acme.shop/Order` and `acme.shop/Product`,
    and the version their name says. Every other entry in such a file is
    internal to it: `acme.shop.Order/Line`.
  - **A file holding no entry named like it is a namespace file**:
    `acme.common.dxns` holds `acme.common/Money` and the rest.
  - **A name with no namespace is its own file**: `HealthCheck.dxns`
    holding `HealthCheck`.
  """

  @typedoc "What a file's path says about the entries it holds."
  @type t :: %{
          names: %{String.t() => String.t()},
          holder: String.t() | nil,
          version: pos_integer() | nil,
          internal: [String.t()]
        }

  @doc """
  The layout of the file at `relative` (to its root), holding the entries
  `keys`.

      iex> Dextrin.Schema.Layout.of("acme/shop/Order-v2.dxns", ["Order", "Line"])
      %{names: %{"Order" => "acme.shop/Order", "Line" => "acme.shop.Order/Line"},
        holder: "Order", version: 2, internal: ["Line"]}

      iex> Dextrin.Schema.Layout.of("acme.common.dxns", ["Money"]).names
      %{"Money" => "acme.common/Money"}
  """
  @spec of(Path.t(), [String.t()]) :: t()
  def of(relative, keys) do
    {stem, version} = stem(relative)
    own = List.last(stem)
    holder = if own in keys, do: own
    namespace = stem |> Enum.drop(-1) |> Enum.join(".")
    whole = Enum.join(stem, ".")

    names =
      Map.new(keys, fn key ->
        if key == holder, do: {key, join(namespace, key)}, else: {key, join(whole, key)}
      end)

    %{
      names: names,
      holder: holder,
      version: if(holder, do: version),
      internal: if(holder, do: Enum.reject(keys, &(&1 == holder)), else: [])
    }
  end

  # A file's dotted stem and the version its name says: `Customer-v2`
  # and `Order/v1` carry one, anything else none.
  defp stem(relative) do
    parts = relative |> String.replace_suffix(".dxns", "") |> Path.split()
    {dirs, [last]} = Enum.split(parts, -1)

    {name_parts, version} =
      cond do
        dirs != [] and Regex.match?(~r/^v[1-9][0-9]*$/, last) ->
          {dirs, last |> String.trim_leading("v") |> String.to_integer()}

        match = Regex.run(~r/^(.+)-v([1-9][0-9]*)$/, last) ->
          [_, base, n] = match
          {dirs ++ [base], String.to_integer(n)}

        true ->
          {dirs ++ [last], nil}
      end

    {Enum.flat_map(name_parts, &String.split(&1, ".")), version}
  end

  defp join("", name), do: name
  defp join(namespace, name), do: namespace <> "/" <> name
end
