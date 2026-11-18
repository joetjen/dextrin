defmodule Dextrin.Codegen.Runtime do
  @moduledoc """
  The few functions generated modules call (T684, design/codegen-elixir.md):
  ways to read a field out of a map whatever its key's spelling, to say
  what a value is in an error, to read a refine's constraints at compile
  time, and to write a struct back as DXN. None of them reads a schema;
  everything a schema says is in the generated code.
  """

  require Logger

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

  # ---- deprecation warnings (T698) ------------------------------------------

  # Generated code warns as Dextrin's reader does (DXNS.md §1b,
  # `Dextrin.Schema.Deprecations`), with nothing but itself: a value that
  # goes through something deprecated is *noted* while it is read, and the
  # notes are settled when the outermost read ends --
  #
  #   * so a variant tried and refused stays silent: `attempt/2` drops
  #     what it noted;
  #   * so `:error` refuses the whole value, whichever function noted it;
  #   * so the type functions keep one argument: the read's options and
  #     notes are in the process dictionary for as long as it runs, and
  #     gone after (`reading/2`).
  #
  # "Once" is per generated module and deprecated thing: an `:atomics`
  # array the module puts in `:persistent_term` when it loads, one slot
  # each, numbered when it is generated. Loading the module again starts
  # it afresh.

  @reading {__MODULE__, :reading}

  @doc """
  `fun.()`, a read or a check, with deprecation warnings as `opts`
  say: `deprecations:` -- `:once` per deprecated thing (the default),
  `:every` use, `:off`, or `:error`, which turns the first into
  `{:error, why}` -- and `on_deprecated:`, a function that receives each
  warning in place of `Logger.warning`. Inside another read it only runs
  `fun`: the outermost read settles.
  """
  @spec reading(keyword(), (-> result)) :: result when result: term()
  def reading(opts, fun) do
    case Process.get(@reading) do
      nil ->
        mode = Keyword.get(opts, :deprecations, :once)

        unless mode in [:once, :every, :off, :error],
          do:
            raise(
              ArgumentError,
              "deprecations: is :once, :every, :off or :error, got #{inspect(mode)}"
            )

        Process.put(@reading, %{mode: mode, notes: []})

        try do
          result = fun.()
          settle(result, Enum.reverse(Process.get(@reading).notes), mode, opts[:on_deprecated])
        after
          Process.delete(@reading)
        end

      _inside ->
        fun.()
    end
  end

  @doc """
  A value went through something deprecated: `slot` of `module`, with
  `warning` (`Dextrin.Schema.Deprecations.warning/3`). Outside a read it
  is settled at once, as `:once` and to the log.
  """
  @spec deprecated(module(), pos_integer(), Dextrin.Schema.Deprecations.warning()) :: :ok
  def deprecated(module, slot, warning) do
    case Process.get(@reading) do
      nil ->
        settle(:ok, [{module, slot, warning}], :once, nil)
        :ok

      %{mode: :off} ->
        :ok

      state ->
        Process.put(@reading, %{state | notes: [{module, slot, warning} | state.notes]})
        :ok
    end
  end

  @doc """
  `value` went through an enum whose deprecated values are `values`,
  each `{literal, slot, warning}`: noted when it is one of them.
  """
  @spec deprecated_value(module(), term(), [{term(), pos_integer(), map()}]) :: :ok
  def deprecated_value(module, value, values) do
    case Enum.find(values, fn {literal, _, _} -> plain(literal) == plain(value) end) do
      {_, slot, warning} -> deprecated(module, slot, warning)
      nil -> :ok
    end
  end

  # A literal as written may be a keyword, the value an atom.
  defp plain(%Dextrin.Keyword{name: name}), do: {:keyword, name}

  defp plain(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: {:keyword, Atom.to_string(atom)}

  defp plain(other), do: other

  @doc """
  `fun.(value)`, a variant tried: what it noted is kept only when it
  takes the value.
  """
  @spec attempt((term() -> {:ok, term()} | {:error, term()}), term()) ::
          {:ok, term()} | {:error, term()}
  def attempt(fun, value) do
    before = Process.get(@reading)
    result = fun.(value)

    with %{} <- before, {:error, _} <- result do
      Process.put(@reading, %{Process.get(@reading) | notes: before.notes})
    end

    result
  end

  @doc "A generated module's \"once\" state: an `:atomics` of `size` slots, kept while it is loaded."
  @spec slots(module(), pos_integer()) :: :ok
  def slots(module, size) do
    :persistent_term.put({__MODULE__, module}, :atomics.new(size, signed: false))
    :ok
  end

  defp settle({:error, _} = result, _notes, _mode, _fun), do: result
  defp settle(result, [], _mode, _fun), do: result

  defp settle(_result, [{_, _, warning} | _], :error, _fun),
    do: {:error, Dextrin.Schema.Deprecations.text(warning)}

  defp settle(result, notes, mode, fun) do
    for {module, slot, warning} <- notes,
        mode == :every or first_use?(module, slot),
        do: report(warning, fun)

    result
  end

  defp first_use?(module, slot) do
    case :persistent_term.get({__MODULE__, module}, nil) do
      nil -> true
      seen -> :atomics.compare_exchange(seen, slot, 0, 1) == :ok
    end
  end

  defp report(warning, fun) when is_function(fun, 1), do: fun.(warning)

  defp report(warning, _fun) do
    Logger.warning(Dextrin.Schema.Deprecations.text(warning),
      dextrin_deprecated: warning.name,
      category: Dextrin.Schema.Deprecations.category()
    )
  end

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
