defmodule Dextrin.Schema.Provider do
  @moduledoc """
  Lets a struct's *own* library ship a DXN schema for it — field
  names, types, required/optional, closed/forbidden, refinements, a
  materializer — without that library ever taking a hard dependency on
  `dextrin`. This is the `struct` (schema-backed) counterpart to what
  `Dextrin.Registry.put_tag_encoder/4` already does for simple
  scalar-wrapping `custom-tag` values: an extension point owned by the
  *consuming* application, not forced onto every struct-defining
  library it might want to use with `dextrin`.

  ## The problem this solves

  A schema-backed struct needs three things wired into a
  `Dextrin.Registry` before it round-trips: a compiled `.dxns` schema
  (`Dextrin.Schema.compile/3`), an association between the schema name
  and the real Elixir struct module
  (`Dextrin.Registry.put_struct_module/3`, needed for both
  `{:reference, name}` checks and — since a recent fix — for
  `Dextrin.encode/2`/`encode_binary/2` to serialize the struct at all),
  and, optionally, a materializer turning decoded fields into that
  struct (`Dextrin.Registry.put_struct_materializer/3`). Nothing about
  any of this is specific to the struct's own library — it's
  Dextrin-side wiring — but if the struct's library wants to be the
  one to define its own canonical schema (rather than leaving every
  downstream application to redefine it, possibly inconsistently), it
  needs *some* way to hand that definition over.

  The key fact that makes this possible without a hard dependency: a
  `.dxns` schema is plain text, not Elixir code. Defining one needs no
  reference to any `dextrin` module at all. Only *compiling* that text
  and calling the three `Dextrin.Registry` functions above genuinely
  needs `dextrin` — and that step doesn't have to happen inside the
  struct's own library. It can happen in whichever application
  actually depends on both, via `Dextrin.Schema.register_provider/2`.

  ## Why a companion module, not the struct's own module

  The recommended shape puts `@behaviour Dextrin.Schema.Provider` on a
  small, separate module (`SomeLib.Money.DXN`), never on the struct's
  own module (`SomeLib.Money`). This is deliberate: the struct's
  primary module should compile identically regardless of whether
  `dextrin` happens to be present, so its `defstruct` is never
  conditionally compiled. A companion module can be skipped entirely
  (see below) without touching the struct definition at all.

  ## Why a behaviour, not a bare naming convention

  An earlier design considered checking for conventionally-named
  functions (`function_exported?(module, :dxn_schema, 0)`, etc.)
  instead of a formal behaviour, specifically to avoid needing
  `dextrin` as a dependency anywhere. That still doesn't need a
  dependency, but it buys nothing over a behaviour for the one thing
  that actually matters: catching mistakes early. `@behaviour
  Dextrin.Schema.Provider` makes the *compiler* fail, at the companion
  module's own build time, if a required callback is missing or
  misspelled — regardless of whether `register_provider/2` is ever
  called, and independent of whatever discovery mechanism (if any) a
  caller uses. A naming convention has no equivalent: a typo'd function
  name simply isn't found, silently, with nothing to tell you it was
  ever supposed to exist.

  ## Why explicit registration, not automatic discovery

  `register_provider/2` is called explicitly, by name, once per
  provider module — it does not scan loaded modules looking for
  behaviour implementations. This is a deliberate choice, not an
  oversight: automatic discovery would need to run after all relevant
  applications have started (to have a complete, deterministic module
  list) and would make "why does encoding this struct suddenly work"
  a fact about *load order* rather than something visible at the call
  site. One explicit line per struct is a small, fixed cost; the
  alternative is a standing, harder-to-reason-about mechanism for a
  problem — typing one extra line — that isn't actually expensive.

  ## The optional-dependency mechanics, in full

  `SomeLib` (the struct's library) adds `dextrin` as an *optional*
  dependency in its own `mix.exs`:

      # some_lib's own mix.exs
      defp deps do
        [{:dextrin, "~> 0.1", optional: true}]
      end

  Mix's optional-dependency resolution means this never forces
  `dextrin` on anyone who depends on `some_lib` alone — `dextrin` only
  ends up fetched and compiled if the final application *also* lists
  it (directly, or via some other non-optional path). `SomeLib` then
  guards the companion module with `Code.ensure_loaded?/1`, which
  returns `false` (never raises) when the module can't be found, so
  the whole `defmodule` is simply skipped at compile time if `dextrin`
  isn't part of the build:

      # lib/some_lib/money/dxn.ex
      if Code.ensure_loaded?(Dextrin.Schema.Provider) do
        defmodule SomeLib.Money.DXN do
          @behaviour Dextrin.Schema.Provider

          @impl true
          def dxn_schema, do: \"\"\"
          %{
            Money: %schema{
              fields: @ordered %{ amount: :decimal, currency: {:enum :usd :eur :gbp} }
            }
          }
          \"\"\"

          @impl true
          def dxn_schema_name, do: "Money"

          @impl true
          def dxn_struct, do: SomeLib.Money

          @impl true
          def dxn_materialize(%{amount: a, currency: c}), do: {:ok, %SomeLib.Money{amount: a, currency: c}}
        end
      end

  An application depending on both `some_lib` and `dextrin` compiles
  `SomeLib.Money.DXN` normally (`Dextrin.Schema.Provider` is available
  in that build, so `Code.ensure_loaded?/1` succeeds) and registers it
  once, wherever it's already building its registry:

      {:ok, registry} = Dextrin.Schema.register_provider(Dextrin.Registry.new(), SomeLib.Money.DXN)

      Dextrin.decode(~s(%Money{amount: 19.99M, currency: :usd}), registry: registry)
      #=> {:ok, %SomeLib.Money{amount: Decimal.new("19.99"), currency: :usd}}

      Dextrin.encode(%SomeLib.Money{amount: Decimal.new("19.99"), currency: :usd}, registry: registry)
      #=> {:ok, "%Money{amount: 19.99M, currency: :usd}"}

  An application depending on `some_lib` alone never compiles
  `SomeLib.Money.DXN` at all, and never touches `dextrin`.

  This is a well-established Elixir idiom, not something novel or
  fragile — it's the same shape many libraries already use for
  optional integrations with alternative JSON encoders, telemetry
  backends, and similar.

  ## Multiple named types, not just the one schema

  `dxn_schema/0` doesn't have to define *only* this struct's schema.
  `register_provider/2` compiles the *entire* document `dxn_schema/0`
  returns (via `Dextrin.Schema.compile/3`, same as any other `.dxns`
  document) and folds all of it into the registry — reusable named
  types, other related struct schemas, whatever the document contains
  — not only the one entry `dxn_schema_name/0` points at. A library
  exposing several related structs can ship them all from one provider
  module's `dxn_schema/0`, calling `register_provider/2` once per
  struct that needs its own `dxn_struct/0`/`dxn_materialize/1`
  association, while every schema still shares the same compiled
  named-type vocabulary.

  ## Schema source: inline string, or a file read at compile time

  `dxn_schema/0` only has to return a `String.t()` — how that string
  comes into being is invisible to this behaviour. A heredoc, as
  above, is the simplest option. For a larger schema, reading it from
  its own `.dxns` file *at compile time* works just as well, and means
  the file itself never has to ship inside a release:

      @external_resource Path.join(__DIR__, "money.dxns")
      @dxn_schema_source File.read!(Path.join(__DIR__, "money.dxns"))

      @impl true
      def dxn_schema, do: @dxn_schema_source

  `@external_resource` also tells Mix to recompile this module if the
  file's contents change, so the compiled string never goes stale
  relative to its source. `Dextrin.Schema.Std` (dextrin's own standard
  named-type library) already uses exactly this pattern for
  `priv/schema/std.dxns` — read its source for a complete, working
  example.

  ## The materializer is optional

  `dxn_materialize/1` is the one optional callback. Without it, a
  value decoded against this schema falls back to the default plain
  string-keyed field map — the same default any other registered
  schema gets with no materializer of its own. Provide it only when
  you actually want decoding to produce your own struct rather than a
  generic map.

  ## This is sugar, not a new capability

  Everything `register_provider/2` does is expressible with the
  existing primitives directly — `Dextrin.decode/2` the schema source,
  `Dextrin.Schema.compile/3` it into a registry, then
  `Dextrin.Registry.put_struct_module/3` and, optionally,
  `Dextrin.Registry.put_struct_materializer/3`. `Dextrin.Schema.Provider`
  only exists to give that four-step sequence one name, one call, and
  a compile-time-checked contract for the module supplying the pieces
  — it doesn't change what a schema-backed struct fundamentally needs.
  """

  @doc """
  The `.dxns` source defining this struct's schema — and, optionally,
  anything else (see "Multiple named types, not just the one schema"
  above). May be a literal string or read from a file at compile time.
  """
  @callback dxn_schema() :: String.t()

  @doc "Which entry in `dxn_schema/0`'s compiled document is this struct's own schema."
  @callback dxn_schema_name() :: String.t()

  @doc """
  The Elixir struct module `dxn_schema_name/0`'s schema should be
  associated with (`Dextrin.Registry.put_struct_module/3`) — never
  this provider module itself, which typically isn't a struct at all.
  """
  @callback dxn_struct() :: module()

  @doc """
  Optional. Same shape as `Dextrin.Registry.put_struct_materializer/3`'s
  callback — turns a schema-validated field map into `dxn_struct/0`'s
  struct. Omit it to fall back to the default plain field map.
  """
  @callback dxn_materialize(%{optional(atom()) => term()}) :: {:ok, term()} | {:error, term()}

  @optional_callbacks dxn_materialize: 1
end
