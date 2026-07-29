# Tutorial

A step-by-step walkthrough of `dextrin`'s features, building up to a
small, complete example: decoding a config file, validating it against
a schema, and re-encoding it to both text and binary. If you want the
DXN *format itself* explained independently of this Elixir
implementation, see the [DXN tutorial](dxn/TUTORIAL.md) instead — this
one assumes you already roughly know what `.dxn` text looks like and
focuses on the Elixir API around it.

## 1. Decoding and encoding text

```elixir
{:ok, value} = Dextrin.decode(~s(%{name: "Ada", active: true, score: 19.99M}))
#=> {:ok, %{
#=>   %Dextrin.Keyword{name: "name"} => "Ada",
#=>   %Dextrin.Keyword{name: "active"} => true,
#=>   %Dextrin.Keyword{name: "score"} => Decimal.new("19.99")
#=> }}

Dextrin.encode(value)
#=> {:ok, "%{name: \"Ada\", active: true, score: 19.99M}"}
```

Notice the map's keys: a plain map's shorthand keys (`name:`) are
themselves DXN `keyword`s, not bare strings — `%{name: "Ada"}` and
`%{:name => "Ada"}` are the exact same value. A schema-backed `struct`'s
fields are the one place names *do* come back as plain strings (§6
below), since a schema always knows its field names up front.

Both directions return `{:ok, _} | {:error, %Dextrin.Error{}}` —
`decode/2` never raises on malformed input, and `encode/2` never
raises on a value it can't represent. `Dextrin.Error.format/1` renders
either kind of error, including caret-annotated source context for
text-side syntax errors.

```elixir
{:error, error} = Dextrin.decode("%{x: }")
IO.puts(Dextrin.Error.format(error))
```

## 2. What a decoded value looks like

Every DXN type maps to a plain Elixir value where one exists, and to a
small wrapper struct only where nothing native fits without losing
information:

```elixir
{:ok, sym}  = Dextrin.decode("some-symbol")
#=> {:ok, %Dextrin.Symbol{name: "some-symbol"}}

{:ok, kw}   = Dextrin.decode(":ok")
#=> {:ok, %Dextrin.Keyword{name: "ok"}}

{:ok, tup}  = Dextrin.decode("{1 2 3}")
#=> {:ok, %Dextrin.Tuple{items: [1, 2, 3]}}

{:ok, om}   = Dextrin.decode("@ordered %{b: 2, a: 1}")
#=> {:ok, %Dextrin.OrderedMap{pairs: [{%Dextrin.Keyword{name: "b"}, 2}, {%Dextrin.Keyword{name: "a"}, 1}]}}
```

Notably, `symbol`/`keyword` wrap a plain `String.t()`, never an Elixir
atom — decoding untrusted DXN data can never be used to exhaust the
atom table. See the module docs under `Dextrin.Value` (the full type
union) and each wrapper module for why it exists.

## 3. Round-tripping through `.dxnb`

```elixir
{:ok, bytes} = Dextrin.encode_binary(value)
{:ok, ^value} = Dextrin.decode_binary(bytes)
```

`.dxnb` is CBOR underneath, with a 3-byte envelope (`"DX"` + a version
byte) in front for cheap magic-number sniffing. Pass `share: true` to
`encode_binary/2` to opt into DXN's value-sharing extension — repeated
compound values get written once and referenced afterward, when the
byte-count math actually favors it:

```elixir
big_map = %{"k" => List.duplicate(%{"a" => 1, "b" => 2}, 100)}
{:ok, small} = Dextrin.encode_binary(big_map, share: true)
{:ok, large} = Dextrin.encode_binary(big_map, share: false)
byte_size(small) < byte_size(large)
#=> true
```

## 4. Formatting

`Dextrin.encode/2` is a printer, not a formatter: single-line, minimal
whitespace, with no line-wrapping policy. For human-readable,
multi-line output — e.g. for a CLI or a config file you're about to
commit — use `Dextrin.Text.Formatter.pretty/2`:

