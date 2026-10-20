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

## All 28 data types

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
date         @date "YYYY-MM-DD"
time         @time "HH:MM:SS(.fffffffff)?"           nanoseconds
datetime     @datetime "YYYY-MM-DDTHH:MM:SS(Z|±HH:MM)"  an instant with its offset
local-dt     @local-datetime "YYYY-MM-DDTHH:MM:SS"    no offset
duration     @duration "P..."                         ISO 8601 duration
uuid         @uuid "..."                              RFC 4122
objectid     @objectid "<24 hex>"                     BSON's ObjectId, 12 bytes
ip           @ip "192.0.2.1" | "2001:db8::/32"        an address or a prefix
uri          @uri "..."                               RFC 3986
bytes        @bytes "..."                             base64 in text
bits         @bits {"..." n}                          base64 and a bit count; whole bytes are bytes
regex        @regex "pattern" | @regex(im) "pattern"  flags: i m s u x f r
custom-tag   @tag value                                open extension point
```

Plus one meta form: `@dxn "1.0"` — an optional header, first thing in
the document only.

## Struct forms

```text
%Name{field: value, ...}     keyed -- order doesn't matter
%Name[value, ...]            positional -- order is everything
```

Both parse without a schema (to an opaque tagged value); a schema is
what supplies field names/order/types to interpret one or convert
between them.

## Discard

```text
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
{:list-items A {:repeat B 0 nil}}  a list's items in order; {:repeat {:group A B} 1 nil}
{:set-of T}                     set, every element matches T
{:tuple-of A B C}                fixed-arity positional tuple
{:tuple-of-all T}               tuple of any length, every element a T
{:map-of K V}                   every key matches K, every value matches V
{:array-of T}                   array, every element matches T
{:ordered-map-of K V}           ordered map, keys match K, values match V
{:sorted-set-of T}              sorted set, every element matches T
{:enum lit lit ...}              value equals one of the literals
{:one-of T U}                    exactly one matches
{:any-of T U}                    union: one or more match
{:all-of T U}                    intersection
{:not T}                         matches what T refuses
:never                           matches nothing
{:nilable T}                     sugar for {:any-of :nil T}
{:refine T %{constraints}}       base type + constraints, see below
%schema{}    struct/record shape
%shape{}     plain map with these fields, defaults filled (unversioned)
{:case f %{v => T, :else => U}}  the type field f's value chooses
{:generic [t] body}             a named type with parameters
{:of Name T}                    one use of a generic
```

## `refine` constraints

```text
min / max / exclusive-min / exclusive-max / multiple-of   int/float/decimal/rational
min / max / exclusive-*  on temporals                     date/time/datetime/local-datetime/duration, same kind
min-bytes / max-bytes                                     string: UTF-8 bytes
format                                                    string: :email :uri :hostname :semver ... (DXN.md §4.2a)
encoding / media-type                                     string: :base64 ... / "type/subtype"
content                                                   string: a DXN document of this type
encodes / encodes-seq                                     bytes: .dxnb document(s) of this type
float32                                                   float: single precision holds it
min-precision / max-precision                             decimal: coefficient digits
min-exponent / max-exponent                               decimal: exponent
bits                                                      integer/bytes: only these bit numbers set
before-now / after-now / within                           datetime against the clock
resolution                                                time/datetime/duration: :second :millisecond ...
min-length / max-length / pattern                          string/keyword/symbol/bytes (bits: length only)
min-count / max-count                                       list/set/tuple/sorted-set/array
contains / min-contains / max-contains                      how many elements are a given type
unique / unique-by                                          no two elements, or their field, the same
finite                                                      float: true refuses NaN and the infinities
offsets                                                     datetime: ["Z" "+02:00" ...]
version / prefix                                            ip: 4 or 6; true a prefix, false an address
```

## Struct schema shape

```text
%schema{
    required_field:  type_expr
    optional_field?: type_expr           # trailing "?" on the key = optional
    described_field: %field{
      type:        type_expr
      default:     value
      description: "..."
    }
  }
```

## Named types

```text
PositiveInt: {:refine :integer %{min: 1}}
```

Any `.dxns` entry that isn't a `%schema{}` is a named type — a
reusable name for a combination of the fixed type_expr forms above,
referenced exactly like a struct name, from a sibling in the same
document in any order, or from an earlier-compiled one; it may refer to
itself through a field or a collection (DXN.md §4.5).

## Reserved leaders

None of these may begin a bare identifier: `#` `@` `%` `?` `:`.

## Binary (`.dxnb`) envelope

```text
"DX" <version byte> <cbor item>
```

3-byte magic + version prefix, then one self-delimiting CBOR item.
Structs are always positional on the wire (no field names in binary —
the keyed text form is a human-readability-only convenience). `@_` and
comments have no binary encoding at all — both are resolved away
before a value exists.
