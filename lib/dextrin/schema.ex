defmodule Dextrin.Schema do
  @moduledoc """
  Public entry point for `.dxns` schema compilation and validation.

    * `compile/3` — the one-time walk from a decoded `.dxns` document
      to a populated `Dextrin.Registry`.
    * `validate/3` — checks an already-decoded value against a named
      schema (decode-side, but not decode itself — see its own doc).
    * `validate_encode/3` / `validate_encode_tree/2` — the encode-side
      mirror, one named schema vs. an automatic whole-tree walk.

  Enforcement during actual decoding is fail-fast and automatic: every
  registered struct name is checked unconditionally as part of
  `Dextrin.decode/2`/`decode_binary/2`, and a violation surfaces as an
  ordinary `{:error, %Dextrin.Error{}}` — the functions here are for
  the cases that aren't "check while decoding" (see `validate/3`'s doc).
  """

  alias Dextrin.Registry
  alias Dextrin.Schema.{Compiled, Validator}

  @doc """
  Compiles a decoded `.dxns` document (see `Dextrin.decode/2`) into
  `base_registry` — a struct schema for each `%schema{}` entry, and a
  reusable named type for every other entry, e.g.
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
  — for the cases that aren't "check while decoding": a value built
  directly in Elixir before encoding, an opaque `Dextrin.Struct`
  decoded before a schema became available, or checking against a
  different schema than the one originally used.
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

        with {:ok, _materialized} <-
               Validator.materialize(compiled, fields, materializer, registry),
             do: :ok

      {:unknown, _registry} ->
        {:error, "no compiled schema registered for #{inspect(schema_name)}"}
    end
  end

  def validate(value, %Registry{}, schema_name) do
    {:error, "expected a Dextrin.Struct named #{inspect(schema_name)}, got #{inspect(value)}"}
  end

  @doc """
  Encode-time schema validation: checks `value` —
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
      {:ok, compiled, _registry} ->
        Validator.validate_for_encode(compiled, value, registry)

      {:unknown, _registry} ->
        {:error, "no compiled schema registered for #{inspect(schema_name)}"}
    end
  end

  @doc """
  Automatic, name-driven encode-time validation: walks `value` and
  checks *every* `Dextrin.Struct` or registered
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

  @doc """
  Compiles and registers one `Dextrin.Schema.Provider` implementation
  into `registry` — the explicit half of letting a struct's own
  library define its DXN schema without depending on `dextrin`; see
  `Dextrin.Schema.Provider`'s own moduledoc for the full pattern this
  is meant to support, including why it's a small companion module
  rather than the struct's own, and the optional-dependency mechanics
  that keep the struct's library dependency-free.

  Concretely, in order:

    1. Decodes and compiles `module.dxn_schema/0`'s source
       (`Dextrin.decode/2` + `compile/3`, same as any other `.dxns`
       document) into `registry`. Every named type and every `%schema{}`
       entry that document defines gets folded in, not only the one
       `module.dxn_schema_name/0` points at — a provider module for one
       struct can usefully define shared named types (or even other
       related structs) that end up available in the resulting
       registry regardless.
    2. Looks up `module.dxn_schema_name/0` in the now-compiled registry.
       If it isn't there — the provider declared a name its own schema
       document doesn't actually define, almost certainly a typo in
       one place or the other — this returns a specific `{:error, _}`
       naming both the module and the mismatched name, rather than
       silently registering nothing or raising a generic `KeyError`
       deeper in `Dextrin.Registry`.
    3. Associates `module.dxn_struct/0` with that schema name via
       `Dextrin.Registry.put_struct_module/3` — the same call you'd
       make by hand for a struct schema you wrote yourself; this is
       what lets `Dextrin.encode/2`/`encode_binary/2` serialize
       `dxn_struct/0`'s struct directly and lets `{:reference, name}`
       checks recognize it.
    4. If `module` exports `dxn_materialize/1` (the one optional
       callback), registers it via
       `Dextrin.Registry.put_struct_materializer/3`. If not, decoding
       this schema falls back to the default plain field map, same as
       any other materializer-less schema.

  Composes exactly like `compile/3`'s own `base_registry` — calling
  `register_provider/2` more than once, for different provider modules,
  threads the same growing registry through each call, same as chaining
  `compile/3` calls or seeding from `Dextrin.Schema.Std.registry/1`.
  """
  @spec register_provider(Registry.t(), module()) :: {:ok, Registry.t()} | {:error, term()}
  def register_provider(%Registry{} = registry, module) when is_atom(module) do
    with {:ok, doc} <- Dextrin.decode(module.dxn_schema()),
         {:ok, registry} <- compile(doc, registry) do
      name = module.dxn_schema_name()

      # Re-fetching by name (rather than trusting compile/3 blindly
      # succeeded for *this* entry) is what catches a provider whose
      # dxn_schema_name/0 doesn't match its own dxn_schema/0 -- a
      # mismatch between the two callbacks that compile/3 alone has no
      # way to notice, since it only ever sees the document as a whole.
      case Registry.fetch_struct_schema(registry, name) do
        {:ok, _compiled, registry} ->
          registry = Registry.put_struct_module(registry, name, module.dxn_struct())

          registry =
            if function_exported?(module, :dxn_materialize, 1) do
              Registry.put_struct_materializer(registry, name, &module.dxn_materialize/1)
            else
              registry
            end

          {:ok, registry}

        {:unknown, _registry} ->
          {:error,
           "#{inspect(module)}.dxn_schema_name/0 returned #{inspect(name)}, " <>
             "but its own dxn_schema/0 document has no such schema entry"}
      end
    end
  end
end
