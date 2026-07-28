defmodule Dextrin.Error do
  @moduledoc """
  One error struct for both pipelines, so a caller never has to
  special-case which one produced it. Wraps `Ichor.Error` verbatim for
  the text side (including its caret-annotated `context_lines`); the
  binary side has no source text to annotate, so it only ever carries
  a message, a byte offset, and a stage.

  Also the channel for schema-violation errors (DESIGN.md §4.4.5) —
  those come back with `stage: :action`, the same stage `Ichor.Error`
  already uses for `Ichor.Actions`-level failures, so a schema
  violation and a syntax error are indistinguishable by shape alone
  and a caller only ever needs to check `{:error, %Dextrin.Error{}}`.
  """

  @type stage :: Ichor.Error.stage() | :binary

  @type t :: %__MODULE__{
          message: String.t(),
          stage: stage(),
          byte_offset: non_neg_integer() | nil,
          ichor_error: Ichor.Error.t() | nil
        }

  defstruct [:message, :stage, :byte_offset, :ichor_error]

  @spec from_ichor(Ichor.Error.t()) :: t()
  def from_ichor(%Ichor.Error{message: message, stage: stage} = err) do
    %__MODULE__{message: message, stage: stage, ichor_error: err}
  end

  @spec binary(String.t(), non_neg_integer() | nil) :: t()
  def binary(message, byte_offset \\ nil) when is_binary(message) do
    %__MODULE__{message: message, stage: :binary, byte_offset: byte_offset}
  end

  @spec action(String.t()) :: t()
  def action(message) when is_binary(message) do
    %__MODULE__{message: message, stage: :action}
  end

  @spec format(t()) :: String.t()
  def format(%__MODULE__{ichor_error: %Ichor.Error{} = ichor_error}), do: Ichor.Error.format(ichor_error)

  def format(%__MODULE__{message: message, byte_offset: nil}), do: message

  def format(%__MODULE__{message: message, byte_offset: offset}) do
    "#{message} (at byte offset #{offset})"
  end
end
