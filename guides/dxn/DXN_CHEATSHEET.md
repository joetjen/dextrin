# DXN Cheatsheet

Quick reference for the DXN format itself, independent of any
implementation. See the [tutorial](TUTORIAL.md) if anything here
doesn't make sense yet, or [dextrin's own cheatsheet](../CHEATSHEET.md)
for the Elixir-API-level equivalent.

## Whitespace, commas, comments

- Whitespace and `,` are **fully insignificant everywhere** — `[1 2
  3]` and `[1, 2, 3]` are identical.
- `#` starts a comment running to end of line; comments vanish before
  any value exists (no reader can recover them after parsing).

## All 24 data types

```text
nil          nil
boolean      true | false
integer      -?[0-9]+                             arbitrary precision
float        -?[0-9]+(.[0-9]+)?([eE][+-]?[0-9]+)? | NaN | Infinity | -Infinity
decimal      [0-9]+(.[0-9]+)?M                     exact fixed-point
rational     int/uint                              exact ratio, never auto-reduced
string       "..."                                  UTF-8
char         ?c                                     one Unicode codepoint
symbol       bare identifier                        unevaluated reference
keyword      :name | :"..." | name: (key pos.)
list         [ ... ]
tuple        { ... }
map          %{ ... }                                no ordering guarantee
ordered-map  @ordered %{ ... }                        order is part of identity
set          @{ ... }
sorted-set   @sorted-set @{ ... }
struct       %Name{ ... } | %Name[ ... ]              needs a schema to fully interpret
array        @array[ ... ]                           fixed-size, indexed
date         ~D[YYYY-MM-DD]
time         ~T[HH:MM:SS(.ffffff)?]
timestamp    ~U[YYYY-MM-DD HH:MM:SSZ]                 UTC only
datetime     @datetime "..."                          non-UTC offset required
duration     @duration "P..."                         ISO 8601 duration
uuid         @uuid "..."                              RFC 4122
uri          @uri "..."                               RFC 3986
bytes        @bytes "..."                             base64 in text
regex        ~r/pattern/flags                          flags: i m s u x f r
custom-tag   @tag value                                open extension point
```

Plus one meta form: `@dxn "1.0"` — an optional header, first thing in
the document only.

## Struct forms

```
%Name{field: value, ...}     keyed -- order doesn't matter
%Name[value, ...]            positional -- order is everything
```

Both parse without a schema (to an opaque tagged value); a schema is
what supplies field names/order/types to interpret one or convert
between them.

## Discard

```
@_ value
```

Parses `value` (so a malformed discard is still a parse error) and
produces nothing — never appears in the result, no binary encoding.

## `.dxns` type_expr forms

```text
:any                            matches anything
:integer / :string / ...        one keyword per primitive type name above
Name                            bare symbol -- a struct name or a named type
{:list-of T}                    list, every element matches T
{:set-of T}                     set, every element matches T
{:tuple-of A B C}                fixed-arity positional tuple
{:map-of K V}                   every key matches K, every value matches V
{:enum lit lit ...}              value equals one of the literals
{:one-of T U}                    union
{:all-of T U}                    intersection
{:nilable T}                     sugar for {:one-of :nil T}
{:refine T %{constraints}}       base type + constraints, see below
%schema{fields: @ordered %{}}    struct/record shape
```

## `refine` constraints

```text
min / max / exclusive-min / exclusive-max / multiple-of   int/float/decimal/rational
min-length / max-length / pattern                          string
min-count / max-count                                       list/set/tuple
```

## Struct schema shape

```
%schema{
  closed:    true | false        # default false -- unlisted fields preserved, not rejected
  forbidden: [name, ...]         # explicit deny-list, reported by name specifically
  refine-fn: ns/predicate-name   # cross-field/whole-value check
  fields: @ordered %{
    required_field:  type_expr
    optional_field?: type_expr           # trailing "?" on the key = optional
    described_field: %field{
      type:        type_expr
      default:     value
      description: "..."
    }
  }
}
```

## Named types

```
PositiveInt: {:refine :integer %{min: 1}}
```

Any `.dxns` entry that isn't a `%schema{}` is a named type — a
reusable name for a combination of the fixed type_expr forms above,
referenced exactly like a struct name. Can't reference a sibling named
type declared in the *same* document (no ordering guarantee to resolve
against); can freely reference one from an earlier-compiled document.

## Reserved sigils

None of these may begin a bare identifier: `#` `@` `%` `~` `?` `:`.

## Binary (`.dxnb`) envelope

```
"DX" <version byte> <cbor item>
```

3-byte magic + version prefix, then one self-delimiting CBOR item.
Structs are always positional on the wire (no field names in binary —
the keyed text form is a human-readability-only convenience). `@_` and
comments have no binary encoding at all — both are resolved away
before a value exists.
