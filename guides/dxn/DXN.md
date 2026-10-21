# DXN Technical Reference

Implementation-ready grammar and binary encoding for DXN (Data eXchange
Notation), `.dxn` (text) and `.dxnb` (binary). This document is
normative and terse by design. Nothing beyond it should be required to
implement a conforming parser, encoder, or decoder — see the
[DXN tutorial](TUTORIAL.md), [examples](DXN_EXAMPLES.md), and
[cheatsheet](DXN_CHEATSHEET.md) for a gentler introduction, and
`dextrin`'s own module docs for one particular implementation's choices.

This is **format version 1.0**, and it stays 1.0 until the libraries
that implement it reach 1.0.0. Until then the format changes between
releases without a new version number -- Dextrin 0.3 changed `.dxns`
documents (DXNS.md §4: the body lists the fields, `%schema(N)` carries a
version) and added `bits` (§1.3). The `@dxn` header's version is
informational: a reader MUST accept any `1.x` and MAY refuse another
major version. The `.dxnb` envelope's version byte (§2.1) counts major
versions and is `1`.

Grammar is ISO/IEC 14977 EBNF. Reference tables are Markdown tables.

---

## 1. `.dxn` — text format

### 1.1 Lexical grammar

```ebnf
document     = [ header ] , value ;
header       = "@dxn" , ws , string ;

ws           = { " " | "\t" | "\n" | "\r" | "," } ;  (* fully insignificant, everywhere *)
comment      = "#" , { any char except "\n" } ;

digit        = "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" ;
hex_digit    = digit | "a" | "b" | "c" | "d" | "e" | "f" | "A" | "B" | "C" | "D" | "E" | "F" ;
letter       = ? any character with Unicode property XID_Start (UAX #31) ? ;
ident_char   = ? any character with Unicode property XID_Continue (UAX #31) ? | "-" | "?" | "!" ;

identifier   = segments , [ "/" , segments ] ;           (* namespace / name *)
segments     = segment , { "." , segment } ;              (* Foo.Bar.Baz *)
segment      = ( letter | "_" ) , { ident_char } ;
reserved     = "nil" | "true" | "false" | "NaN" | "Infinity" ;

string_char  = ? any character except '"' or "\" ? | escape ;
escape       = "\" , ( '"' | "\" | "n" | "t" | "r" | "0" | "a" | "b" | "f" | "v"
             | ( "x{" , hex_digit , { hex_digit } , "}" ) ) ;
string       = '"' , { string_char } , '"' ;

char_body    = ? any single non-whitespace character ? | escape | "s" (* space, char-literal only *) ;
char         = "?" , char_body ;
```

Reserved leaders — none may begin a bare `identifier`: `#` comment, `@`
tag, `%` map/struct, `?` char, `:` keyword.

### 1.2 Value grammar

```ebnf
value        = { skip } , value_body ;
skip         = comment | discard ;
discard      = "@_" , value ;                      (* parses and discards one value; produces nothing *)

value_body   = nil | boolean | number | string | char | symbol | keyword
             | list | tuple | map_lit | struct_lit | set_lit
             | tag_form ;

nil          = "nil" ;
boolean      = "true" | "false" ;

number       = integer | float | decimal | rational ;
integer      = [ "-" ] , digit , { digit } ;
float        = [ "-" ] , digit , { digit } ,
                 ( ( "." , digit , { digit } , [ exponent ] ) | exponent )
             | "NaN" | "Infinity" | "-Infinity" ;
exponent     = ( "e" | "E" ) , [ "+" | "-" ] , digit , { digit } ;
decimal      = [ "-" ] , digit , { digit } , [ "." , digit , { digit } ] , "M" ;
rational     = [ "-" ] , digit , { digit } , "/" , digit , { digit } ;

symbol       = identifier - reserved ;              (* bare, unevaluated reference *)
keyword      = ":" , ( identifier | string ) ;       (* value position; see map_entry for key position *)

list         = "[" , { value } , "]" ;
tuple        = "{" , { value } , "}" ;
set_lit      = "@{" , { value } , "}" ;

map_lit      = "%{" , { map_entry } , "}" ;
map_entry    = ( identifier , ":" , value )          (* shorthand — plain-atom keys only *)
             | ( value , "=>" , value ) ;             (* arrow — a key type of §1.6 *)

struct_lit   = "%" , identifier , [ "(" , integer , ")" ] ,   (* version, DXNS.md §8 *)
                 ( ( "{" , { map_entry } , "}" )      (* keyed *)
                 | ( "[" , { item } , { map_entry } , "]" ) ) ;   (* positional, then extra fields *)
item         = value ;                                (* a value not followed by "=>" (DXNS.md §7) *)

tag_form     = "@" , identifier , [ "(" , regex_flags , ")" ] , value ;
                                                      (* built-in tag name -> §1.3; else custom *)
regex_flags  = ( "i" | "m" | "s" | "u" | "x" | "f" | "r" ) ,
               { "i" | "m" | "s" | "u" | "x" | "f" | "r" } ;   (* @regex only, §1.3 *)
```

