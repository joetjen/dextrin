defmodule Dextrin.Error do
  @moduledoc """
  One error struct for both the text and binary pipelines, so a caller
  never has to special-case which one produced it. Wraps `Ichor.Error`
  verbatim for the text side (including its caret-annotated
  `context_lines`, useful for CLI/log output); the binary side has no
  source text to annotate, so it only ever carries a message, a byte
  offset, and a stage.

  Also the channel for schema-violation errors: those come back with
  `stage: :action`, the same stage `Ichor.Error` already uses for
  `Ichor.Actions`-level failures (a `handle_rule/3`/`handle_token/3`
  callback returning `{:error, _}`) — so a schema violation and a
  syntax error are indistinguishable by shape alone, and a caller only
  ever needs to check `{:error, %Dextrin.Error{}}`.
  """

  @type stage :: Ichor.Error.stage() | :binary

  @typedoc """
  What kind of error this is, as `DXN.md` §5 names it — `"syntax"`,
  `"binary"`, `"encode/unsupported"`, `"schema/missing-field"`, ... —
  which every conforming implementation exposes, so the conformance
  suite can compare errors across languages without comparing messages.
  `nil` where no category has been assigned yet.
  """
  @type category :: String.t() | nil

  @type t :: %__MODULE__{
          message: String.t(),
          stage: stage(),
          category: category(),
          byte_offset: non_neg_integer() | nil,
          ichor_error: Ichor.Error.t() | nil
        }

  defstruct [:message, :stage, :category, :byte_offset, :ichor_error]

  @doc """
  An Ichor error, as a `Dextrin.Error`. One that carries a
  `Dextrin.Error` in its `data` -- an action's own refusal, with its own
  category -- is that error, with the Ichor error kept for its position;
  any other is a `syntax` error.
  """
  @spec from_ichor(Ichor.Error.t()) :: t()
  def from_ichor(%Ichor.Error{data: %__MODULE__{} = carried} = err),
    do: %{carried | ichor_error: err}

  def from_ichor(%Ichor.Error{message: message, stage: stage} = err) do
    %__MODULE__{message: message, stage: stage, category: "syntax", ichor_error: err}
  end

  @spec binary(String.t(), non_neg_integer() | nil) :: t()
  def binary(message, byte_offset \\ nil) when is_binary(message) do
    %__MODULE__{message: message, stage: :binary, category: "binary", byte_offset: byte_offset}
  end

  @doc """
  An error raised outside the parsers — a schema violation, a value
  with no DXN meaning — with its `DXN.md` §5 category, when it has one.
  """
  @spec action(String.t(), category()) :: t()
  def action(message, category \\ nil) when is_binary(message) do
    %__MODULE__{message: message, stage: :action, category: category}
  end

  @spec format(t()) :: String.t()
  def format(%__MODULE__{ichor_error: %Ichor.Error{} = ichor_error}),
    do: Ichor.Error.format(ichor_error)

  def format(%__MODULE__{message: message, byte_offset: nil}), do: message

  def format(%__MODULE__{message: message, byte_offset: offset}) do
    "#{message} (at byte offset #{offset})"
  end
end
