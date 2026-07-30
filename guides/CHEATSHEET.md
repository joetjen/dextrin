# Cheatsheet

Quick reference for common `dextrin` tasks. See the
[tutorial](TUTORIAL.md) if anything here doesn't make sense yet, or
the [DXN cheatsheet](dxn/DXN_CHEATSHEET.md) for format-syntax-level
lookups.

## Decode / encode

```elixir
Dextrin.decode(text, opts \\ [])            #=> {:ok, value} | {:error, %Dextrin.Error{}}
Dextrin.encode(value, opts \\ [])           #=> {:ok, text}  | {:error, %Dextrin.Error{}}
Dextrin.decode_binary(bytes, opts \\ [])    #=> {:ok, value} | {:error, %Dextrin.Error{}}
Dextrin.encode_binary(value, opts \\ [])    #=> {:ok, bytes} | {:error, %Dextrin.Error{}}
```

`opts`: `registry:` (a `Dextrin.Registry.t()`, both directions),
`schema:` (encode only — validate the top-level value against one
named schema), `validate:` (encode only, default `true` — set `false`
to skip the automatic whole-tree schema check), `pretty:` (`encode/2`
only, default `false` — multi-line, indented output instead of
single-line/compact), `indent:` (`encode/2` only, meaningful with
`pretty: true` — spaces per nesting level, default 2), `trusted:`
(decode only, default `true` — `keyword` decodes as a real atom;
`false` for untrusted input decodes it as `Dextrin.Keyword.t()`
instead, so `String.to_atom/1` is never reachable from attacker
-controlled text).

## Render an error

```elixir
{:error, error} = Dextrin.decode(bad_text)
IO.puts(Dextrin.Error.format(error))
```

## Pretty-print / reformat

```elixir
Dextrin.encode(value, pretty: true)                #=> {:ok, text} | {:error, %Dextrin.Error{}}
Dextrin.encode(value, pretty: true, indent: 4)      # 4 spaces per level instead of the default 2

Dextrin.Text.Formatter.pretty(value, opts \\ [])    # what pretty: true calls; same {:ok, _}|{:error, _}
                                                     # contract, same indent: opt
```

Compact is `encode/2`'s default — the smallest text a value can
round-trip through, no line-wrapping or indentation at all. `pretty:`
only changes rendering, never what the value decodes back to.

```sh
mix dextrin.format data.dxn --mode pretty|condense [--in-place]
```

## Value-type cheatsheet

```text
symbol      Dextrin.Symbol{name: string}          bare identifier, e.g. `foo`
keyword     atom (default) / Dextrin.Keyword      `:foo` / `foo:` (key position) — trusted: false for the latter
tuple       Dextrin.Tuple{items: [term]}          `{1 2 3}` — list-backed, arbitrary length
array       Dextrin.Array{items: tuple}           `@array[1 2 3]` — tuple-backed, fixed size
ordered-map Dextrin.OrderedMap{pairs: [{k,v}]}    `@ordered %{...}` — order is part of identity
sorted-set  Dextrin.SortedSet{items: [term]}      `@sorted-set @{...}` — always sorted, deduped
struct      Dextrin.Struct{name, fields}          `%Name{...}` / `%Name[...]`, opaque w/o schema
duration    Dextrin.Duration{years, months, ...}  `@duration "P1Y2M"` — 7 independent fields
rational    Dextrin.Rational{numerator, denom}    `22/7` — stored exactly, never auto-reduced
uuid        Dextrin.Uuid{bytes: <<_::128>>}       `@uuid "..."` — 16 raw bytes, not the text form
uri         Dextrin.Uri{value: string}            `@uri "..."` — raw string, not parsed
bytes       Dextrin.Bytes{data: binary}           `@bytes "..."` (base64 in text)
char        Dextrin.Char{codepoint: integer}      `?a` — distinct from a 1-grapheme string
custom-tag  Dextrin.CustomTag{name, value}        `@tag value`, no decoder registered
```

Everything else (`nil`, `boolean`, `integer`, `float`, `Decimal.t()`,
`String.t()`, `list()`, plain `map()`, `MapSet.t()`, `Date.t()`,
`Time.t()`, `DateTime.t()`, `Regex.t()`) is the obvious native Elixir
value — see `Dextrin.Value`'s moduledoc for the full union.

## Registry: custom tags

