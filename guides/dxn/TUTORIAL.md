# DXN Tutorial

A step-by-step introduction to DXN (Data eXchange Notation) itself —
the format, independent of any particular implementation. Every
snippet below is plain `.dxn` text; try each one with
`Dextrin.decode/1` (or any other conformant reader) as you go. See the
[reference](DXN.md) for the complete, terse specification this
tutorial is building intuition for.

## 1. Scalars

```
nil
true
false
42
-17
3.14
NaN
Infinity
19.99M
22/7
"hello, world"
?a
```

`nil`/`true`/`false` are exactly what they look like. Integers are
arbitrary precision. Floats are IEEE 754 doubles, with `NaN`/
`Infinity`/`-Infinity` as explicit literals (no sign on `NaN`). A
trailing `M` marks a `decimal` — exact fixed-point, the type you want
for money. A bare `int/uint` is a `rational` — stored exactly as
written, `22/7` and `44/14` are different values unless you reduce
them yourself. `?a` is a `char` — one Unicode codepoint, distinct from
the one-character string `"a"`.

## 2. Symbols and keywords

```
some-symbol
Point
Namespace/Name
:ok
:error
name:
```

A **symbol** is a bare, unevaluated identifier — a reference, not a
value in the way a string is. A **keyword** starts with `:` in value
position (`:ok`) or is written as `name:` immediately before a value,
in key position (`name: 1` inside a map). Identifiers may contain a
single `/` to namespace them (`Namespace/Name`) — used for
cross-file schema references.

## 3. Collections

```
[1 2 3]
{1 2 3}
%{ x: 1, y: 2 }
@ordered %{ first: 1, second: 2 }
@{:a :b :c}
@sorted-set @{3 1 2}
```

`[...]` is a **list**. `{...}` is a **tuple** — also ordered and
heterogeneous, but conceptually a fixed record rather than a growable
list (an implementation may still store both similarly; the
distinction is about intent). `%{...}` is a **map** — note commas are
fully optional everywhere in DXN, so `%{x: 1, y: 2}` and `%{x: 1 y:
2}` are identical. Plain maps make **no ordering guarantee**, even
though entries sit sequentially in the source text — if order matters,
say so explicitly with `@ordered %{...}`, which makes order part of
the value's identity. `@{...}` is a **set**; `@sorted-set @{...}` is a
set that's always kept sorted.

## 4. Structs — with and without a schema

```
%Point{x: 1, y: 2}
%Point[1, 2]
```

Both are the same struct, written two ways: **keyed** (field names
inline, order doesn't matter) and **positional** (order matters, no
names). A reader that doesn't have a schema for `Point` still parses
this successfully — it just can't fully interpret it, and returns an
opaque tagged value instead of failing. A reader that *does* have a
compiled schema can convert between the keyed and positional forms
freely, validate required/optional fields, and reject data that
doesn't conform. See [the reference](DXN.md#4-schema-documents-dxns)
(or `dextrin`'s own schema tutorial in its main
[tutorial](../TUTORIAL.md)) for how schemas are themselves written —
in DXN, not a separate DSL.

## 5. Temporal types

```
@date "2024-01-01"
@time "12:30:00.5"
@datetime "2024-01-01T12:30:00Z"
@datetime "2024-01-01T14:30:00+02:00"
@local-datetime "2024-01-01T12:30:00"
@duration "P1Y2M10D"
```

Every date and time is an ISO 8601 string under its tag, one way of
writing each: a time keeps up to nine fraction digits (nanoseconds). A
`@datetime` is an instant with its offset -- `Z` for UTC, or `±HH:MM` --
and keeps the offset it was written with; a `@local-datetime` has none,
a wall-clock time that is no instant. `@duration` uses ISO 8601 duration syntax;
note a duration tracks years/months/weeks/days/hours/minutes/seconds
as **independent** fields, since years and months are calendar-relative
(a "month" isn't a fixed number of seconds) and can't be folded into
one elapsed-time number.

## 6. Extended types

```
@uuid "550e8400-e29b-41d4-a716-446655440000"
@uri "https://example.com/path"
@bytes "SGVsbG8="
@regex(i) "^[a-z0-9_]{3,20}$"
```

`@uuid` takes the canonical 36-character hyphenated form. `@uri` is
any RFC 3986 URI, kept as the exact string given. `@bytes` is raw
binary data, base64-encoded in text. `@regex "pattern"` is a regular
expression, PCRE syntax, its flags (`i m s u x f r`) in a header,
`@regex(im) "..."`, or inline in the pattern, `@regex "(?im)..."`. The
pattern is a string, so a backslash in it is doubled: `@regex "\\d+"`.

## 7. Custom tags — the open extension point

```
@my-app/money 500
```

Any `@name` not matching one of the built-ins above (`@uuid`,
`@duration`, `@datetime`, `@bytes`, `@array`, `@ordered`,
`@sorted-set`) is a **custom tag**: a single opaque value wrapped with
an application-defined name. A reader with no decoder registered for
`my-app/money` still parses this fine — it decodes to an opaque
tagged value, the same graceful-degradation contract structs get.
Reserve custom tags for simple scalar-wrapping; prefer a schema-backed
struct for anything with real field structure.

## 8. Discarding a value

```
@_ "this text is parsed but produces nothing"
[1 @_ "skip me" 2 3]
```

`@_` parses the value that follows it (so a malformed discarded value
is still a real parse error, not silently swallowed) and then discards
it entirely — it never appears in the resulting value tree, and has
no binary encoding at all.

## 9. Comments and the optional header

```
# this is a comment, running to end of line
@dxn "1.0"
%{ x: 1 }
```

`#` starts a comment that runs to the end of the line; comments are
fully insignificant, exactly like whitespace, and are gone by the time
a value exists — no reader can recover them after parsing. `@dxn
"1.0"` is an optional header, allowed only as the very first thing in
a document, naming the format version.

## 10. A complete, functional example

Putting all of the above together — a single, realistic document
using nearly every type at once:

```
@dxn "1.0"
%{
  id:      @uuid "550e8400-e29b-41d4-a716-446655440000"
  name:    "Ada Lovelace"
  active:  true
  score:   19.99M
  tags:    @{:admin :staff}
  meta:    @ordered %{created: @datetime "1990-01-01T00:00:00Z"}
  address: %Point[51.05, 13.74]
  result:  {:ok, 200}
  handle:  @regex(i) "^[a-z0-9_]{3,20}$"
}
```

Every field here round-trips losslessly through `.dxnb`, the binary
form — see the [reference](DXN.md) §2 for the full binary type
mapping, and [examples](DXN_EXAMPLES.md)/[cheatsheet](DXN_CHEATSHEET.md)
for more. If you're working in Elixir, `dextrin`'s own
[tutorial](../TUTORIAL.md) picks up exactly here and shows what each
of these types looks like once decoded.
