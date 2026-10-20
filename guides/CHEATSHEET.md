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
single-line/compact: the top-level collection one entry per line, a
nested one on one line when it fits), `indent:` (`encode/2` only,
meaningful with `pretty: true` — spaces per nesting level, default 2),
`width:` (`encode/2` only, meaningful with `pretty: true` — the columns
a nested collection's one line must fit in, default 80), `trusted:`
(decode only, default `false` — `keyword` decodes as
`Dextrin.Keyword.t()`, so `String.to_atom/1` is never reachable from
the input; `true`, for a source you control, decodes it as a real
atom).

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
mix dextrin.format data.dxn --mode pretty|condense [--in-place]   # pretty keeps comments
```

## Documents: keeping comments

```elixir
{:ok, doc} = Dextrin.Document.parse(source, opts)     # decode/2's opts and errors
Dextrin.Document.to_value(doc)                       # what decode/2 gives
Dextrin.Document.render(doc)                         # the source, byte for byte
Dextrin.Document.format(doc)                         # laid out, comments kept
{:ok, doc} = Dextrin.Document.replace(doc, [:version], "2.0.0")
{:ok, doc} = Dextrin.Document.delete(doc, [:deps, 0])          # with its own comments
{:ok, doc} = Dextrin.Document.insert(doc, [:deps], -1, "new")  # index, or a map's new key
{:ok, doc, changes} = Dextrin.Document.update(doc, new_value, on_ambiguity: :safe)
```

## Value-type cheatsheet

```text
symbol      Dextrin.Symbol{name: string}          bare identifier, e.g. `foo`
keyword     Dextrin.Keyword (default) / atom      `:foo` / `foo:` (key position) — trusted: true for the latter
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
{:ok, registry} = Dextrin.Schema.compile(schema_doc, base_registry \\ Dextrin.Registry.new())

registry
|> Dextrin.Registry.put_struct_materializer(name, fn name, version, fields -> {:ok, term} end)   # every version; result checked against the latest
|> Dextrin.Registry.put_struct_module(name, module)   # for {:reference, name} checks on hand-built structs
|> Dextrin.Registry.put_resolver(fn name -> {:ok, compiled} | :unknown end)   # lazy/on-demand schema loading
|> Dextrin.Registry.put_strict(true)   # refuse extra fields (schema/undeclared-field); or decode(..., strict: true)

Dextrin.Registry.fetch_struct_schema(registry, name)            # the latest version
Dextrin.Registry.fetch_struct_schema(registry, name, version)   # exactly that one
Dextrin.Registry.replace_struct_schema(registry, name, compiled) # hot swap a loaded version
```

`Dextrin.Schema.FileResolver.for_paths(paths)` builds
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
`dxn_materialize/3`) — a small, separately-compiled companion module,
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
{:array-of T}                  array whose every element matches T
{:ordered-map-of K V}          ordered map: keys match K, values match V
{:sorted-set-of T}             sorted set whose every element matches T
{:enum :a :b :c}                value must equal one of the given literals
{:one-of A B}                  exactly one matches (JSON Schema's oneOf)
{:any-of A B}                  union — matches one or more (anyOf)
{:all-of A B}                  intersection — matches all
{:not T}                       matches what T refuses
:never                         matches nothing
{:nilable T}                   sugar for {:any-of :nil T}
{:refine T %{constraints}}     base type + refine constraints (below)
%schema{}  struct/record shape
%shape{}   plain map with these fields, defaults filled (unversioned)
{:case f %{v => T, :else => U}}  the type the sibling field f's value chooses
{:generic [t] body}             a named type with parameters
{:of Name T}                    one use of a generic
```

## `refine` constraints

```text
min / max / exclusive-min / exclusive-max / multiple-of   -- integer/float/decimal/rational
min-length / max-length / pattern                          -- string
min-count / max-count                                      -- list/set/tuple
```

## Checking without decoding

```elixir
Dextrin.Schema.check(value, registry, "OrderPlaced")    # :ok | {:error, error}, never changes value
Dextrin.Schema.conform(value, registry, "OrderPlaced")  # {:ok, value with shape defaults filled}
```

## Struct schema options

```elixir
%schema(2){                              # version 2; no header = version 1
    required_field:  :integer            # the body's order is the .dxnb position
    optional_field?: :string             # trailing `?` = optional
    with_default:    %field{type: :integer, default: 0, description: "..."}
  }
```

## Versions and extra fields

```elixir
%Point(2){x: 1, y: 2}            # written with version 2; encoding always writes the latest
%Point{x: 1, y: 2}               # no version: read as the latest
%Point[1 2 label: "a"]           # extra fields after a positional struct's items
%Point{x: 1, y: 2, label: "a"}   # an undeclared name is an extra field
```

Newer than loaded: read against the latest (text by name, `.dxnb` by
position). Older and loaded: the materializer upgrades it, else
`schema/no-materializer`. Older and not loaded: `schema/unknown-version`.
Reordering fields misreads silently in older `.dxnb` readers: append only.

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
mix dextrin.compat old-schemas/ schemas/
mix dextrin.check schemas/ [--extern NAMESPACE]...
mix dextrin.docs schemas/ [--out DIR] [--title TITLE]
mix dextrin.gen.schema MyApp.SomeStruct [--out schema.dxns] [--name Name]
mix dextrin.gen.unicode [--file PATH] [--force]
```
