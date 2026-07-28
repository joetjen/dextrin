defmodule Dextrin do
  @moduledoc """
  Public API for DXN (Data eXchange Notation) — `.dxn` text and
  `.dxnb` binary, per `DXN.md` (the normative format specification).

  Four functions, one shared error type (`Dextrin.Error`):

    * `decode/2` / `encode/2` — `.dxn` text.
    * `decode_binary/2` / `encode_binary/2` — `.dxnb` binary.

  Every DXN type decodes to a plain Elixir value where one exists
  (integer, float, list, a plain map, ...) and to a small wrapper
  struct where Elixir has nothing that fits without losing information
  (`Dextrin.Symbol`, `Dextrin.Tuple`, `Dextrin.OrderedMap`, ...) — see
  each value module under `Dextrin.Value` for the full list. `symbol`
  and `keyword` in particular always wrap a `String.t()`, never an
  Elixir atom: decoding untrusted DXN data can never be used to exhaust
  the atom table.

  `struct` is schema-dependent: without a compiled `.dxns` schema for a
  given name it decodes to an opaque `Dextrin.Struct`; with one
  (`Dextrin.Schema.compile/3`, passed in as `registry:`), field
  enforcement happens automatically in both decode functions, and a
  violation is an ordinary `{:error, %Dextrin.Error{}}`, never a raised
  exception. `encode/2`/`encode_binary/2` validate the other
  direction the same way, automatically — see `encode/2`'s own doc.

  `.dxnb`'s private CBOR tag block (200–214, mirrored in
  `Dextrin.Binary.Tags`) is not IANA-registered — collision-free only
  within `dextrin`-produced documents. Don't assume interop with some
  *other* CBOR-based format that happens to also use a tag in that
  range; it isn't reserved for DXN outside this library's own output.
  """

  alias Dextrin.Registry

  @type opts :: [registry: Registry.t(), schema: String.t(), validate: boolean()]

  @doc "Decodes `.dxn` text into a value."
  @spec decode(String.t(), opts()) :: {:ok, term()} | {:error, Dextrin.Error.t()}
  def decode(text, opts \\ []) when is_binary(text) do
    registry = Keyword.get(opts, :registry, Registry.new())

    case Dextrin.Text.Grammar.run(text, registry) do
      {:ok, value} ->
        {:ok, Dextrin.Schema.Validated.strip(value)}

      {:error, %Ichor.Error{} = error} ->
        {:error, Dextrin.Error.from_ichor(error)}

      {:error, errors} when is_list(errors) ->
        {:error, Enum.map(errors, &Dextrin.Error.from_ichor/1)}
    end
  end

  @doc """
  Encodes a value back to `.dxn` text.

  A printer, not a formatter: single-line, minimal-whitespace output,
  with no line-wrapping or indentation policy — use
  `Dextrin.Text.Formatter.pretty/2` for multi-line, human-readable
  output (e.g. for `mix dextrin.format`).

  Automatically validates every `Dextrin.Struct` or registered
  application struct found anywhere in `value` against its own schema
  (`Dextrin.Schema.validate_encode_tree/2`), the same way decoding
  checks every named struct unconditionally — set `validate: false` to
  skip this (e.g. deliberately encoding data that doesn't conform, for
  a test fixture or a pass-through/relay that shouldn't second-guess
  data it isn't the origin of). A `schema:` opt additionally validates
  `value` itself against that specific schema
  (`Dextrin.Schema.validate_encode/3`) — the one case the automatic
  walk can't cover on its own, a nameless plain map or struct at the
  very top. Either check failing returns `{:error, _}` instead of
  encoding a value that doesn't conform.
  """
  @spec encode(term(), opts()) :: {:ok, String.t()} | {:error, Dextrin.Error.t()}
  def encode(value, opts \\ []) do
    with :ok <- maybe_validate_encode(value, opts) do
      Dextrin.Text.Printer.print(value, opts)
    end
  end

  @doc "Decodes a `.dxnb` binary into a value."
  @spec decode_binary(binary(), opts()) :: {:ok, term()} | {:error, Dextrin.Error.t()}
  def decode_binary(bytes, opts \\ []) when is_binary(bytes) do
    Dextrin.Binary.Decoder.decode(bytes, opts)
  end

  @doc """
  Encodes a value to `.dxnb` binary. Same `schema:`/`validate:` opts
  as `encode/2`.
  """
  @spec encode_binary(term(), opts()) :: {:ok, binary()} | {:error, Dextrin.Error.t()}
  def encode_binary(value, opts \\ []) do
    with :ok <- maybe_validate_encode(value, opts) do
      Dextrin.Binary.Encoder.encode(value, opts)
    end
  end

  # Two independent checks, both must pass: the automatic whole-tree
  # walk (every named struct anywhere in `value`, driven by whether a
  # schema is registered for its name) and, only if `schema:` was
  # given, a check of `value` itself against that one named schema —
  # the only way to validate a nameless top-level map or unregistered
  # struct, which the whole-tree walk has nothing to key off of.
  defp maybe_validate_encode(value, opts) do
    registry = Keyword.get(opts, :registry, Registry.new())

    with :ok <- maybe_validate_named_schema(value, opts, registry) do
      maybe_validate_tree(value, opts, registry)
    end
  end

  defp maybe_validate_named_schema(value, opts, registry) do
    case Keyword.fetch(opts, :schema) do
      {:ok, schema_name} ->
        case Dextrin.Schema.validate_encode(value, registry, schema_name) do
          :ok ->
            :ok

          {:error, reason} ->
            {:error,
             Dextrin.Error.action("value violates schema #{inspect(schema_name)}: #{reason}")}
        end

      :error ->
        :ok
    end
  end

  defp maybe_validate_tree(value, opts, registry) do
    if Keyword.get(opts, :validate, true) do
      case Dextrin.Schema.validate_encode_tree(value, registry) do
        :ok -> :ok
        {:error, reason} -> {:error, Dextrin.Error.action(reason)}
      end
    else
      :ok
    end
  end
end