**One way to write a value** (Jan, 2026-10-20): every type that is not
a number, string, char, symbol, keyword or collection is a tag, `@name
value` -- dates and times among them. DXN 0.2 wrote dates, times, UTC
timestamps and regexes as sigils, `~D[...]`, `~T[...]`, `~U[...]` and
`~r/.../`; those are gone, and a reader refuses them (`syntax`).

**Dates and times are ISO 8601 strings** under their tag:

```text
@date "2026-10-20"
@time "14:30:00.123456789"
@datetime "2026-10-20T14:30:00Z"          # UTC
@datetime "2026-10-20T16:30:00+02:00"     # the same instant, written with its offset
@local-datetime "2026-10-20T14:30:00"     # a wall-clock time, no offset
@duration "PT1H30M"
```

A time takes up to nine fraction digits: nanoseconds. A `datetime` has
an offset, `Z` or `±HH:MM`; `Z` is `+00:00`, and `-00:00` ("offset
unknown") is refused -- a value with no offset is a `local-datetime`. A
string that is not the form its tag names is `syntax`.

**`@objectid` and `@ip` are built in** (Jan, 2026-10-20), like `@uuid`:
readable in text, raw bytes in `.dxnb`. An ObjectId is BSON's 12 bytes,
written as 24 hex digits, either case read, lowercase written. An `@ip`
is an IPv4 or IPv6 address, or a prefix with its length; a prefix whose
host bits are not zero (`10.0.0.1/8`) is `syntax`, as RFC 9164 asks.

**A regex is its pattern as a string**, its flags in a header against
the tag: `@regex(im) "^\\d+$"`. PCRE's own inline modifiers are part of
the pattern and need no header: `@regex "(?im)^\\d+$"` matches what the
first does, and is a different value (its pattern differs). A pattern is
an ordinary string, so a backslash in it is written `\\`. A header on
any tag but `regex` is `syntax`, and so is a flag given twice.

**A pattern that PCRE does not compile is `syntax`** (Jan, 2026-10-21):
`@regex "a("` is no regex. An implementation without a PCRE engine
cannot tell every pattern apart, and says so: the Node implementation
reads any pattern, since JavaScript's own engine refuses valid PCRE --
inline modifiers such as `(?im)`, atomic groups, `\\A` -- and so cannot
stand in for it. That is a documented limit of the platform, not of DXN.

Tag resolution: an `identifier` immediately following `@` is matched
against the built-in tag table (§1.3) first; any name not found there is
a **custom tag** — parses identically (`@tag value`), decodes to an
application-defined type via a registered decoder, per §2 goal 4 of the
design log.

Whitespace between a tag and its value is allowed and means nothing:
`@array[1 2]` and `@array [1 2]` are the same array. **`@array[`, the
bracket against the tag, is the preferred spelling** (Jan, 2026-10-20),
and the one every writer produces; every other tag is written with one
space before its value (`@ordered %{...}`, `@uuid "..."`).

### 1.3 Type reference

| Type | Category | DXN syntax | Notes |
|---|---|---|---|
| `nil` | scalar | `nil` |  |
| `boolean` | scalar | `true \| false` |  |
| `integer` | scalar | `-?[0-9]+` | arbitrary precision |
| `float` | scalar | `-?[0-9]+(.[0-9]+)?([eE][+-]?[0-9]+)? \| NaN \| Infinity \| -Infinity` | IEEE 754 double |
| `decimal` | scalar | `[0-9]+(.[0-9]+)?M` | exact fixed-point |
| `rational` | scalar | `int/uint` | exact ratio |
| `string` | scalar | `"..."` | UTF-8 |
| `char` | scalar | `?c` | Unicode codepoint |
| `symbol` | scalar | `bare identifier` | unevaluated reference, e.g. type name |
| `keyword` | scalar | `:name \| :"..." \| name: (key pos.)` | Elixir atom |
| `list` | collection | `[ ... ]` |  |
| `tuple` | collection | `{ ... }` |  |
| `map` | collection | `%{ ... }` | no ordering guarantee |
| `ordered-map` | collection | `@ordered %{ ... }` | order is part of value identity |
| `set` | collection | `@{ ... }` |  |
| `sorted-set` | collection | `@sorted-set @{ ... }` |  |
| `struct-keyed` | collection | `%Name{ ... }` | requires schema to fully interpret |
| `struct-positional` | collection | `%Name[ ... ]` | field order per schema; both struct forms parse equal |
| `array` | collection | `@array[ ... ]` | fixed-size/indexed |
| `date` | temporal | `@date "YYYY-MM-DD"` | ISO 8601 |
| `time` | temporal | `@time "HH:MM:SS(.f{1,9})?"` | ISO 8601, nanoseconds |
| `datetime` | temporal | `@datetime "YYYY-MM-DDTHH:MM:SS(.f{1,9})?(Z\|±HH:MM)"` | ISO 8601, an instant with its offset; Z is UTC |
| `local-datetime` | temporal | `@local-datetime "YYYY-MM-DDTHH:MM:SS(.f{1,9})?"` | ISO 8601, no offset: a wall-clock time |
| `duration` | temporal | `@duration "P..."` | ISO 8601 duration, nanoseconds |
| `uuid` | extended | `@uuid "..."` | RFC 4122 |
| `objectid` | extended | `@objectid "<24 hex digits>"` | BSON's ObjectId: 12 bytes |
| `ip` | extended | `@ip "192.0.2.1" \| "10.0.0.0/8" \| "2001:db8::1" \| "2001:db8::/32"` | an IPv4 or IPv6 address, or a prefix (RFC 9164) |
| `uri` | extended | `@uri "..."` | RFC 3986 |
| `bytes` | extended | `@bytes "..."` | base64 |
| `bits` | extended | `@bits {"..." n}` | base64 and a bit count: a run of bits that is not whole bytes |
| `regex` | extended | `@regex "pattern" \| @regex(flags) "pattern"` | PCRE-style via Erlang :re |
| `custom-tag` | extended | `@tag value` | open extension point, any unrecognized tag name |
| `header` | meta | `@dxn "1.0"` | optional, first form only; the format version (see the introduction) |

### 1.4 Semantic notes not expressible in grammar alone

- **Map key equality/ordering.** `%{ }` makes no ordering guarantee even
  though entries are physically sequential in source text; `@ordered %{ }`
  makes ordering part of the value's identity. This is a semantic
  distinction, not a syntactic one.
- **Struct interpretation requires a schema.** Both struct forms parse
  without one; a reader lacking the schema for a given type name returns
  an opaque tagged value rather than failing.
- **`@_` (discard)** is resolved during parsing — it never appears in a
  parsed value tree, and has no `.dxnb` encoding (§2.1).
- **`NaN` has no sign variant.** `-NaN` is not valid; IEEE 754's NaN sign
  bit has no meaningful, observable use here.
- **Duration is not reducible to a single elapsed-time scalar** — `years`
  and `months` are calendar-relative (variable length), so they, along
  with weeks/days/hours/minutes/seconds, are tracked as independent
  fields (see §2.3 for the exact field set, shared with `.dxnb`).
- **`bits` and `bytes` are one value space.** A run of bits whose count
  is a multiple of 8 *is* bytes: `@bits {"AQID" 24}` reads as
  `@bytes "AQID"`, and a writer writes it so. In `@bits {data n}`, `n`
  is a non-negative integer and `data` holds exactly the bytes `n` needs
  (`ceil(n / 8)`); the bits run from the high bit of the first byte, and
  a reader MUST refuse (`syntax`, or `binary` for `T_BITS`) a count the
  data does not match. The unused low bits of the last byte are written
  zero and ignored when read. A language with no bitstring type holds
  bits in a value of its own (bytes and a count).

### 1.5 Canonical form

Every value has exactly one **canonical form**: a `.dxn` rendering
fixed down to the byte, so that two implementations' values can be
compared as text, and so that map-key identity (§1.6) has one
definition. A conforming implementation MUST be able to produce it.
Parsing a value's canonical form yields an equal value.

General rules:

- No header, no comments, no `@_`.
- Exactly one space between consecutive items or entries; nothing after
  an opening or before a closing bracket; no commas, no newlines.
- **Canonical order** compares the canonical forms of two values by
  Unicode code point, first difference wins, a proper prefix sorts
  first. (UTF-8 byte order is the same order; UTF-16 code-unit order is
  not.)

Per type:

| Type | Form |
|---|---|
| `nil` | nil |
| `boolean` | true \| false |
| `integer` | optional -, then decimal digits without leading zeros |
| `float` | see the float rules below |
| `decimal` | as given: the coefficient with exactly scale fractional digits and its sign, negative zero included, then M; a positive exponent, which text cannot write, is written out with zeros |
| `rational` | numerator/denominator as held, not reduced; the sign on the numerator, the denominator positive |
| `string` | see the string rules below |
| `char` | ? then the character; ?s for space; \\ escape forms for \\, whitespace and control characters |
| `symbol` | the identifier |
| `keyword` | :name when name is an identifier and not reserved, else :"..." with string escaping |
| `list` | [ items ] |
| `tuple` | { items } |
| `array` | @array[ items ] |
| `map` | %{ entries } in canonical order of their keys |
| `ordered-map` | @ordered %{ entries } in held order |
| `set` | @{ items } in canonical order |
| `sorted-set` | @sorted-set @{ items } in canonical order |
| `struct` | %Name(N){ entries } keyed, or %Name(N)[ items ] positional, as held; (N) when the version is known; keyed entries in held order, since in a %schema body the order is the field order |
| `map entry` | name: value when the key is a keyword whose name is an identifier and not reserved, else key => value |
| `date` | @date "YYYY-MM-DD" |
| `time` | @time "HH:MM:SS" then .fraction with trailing zeros removed, omitted when zero |
| `datetime` | @datetime "YYYY-MM-DDTHH:MM:SS" with the fraction as for time, then Z when the offset is zero, else ±HH:MM |
| `local-datetime` | @local-datetime "YYYY-MM-DDTHH:MM:SS" with the fraction as for time |
| `duration` | @duration "P..." with fields in the order of §2.3, zero fields omitted, PT0S when all are zero |
| `uuid` | @uuid "8-4-4-4-12" in lowercase hex |
| `objectid` | @objectid "..." in 24 lowercase hex digits |
| `ip` | @ip "...": IPv4 in dotted decimal, IPv6 as RFC 5952 writes it (lowercase, the longest run of zero groups as ::), then /length for a prefix |
| `uri` | @uri "..." as held, with string escaping |
| `bytes` | @bytes "..." in standard base64 with padding |
| `bits` | @bits {"..." n}: the bits in standard base64 with padding, the unused low bits of the last byte zero, and n their count; a run of whole bytes is bytes |
| `regex` | @regex "pattern" with string escaping, or @regex(flags) "pattern" with the flags in the order of §2.3 |
| `custom-tag` | @name value |
| `extra fields` | in a keyed struct, entries after the declared fields in held order; in a positional struct, entries after the items, in canonical order of their keys (DXNS.md §7) |

**Nothing is normalised.** A value is written as it was given: `1.50M`
stays `1.50M` (and `[-2, 150]` in `.dxnb`), `2/4` stays `2/4`. A
language whose own numbers normalise holds such a value in a type that
does not.

**Floats.** Take the shortest decimal digit string *d₁…dₖ* that reads
back as exactly the same IEEE 754 double, and its exponent *n* such
that the value is 0.*d₁…dₖ* × 10ⁿ. Then:

- if *k* ≤ *n* ≤ 21: the digits, *n* − *k* zeros, then `.0`
  (`100.0`, `123456789012345680000.0`);
- if 0 < *n* < *k*: the digits with a `.` after the *n*th
  (`1.5`, `123.456`);
- if −6 < *n* ≤ 0: `0.`, −*n* zeros, then the digits (`0.1`, `0.000001`);
- otherwise: *d₁*, `.`, then *d₂…dₖ* or `0` when *k* = 1, then `e`, then
  *n* − 1, with a `-` only when negative (`1.0e21`, `1.5e-7`,
  `2.5e300`);
- a negative value gets a leading `-`, **including negative zero**
  (`-0.0`);
- `NaN`, `Infinity`, `-Infinity` as written.

These are ECMAScript's `Number.prototype.toString` thresholds, with
`.0` added to whole numbers and no `+` in exponents.

**Strings.** `"`, then each code point: `"` as `\"`, `\` as `\\`,
U+000A as `\n`, U+0009 as `\t`, U+000D as `\r`, every other code point
below U+0020 and U+007F as `\x{…}` in lowercase hex without leading
zeros, everything else literally; then `"`.

### 1.6 Map keys

A map key, and the key of a struct's extra field (DXNS.md §7), MUST be one of
`string`, `keyword`, `integer`, `uuid`, `objectid`, `date`, `bytes`,
`symbol`, `char`. Any other key is an error (`key/not-allowed`, §5), in text, in
binary and when encoding.

Two keys are the same key exactly when their canonical forms (§1.5) are
equal: same type, same value, no normalization. So `1` and `"1"` are
different keys, as are `:x` and `"x"`. A key that occurs twice in one
map keeps its last value.

The allowed types are those whose identity is exact and obvious in
every language. Excluded, and why:

- `float`, `decimal`, `rational`: `1` and `1.0`, `0.0` and `-0.0`,
  `NaN`, `1.0M` and `1.00M`, `2/4` and `1/2` are distinct DXN values
  that some languages hold as one, and the BEAM has no `NaN` or
  infinities.
- `time`, `datetime`, `local-datetime`, `duration`, `uri`: precision,
  offsets, `P1D` against `PT24H`, URI normalization.
- `nil` and `boolean`: they collide with other keys in some languages
  (in PHP, `nil` with `""` and `true` with `1` as array keys), and they
  are rare as keys anyway.
- `regex`, custom tags, and every collection.

---

## 2. `.dxnb` — binary format

Built on CBOR (RFC 8949). Every `.dxnb` value is a self-describing CBOR
item; DXN types not covered by a standard CBOR major type use a CBOR tag
(standard where one is registered, DXN-private otherwise — §2.3).

### 2.1 Envelope

```ebnf
dxnb_file    = magic , version , cbor_item ;
magic        = %x44 %x58 ;                          (* "DX" *)
version      = %x01 ;                                (* format major version, currently 1 *)
```

Mandatory (unlike the optional text header) — fixed 3-byte cost
regardless of document size, and binary tooling depends on magic-number
sniffing far more than text tooling does. No end-of-document marker
needed; a CBOR item is self-delimiting.

Structs are **always positional** in `.dxnb` (§1.3's keyed form exists
only for human readability, which doesn't apply to raw bytes) — one wire
shape per struct value, `[type-name-or-ref, field-1, field-2, ...]`.

`@_` (discard) and `#` comments have no binary encoding — both are
resolved away before a value exists to encode.

### 2.2 Type mapping

**Every value takes the smallest representation that keeps it exactly**
(Jan, 2026-10-20): raw bytes where a type is bytes at heart (a uuid, an
ObjectId, an IP address), integers where it is a count (dates, times,
durations), CBOR's shortest integer and length forms everywhere, and
never the text form a value has in `.dxn`.

| Type | CBOR major type or tag | Payload | Integrity note |
|---|---|---|---|
| `nil` | simple(22) |  |  |
| `boolean` | simple(20/21) |  | false/true |
| `integer` | major0/1; tag2/3 | two's complement bignum bytes past 64-bit | arbitrary precision preserved exactly |
| `float` | major7 | IEEE 754: the shortest of half, single and double that holds the value exactly | NaN/Infinity encode natively in half precision, no tag needed; a reader reads all three widths |
| `decimal` | tag4 | [exponent,mantissa] | a negative zero has no mantissa of its own: `-0.0M` is written as `0.0M`, the one value `.dxnb` does not keep (text does, §1.5) |
| `rational` | tag30 | [numerator,denominator] |  |
| `string` | major3 (untagged) | UTF-8 bytes | default/untagged case |
| `char` | tag T_CHAR | major0 codepoint |  |
| `symbol` | tag T_SYMBOL | major3 text |  |
| `keyword` | tag T_KEYWORD | major3 text |  |
| `list` | major4 (untagged) | items | default/untagged case |
| `tuple` | tag T_TUPLE | major4 items |  |
| `map` | major5 (untagged) | pairs | default/untagged case |
| `ordered-map` | tag T_ORDERED | major5 pairs | order preserved by tag presence, not byte sequence |
| `set` | tag T_SET | major4 items |  |
| `sorted-set` | tag T_SORTED_SET | major4 items, in canonical order (§1.5) |  |
| `struct` | tag T_STRUCT | [type-name-or-ref, field..., extras?] | positional only, §2.1; the type name carries the version, `User(3)` (DXNS.md §8); extra fields, when there are any, as one trailing `T_EXTRA` map (DXNS.md §7) |
| `array` | tag T_ARRAY | major4 items |  |
| `date` | tag T_DATE | integer days since 1970-01-01 | Unix epoch, day granularity |
| `time` | tag T_TIME (218) | integer nanoseconds since midnight | 0.2's T_TIME_US (210), microseconds, is read, never written |
| `datetime` | tag T_DATETIME (219) | epoch-nanoseconds int in UTC, else [epoch-nanoseconds int, offset-minutes] | integers only -- a float loses nanoseconds at scale. 0.2's tag 1 (UTC, epoch microseconds) and T_DATETIME_US (211, [epoch-us, offset-min]) are read, never written |
| `local-datetime` | tag T_LOCAL_DATETIME | integer nanoseconds since 1970-01-01T00:00:00 on the wall clock | no offset, so no instant |
| `duration` | tag T_DURATION (220) | bitmask byte + present fields, §2.3 | 0.2's T_DURATION_US (212), its seventh field microseconds, is read, never written |
| `uuid` | tag37 | 16 raw bytes | not the 36-char text form |
| `objectid` | tag T_OBJECTID | 12 raw bytes | not the 24-char text form |
| `ip` | tag52 (IPv4) \| tag54 (IPv6), RFC 9164 | an address: its raw bytes; a prefix: [length, the bytes with trailing zero bytes left off] | host bits of a prefix are zero, or it is refused |
| `uri` | tag32 | major3 text |  |
| `bytes` | major2 | raw bytes | no base64 in binary |
| `bits` | tag T_BITS | [major2 bytes, bit count] | the unused low bits of the last byte are zero; a run of whole bytes is bytes, never T_BITS |
| `regex` | tag T_REGEX | pattern text with no flags, else [pattern text, flags byte] | flags bit layout in §2.3 |
| `custom-tag` | tag T_CUSTOM | [tag-name-or-ref, value] | binary form of the open extension point |
| `header` | envelope, §2.1 | magic+version bytes | not a CBOR item; metadata, not data |

### 2.3 Private tag assignments and bit layouts

| Name | Number | Wraps |
|---|---|---|
| `T_CHAR` | 200 | integer codepoint |
| `T_SYMBOL` | 201 | text string |
| `T_KEYWORD` | 202 | text string |
| `T_TUPLE` | 203 | array |
| `T_ARRAY` | 204 | array |
| `T_ORDERED` | 205 | map |
| `T_SET` | 206 | array |
| `T_SORTED_SET` | 207 | array |
| `T_STRUCT` | 208 | array: [type-ref, field...] |
| `T_DATE` | 209 | integer |
| `T_TIME_US` | 210 | integer: DXN 0.2's microseconds since midnight; read, never written |
| `T_DATETIME_US` | 211 | array: [epoch-us, offset-min], DXN 0.2's; read, never written |
| `T_DURATION_US` | 212 | bitmask byte + fields, the seventh microseconds, DXN 0.2's; read, never written |
| `T_REGEX` | 213 | text: the pattern, with no flags; else array: [pattern, flags-byte] |
| `T_CUSTOM` | 214 | array: [tag-ref, value] |
| `T_EXTRA` | 215 | map: {key: value, ...} — a struct's extra fields, only ever its last item (DXNS.md §7) |
| `T_BITS` | 216 | array: [bytes, bit-count] — a run of bits that is not whole bytes (§1.3) |
| `T_LOCAL_DATETIME` | 217 | integer: nanoseconds since 1970-01-01T00:00:00, wall clock |
| `T_TIME` | 218 | integer: nanoseconds since midnight |
| `T_DATETIME` | 219 | integer: epoch-ns, in UTC; else array: [epoch-ns, offset-min] |
| `T_DURATION` | 220 | bitmask byte + fields, the seventh nanoseconds |
| `T_OBJECTID` | 221 | byte string: BSON's 12-byte ObjectId |

**A tag never changes its meaning** (2026-10-20): when DXN's times went
from microseconds to nanoseconds, the nanosecond forms took new tags,
and a reader still reads the old ones as what they meant -- a
document DXN 0.2 wrote is not misread, and nothing writes them again.

Allocated from CBOR's one-extra-byte tag range (24–255), placed at
200–221 specifically to stay clear of the actively-managed low range
(0–40 has multiple assignments and gaps IANA could fill later). Not
IANA-registered — collision-free only within `dextrin`-produced documents;
register formally before any non-`dextrin` interop is expected.

**Duration bitmask** (`T_DURATION` payload) — one byte, low bit first;
each set bit is followed, in bit order, by that field's value as a signed
integer:

| Bit | Field | Unit |
|---|---|---|
| 0 | `years` | count |
| 1 | `months` | count |
| 2 | `weeks` | count |
| 3 | `days` | count |
| 4 | `hours` | count |
| 5 | `minutes` | count |
| 6 | `nanoseconds` | count (fractional seconds folded in, matching time and datetime precision) |

Bit 7 is reserved (must be 0).

**Regex flags byte** (`T_REGEX` payload, second element) — one byte, low
bit first, each bit a boolean modifier matching Erlang `:re`/Elixir
`Regex` semantics:

| Bit | Flag | Meaning |
|---|---|---|
| 0 | `i` | caseless |
| 1 | `m` | multiline |
| 2 | `s` | dotall |
| 3 | `u` | unicode |
| 4 | `x` | extended |
| 5 | `f` | firstline |
| 6 | `r` | ungreedy |

Bit 7 is reserved (must be 0).

### 2.4 Value sharing (repeated symbols, keywords, struct type names)

Use CBOR's registered string-reference extension: tag 256 marks the
enclosing scope as using shared references, tag 25 references the *n*th
previously-seen string within it. Apply to repeated `T_SYMBOL`/
`T_KEYWORD` text and struct type names; leave one-off values inline. Not
required for a conforming decoder to produce, but a conforming decoder
MUST accept it.

### 2.5 Value sharing (arbitrary repeated values)

Same motivation as §2.4, generalized from text to *any* `.dxnb` item —
a repeated `map`/`list`/`struct`/etc. subtree, not just repeated
symbol/keyword text. Uses CBOR tags 28 (mark the following item as
shareable) and 29 (reference the *n*th previously tag-28-marked item,
0-indexed across the whole document). An encoder MAY wrap a repeated
subtree's first occurrence in tag 28 and encode every later occurrence
as a bare tag-29 index instead of repeating its bytes.

This is a size optimization only, never an identity/aliasing feature:

- A decoder MUST resolve every tag-29 reference to an independent copy
  of the tag-28-marked value it points to. The decoded result MUST be
  indistinguishable from a document that wrote every occurrence out in
  full — no decoder-visible aliasing, no shared mutable identity.
- A tag-29 index that refers to a not-yet-seen tag-28 item, or that
  would create a cycle (directly or through nested references), is
  malformed; a decoder MUST reject it rather than attempt to represent
  a graph. `.dxnb` values are trees, always — §2.5 shortens the
  encoding of a tree with repeated subtrees, it does not turn the
  format into one that can express sharing as observable structure.

Not required for a conforming encoder to produce; a conforming decoder
MUST accept it. Tags 28/29 do not collide with the private range in
§2.3 (200–221) or with §2.4's tags (256, 25) — confirm both against
the current IANA CBOR tags registry before final implementation, as
with any tag number cited normatively here.

---

## 3. Worked example

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

Every construct above is fully specified by §1.2 + §1.3; every field
round-trips through §2 without loss (§2.2's `integrity_note` column
records the two places — bignum and datetime precision — where that
took a specific encoding choice to guarantee, and the one value that
does not: a negative-zero decimal, which `.dxnb` writes as positive
zero).

---

## 4. Schema documents (`.dxns`)

The schema language, DXNS, has its own reference:
[DXNS.md](../dxns/DXNS.md). Its sections 1 to 8 were this section's 4.1
to 4.8, and "DXNS.md §2" is the old "DXNS.md §2".

---

## 5. Errors

Implementations report errors in their own way (DXNS.md §7), but every error
a conforming reader, writer or schema compiler raises belongs to
exactly one **category**, and an implementation MUST expose it on the
error value. Categories are compared exactly; messages are not
normative.

| Category | Raised when |
|---|---|
| `syntax` | text does not parse |
| `binary` | a .dxnb document is malformed: magic, version, a tag's payload |
| `key/not-allowed` | a map or extra-field key has a type §1.6 does not allow |
| `encode/unsupported` | a host value has no DXN meaning, or no form in the text being written -- a symbol whose name is not an identifier |
| `schema/compile` | a .dxns document is not a valid schema |
| `schema/duplicate-version` | a (name, version) is loaded twice |
| `schema/not-loaded` | a replace names a (name, version) that is not loaded |
| `schema/unknown-version` | a struct's version is older than the latest loaded and not loaded itself |
| `schema/no-materializer` | an older version arrives and no materializer is registered |
| `schema/field-count` | a positional struct's item count differs from its own version's field count |
| `schema/missing-field` | a required field is absent, or a positional form has no value for an optional field without a default (DXNS.md §3) |
| `schema/type-mismatch` | a field's value does not match its declared type |
| `schema/undeclared-field` | a strict decode meets a field the schema does not declare |
| `schema/shadowed-field` | an extra field has the name of a declared field |
| `schema/materializer` | a materializer answers an error, or a value the latest schema rejects |
| `schema/version-discipline` | the compatibility check: changed content under the same version, or a version going down |
| `document/not-found` | an edit to a document (a reader that keeps comments) names a path that is not there |
| `document/exists` | an insert names a key the map already has |
| `document/ambiguous` | an update finds a deleted item followed by an inserted one -- a replace, or the two -- and its setting refuses to choose: always, or where the deleted item owns a comment |
| `document/not-a-collection` | an edit's path goes into a value that holds no entries |

## 6. Media types and identification

How a program that receives a body or meets a file names DXN's three
forms, and decides cheaply whether a body is worth decoding as one. A
reader MAY offer this; one that does answers as below, so every
implementation sniffs the same way.

| Form | Media type | Extension |
|---|---|---|
| text | `application/vnd.dxn` | `.dxn` |
| binary | `application/vnd.dxnb` | `.dxnb` |
| schema | `application/vnd.dxns` | `.dxns` |

**A media type names its form.** The three above name theirs, and any
media type with a structured `+dxn` suffix (`application/vnd.acme.event+dxn`)
names text: a document in DXN text whose vocabulary is the type's own.
There is no `+dxnb` suffix. Media types compare without regard to case;
parameters (`; charset=...`) are not part of the type, and whoever reads
the type strips them first. Anything else names no form.

**Identification is a prefix test, not a parse**: *yes* means the body
is worth decoding as the form, never that it decodes.

- **Binary**: the envelope's magic, `DX`, followed by a version byte
  (§2.1). Whether the version is one the reader supports is decoding's
  business.
- **Text and schemas**: skip whitespace (`ws`, commas included), `#`
  comments, and an optional header (`@dxn "..."`, with any whitespace
  and comments around it); then the first character is `%` -- a map
  (`%{`), a struct (`%Name{`, `%ns/Name[`, `%Name(2){`) or a schema
  document. Every other body is not identified, **lists and scalars
  included**: they are DXN, but `[`, `"`, digits, `true` and the rest
  begin JSON just as well, and telling DXN from JSON in a body that came
  without a type is what this test is mostly for.
