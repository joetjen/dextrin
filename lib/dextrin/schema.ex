defmodule Dextrin.Schema do
  @moduledoc """
  Public entry point for `.dxns` schema compilation and validation
  (DESIGN.md §4.4.5).
  """

  alias Dextrin.Registry
  alias Dextrin.Schema.{Compiled, Validator}

  @doc """
  Compiles a decoded `.dxns` document (see `Dextrin.decode/2`) into
  `base_registry` — a struct schema for each `%schema{}` entry, and a
  reusable named type (DESIGN.md §4.4.1) for every other entry, e.g.
  `PositiveInt: {:refine :integer {min: 1}}`. `predicates` resolves any
  `refine-fn:` names used in the document.
  """
  @spec compile(term(), Registry.t(), %{optional(String.t()) => Compiled.refine_fn()}) ::
          {:ok, Registry.t()} | {:error, term()}
  def compile(schema_doc, base_registry \\ Registry.new(), predicates \\ %{}) do
    Dextrin.Schema.Compiler.compile(schema_doc, base_registry, predicates)
  end

  @doc """
  Validates an already-decoded value against a named, compiled schema
  — for the cases that aren't "check while decoding" (DESIGN.md
  §4.4.5): a value built directly in Elixir before encoding, an
  opaque `Dextrin.Struct` decoded before a schema became available,
  or checking against a different schema than the one originally used.
  """
  @spec validate(term(), Registry.t(), String.t()) :: :ok | {:error, term()}
  def validate(%Dextrin.Struct{name: name, fields: fields}, %Registry{} = registry, schema_name)
      when name == schema_name do
    case Registry.fetch_struct_schema(registry, schema_name) do
      {:ok, compiled, _registry} ->
        materializer =
          case Registry.fetch_materializer(registry, schema_name) do
            {:ok, fun} -> fun
            :error -> nil
          end

        with {:ok, _materialized} <- Validator.materialize(compiled, fields, materializer, registry), do: :ok

      {:unknown, _registry} ->
        {:error, "no compiled schema registered for #{inspect(schema_name)}"}
    end
  end

  def validate(value, %Registry{}, schema_name) do
    {:error, "expected a Dextrin.Struct named #{inspect(schema_name)}, got #{inspect(value)}"}
  end

  @doc """
  Encode-time schema validation (DESIGN.md §10/§12): checks `value` —
  ordinary Elixir data you're about to encode (a plain map, atom or
  string keys, or a real struct) — against a named, compiled schema
  *before* encoding produces any output. The mirror image of
  `validate/3`, for data on its way out rather than in: a decode-time
  check protects against untrusted incoming data; this protects
  against your own program accidentally handing the encoder the
  wrong shape. `Dextrin.encode/2`/`encode_binary/2`'s `schema:` opt
  calls this automatically.
  """
  @spec validate_encode(term(), Registry.t(), String.t()) :: :ok | {:error, term()}
  def validate_encode(value, %Registry{} = registry, schema_name) do
    case Registry.fetch_struct_schema(registry, schema_name) do
      {:ok, compiled, _registry} -> Validator.validate_for_encode(compiled, value, registry)
      {:unknown, _registry} -> {:error, "no compiled schema registered for #{inspect(schema_name)}"}
    end
  end

  @doc """
  Automatic, name-driven encode-time validation (DESIGN.md §10/§12):
  walks `value` and checks *every* `Dextrin.Struct` or registered
  application struct anywhere in it against its own schema, wherever
  it turns out to be — not just what `validate_encode/3`'s one named
  schema's own field types happen to reach. Symmetric to how decode
  checks every named struct unconditionally. `Dextrin.encode/2`/
  `encode_binary/2` call this automatically by default (opt out with
  `validate: false`).
  """
  @spec validate_encode_tree(term(), Registry.t()) :: :ok | {:error, term()}
  def validate_encode_tree(value, %Registry{} = registry) do
    Validator.validate_tree_for_encode(value, registry)
  end
end
