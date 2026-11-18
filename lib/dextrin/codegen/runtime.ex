defmodule Dextrin.Codegen.Runtime do
  @moduledoc """
  The few functions generated modules call (T684, design/codegen-elixir.md):
  ways to read a field out of a map whatever its key's spelling, to say
  what a value is in an error, to read a refine's constraints at compile
  time, and to write a struct back as DXN. None of them reads a schema;
  everything a schema says is in the generated code.
  """

  @doc """
  A constraint map written as DXN text, decoded once, when the generated
  module compiles: the arguments of a refine (regexes, decimals, dates)
  carried without a schema.
  """
  @spec constraints!(String.t()) :: %{optional(String.t()) => term()}
  def constraints!(text) do
    {:ok, value} = Dextrin.decode(text)
    value
  end

  @doc "A DXN value written as text, decoded when the generated module compiles."
  @spec value!(String.t()) :: term()
  def value!(text) do
    {:ok, value} = Dextrin.decode(text)
    value
  end

  @doc """
  The value under the field `name` in a map: its key may be the keyword,
  the atom or the string of that name, as a shape matches it. `:none` when
  it is absent.
  """
  @spec field(map(), String.t()) :: {:ok, term(), term()} | :none
  def field(map, name) do
    Enum.find_value(map, :none, fn {key, value} ->
      if key_name(key) == name, do: {:ok, key, value}
    end)
  end

  @doc "The entries of `map` whose key names none of `names`."
  @spec undeclared(map(), [String.t()]) :: [{term(), term()}]
  def undeclared(map, names), do: Enum.reject(map, fn {key, _} -> key_name(key) in names end)

  defp key_name(%Dextrin.Keyword{name: name}), do: name
  defp key_name(key) when is_atom(key) and key not in [nil, true, false], do: Atom.to_string(key)
  defp key_name(key) when is_binary(key), do: key
  defp key_name(_key), do: nil

  @doc "A struct's fields by name: keyed as they are, positional by `names`."
  @spec named(Dextrin.Struct.fields(), [String.t()]) :: {:ok, map()} | {:error, String.t()}
  def named({:keyed, pairs}, _names), do: {:ok, Map.new(pairs)}

  def named({:positional, items}, names) when length(items) == length(names),
    do: {:ok, Map.new(Enum.zip(names, items))}

  def named({:positional, items}, names),
    do: {:error, "expected #{length(names)} positional field(s), got #{length(items)}"}

  @doc "What a value is, for an error."
  @spec show(term()) :: String.t()
  def show(value) do
    case Dextrin.encode(value) do
      {:ok, text} -> text
      _ -> inspect(value)
    end
  end

  @doc """
  `value` written back as DXN: a generated module's struct as its own
  `to_dxn/1` writes it, inside lists, maps and tuples too.
  """
  @spec to_dxn(term()) :: term()
  def to_dxn(%module{} = value) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__dextrin_schema__, 0),
      do: module.to_dxn(value),
      else: value
  end

  def to_dxn(list) when is_list(list), do: Enum.map(list, &to_dxn/1)

  def to_dxn(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {k, to_dxn(v)} end)

  def to_dxn(other), do: other
end
