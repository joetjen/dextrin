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
{:ok, value} = Dextrin.decode(~s(%{name: "Ada", active: true, score: 19.99M}), trusted: true)
#=> {:ok, %{active: true, name: "Ada", score: Decimal.new("19.99")}}

Dextrin.encode(value)
#=> {:ok, "%{active:true,name:\"Ada\",score:19.99M}"}
```

Notice the map's keys: a plain map's shorthand keys (`name:`) are
themselves DXN `keyword`s, not bare strings — `%{name: "Ada"}` and
`%{:name => "Ada"}` are the exact same value. **By default a keyword
decodes as `Dextrin.Keyword.t()`**, never an atom: a `.dxn`/`.dxnb` from
anywhere must never be able to exhaust the atom table via an unbounded
`String.to_atom/1`:

```elixir
Dextrin.decode(~s(%{name: "Ada"}))
#=> {:ok, %{%Dextrin.Keyword{name: "name"} => "Ada"}}
```

For input you control, `trusted: true` decodes it as a real atom,
`keyword`'s own Elixir type (`DXN.md` §1.3) -- as in the first example.

A schema-backed `struct`'s fields are the one place names *do* come
back as plain strings regardless of `trusted:` (§6 below), since a
schema always knows its field names up front.

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

{:ok, om}   = Dextrin.decode("@ordered %{b: 2, a: 1}", trusted: true)
#=> {:ok, %Dextrin.OrderedMap{pairs: [{:b, 2}, {:a, 1}]}}
```

`symbol` always wraps a plain `String.t()`, never an Elixir atom —
decoding DXN data can never exhaust the atom table through a symbol,
`trusted:` or not. `keyword` is the one type with two faces, controlled
by `trusted:` (default `false`): `Dextrin.Keyword.t()`, as shown above,
or a real atom when the input is trusted (`trusted: true`) — see
`Dextrin.Registry.put_trusted/2`'s own doc.
See the module docs under `Dextrin.Value` (the full type union) and
each wrapper module for more.

## 3. Round-tripping through `.dxnb`

```elixir
{:ok, bytes} = Dextrin.encode_binary(value)
{:ok, ^value} = Dextrin.decode_binary(bytes, trusted: true)
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

`Dextrin.encode/2` defaults to the smallest text a value can
round-trip through: single-line, minimal whitespace, no line-wrapping
or indentation at all. Pass `pretty: true` for human-readable,
multi-line output instead — e.g. for a CLI or a config file you're
about to commit:

```elixir
{:ok, value} = Dextrin.decode(~s(%{name: "Ada", tags: @{:admin :staff}}))

