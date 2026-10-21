defmodule Dextrin.Struct do
  @moduledoc """
  Opaque DXN `struct` value, produced when no schema is compiled for
  its name (DXN.md §1.4: "a reader lacking the schema... returns an
  opaque tagged value rather than failing").

  `fields` is one of two shapes, and deliberately not normalized to a
  single common one — `.dxn`'s keyed literal form carries field
  *names*; `.dxnb`'s wire form is always positional (DXN.md §2.1) and
  never carries names at all. Without a schema there is no way to
  recover one shape from the other (a positional `.dxnb` struct has no
  names to reconstruct), so `Dextrin.Struct` says which shape it
  actually is rather than pretend they're interchangeable. This is
  also why an opaque struct decoded from `.dxnb` can't be
  cross-checked against the same struct decoded from `.dxn` without a
  schema in hand — there's nothing to compare field-by-field yet.

  `version` is the schema version the struct was written with
  (`%Name(3){...}`, DXNS.md §8), or `nil` when it was written without
  one, which a reader takes as the latest version it has loaded.

  `extra` holds the fields a struct carries beyond its declared ones
  (DXNS.md §7), as `{key, value}` pairs in the order they were written:
  a name for a named field, any other map key (§1.6) as itself. In text
  they are entries after the fields or the items; in `.dxnb`, one
  trailing tag-215 map. Code relying on a struct is guaranteed only its
  declared fields.
  """

  @type fields :: {:keyed, [{String.t(), term()}]} | {:positional, [term()]}

  @type t :: %__MODULE__{
          name: String.t(),
          version: pos_integer() | nil,
          fields: fields(),
          extra: [{term(), term()}]
        }

  defstruct [:name, :fields, version: nil, extra: []]

  @doc "A struct written with names, at `version` when one is given, carrying `extra`."
  @spec keyed(String.t(), [{String.t(), term()}], pos_integer() | nil, [{term(), term()}]) :: t()
  def keyed(name, pairs, version \\ nil, extra \\ []) when is_binary(name) and is_list(pairs) do
    %__MODULE__{name: name, version: version, fields: {:keyed, pairs}, extra: extra}
  end

  @doc """
  How a struct literal opens: `%Name`, or `%Name(3)` when it carries a
  version. Shared by every writer, so the printer, the formatter and the
  canonical form agree.

      Dextrin.Struct.head("P", 3)   #=> "%P(3)"
  """
  @spec head(String.t(), pos_integer() | nil) :: String.t()
  def head(name, version), do: "%" <> type_name(name, version)

  @doc """
  The struct's name as `.dxnb` writes it: `Name`, or `Name(3)` when it
  carries a version (DXN.md §2.4, §4.8).

      Dextrin.Struct.type_name("P", 3)     #=> "P(3)"
      Dextrin.Struct.type_name("P", nil)   #=> "P"
  """
  @spec type_name(String.t(), pos_integer() | nil) :: String.t()
  def type_name(name, nil), do: name
  def type_name(name, version), do: name <> "(" <> Integer.to_string(version) <> ")"

  @doc """
  The other direction: a `.dxnb` type name read back into its name and
  version. A version that is not a positive integer is `:error`.

      Dextrin.Struct.parse_type_name("P(3)")   #=> {:ok, "P", 3}
      Dextrin.Struct.parse_type_name("P")      #=> {:ok, "P", nil}
      Dextrin.Struct.parse_type_name("P(0)")   #=> :error
  """
  @spec parse_type_name(String.t()) :: {:ok, String.t(), pos_integer() | nil} | :error
  def parse_type_name(text) when is_binary(text) do
    case Regex.run(~r/\A(.+)\((-?[0-9]+)\)\z/s, text, capture: :all_but_first) do
      nil ->
        if String.contains?(text, ["(", ")"]), do: :error, else: {:ok, text, nil}

      [name, digits] ->
        case String.to_integer(digits) do
          version when version > 0 -> {:ok, name, version}
          _ -> :error
        end
    end
  end

  @doc "A struct written by position, at `version` when one is given, carrying `extra`."
  @spec positional(String.t(), [term()], pos_integer() | nil, [{term(), term()}]) :: t()
  def positional(name, values, version \\ nil, extra \\ [])
      when is_binary(name) and is_list(values) do
    %__MODULE__{name: name, version: version, fields: {:positional, values}, extra: extra}
  end

  @doc """
  An entry's key as an extra field's key: a keyword, symbol or string is
  a name (its text); any other map key (DXN.md §1.6) is kept as itself.

      Dextrin.Struct.extra_key(%Dextrin.Keyword{name: "nick"})   #=> "nick"
      Dextrin.Struct.extra_key(3)                                #=> 3
  """
  @spec extra_key(term()) :: term()
  def extra_key(%Dextrin.Keyword{name: name}), do: name
  def extra_key(%Dextrin.Symbol{name: name}), do: name
  def extra_key(key) when is_atom(key) and key not in [nil, true, false], do: Atom.to_string(key)
  def extra_key(key), do: key

  @doc """
  The extra fields an application struct carries at run time: the keys
  of `value` its module's own `defstruct` does not declare, as named
  extras. An Elixir struct is a map, so a key put on it after the fact
  is the struct carrying more than it declares (DXNS.md §7).
  """
  @spec runtime_extra(struct()) :: [{String.t(), term()}]
  def runtime_extra(%module{} = value) do
    declared = module.__struct__() |> Map.keys() |> MapSet.new()

    for {key, field} <- Map.to_list(value), not MapSet.member?(declared, key) do
      {extra_key(key), field}
    end
  end
end
