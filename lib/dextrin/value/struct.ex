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

  A keyed field *name* is likewise whatever shape the same key would
  be as an ordinary DXN map key: a real atom under trusted decode's
  keyword-shorthand (`x:`), a `Dextrin.Symbol.t()`/`Dextrin.Keyword.t()`
  for symbol syntax or untrusted decode, or a plain `String.t()` for a
  quoted-string field name — never forced to one canonical
  representation, so a struct field round-trips the exact literal form
  it was written in, same as a map entry does.
  """

  @type field_name :: String.t() | atom() | Dextrin.Keyword.t() | Dextrin.Symbol.t()

  @type fields :: {:keyed, [{field_name(), term()}]} | {:positional, [term()]}

  @type t :: %__MODULE__{name: String.t(), fields: fields()}

  defstruct [:name, :fields]

  @spec keyed(String.t(), [{field_name(), term()}]) :: t()
  def keyed(name, pairs) when is_binary(name) and is_list(pairs) do
    %__MODULE__{name: name, fields: {:keyed, pairs}}
  end

  @spec positional(String.t(), [term()]) :: t()
  def positional(name, values) when is_binary(name) and is_list(values) do
    %__MODULE__{name: name, fields: {:positional, values}}
  end
end
