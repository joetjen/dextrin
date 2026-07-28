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
  """

  @type fields :: {:keyed, [{String.t(), term()}]} | {:positional, [term()]}

  @type t :: %__MODULE__{name: String.t(), fields: fields()}

  defstruct [:name, :fields]

  @spec keyed(String.t(), [{String.t(), term()}]) :: t()
  def keyed(name, pairs) when is_binary(name) and is_list(pairs) do
    %__MODULE__{name: name, fields: {:keyed, pairs}}
  end

  @spec positional(String.t(), [term()]) :: t()
  def positional(name, values) when is_binary(name) and is_list(values) do
    %__MODULE__{name: name, fields: {:positional, values}}
  end
end