```elixir
registry
|> Dextrin.Registry.put_tag(name, fn value -> {:ok, term} | {:error, reason} end)
|> Dextrin.Registry.put_tag_encoder(module, name, fn struct -> {:ok, value} | {:error, reason} end)
```

## Registry: schemas

```elixir
{:ok, registry} = Dextrin.Schema.compile(schema_doc, base_registry \\ Dextrin.Registry.new(), predicates \\ %{})

registry
|> Dextrin.Registry.put_struct_materializer(name, fn field_map -> {:ok, term} end)
|> Dextrin.Registry.put_struct_module(name, module)   # for {:reference, name} checks on hand-built structs
|> Dextrin.Registry.put_resolver(fn name -> {:ok, compiled} | :unknown end)   # lazy/on-demand schema loading
```

`Dextrin.Schema.FileResolver.for_paths(paths, predicates \\ %{})` builds
a ready-made resolver for `Namespace/Name -> paths/Namespace.dxns`.

## Registry: third-party structs (`Dextrin.Schema.Provider`)

For a struct defined by a library that doesn't (and shouldn't have to)
depend on `dextrin` itself — see `Dextrin.Schema.Provider`'s own
moduledoc for the full optional-dependency pattern this is meant to
support:

```elixir
{:ok, registry} = Dextrin.Schema.register_provider(registry, SomeLib.Money.DXN)
```

`SomeLib.Money.DXN` implements the `Dextrin.Schema.Provider` behaviour
(`dxn_schema/0`, `dxn_schema_name/0`, `dxn_struct/0`, and optionally
`dxn_materialize/1`) — a small, separately-compiled companion module,
not the struct's own module, so the struct itself is never
conditionally compiled.

## Schema validation, outside of decode

```elixir
Dextrin.Schema.validate(value, registry, schema_name)              #=> :ok | {:error, reason}
Dextrin.Schema.validate_encode(value, registry, schema_name)        # one named schema, encode-side
Dextrin.Schema.validate_encode_tree(value, registry)                # automatic whole-tree walk, encode-side
```

## `.dxns` type_expr forms, at a glance

```text
:any                           any value at all
:integer / :string / ...       one keyword per DXN.md §1.3 type name
Address                        bare symbol — a struct name or a named type
{:list-of T}                   list whose every element matches T
{:set-of T}                    set whose every element matches T
{:tuple-of A B C}              fixed-arity positional tuple
{:map-of K V}                  every key matches K, every value matches V
{:enum :a :b :c}                value must equal one of the given literals
{:one-of A B}                  union — matches at least one
{:all-of A B}                  intersection — matches all
{:nilable T}                   sugar for {:one-of :nil T}
{:refine T %{constraints}}     base type + refine constraints (below)
%schema{fields: @ordered %{}}  struct/record shape
```

## `refine` constraints

```text
min / max / exclusive-min / exclusive-max / multiple-of   -- integer/float/decimal/rational
min-length / max-length / pattern                          -- string
min-count / max-count                                      -- list/set/tuple
```

## Struct schema options

```elixir
%schema{
  closed:    true              # no field outside `fields` may be present at all
  forbidden: [legacy_field]    # explicit deny-list, reported by name
  refine-fn: ns/predicate-name # cross-field/whole-value check, resolved from `predicates`
  fields: @ordered %{
    required_field:  :integer
    optional_field?: :string             # trailing `?` = optional
    with_default:    %field{type: :integer, default: 0, description: "..."}
  }
}
```

## Standard named types (`Dextrin.Schema.Std`)

```elixir
{:ok, registry} = Dextrin.Schema.compile(doc, Dextrin.Schema.Std.registry())
```

```text
PositiveInteger, NonNegativeInteger, NegativeInteger, NonPositiveInteger
PositiveFloat, NonNegativeFloat, Percentage
NonEmptyString
NonEmptyList, NonEmptySet
```

## Mix tasks

```sh
mix dextrin.validate data.dxn [--format text|binary] [--schema s.dxns --as Name]
mix dextrin.encode data.dxn [--out data.dxnb] [--share]
mix dextrin.decode data.dxnb [--out data.dxn]
mix dextrin.format data.dxn [--mode pretty|condense] [--in-place]
mix dextrin.gen.schema MyApp.SomeStruct [--out schema.dxns] [--name Name]
mix dextrin.gen.unicode [--file PATH] [--force]
```