Dextrin.encode(value, pretty: true)
#=>
# {:ok, "%{
#   name: \"Ada\"
#   tags: @{
#     :admin
#     :staff
#   }
# }"}
```

`indent:` sets the number of spaces per nesting level (default 2):

```elixir
Dextrin.encode(value, pretty: true, indent: 4)
#=> {:ok, "%{\n    name: \"Ada\"\n    tags: @{\n        :admin\n        :staff\n    }\n}"}
```

`pretty`/`indent` only change *rendering* — the value `decode/2` gets
back is identical either way. Schema validation (§6 below) runs the
same regardless too; it's an independent concern from formatting.
`pretty: true` calls `Dextrin.Text.Formatter.pretty/2` under the hood.

### Keeping comments

A value has no comments: `decode/2` keeps the data and nothing else, so
decoding a file, changing it and encoding it again deletes every
comment in it. For a file people annotate, parse it as a
`Dextrin.Document` instead, which keeps everything — comments, blank
lines, commas — beside the value:

```elixir
{:ok, doc} = Dextrin.Document.parse(~s|# the config\n%{name: "acme", version: "1.0.0" # bumped for the fix\n}\n|)

Dextrin.Document.to_value(doc)
#=> %{name: "acme", version: "1.0.0"}

Dextrin.Document.format(doc)
#=> "# the config\n%{\n  name: \"acme\"\n  version: \"1.0.0\"  # bumped for the fix\n}"
```

`format/2` changes layout only and keeps every comment with its entry —
it is what `mix dextrin.format` does. Edits change exactly what they
name, and every byte they do not touch stays as it was:

```elixir
{:ok, doc} = Dextrin.Document.replace(doc, [:version], "2.0.0")
Dextrin.Document.render(doc)
#=> "# the config\n%{name: \"acme\", version: \"2.0.0\" # bumped for the fix\n}\n"
```

`delete/2` takes an entry's own comments with it, the ones above it and
the one beside it; `insert/4` puts a new entry above the comments of the
one it lands before; `update/3` turns a whole new value into these
edits, and refuses where guessing which edit you meant would lose a
comment.

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
  Point: %schema{ x: :integer, y: :integer }
}
""")

{:ok, registry} = Dextrin.Schema.compile(schema_doc)

Dextrin.decode("%Point{x: 1, y: 2}", registry: registry)
#=> {:ok, %Dextrin.Struct{name: "Point", version: 1, fields: {:keyed, [{"x", 1}, {"y", 2}]}}}
```

With no materializer registered (§7), a checked struct comes back as a
generic `Dextrin.Struct` at its schema's latest version, its fields in
the schema's order — which encodes back to exactly the text it came
from.

Field enforcement (required fields, declared types and their
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

By default a checked struct comes back as a generic `Dextrin.Struct`.
Register a materializer — one per schema — to produce your own struct
instead. It is called for every decoded struct of its schema, with the
schema's name, the version the struct was written with and its fields
keyed by string, and what it answers is checked against the latest
schema:

```elixir
defmodule MyApp.Point do
  defstruct [:x, :y]
end

registry =
  registry
  |> Dextrin.Registry.put_struct_materializer("Point", fn "Point", _version, %{"x" => x, "y" => y} ->
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
#=> {:ok, "%Point(1){x:1,y:2}"}
```

The `(1)` is the schema's version; §8 is about what it is for.

### Fields a schema does not declare

A struct guarantees the fields its schema declares and may carry more.
A field the schema does not know is kept as an **extra field**, in the
struct's `extra` list, and written back with it — so a newer producer's
fields pass through an older reader instead of being lost:

```elixir
Dextrin.decode(~s|%Point{x: 1, y: 2, label: "origin"}|, registry: registry)
#=> {:ok, %Dextrin.Struct{name: "Point", version: 1, fields: {:keyed, [{"x", 1}, {"y", 2}]}, extra: [{"label", "origin"}]}}
```

A positional struct writes its extras as entries after its items,
`%Point[1 2 label: "origin"]`, and `.dxnb` as one trailing map. An extra
never shadows a declared field — `%Point{x: 1, "x" => 2}` is refused —
and a materializer receives the extras with the declared fields. Pass
`strict: true` to refuse every extra field instead
(`schema/undeclared-field`): right for a config file written by hand,
where an unknown field is a typo.

## 8. Evolving a schema

A schema changes; data written with the old one does not. Each `.dxns`
document describes one **version** of each schema in it — no header
is version 1, `%schema(2){...}` is version 2 — and a registry holds as
many versions of `Point` side by side as you load:

```elixir
load = fn sources ->
  Enum.reduce(sources, Dextrin.Registry.new(), fn source, registry ->
    {:ok, doc} = Dextrin.decode(source)
    {:ok, registry} = Dextrin.Schema.compile(doc, registry)
    registry
  end)
end

v1 = "%{Point: %schema{x: :integer, y: :integer}}"
v2 = "%{Point: %schema(2){x: :integer, y: :integer, label?: :string}}"
```

**Every struct is written with the latest version loaded**, so a
reader always knows which shape it is looking at:

```elixir
{:ok, point} = Dextrin.decode(~s|%Point{x: 1, y: 2, label: "origin"}|, registry: load.([v2]))
Dextrin.encode(point, registry: load.([v2]))
#=> {:ok, "%Point(2){x:1,y:2,label:\"origin\"}"}
```

A struct written without a version, `%Point{...}` — mostly text written
by hand — is read as the latest.

### A newer writer, an older reader

A reader that has only version 1 reads version 2 against what it has.
Text matches fields by name, and a field it does not know is kept as an
extra field (§7), so it travels on:

```elixir
Dextrin.decode(~s|%Point(2){x: 1, y: 2, label: "origin"}|, registry: load.([v1]))
#=> {:ok, %Dextrin.Struct{name: "Point", version: 1, fields: {:keyed, [{"x", 1}, {"y", 2}]}, extra: [{"label", "origin"}]}}
```

`.dxnb` has no names, only positions: the reader takes as many items
as it has fields and drops the rest, so the same point read from binary
comes back without its `label`. Every field the reader requires must be
there, with the right type, either way.

### An older writer, a newer reader

A reader whose latest is version 2 cannot read version 1 as though it
were version 2 — that would be a guess — so it refuses, unless the
schema has a materializer to upgrade it:

```elixir
Dextrin.decode("%Point(1){x: 1, y: 2}", registry: load.([v1, v2]))
#=> {:error, %Dextrin.Error{category: "schema/no-materializer", ...}}

registry =
  Dextrin.Registry.put_struct_materializer(load.([v1, v2]), "Point", fn
    "Point", 1, fields -> {:ok, Dextrin.Struct.keyed("Point", [{"x", fields["x"]}, {"y", fields["y"]}, {"label", "unnamed"}], 2)}
    "Point", 2, fields -> {:ok, Dextrin.Struct.keyed("Point", Enum.sort(fields), 2)}
  end)

Dextrin.decode("%Point(1){x: 1, y: 2}", registry: registry)
#=> {:ok, %Dextrin.Struct{name: "Point", version: 2, fields: {:keyed, [{"x", 1}, {"y", 2}, {"label", "unnamed"}]}}}
```

The materializer is called for every `Point`, whatever its version, and
what it answers is checked against the latest. That is why the version
needs loading: an older version that is not loaded is refused
(`schema/unknown-version`), because without its schema there are no
field names to hand the materializer.

### The one thing that goes wrong silently

**Reading forward in `.dxnb` trusts the positions.** Suppose version 3
only swaps two fields:

```elixir
v3 = "%{Point: %schema(3){y: :integer, x: :integer, label?: :string}}"

{:ok, point} = Dextrin.decode(~s|%Point{x: 1, y: 2, label: "a"}|, registry: load.([v3]))
{:ok, bytes} = Dextrin.encode_binary(point, registry: load.([v3]))

Dextrin.decode_binary(bytes, registry: load.([v2]))
#=> {:ok, %Dextrin.Struct{name: "Point", version: 2, fields: {:keyed, [{"x", 2}, {"y", 1}, {"label", "a"}]}}}
```

The version 2 reader has `x` and `y` the wrong way round, and nothing
said so: both are integers. Text, read by name, gets it right. So a
schema whose older readers must keep working **only ever appends**
fields; reordering, inserting or removing one is for when every reader
has the new version — deploy readers first (DXNS.md §8).

### Checking a tree of schemas

`mix dextrin.check` reads every `.dxns` file under a directory as one
tree: each entry named from its file's path (DXNS.md §6), the files
compiled in the order their references need. It prints every problem
as `file:line: message` and fails -- a file that does not parse, a
definition that does not compile, a versioned file holding another
version, and a name that resolves to nothing, such as a typo in
`acme.comon/Money`:

```sh
$ mix dextrin.check schemas/
OK: 7 files, 26 definitions
```

A name another tree or a provider supplies is allowed by its namespace,
`--extern google.protobuf`. `Dextrin.Schema.Tree.load/2` is the same
check, answering the registry it compiled.

### Checking a change before it ships

`mix dextrin.compat` compares the previous release's schema files with
the current ones, for CI. It fails when a version's content changed
without a new version, or when a version went down, and lists what the
latest version's materializer has to upgrade from each older one:

```sh
$ mix dextrin.compat schemas-v1.4.0/ schemas/
Point 1 -> 3: added label
Point 2 -> 3: no field changes
OK: no version discipline problems
```

## 9. Named types and the standard library

Any `.dxns` entry that *isn't* a `%schema{}` defines a reusable named
type instead — purely data, composing the fixed type_expr vocabulary:

```elixir
{:ok, doc} = Dextrin.decode("""
%{
  PositiveInt: {:refine :integer %{min: 1}}
  Point: %schema{ x: PositiveInt, y: :integer }
}
""")
```

`Dextrin.Schema.Std` ships a small library of common ones
(`PositiveInteger`, `NonEmptyString`, `Percentage`, ...) — pass its
registry as `compile/3`'s `base_registry` to use them:

```elixir
{:ok, registry} = Dextrin.Schema.compile(doc, Dextrin.Schema.Std.registry())
```

## 10. Letting a third-party struct provide its own schema

Everything so far assumed you write the `.dxns` schema yourself. If
`MyApp.Point` instead came from a library that doesn't want to (and
shouldn't have to) depend on `dextrin`, that library can ship a small,
separately-compiled companion module implementing
`Dextrin.Schema.Provider` — guarded behind an optional dependency, so
the struct's own module is never conditionally compiled:

```elixir
# the library's own mix.exs: {:dextrin, "~> 0.3", optional: true}

if Code.ensure_loaded?(Dextrin.Schema.Provider) do
  defmodule MyLib.Point.DXN do
    @behaviour Dextrin.Schema.Provider

    @impl true
    def dxn_schema, do: """
    %{ Point: %schema{ x: :integer, y: :integer } }
    """

    @impl true
    def dxn_schema_name, do: "Point"

    @impl true
    def dxn_struct, do: MyLib.Point

    @impl true
    def dxn_materialize("Point", _version, %{"x" => x, "y" => y}), do: {:ok, %MyLib.Point{x: x, y: y}}
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
#=> {:ok, "%Point(1){x:1,y:2}"}
```

`dxn_materialize/3` is optional — without it, decoding falls back to
the same generic `Dextrin.Struct` any other schema with no materializer
produces. See `Dextrin.Schema.Provider`'s own moduledoc for why this
is a companion module rather than the struct's own, and for reading
`dxn_schema/0`'s source from a file at compile time instead of an
inline string.

## 11. Putting it together: a small config loader

```elixir
defmodule MyApp.ConfigLoader do
  @schema """
  %{
    Server: %schema{
        host:  NonEmptyString
        port:  {:refine :integer %{min: 1, max: 65535}}
        tags?: {:list-of :symbol}
      }
  }
  """

  def registry do
    {:ok, doc} = Dextrin.decode(@schema)
    {:ok, registry} = Dextrin.Schema.compile(doc, Dextrin.Schema.Std.registry())
    registry
  end

  def load(path) do
    with {:ok, source} <- File.read(path) do
      Dextrin.decode(source, registry: registry())
    end
  end
end
```

No separate validation step is needed here — `registry()` already has
`Server`'s schema compiled into it, so `Dextrin.decode/2` itself
enforces every field, automatically, as part of decoding (§6). A
malformed config file comes back as an ordinary `{:error,
%Dextrin.Error{}}` from `load/1` directly, not something the caller
has to separately check for.

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
#=> {:ok, %Dextrin.Struct{name: "Server", version: 1, fields: {:keyed, [{"host", "localhost"}, {"port", 4000}, {"tags", [%Dextrin.Symbol{name: "dev"}, %Dextrin.Symbol{name: "local"}]}]}}}
```

From here: [Examples](EXAMPLES.md) for more worked scenarios, the
[Cheatsheet](CHEATSHEET.md) for quick lookups, and the
[DXN reference](dxn/DXN.md) for the full format specification.
