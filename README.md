# Dextrin

An Elixir implementation of DXN (Data eXchange Notation) — `.dxn` text,
`.dxnb` binary, and `.dxns` schema documents. See `DXN.md` for the
normative format spec and `DESIGN.md` for this library's implementation
plan; this file is just usage.

```elixir
{:ok, value} = Dextrin.decode(~s(%{x: 1, y: 2}))
Dextrin.encode(value)
#=> {:ok, "%{x: 1, y: 2}"}

{:ok, bytes} = Dextrin.encode_binary(value)
Dextrin.decode_binary(bytes)
#=> {:ok, %{...}}
```

Every DXN type decodes to a plain Elixir value where one exists
(`integer`, `float`, `list`, a plain `map`, ...) and to a small wrapper
struct where Elixir has nothing that fits without losing information
— `Dextrin.Symbol`, `Dextrin.Keyword`, `Dextrin.Tuple`,
`Dextrin.OrderedMap`, `Dextrin.SortedSet`, `Dextrin.Struct`,
`Dextrin.Array`, `Dextrin.Duration`, `Dextrin.Rational`,
`Dextrin.Uuid`, `Dextrin.Uri`, `Dextrin.Bytes`, `Dextrin.Char`,
`Dextrin.CustomTag`. Notably, `symbol`/`keyword` wrap a `String.t()`,
never an Elixir atom — decoding untrusted DXN data can't be used to
exhaust the atom table.

## Schemas

`struct` is schema-dependent: without a compiled `.dxns` schema for a
given struct name, it decodes to an opaque `Dextrin.Struct`; with one,
enforcement (required/optional/closed/forbidden fields, refinements)
happens at decode time, in both `Dextrin.decode/2` and
`Dextrin.decode_binary/2`, and a violation is an ordinary decode error.

```elixir
{:ok, schema_doc} = Dextrin.decode("""
%{
  Point: %schema{
    fields: @ordered %{ x: :integer, y: :integer }
  }
}
""")

{:ok, registry} = Dextrin.Schema.compile(schema_doc)
Dextrin.decode("%Point{x: 1, y: 2}", registry: registry)
#=> {:ok, %{"x" => 1, "y" => 2}}
```

A registered materializer (`Dextrin.Registry.put_struct_materializer/3`)
turns that generic field map into a real application struct instead.

`encode/2`/`encode_binary/2` validate the *other* direction, too —
your own data, before it's sent anywhere — automatically: every
`Dextrin.Struct` (or registered application struct,
`Dextrin.Registry.put_struct_module/3`) found anywhere in the value is
checked against its own schema, the same way decoding checks every
named struct unconditionally. Validation never changes what gets
encoded; a `Dextrin.Struct` is the one shape that round-trips to
`%Point{...}` wire syntax, same as decode produces it:

```elixir
point = Dextrin.Struct.keyed("Point", [{"x", 1}, {"y", 2}])
Dextrin.encode(point, registry: registry)
#=> {:ok, "%Point{x: 1, y: 2}"}

bad = Dextrin.Struct.keyed("Point", [{"x", 1}])
Dextrin.encode(bad, registry: registry)
#=> {:error, %Dextrin.Error{}}   # missing required field "y"
```

Pass `validate: false` to skip this — for deliberately building
non-conforming data (test fixtures, or a pass-through/relay that
shouldn't second-guess data it isn't the origin of). A `schema:` opt
additionally validates a *nameless* top-level value (a plain map, or
an unregistered struct) against a specific schema — the one case the
automatic check can't cover on its own.

Any `.dxns` entry that isn't a `%schema{}` defines a reusable **named
type** instead — purely data, no Elixir code, so any dextrin-compatible
reader in any language resolves it the same way:

```elixir
%{
  PositiveInt: {:refine :integer %{min: 1}}
  Point: %schema{ fields: @ordered %{ x: PositiveInt, y: :integer } }
}
```

See `DESIGN.md` §4.4.1 for the full type_expr vocabulary and named
types' one deliberate limitation (no same-document forward references).

A small standard library of common ones (`PositiveInteger`,
`NonEmptyString`, `Percentage`, ...) ships in `Dextrin.Schema.Std` —
pass `Dextrin.Schema.Std.registry()` as `compile/3`'s `base_registry`
to use them.

## Mix tasks

```sh
mix dextrin.validate data.dxn [--format text|binary] [--schema s.dxns --as Name]
mix dextrin.encode data.dxn [--out data.dxnb] [--share]
mix dextrin.decode data.dxnb [--out data.dxn]
mix dextrin.format data.dxn [--mode pretty|condense] [--in-place]
mix dextrin.gen.schema MyApp.SomeStruct [--out schema.dxns] [--name Name]
```

## Installation

```elixir
def deps do
  [
    {:dextrin, path: "../dextrin"}
    # or, once published: {:dextrin, "~> 0.1.0"}
  ]
end
```

Depends on [`ichor`](../ichor) (the grammar compiler `.dxn` parsing is
built on) as a sibling path dependency — see `DESIGN.md` §3.

## Development

```sh
mix deps.get
mix test
```

`priv/grammar/dxn.aether`'s generated Unicode identifier ranges are
regenerated with `mix dextrin.gen.unicode`, which fetches the latest
`DerivedCoreProperties.txt` from unicode.org, compares its version
against `priv/unicode/VERSION`, and updates the grammar (and the
checked-in UCD data) only if it's newer. A deliberate, reviewed action
on a Unicode version bump, not run at build time (`DESIGN.md` §5.2).

## License

MIT — see `LICENSE`.
