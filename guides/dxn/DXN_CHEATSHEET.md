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

## All 31 data types

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

## Schemas

The schema language, DXNS, has a cheatsheet of its own:
[DXNS_CHEATSHEET.md](../dxns/DXNS_CHEATSHEET.md).

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
