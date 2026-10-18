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
  (`%Name(3){...}`, DXN.md §4.8), or `nil` when it was written without
  one, which a reader takes as the latest version it has loaded.
  """

  @type fields :: {:keyed, [{String.t(), term()}]} | {:positional, [term()]}

  @type t :: %__MODULE__{name: String.t(), version: pos_integer() | nil, fields: fields()}

  defstruct [:name, :fields, version: nil]

  @doc "A struct written with names, at `version` when one is given."
  @spec keyed(String.t(), [{String.t(), term()}], pos_integer() | nil) :: t()
  def keyed(name, pairs, version \\ nil) when is_binary(name) and is_list(pairs) do
    %__MODULE__{name: name, version: version, fields: {:keyed, pairs}}
  end

  @doc """
  How a struct literal opens: `%Name`, or `%Name(3)` when it carries a
  version. Shared by every writer, so the printer, the formatter and the
  canonical form agree.

      Dextrin.Struct.head("P", 3)   #=> "%P(3)"
  """
  @spec head(String.t(), pos_integer() | nil) :: String.t()
  def head(name, nil), do: "%" <> name
  def head(name, version), do: "%" <> name <> "(" <> Integer.to_string(version) <> ")"

  @doc "A struct written by position, at `version` when one is given."
  @spec positional(String.t(), [term()], pos_integer() | nil) :: t()
  def positional(name, values, version \\ nil) when is_binary(name) and is_list(values) do
    %__MODULE__{name: name, version: version, fields: {:positional, values}}
  end
end
