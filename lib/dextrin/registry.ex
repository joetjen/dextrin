defmodule Dextrin.Registry do
  @moduledoc """
  Extension point for both `struct` and `custom-tag` decoding/encoding.
  No entry for a given name → decode falls back to an opaque
  `Dextrin.Struct`/`Dextrin.CustomTag` — never a hard failure, since
  neither type requires a registration to be representable at all.

  Struct entries only ever come from a compiled `.dxns` schema
  (`Dextrin.Schema.compile/3`) plus an optional materializer layered on
  top (`put_struct_materializer/3`) — there is no `put_struct/3` that
  hand-writes a struct's shape directly, because `struct` is
  schema-dependent by design: the schema is what supplies field
  names/order/types, a materializer only decides what nicer decoded
  shape to produce from an already-schema-validated field map.

  Every `put_*`/`fetch_*` pair here is a plain, immutable map update —
  `Registry.t()` is ordinary data threaded explicitly through
  `Dextrin.decode/2`, `Dextrin.Schema.compile/3`, etc.; nothing about
  it is a process, an ETS table, or otherwise global/mutable state.
  """

  alias Dextrin.Schema.{Compiled, TypeExpr}

  @type tag_decoder :: (Dextrin.Value.t() -> {:ok, term()} | {:error, term()})
  @type tag_encoder :: (struct() -> {:ok, Dextrin.Value.t()} | {:error, term()})
  @type struct_materializer :: (%{atom() => term()} -> {:ok, term()} | {:error, term()})
  @type struct_resolver :: (String.t() -> {:ok, Compiled.t()} | :unknown)

  @type t :: %__MODULE__{
          tags: %{optional(String.t()) => tag_decoder()},
          tag_encoders: %{optional(module()) => {String.t(), tag_encoder()}},
          structs: %{optional(String.t()) => Compiled.t()},
          materializers: %{optional(String.t()) => struct_materializer()},
          resolver: struct_resolver() | nil,
          type_aliases: %{optional(String.t()) => TypeExpr.t()},
          struct_modules: %{optional(String.t()) => module()},
          trusted: boolean()
        }

  defstruct tags: %{},
            tag_encoders: %{},
            structs: %{},
            materializers: %{},
            resolver: nil,
            type_aliases: %{},
            struct_modules: %{},
            trusted: true

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Marks (or unmarks) this registry as decoding a *trusted* source —
  the default — vs. an *untrusted* one. Currently the one thing this
  affects is `keyword`: trusted (the default) decodes it as a real
  Elixir atom (`DXN.md` §1.3's own type table: `keyword`'s Elixir type
  is "Elixir atom"); untrusted decodes it as `Dextrin.Keyword.t()`
  instead, so a `String.to_atom/1` call is never reachable from
  attacker-controlled text (which could otherwise exhaust the atom
  table). Pass `trusted: false` to `Dextrin.decode/2`/`decode_binary/2`
  — or `put_trusted(registry, false)` on a reused registry — for any
  source you *don't* fully control; the default assumes you do.

  `symbol` is deliberately unaffected either way — it stays
  `Dextrin.Symbol.t()` regardless of `trusted`, mirroring `encode/2`'s
  own choice to accept a bare atom as a stand-in for `keyword`, never
  for `symbol`.
  """
  @spec put_trusted(t(), boolean()) :: t()
  def put_trusted(%__MODULE__{} = registry, trusted?) when is_boolean(trusted?) do
    %{registry | trusted: trusted?}
  end

  @spec put_tag(t(), String.t(), tag_decoder()) :: t()
  def put_tag(%__MODULE__{} = registry, name, decoder)
      when is_binary(name) and is_function(decoder, 1) do
    %{registry | tags: Map.put(registry.tags, name, decoder)}
  end

  @spec fetch_tag(t(), String.t()) :: {:ok, tag_decoder()} | :error
  def fetch_tag(%__MODULE__{tags: tags}, name), do: Map.fetch(tags, name)

  @doc """
  The reverse of `put_tag/3`: registers how to turn an application
  struct (keyed by its module) back into `@name value` on encode.
  `put_tag/3` alone lets you *decode* `@my-app/money 100` into
  `%MyApp.Money{}`, but never re-`encode` it, since dispatch on the way
  out has to happen by Elixir module, not by wire-format tag name — the
  two directions need separate lookup tables, not one shared one.
  """
  @spec put_tag_encoder(t(), module(), String.t(), tag_encoder()) :: t()
  def put_tag_encoder(%__MODULE__{} = registry, module, name, encoder)
      when is_atom(module) and is_binary(name) and is_function(encoder, 1) do
    %{registry | tag_encoders: Map.put(registry.tag_encoders, module, {name, encoder})}
  end

  @spec fetch_tag_encoder(t(), module()) :: {:ok, {String.t(), tag_encoder()}} | :error
  def fetch_tag_encoder(%__MODULE__{tag_encoders: tag_encoders}, module),
    do: Map.fetch(tag_encoders, module)

  @spec put_struct_schema(t(), String.t(), Compiled.t()) :: t()
  def put_struct_schema(%__MODULE__{} = registry, name, %Compiled{} = compiled)
      when is_binary(name) do
    %{registry | structs: Map.put(registry.structs, name, compiled)}
  end

  @spec put_struct_materializer(t(), String.t(), struct_materializer()) :: t()
  def put_struct_materializer(%__MODULE__{} = registry, name, materializer)
      when is_binary(name) and is_function(materializer, 1) do
    %{registry | materializers: Map.put(registry.materializers, name, materializer)}
  end

  @spec put_resolver(t(), struct_resolver()) :: t()
  def put_resolver(%__MODULE__{} = registry, resolver) when is_function(resolver, 1) do
    %{registry | resolver: resolver}
  end

  @doc """
  Looks up a compiled schema by struct name, consulting the lazy
  resolver (if any) on a miss and caching the result. Whether schemas
  are all compiled up front (`Dextrin.Schema.compile/3` once, at
  startup) or resolved on demand (a resolver reading a file, calling a
  schema service, whatever the caller wants) is entirely the caller's
  choice — this function is what makes both paths look identical to
  the rest of `Dextrin`, which never needs to know which one is in play.
  """
  @spec fetch_struct_schema(t(), String.t()) :: {:ok, Compiled.t(), t()} | {:unknown, t()}
  def fetch_struct_schema(%__MODULE__{structs: structs} = registry, name) do
    case Map.fetch(structs, name) do
      {:ok, compiled} ->
        {:ok, compiled, registry}

      :error ->
        case registry.resolver do
          nil ->
            {:unknown, registry}

          resolver ->
            case resolver.(name) do
              {:ok, compiled} -> {:ok, compiled, put_struct_schema(registry, name, compiled)}
              :unknown -> {:unknown, registry}
            end
        end
    end
  end

  @spec fetch_materializer(t(), String.t()) :: {:ok, struct_materializer()} | :error
  def fetch_materializer(%__MODULE__{materializers: materializers}, name),
    do: Map.fetch(materializers, name)

  @doc """
  Registers a named type_expr — a reusable name for a combination of
  the fixed type_expr vocabulary (`Dextrin.Schema.TypeExpr`), defined
  entirely in `.dxns` data, never Elixir code. `Dextrin.Schema.compile/3`
  populates this automatically from a document's non-`%schema{}`
  entries; `put_type_alias/3` itself is only needed to seed a base
  registry by hand (e.g. sharing one vocabulary across several
  `compile/3` calls without redeclaring it each time).
  """
  @spec put_type_alias(t(), String.t(), TypeExpr.t()) :: t()
  def put_type_alias(%__MODULE__{} = registry, name, type_expr) when is_binary(name) do
    %{registry | type_aliases: Map.put(registry.type_aliases, name, type_expr)}
  end

  @spec fetch_type_alias(t(), String.t()) :: {:ok, TypeExpr.t()} | :error
  def fetch_type_alias(%__MODULE__{type_aliases: type_aliases}, name),
    do: Map.fetch(type_aliases, name)

  @doc """
  Declares which Elixir module a schema's data is expected to be —
  used only for `{:reference, name}` checks during *encode-time*
  validation (`Dextrin.Schema.validate_encode/3`). Decode-time
  reference checks don't need this: they carry an
  internal provenance marker regardless of materializer shape
  (`Dextrin.Schema.Validated`). Encode-time has no wire data to carry
  that marker before anything's even been encoded — `__struct__` is
  the one signal actually available pre-encode, and this is what a
  reference check compares it against. Independent of
  `put_struct_materializer/3`: you can declare a module here even if
  you use the default plain-map materialization for something else.
  """
  @spec put_struct_module(t(), String.t(), module()) :: t()
  def put_struct_module(%__MODULE__{} = registry, name, module)
      when is_binary(name) and is_atom(module) do
    %{registry | struct_modules: Map.put(registry.struct_modules, name, module)}
  end

  @spec fetch_struct_module(t(), String.t()) :: {:ok, module()} | :error
  def fetch_struct_module(%__MODULE__{struct_modules: struct_modules}, name),
    do: Map.fetch(struct_modules, name)

  @doc """
  The reverse of `fetch_struct_module/2`: given an application
  struct's own module, finds the schema name it was registered under
  (if any) — what lets automatic encode-time validation
  (`Dextrin.Schema.validate_encode_tree/2`) recognize a plain Elixir
  struct as "this is a Foo" without being told so explicitly, the same
  way a `Dextrin.Struct`'s own `name` already identifies it.
  """
  @spec fetch_schema_name_for_module(t(), module()) :: {:ok, String.t()} | :error
  def fetch_schema_name_for_module(%__MODULE__{struct_modules: struct_modules}, module) do
    Enum.find_value(struct_modules, :error, fn {name, mod} ->
      if mod == module, do: {:ok, name}
    end)
  end
end
