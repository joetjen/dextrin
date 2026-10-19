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
  @typedoc """
  A schema's materializer (DXN.md §4.8): called for every decoded struct
  of its schema, whatever the version, with the schema's name, the
  version the fields were read with and the fields keyed by string. It
  answers the application's latest-version value, which is checked
  against the latest schema, or `{:error, reason}`.
  """
  @type struct_materializer ::
          (String.t(), pos_integer(), %{String.t() => term()} -> {:ok, term()} | {:error, term()})
  @typedoc """
  A lazy source of schemas, asked on a miss for a name: every version it
  finds -- one compiled schema, or a list of them, all loaded -- or
  `:unknown`, or why the schemas it found cannot be used (two files with
  one version, a file that is not the version its name says, ...).
  """
  @type struct_resolver ::
          (String.t() ->
             {:ok, Compiled.t() | [Compiled.t()]} | :unknown | {:error, Dextrin.Error.t()})

  @type t :: %__MODULE__{
          tags: %{optional(String.t()) => tag_decoder()},
          tag_encoders: %{optional(module()) => {String.t(), tag_encoder()}},
          structs: %{optional(String.t()) => %{optional(pos_integer()) => Compiled.t()}},
          materializers: %{optional(String.t()) => struct_materializer()},
          resolver: struct_resolver() | nil,
          type_aliases: %{optional(String.t()) => TypeExpr.t()},
          struct_modules: %{optional(String.t()) => module()},
          trusted: boolean(),
          strict: boolean()
        }

  defstruct tags: %{},
            tag_encoders: %{},
            structs: %{},
            materializers: %{},
            resolver: nil,
            type_aliases: %{},
            struct_modules: %{},
            trusted: true,
            strict: false

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

  @doc """
  The registry a decode's `opts` describe: `:registry` (a new one when
  absent), with `:trusted` and `:strict` applied over it when given --
  what `Dextrin.decode/2`, `Dextrin.decode_binary/2` and
  `Dextrin.Document.parse/2` all read.
  """
  @spec from_options(keyword()) :: t()
  def from_options(opts) do
    registry = Keyword.get(opts, :registry, new())

    registry =
      case Keyword.fetch(opts, :trusted) do
        {:ok, trusted?} -> put_trusted(registry, trusted?)
        :error -> registry
      end

    case Keyword.fetch(opts, :strict) do
      {:ok, strict?} -> put_strict(registry, strict?)
      :error -> registry
    end
  end

  @doc """
  Marks this registry as decoding *strictly*: a schema-backed struct
  that carries a field its schema does not declare is refused
  (`schema/undeclared-field`, DXN.md §4.7) instead of keeping it as an
  extra field. A config loader decodes strictly, to catch a typo in a
  hand-written file; a message consumer does not, so a newer producer's
  fields pass through. `Dextrin.decode/2`/`decode_binary/2` take it as
  `strict: true`.
  """
  @spec put_strict(t(), boolean()) :: t()
  def put_strict(%__MODULE__{} = registry, strict?) when is_boolean(strict?) do
    %{registry | strict: strict?}
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

  @doc """
  Sets `compiled` as version `compiled.version` of the schema `name`,
  whether or not that version was there already.

  **Not how schemas are loaded.** `Dextrin.Schema.compile/2` uses
  `add_struct_schema/3`, which refuses a version already loaded, and a
  deliberate swap is `replace_struct_schema/3`. This is the unchecked
  setter underneath both, also used to cache what a resolver answers.
  """
  @spec put_struct_schema(t(), String.t(), Compiled.t()) :: t()
  def put_struct_schema(%__MODULE__{} = registry, name, %Compiled{version: version} = compiled)
      when is_binary(name) do
    versions = registry.structs |> Map.get(name, %{}) |> Map.put(version, compiled)
    %{registry | structs: Map.put(registry.structs, name, versions)}
  end

  @doc """
  Loads `compiled` as a new version of the schema `name`.

  Loading a version that is already loaded is a `schema/duplicate-version`
  error (DXN.md §4.8): two documents both claiming to be `User` v3 is a
  mistake, not an update. Replacing a version on purpose -- a hot swap in
  a running system -- is `replace_struct_schema/3`.
  """
  @spec add_struct_schema(t(), String.t(), Compiled.t()) ::
          {:ok, t()} | {:error, Dextrin.Error.t()}
  def add_struct_schema(%__MODULE__{} = registry, name, %Compiled{version: version} = compiled) do
    if loaded?(registry, name, version) do
      {:error,
       Dextrin.Error.action(
         "schema #{inspect(name)} version #{version} is already loaded",
         "schema/duplicate-version"
       )}
    else
      {:ok, put_struct_schema(registry, name, compiled)}
    end
  end

  @doc """
  Replaces version `compiled.version` of the schema `name` -- the hot swap
  of a running system.

  **Replace only replaces.** Naming a version that is not loaded is a
  `schema/not-loaded` error, so a typo in a hot swap never quietly adds a
  version instead.
  """
  @spec replace_struct_schema(t(), String.t(), Compiled.t()) ::
          {:ok, t()} | {:error, Dextrin.Error.t()}
  def replace_struct_schema(
        %__MODULE__{} = registry,
        name,
        %Compiled{version: version} = compiled
      ) do
    if loaded?(registry, name, version) do
      {:ok, put_struct_schema(registry, name, %{compiled | name: name})}
    else
      {:error,
       Dextrin.Error.action(
         "schema #{inspect(name)} version #{version} is not loaded, so there is nothing to replace",
         "schema/not-loaded"
       )}
    end
  end

  defp loaded?(registry, name, version),
    do: registry.structs |> Map.get(name, %{}) |> Map.has_key?(version)

  @spec put_struct_materializer(t(), String.t(), struct_materializer()) :: t()
  def put_struct_materializer(%__MODULE__{} = registry, name, materializer)
      when is_binary(name) and is_function(materializer, 3) do
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
  @spec fetch_struct_schema(t(), String.t()) ::
          {:ok, Compiled.t(), t()} | {:unknown, t()} | {:error, Dextrin.Error.t(), t()}
  def fetch_struct_schema(%__MODULE__{structs: structs} = registry, name) do
    case Map.fetch(structs, name) do
      {:ok, versions} when map_size(versions) > 0 ->
        {:ok, versions |> Map.keys() |> Enum.max() |> then(&Map.fetch!(versions, &1)), registry}

      _ ->
        resolve(registry, name)
    end
  end

  @doc """
  `struct` as it is written here: carrying the latest loaded version of
  its schema (DXN.md §4.8), whatever version it says itself. A struct
  whose name has no schema keeps its own version, or none.

  Every writer goes through this -- text, the formatter and binary -- so
  encoding never writes a version other than the latest, and never
  writes one no schema stands behind.
  """
  @spec as_written(t() | nil, Dextrin.Struct.t()) :: Dextrin.Struct.t()
  def as_written(%__MODULE__{} = registry, %Dextrin.Struct{name: name} = struct) do
    case fetch_struct_schema(registry, name) do
      {:ok, %Compiled{version: version}, _registry} -> %{struct | version: version}
      # No schema to stand behind a version: the struct keeps its own. A
      # resolver's refusal surfaces where the struct is read or checked.
      _no_schema -> struct
    end
  end

  def as_written(_no_registry, %Dextrin.Struct{} = struct), do: struct

  @doc """
  Looks up version `version` of the schema `name` -- the one a struct
  written `%Name(3){...}` is read with. Unlike `fetch_struct_schema/2`, a
  miss does not fall back to another version: a struct is only ever read
  with the schema it was written against.
  """
  @spec fetch_struct_schema(t(), String.t(), pos_integer()) ::
          {:ok, Compiled.t(), t()} | {:unknown, t()} | {:error, Dextrin.Error.t(), t()}
  def fetch_struct_schema(%__MODULE__{structs: structs} = registry, name, version) do
    case Map.fetch(structs, name) do
      {:ok, versions} when map_size(versions) > 0 ->
        exact(registry, versions, version)

      # A name not loaded at all is asked of the resolver first, which
      # loads every version it finds.
      _ ->
        case resolve(registry, name) do
          {:ok, _latest, registry} -> exact(registry, Map.fetch!(registry.structs, name), version)
          other -> other
        end
    end
  end

  defp exact(registry, versions, version) do
    case Map.fetch(versions, version) do
      {:ok, compiled} -> {:ok, compiled, registry}
      :error -> {:unknown, registry}
    end
  end

  # A miss consults the lazy resolver, if there is one, and caches what it
  # answers.
  defp resolve(%__MODULE__{resolver: nil} = registry, _name), do: {:unknown, registry}

  defp resolve(%__MODULE__{resolver: resolver} = registry, name) do
    case resolver.(name) do
      {:ok, %Compiled{} = compiled} ->
        {:ok, compiled, put_struct_schema(registry, name, compiled)}

      # Every version found is loaded, so an older struct reaches the
      # materializer (DXN.md §4.6, §4.8); the latest is what a miss asked for.
      {:ok, [_ | _] = all} ->
        registry = Enum.reduce(all, registry, &put_struct_schema(&2, name, &1))
        {:ok, Enum.max_by(all, & &1.version), registry}

      {:ok, []} ->
        {:unknown, registry}

      :unknown ->
        {:unknown, registry}

      {:error, %Dextrin.Error{} = error} ->
        {:error, error, registry}
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
