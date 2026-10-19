defmodule Dextrin.Document do
  @moduledoc """
  A `.dxn` document with everything it holds: its value, and every
  comment, blank line and comma around it (`design/comment-retention.md`).

  `Dextrin.decode/2` keeps only the value, which is right for data and
  wrong for a file people annotate: decoding, changing one entry and
  encoding again deletes every comment. A document keeps the
  **full-fidelity syntax tree** instead -- every token, trivia included
  (`Ichor.Syntax`) -- with the value as a projection of it:

      {:ok, doc} = Dextrin.Document.parse(source)
      Dextrin.Document.to_value(doc)   # what Dextrin.decode/2 returns
      Dextrin.Document.render(doc)     # source, byte for byte

  **One grammar, parsed one way.** The tree comes from the same
  `priv/grammar/dxn.aether` as `decode/2`, through the lossless entry
  point Ichor generates beside the fast one, and the same actions
  build the value -- so a document parses exactly when `decode/2`
  would, and refuses with the same errors.

  **An untouched node renders its own bytes.** Preservation is a
  property of rendering, not something a printer has to get right.
  """

  alias Dextrin.Registry
  alias Dextrin.Schema.Validated

  @enforce_keys [:tree, :value]
  defstruct [:tree, :value]

  @typedoc "A parsed document: its syntax tree, and the value it holds."
  @type t :: %__MODULE__{tree: Ichor.Syntax.Node.t(), value: term()}

  @doc """
  Parses `source`, keeping everything in it. `opts` are
  `Dextrin.decode/2`'s -- `:registry`, `:trusted`, `:strict` -- and mean
  the same; so do the errors.
  """
  @spec parse(String.t(), keyword()) ::
          {:ok, t()} | {:error, Dextrin.Error.t() | [Dextrin.Error.t()]}
  def parse(source, opts \\ []) when is_binary(source) do
    case Dextrin.Text.Grammar.run_lossless(source, Registry.from_options(opts)) do
      {:ok, value, tree} -> {:ok, %__MODULE__{tree: tree, value: Validated.strip(value)}}
      {:error, errors} -> {:error, Dextrin.Error.from_parse(errors)}
    end
  end

  @doc "The value `doc` holds: what `Dextrin.decode/2` gives for its source."
  @spec to_value(t()) :: term()
  def to_value(%__MODULE__{value: value}), do: value

  @doc "`doc` as `.dxn` text: its source, byte for byte, when nothing was edited."
  @spec render(t()) :: String.t()
  def render(%__MODULE__{tree: tree}), do: Ichor.Syntax.text(tree)
end
