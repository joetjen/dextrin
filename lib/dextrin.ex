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
  and `keyword` in particular wrap a `String.t()`, not an Elixir atom,
  unless the input is trusted (`trusted: true`, then a keyword is an
  atom): decoding DXN data can never exhaust the atom table by default.

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

  This is the reference implementation. Two sibling ports read/write
  the exact same `.dxn`/`.dxnb`/`.dxns` documents:
  [`node-dextrin`](https://www.npmjs.com/package/@joetjen/dextrin) (Node.js, on
  npm) and [`php-dextrin`](https://packagist.org/packages/joetjen/dextrin)
  (PHP, on Packagist) — see the README's own "Other language
  implementations" section for the full comparison.
  """

  alias Dextrin.Registry

  @type opts :: [
          registry: Registry.t(),
          schema: String.t(),
          validate: boolean(),
          pretty: boolean(),
          indent: non_neg_integer(),
          width: pos_integer(),
          trusted: boolean()
        ]

  @doc """
  Decodes `.dxn` text into a value. `{:error, _}` carries a single
  `Dextrin.Error` normally, but a list when the underlying grammar
  engine reports more than one (`Ichor.Actions.evaluate/5`'s own
  `Ichor.Error.t() | [Ichor.Error.t()]`).

  **Safe by default**: `keyword` decodes as `Dextrin.Keyword.t()`, never
  an atom, so no input can exhaust the atom table. Pass `trusted: true`
  for a source you control (your own config, your own application's
  data) and a keyword decodes as a real Elixir atom -- opt-in, like
  Jason's `keys: :atoms`; never for network input. See
  `Dextrin.Registry.put_trusted/2` for exactly what it affects.
  """
  @spec decode(String.t(), opts()) ::
          {:ok, term()} | {:error, Dextrin.Error.t() | [Dextrin.Error.t()]}
  def decode(text, opts \\ []) when is_binary(text) do
    case Dextrin.Text.Grammar.run(text, Registry.from_options(opts)) do
      {:ok, value} -> {:ok, Dextrin.Schema.Validated.strip(value)}
      {:error, errors} -> {:error, Dextrin.Error.from_parse(errors)}
    end
  end

  @doc """
  Encodes a value back to `.dxn` text.

  Single-line, minimal-whitespace by default — the smallest text this
  value can round-trip through, with no line-wrapping or indentation
  at all (`Dextrin.Text.Printer`). Pass `pretty: true` for multi-line,
  indented output instead (`Dextrin.Text.Formatter`): the top-level
  collection one entry per line, a nested one on one line when it fits.
  `indent:` then sets the number of spaces per nesting level (default 2),
  and `width:` the columns a nested collection's one line must fit in
  (default 80). Both produce the exact same value on the way back through
  `decode/2`; `pretty`/`indent`/`width` are a rendering choice, never a
  semantic one.

      {:ok, value} = Dextrin.decode("%{x: 1, y: 2}")

      Dextrin.encode(value)
      #=> {:ok, "%{x:1,y:2}"}

      Dextrin.encode(value, pretty: true)
      #=> {:ok, "%{\\n  x: 1\\n  y: 2\\n}"}

      Dextrin.encode(value, pretty: true, indent: 4)
      #=> {:ok, "%{\\n    x: 1\\n    y: 2\\n}"}

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
  encoding a value that doesn't conform — regardless of `pretty:`,
  since validation and rendering are independent concerns.
  """
  @spec encode(term(), opts()) :: {:ok, String.t()} | {:error, Dextrin.Error.t()}
  def encode(value, opts \\ []) do
    with :ok <- maybe_validate_encode(value, opts) do
      if Keyword.get(opts, :pretty, false) do
        Dextrin.Text.Formatter.pretty(value, opts)
      else
        Dextrin.Text.Printer.print(value, opts)
      end
    end
  end

  @doc """
  Decodes a `.dxnb` binary into a value. Same `trusted:` opt as
  `decode/2` — see there for what it does and doesn't affect.
  """
  @spec decode_binary(binary(), opts()) :: {:ok, term()} | {:error, Dextrin.Error.t()}
  def decode_binary(bytes, opts \\ []) when is_binary(bytes) do
    opts = Keyword.put(opts, :registry, Registry.from_options(opts))
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

          {:error, %Dextrin.Error{} = error} ->
            {:error,
             %{error | message: "value violates schema #{inspect(schema_name)}: #{error.message}"}}
        end

      :error ->
        :ok
    end
  end

  defp maybe_validate_tree(value, opts, registry) do
    if Keyword.get(opts, :validate, true) do
      case Dextrin.Schema.validate_encode_tree(value, registry) do
        :ok -> :ok
        {:error, %Dextrin.Error{}} = error -> error
      end
    else
      :ok
    end
  end

  # An explicit `trusted:` opt always wins (per-call override); absent
  # it, a `registry:` the caller already built via
  # `Dextrin.Registry.put_trusted/2` keeps whatever it already had —
  # so `trusted` can be set once on a reused registry, or per call,
  # without one silently clobbering the other.
end