```elixir
Dextrin.Text.Formatter.pretty(%{name: "Ada", tags: MapSet.new([:admin, :staff])})
#=>
# %{
#   name: "Ada",
#   tags: @{
#     :admin,
#     :staff
#   }
# }
```

Comments are never preserved by either path — `.dxn`'s lexer discards
`#`-comments as trivia before the parser ever sees them, so there's no
comment text left by the time a value exists to reprint.

## 5. Extending: custom tags

`@tag value` is DXN's open extension point for a scalar-wrapping type
with no field structure. Register a decoder and (optionally) an
encoder on a `Dextrin.Registry`:

```elixir
defmodule MyApp.Money do
  defstruct [:cents]
end

registry =
  Dextrin.Registry.new()
  |> Dextrin.Registry.put_tag("my-app/money", fn cents -> {:ok, %MyApp.Money{cents: cents}} end)
  |> Dextrin.Registry.put_tag_encoder(MyApp.Money, "my-app/money", fn %MyApp.Money{cents: c} -> {:ok, c} end)

Dextrin.decode(~s(@my-app/money 500), registry: registry)
#=> {:ok, %MyApp.Money{cents: 500}}

Dextrin.encode(%MyApp.Money{cents: 500}, registry: registry)
#=> {:ok, "@my-app/money 500"}
```

With no registration at all, `@my-app/money 500` decodes to an opaque
`%Dextrin.CustomTag{name: "my-app/money", value: 500}` instead of
failing — the same "opaque tagged value, not an error" contract DXN
gives every unrecognized tag.

## 6. Extending: schemas for `struct`

`struct` is DXN's field-structured extension point, and it's
schema-dependent by design: without a compiled schema, `%Point{x: 1,
y: 2}` decodes to an opaque `%Dextrin.Struct{}`. A `.dxns` schema
document is itself just DXN data — no new grammar, no new parser:

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

Field enforcement (required/optional, closed/forbidden fields,
refinements) happens automatically at decode time, in both `decode/2`
and `decode_binary/2` — a violation comes back as an ordinary
`{:error, %Dextrin.Error{}}`, indistinguishable by shape from a syntax
error:

```elixir
Dextrin.decode("%Point{x: 1}", registry: registry)
#=> {:error, %Dextrin.Error{message: "struct \"Point\" violates its schema: missing required field \"y\"", ...}}
```

Encoding checks the same thing, automatically, in the other direction
— every `Dextrin.Struct` (or registered application struct) anywhere
in the value you're encoding gets checked against its own schema
before anything is written:

```elixir
bad = Dextrin.Struct.keyed("Point", [{"x", 1}])
Dextrin.encode(bad, registry: registry)
#=> {:error, %Dextrin.Error{}}   # missing required field "y"
```

Pass `validate: false` to skip this (test fixtures, deliberately
building non-conforming data, a pass-through that shouldn't
second-guess data it isn't the origin of).

## 7. Materializing real Elixir structs

By default a struct materializes to a plain string-keyed map. Register
a materializer to produce your own struct instead:

```elixir
defmodule MyApp.Point do
  defstruct [:x, :y]
end

registry =
  registry
  |> Dextrin.Registry.put_struct_materializer("Point", fn %{x: x, y: y} ->
    {:ok, %MyApp.Point{x: x, y: y}}
  end)

Dextrin.decode("%Point{x: 1, y: 2}", registry: registry)
#=> {:ok, %MyApp.Point{x: 1, y: 2}}
```

To let `{:reference, "Point"}` type-checks and automatic encode-time
validation recognize `%MyApp.Point{}` values you build yourself
(never decoded), also declare the module:

```elixir
registry = Dextrin.Registry.put_struct_module(registry, "Point", MyApp.Point)
```

This also lets you encode a `%MyApp.Point{}` directly — no need to
hand-build a `Dextrin.Struct` first:

```elixir
Dextrin.encode(%MyApp.Point{x: 1, y: 2}, registry: registry)
#=> {:ok, "%Point{x: 1, y: 2}"}
```

## 8. Named types and the standard library

Any `.dxns` entry that *isn't* a `%schema{}` defines a reusable named
type instead — purely data, composing the fixed type_expr vocabulary:

```elixir
{:ok, doc} = Dextrin.decode("""
%{
  PositiveInt: {:refine :integer %{min: 1}}
  Point: %schema{ fields: @ordered %{ x: PositiveInt, y: :integer } }
}
""")
```

`Dextrin.Schema.Std` ships a small library of common ones
(`PositiveInteger`, `NonEmptyString`, `Percentage`, ...) — pass its
registry as `compile/3`'s `base_registry` to use them:

```elixir
{:ok, registry} = Dextrin.Schema.compile(doc, Dextrin.Schema.Std.registry())
```

## 9. Letting a third-party struct provide its own schema

Everything so far assumed you write the `.dxns` schema yourself. If
`MyApp.Point` instead came from a library that doesn't want to (and
shouldn't have to) depend on `dextrin`, that library can ship a small,
separately-compiled companion module implementing
`Dextrin.Schema.Provider` — guarded behind an optional dependency, so
the struct's own module is never conditionally compiled:

```elixir
# the library's own mix.exs: {:dextrin, "~> 0.1", optional: true}

if Code.ensure_loaded?(Dextrin.Schema.Provider) do
  defmodule MyLib.Point.DXN do
    @behaviour Dextrin.Schema.Provider

    @impl true
    def dxn_schema, do: """
    %{ Point: %schema{ fields: @ordered %{ x: :integer, y: :integer } } }
    """

    @impl true
    def dxn_schema_name, do: "Point"

    @impl true
    def dxn_struct, do: MyLib.Point

    @impl true
    def dxn_materialize(%{x: x, y: y}), do: {:ok, %MyLib.Point{x: x, y: y}}
  end
end
```

An application depending on both `my_lib` and `dextrin` registers it
in one call, wherever it's already building its registry:

```elixir
{:ok, registry} = Dextrin.Schema.register_provider(Dextrin.Registry.new(), MyLib.Point.DXN)

Dextrin.decode("%Point{x: 1, y: 2}", registry: registry)
#=> {:ok, %MyLib.Point{x: 1, y: 2}}
Dextrin.encode(%MyLib.Point{x: 1, y: 2}, registry: registry)
#=> {:ok, "%Point{x: 1, y: 2}"}
```

`dxn_materialize/1` is optional — without it, decoding falls back to
the same plain field map any other schema with no materializer
produces. See `Dextrin.Schema.Provider`'s own moduledoc for why this
is a companion module rather than the struct's own, and for reading
`dxn_schema/0`'s source from a file at compile time instead of an
inline string.

## 10. Putting it together: a small config loader

```elixir
defmodule MyApp.ConfigLoader do
  @schema """
  %{
    Server: %schema{
      fields: @ordered %{
        host:  NonEmptyString
        port:  {:refine :integer %{min: 1, max: 65535}}
        tags?: {:list-of :symbol}
      }
    }
  }
  """

  def registry do
    {:ok, doc} = Dextrin.decode(@schema)
    {:ok, registry} = Dextrin.Schema.compile(doc, Dextrin.Schema.Std.registry())
    registry
  end

  def load(path) do
    with {:ok, source} <- File.read(path),
         {:ok, value} <- Dextrin.decode(source, registry: registry()) do
      Dextrin.Schema.validate(value, registry(), "Server")
      {:ok, value}
    end
  end
end
```

```
# config.dxn
%Server{
  host: "localhost"
  port: 4000
  tags: [dev local]
}
```

```elixir
MyApp.ConfigLoader.load("config.dxn")
#=> {:ok, %{"host" => "localhost", "port" => 4000, "tags" => [%Dextrin.Symbol{name: "dev"}, %Dextrin.Symbol{name: "local"}]}}
```

From here: [Examples](EXAMPLES.md) for more worked scenarios, the
[Cheatsheet](CHEATSHEET.md) for quick lookups, and the
[DXN reference](dxn/DXN.md) for the full format specification.
