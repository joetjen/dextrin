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
documents (§4.4: the body lists the fields, `%schema(N)` carries a
version) and added `bits` (§1.3). The `@dxn` header's version is
informational: a reader MUST accept any `1.x` and MAY refuse another
major version. The `.dxnb` envelope's version byte (§2.1) counts major
versions and is `1`.

Grammar is ISO/IEC 14977 EBNF. Reference tables are [TOON](https://toon.sh)
(`name[N]{fields}:` header, one comma-separated row per record) for
token-efficient machine parsing; a cell containing a comma or quote is
wrapped in `"..."` with internal `"` doubled, same as CSV.

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

struct_lit   = "%" , identifier , [ "(" , integer , ")" ] ,   (* version, §4.8 *)
                 ( ( "{" , { map_entry } , "}" )      (* keyed *)
                 | ( "[" , { item } , { map_entry } , "]" ) ) ;   (* positional, then extra fields *)
item         = value ;                                (* a value not followed by "=>" (§4.7) *)

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

```toon
types[33]{type,category,dxn_syntax,notes}:
  nil,scalar,nil,""
  boolean,scalar,"true | false",""
  integer,scalar,"-?[0-9]+","arbitrary precision"
  float,scalar,"-?[0-9]+(.[0-9]+)?([eE][+-]?[0-9]+)? | NaN | Infinity | -Infinity","IEEE 754 double"
  decimal,scalar,"[0-9]+(.[0-9]+)?M","exact fixed-point"
  rational,scalar,"int/uint","exact ratio"
  string,scalar,"""...""","UTF-8"
  char,scalar,"?c","Unicode codepoint"
  symbol,scalar,"bare identifier","unevaluated reference, e.g. type name"
  keyword,scalar,":name | :""..."" | name: (key pos.)","Elixir atom"
  list,collection,"[ ... ]",""
  tuple,collection,"{ ... }",""
  map,collection,"%{ ... }","no ordering guarantee"
  ordered-map,collection,"@ordered %{ ... }","order is part of value identity"
  set,collection,"@{ ... }",""
  sorted-set,collection,"@sorted-set @{ ... }",""
  struct-keyed,collection,"%Name{ ... }","requires schema to fully interpret"
  struct-positional,collection,"%Name[ ... ]","field order per schema; both struct forms parse equal"
  array,collection,"@array[ ... ]","fixed-size/indexed"
  date,temporal,"@date ""YYYY-MM-DD""","ISO 8601"
  time,temporal,"@time ""HH:MM:SS(.f{1,9})?""","ISO 8601, nanoseconds"
  datetime,temporal,"@datetime ""YYYY-MM-DDTHH:MM:SS(.f{1,9})?(Z|±HH:MM)""","ISO 8601, an instant with its offset; Z is UTC"
  local-datetime,temporal,"@local-datetime ""YYYY-MM-DDTHH:MM:SS(.f{1,9})?""","ISO 8601, no offset: a wall-clock time"
  duration,temporal,"@duration ""P...""","ISO 8601 duration, nanoseconds"
  uuid,extended,"@uuid ""...""","RFC 4122"
  objectid,extended,"@objectid ""<24 hex digits>""","BSON's ObjectId: 12 bytes"
  ip,extended,"@ip ""192.0.2.1"" | ""10.0.0.0/8"" | ""2001:db8::1"" | ""2001:db8::/32""","an IPv4 or IPv6 address, or a prefix (RFC 9164)"
  uri,extended,"@uri ""...""","RFC 3986"
  bytes,extended,"@bytes ""...""","base64"
  bits,extended,"@bits {""..."" n}","base64 and a bit count: a run of bits that is not whole bytes"
  regex,extended,"@regex ""pattern"" | @regex(flags) ""pattern""","PCRE-style via Erlang :re"
  custom-tag,extended,"@tag value","open extension point, any unrecognized tag name"
  header,meta,"@dxn ""1.0""","optional, first form only; the format version (see the introduction)"
```

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

```toon
canonical[32]{type,form}:
  nil,"nil"
  boolean,"true | false"
  integer,"optional -, then decimal digits without leading zeros"
  float,"see the float rules below"
  decimal,"as given: the coefficient with exactly scale fractional digits and its sign, negative zero included, then M; a positive exponent, which text cannot write, is written out with zeros"
  rational,"numerator/denominator as held, not reduced; the sign on the numerator, the denominator positive"
  string,"see the string rules below"
  char,"? then the character; ?s for space; \\ escape forms for \\, whitespace and control characters"
  symbol,"the identifier"
  keyword,":name when name is an identifier and not reserved, else :""..."" with string escaping"
  list,"[ items ]"
  tuple,"{ items }"
  array,"@array[ items ]"
  map,"%{ entries } in canonical order of their keys"
  ordered-map,"@ordered %{ entries } in held order"
  set,"@{ items } in canonical order"
  sorted-set,"@sorted-set @{ items } in canonical order"
  struct,"%Name(N){ entries } keyed, or %Name(N)[ items ] positional, as held; (N) when the version is known; keyed entries in held order, since in a %schema body the order is the field order"
  map entry,"name: value when the key is a keyword whose name is an identifier and not reserved, else key => value"
  date,"@date ""YYYY-MM-DD"""
  time,"@time ""HH:MM:SS"" then .fraction with trailing zeros removed, omitted when zero"
  datetime,"@datetime ""YYYY-MM-DDTHH:MM:SS"" with the fraction as for time, then Z when the offset is zero, else ±HH:MM"
  local-datetime,"@local-datetime ""YYYY-MM-DDTHH:MM:SS"" with the fraction as for time"
  duration,"@duration ""P..."" with fields in the order of §2.3, zero fields omitted, PT0S when all are zero"
  uuid,"@uuid ""8-4-4-4-12"" in lowercase hex"
  objectid,"@objectid ""..."" in 24 lowercase hex digits"
  ip,"@ip ""..."": IPv4 in dotted decimal, IPv6 as RFC 5952 writes it (lowercase, the longest run of zero groups as ::), then /length for a prefix"
  uri,"@uri ""..."" as held, with string escaping"
  bytes,"@bytes ""..."" in standard base64 with padding"
  bits,"@bits {""..."" n}: the bits in standard base64 with padding, the unused low bits of the last byte zero, and n their count; a run of whole bytes is bytes"
  regex,"@regex ""pattern"" with string escaping, or @regex(flags) ""pattern"" with the flags in the order of §2.3"
  custom-tag,"@name value"
  extra fields,"in a keyed struct, entries after the declared fields in held order; in a positional struct, entries after the items, in canonical order of their keys (§4.7)"
```

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

A map key, and the key of a struct's extra field (§4.7), MUST be one of
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

```toon
cbor_map[32]{type,cbor_major_or_tag,payload,integrity_note}:
  nil,"simple(22)","",""
  boolean,"simple(20/21)","","false/true"
  integer,"major0/1; tag2/3","two's complement bignum bytes past 64-bit","arbitrary precision preserved exactly"
  float,"major7","IEEE 754: the shortest of half, single and double that holds the value exactly","NaN/Infinity encode natively in half precision, no tag needed; a reader reads all three widths"
  decimal,"tag4","[exponent,mantissa]","a negative zero has no mantissa of its own: `-0.0M` is written as `0.0M`, the one value `.dxnb` does not keep (text does, §1.5)"
  rational,"tag30","[numerator,denominator]",""
  string,"major3 (untagged)","UTF-8 bytes","default/untagged case"
  char,"tag T_CHAR","major0 codepoint",""
  symbol,"tag T_SYMBOL","major3 text",""
  keyword,"tag T_KEYWORD","major3 text",""
  list,"major4 (untagged)","items","default/untagged case"
  tuple,"tag T_TUPLE","major4 items",""
  map,"major5 (untagged)","pairs","default/untagged case"
  ordered-map,"tag T_ORDERED","major5 pairs","order preserved by tag presence, not byte sequence"
  set,"tag T_SET","major4 items",""
  sorted-set,"tag T_SORTED_SET","major4 items, in canonical order (§1.5)",""
  struct,"tag T_STRUCT","[type-name-or-ref, field..., extras?]","positional only, §2.1; the type name carries the version, `User(3)` (§4.8); extra fields, when there are any, as one trailing `T_EXTRA` map (§4.7)"
  array,"tag T_ARRAY","major4 items",""
  date,"tag T_DATE","integer days since 1970-01-01","Unix epoch, day granularity"
  time,"tag T_TIME (218)","integer nanoseconds since midnight","0.2's T_TIME_US (210), microseconds, is read, never written"
  datetime,"tag T_DATETIME (219)","epoch-nanoseconds int in UTC, else [epoch-nanoseconds int, offset-minutes]","integers only -- a float loses nanoseconds at scale. 0.2's tag 1 (UTC, epoch microseconds) and T_DATETIME_US (211, [epoch-us, offset-min]) are read, never written"
  local-datetime,"tag T_LOCAL_DATETIME","integer nanoseconds since 1970-01-01T00:00:00 on the wall clock","no offset, so no instant"
  duration,"tag T_DURATION (220)","bitmask byte + present fields, §2.3","0.2's T_DURATION_US (212), its seventh field microseconds, is read, never written"
  uuid,"tag37","16 raw bytes","not the 36-char text form"
  objectid,"tag T_OBJECTID","12 raw bytes","not the 24-char text form"
  ip,"tag52 (IPv4) | tag54 (IPv6), RFC 9164","an address: its raw bytes; a prefix: [length, the bytes with trailing zero bytes left off]","host bits of a prefix are zero, or it is refused"
  uri,"tag32","major3 text",""
  bytes,"major2","raw bytes","no base64 in binary"
  bits,"tag T_BITS","[major2 bytes, bit count]","the unused low bits of the last byte are zero; a run of whole bytes is bytes, never T_BITS"
  regex,"tag T_REGEX","pattern text with no flags, else [pattern text, flags byte]","flags bit layout in §2.3"
  custom-tag,"tag T_CUSTOM","[tag-name-or-ref, value]","binary form of the open extension point"
  header,"envelope, §2.1","magic+version bytes","not a CBOR item; metadata, not data"
```

### 2.3 Private tag assignments and bit layouts

```toon
private_tags[22]{name,number,wraps}:
  T_CHAR,200,"integer codepoint"
  T_SYMBOL,201,"text string"
  T_KEYWORD,202,"text string"
  T_TUPLE,203,"array"
  T_ARRAY,204,"array"
  T_ORDERED,205,"map"
  T_SET,206,"array"
  T_SORTED_SET,207,"array"
  T_STRUCT,208,"array: [type-ref, field...]"
  T_DATE,209,"integer"
  T_TIME_US,210,"integer: DXN 0.2's microseconds since midnight; read, never written"
  T_DATETIME_US,211,"array: [epoch-us, offset-min], DXN 0.2's; read, never written"
  T_DURATION_US,212,"bitmask byte + fields, the seventh microseconds, DXN 0.2's; read, never written"
  T_REGEX,213,"text: the pattern, with no flags; else array: [pattern, flags-byte]"
  T_CUSTOM,214,"array: [tag-ref, value]"
  T_EXTRA,215,"map: {key: value, ...} — a struct's extra fields, only ever its last item (§4.7)"
  T_BITS,216,"array: [bytes, bit-count] — a run of bits that is not whole bytes (§1.3)"
  T_LOCAL_DATETIME,217,"integer: nanoseconds since 1970-01-01T00:00:00, wall clock"
  T_TIME,218,"integer: nanoseconds since midnight"
  T_DATETIME,219,"integer: epoch-ns, in UTC; else array: [epoch-ns, offset-min]"
  T_DURATION,220,"bitmask byte + fields, the seventh nanoseconds"
  T_OBJECTID,221,"byte string: BSON's 12-byte ObjectId"
```

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

```toon
duration_bits[7]{bit,field,unit}:
  0,years,count
  1,months,count
  2,weeks,count
  3,days,count
  4,hours,count
  5,minutes,count
  6,nanoseconds,"count (fractional seconds folded in, matching time and datetime precision)"
```

Bit 7 is reserved (must be 0).

**Regex flags byte** (`T_REGEX` payload, second element) — one byte, low
bit first, each bit a boolean modifier matching Erlang `:re`/Elixir
`Regex` semantics:

```toon
regex_bits[7]{bit,flag,meaning}:
  0,i,caseless
  1,m,multiline
  2,s,dotall
  3,u,unicode
  4,x,extended
  5,f,firstline
  6,r,ungreedy
```

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

A `.dxns` file is valid `.dxn` — §1's grammar, unchanged, no schema
-specific syntax. What makes a document a *schema* document is purely
the shape of the value it decodes to: a `map` whose values are either
`%schema{...}` (a struct schema) or a `type_expr` (a **named type**,
§4.5) -- a `%shape{...}` (§4.4a) among them. `%schema{}`/`%shape{}`/`%field{}` (§4.4) are recognized by name directly,
the same way a built-in tag name is (§1.2) — not looked up against a
schema of their own, which would be circular.

### 4.1 `type_expr` forms

```toon
type_expr[31]{form,dxn_shape,meaning}:
  any,":any","matches any value at all"
  never,":never","matches no value at all (JSON Schema's false)"
  primitive,":integer / :string / ...","one keyword per §1.3 type name; :bits matches bits and bytes alike, :bytes only whole bytes"
  reference,"bare symbol, e.g. Address","names a struct schema or a named type in this document (or Ns/Name, §4.6)"
  list-of,"{:list-of elem}","list whose every element matches elem"
  list-items,"{:list-items a {:repeat b 0 nil}}","a list's items in order: a type for one item, a repeat for several, §4.1a"
  set-of,"{:set-of elem}","set whose every element matches elem"
  tuple-of,"{:tuple-of a b c}","fixed-arity positional tuple, one type_expr per slot"
  tuple-of-all,"{:tuple-of-all elem}","tuple of any length whose every element matches elem"
  map-of,"{:map-of key-type val-type}","every key matches key-type, every value matches val-type"
  array-of,"{:array-of elem}","array whose every element matches elem"
  ordered-map-of,"{:ordered-map-of key-type val-type}","ordered map: every key matches key-type, every value matches val-type"
  sorted-set-of,"{:sorted-set-of elem}","sorted set whose every element matches elem"
  tagged,"{:tagged acme.money T}","a custom tag of that name whose value matches T; an application's value as its registered tag encoder writes it"
  sized,":int32 :int64 :uint32 :uint64","sugar: {:refine :integer %{min: ..., max: ...}} over that range; :float32 is {:refine :float %{float32: true}}"
  number,":number","sugar: {:any-of :integer :float :decimal :rational}"
  const,"{:const v}","sugar: {:enum v}, the one value v"
  if,"{:if I T E}","a value that matches I must match T, any other E (JSON Schema's if/then/else); E is :any when left out"
  enum,"{:enum lit lit ...}","value must equal one of the given literals (any type)"
  one-of,"{:one-of a b}","exactly one variant matches (JSON Schema's oneOf): none, or two or more, is a refusal"
  any-of,"{:any-of a b}","union — one or more variants match (JSON Schema's anyOf)"
  all-of,"{:all-of a b}","intersection — value must match every variant"
  not,"{:not t}","value must not match t"
  nilable,"{:nilable t}","sugar for {:any-of :nil t}"
  refine,"{:refine t %{constraints}}","base type plus constraints, §4.2"
  struct,"%schema{...}","struct/record shape, §4.4"
  shape,"%shape{...}","a plain map with these fields, defaults filled, §4.4a"
  case,"{:case field %{value => type, :else => type}}","the type the sibling field's value chooses, §4.4a"
  doc,"{:doc T %{description: ...}}","T, annotated: a title, a description, examples and the like, §4.1b; takes what T takes"
  generic,"{:generic [t ...] body}","a named type with parameters, §4.5"
  of,"{:of Name type ...}","one use of a generic, its arguments where its parameters stand, §4.5"
```

A bare `type_expr` (no wrapping tuple/struct) is always a `primitive`
or a `reference` — the tuple form is only needed once a constructor
takes arguments.

`{:tagged name T}` takes the name as a symbol, a keyword or a string
(Jan, 2026-10-20). A built-in tag's name (§1.3) is a compile error
there: `@uuid` is the type `:uuid`, no custom tag. An application's
value -- what a registered tag decoder made of the tag -- matches when
the registry's tag encoder for its module writes it under that name,
with a value that matches `T`; register both directions, as for a
struct (§4.7).

### 4.1a A list's items (`{:list-items}`)

`{:list-items p ...}` describes a list item by item, in order (Jan,
2026-10-20; JSON Schema's `prefixItems` and `items`, CDDL's arrays, Ion
Schema's `ordered_elements`). Each `p` is one of:

- a `type_expr`: exactly one item, of that type;
- `{:repeat p min max}`: between `min` and `max` items of the type `p`,
  `max` `nil` for no upper bound, `0 <= min <= max`;
- `{:repeat {:group p ...} min max}`: the group's items, together, that
  many times; a group's items are again types and repeats.

The list matches when its items are all taken, none left over:

```dxn
%{
  Command: {:list-items :string {:repeat :string 0 nil}}   # a name, then arguments
  Pairs:   {:list-items {:repeat {:group :string :integer} 1 nil}}
  Point:   {:list-items {:repeat :float 2 3}}              # 2D or 3D
}
```

**A repeat takes as many items as it can, then gives them back one at a
time** until the rest of the items match, so `{:list-items {:repeat
:any 0 nil} :string}` takes any list that ends in a string. Every
implementation tries the same choices in the same order, so a shape's
defaults (§4.4a) are filled the same way in each. A repetition that
takes no item is the last: each further one would take none either.
`{:repeat}` and `{:group}` stand only among a `{:list-items}`'s items;
anywhere else they are a compile error (`schema/compile`).

`list-items` closes the list (an item no `p` takes is a refusal), which
is why DXNS has no `unevaluatedItems`: a list that may go on ends in
`{:repeat :any 0 nil}`.

### 4.1b Annotations (`{:doc}`)

`{:doc T %{...}}` says things about `T` and changes nothing it takes
(Jan, 2026-10-20; JSON Schema's annotations, protobuf's options, Ion
Schema's open content). It stands wherever a type does, and around a
whole entry: a named type, a generic, a `%shape` or a `%schema`.

```dxn
%{
  Order: {:doc %schema(2){
    id:      :integer
    email:   {:doc :string %{description: "Where receipts go", meta: %{"acme.pii" => true}}}
    legacy?: {:doc :string %{deprecated: "use email"}}
  } %{title: "An order", deprecated: false}}

  Color: {:doc {:enum :red :green :old-blue} %{
    values: %{:old-blue => %{deprecated: true, description: "Use :blue"}}
  }}
}
```

```toon
annotations[8]{key,takes,meaning}:
  title,string,"a short name for the type"
  description,string,"what the type is for"
  examples,list,"values the type takes, for a reader"
  read-only,boolean,"the value is written by its owner only"
  write-only,boolean,"the value is never read back"
  deprecated,"boolean or string","true, or the reason, when the type is on its way out"
  meta,map,"anything else, kept as written, meaning nothing to a check"
  values,map,"on an enum: each of its values to that value's own annotations (no values of their own)"
```

Any other key is a compile error (`schema/compile`), as is a value of
the wrong kind; `meta` is where what DXNS does not name goes.
`Dextrin.Schema.annotations/2` reads a named type's or a schema's (its
latest version's); a field's stay on its type. A `doc` checks the value
`T` checks, so it is no guard (§4.5): `A: {:doc A %{}}` is a compile
error.

### 4.2 `refine` constraints

```toon
refine_constraints[37]{key,applies_to,meaning}:
  min,"integer/float/decimal/rational/date/time/datetime/local-datetime/duration","value >= given value of the same kind"
  max,"integer/float/decimal/rational/date/time/datetime/local-datetime/duration","value <= given value of the same kind"
  exclusive-min,"integer/float/decimal/rational/date/time/datetime/local-datetime/duration","value > given value of the same kind"
  exclusive-max,"integer/float/decimal/rational/date/time/datetime/local-datetime/duration","value < given value of the same kind"
  multiple-of,"integer/float/decimal/rational","value is an exact multiple of given number"
  min-length,"string/keyword/symbol/bytes/bits","length >= given integer: codepoints of a text or a name, bytes of bytes, bits under :bits"
  max-length,"string/keyword/symbol/bytes/bits","length <= given integer, counted as min-length counts it"
  min-bytes,"string/keyword/symbol","UTF-8 byte count >= given integer"
  max-bytes,"string/keyword/symbol","UTF-8 byte count <= given integer"
  pattern,"string/keyword/symbol/bytes","value matches given regex (§1.3's regex type); bytes one character per byte"
  format,string,"the string is in the format named, one of §4.2a's"
  encoding,string,"the string is valid in RFC 4648's :base64 (padded), :base64url (padded or not), :base32 (padded, upper case) or :base16 (either case)"
  media-type,string,"what the string holds, type/subtype; checks nothing, but tells content how to read it"
  content,string,"the string, decoded by its encoding if it has one, is a DXN document whose value matches the given type: .dxnb under application/dxnb, text otherwise"
  encodes,bytes,"the bytes are a .dxnb document whose value matches the given type (CDDL's .cbor)"
  encodes-seq,bytes,"the bytes are .dxnb documents back to back, each with its envelope, each matching the given type; none at all too (CDDL's .cborseq)"
  min-count,"list/set/tuple/sorted-set/array","element count >= given integer"
  max-count,"list/set/tuple/sorted-set/array","element count <= given integer"
  contains,"list/set/tuple/sorted-set/array","at least min-contains (1 when not given) and at most max-contains elements match the given type"
  min-contains,"with contains","how many elements must match contains, at least"
  max-contains,"with contains","how many elements may match contains, at most"
  unique,"list/set/tuple/sorted-set/array","true: no two elements are the same value"
  unique-by,"list/set/tuple/sorted-set/array","no two elements' given field is the same value; an element without it is compared with none"
  finite,float,"true: neither NaN nor an infinity"
  float32,float,"true: single precision holds the value exactly (NaN and the infinities it holds)"
  min-precision,decimal,"the coefficient's digit count, as written, >= given integer (1.50M has 3)"
  max-precision,decimal,"the coefficient's digit count <= given integer"
  min-exponent,decimal,"the exponent >= given integer (1.50M's is -2)"
  max-exponent,decimal,"the exponent <= given integer"
  bits,"integer/bytes","only the bits numbered in the given list are set: a non-negative integer's from its lowest, bytes from the first byte's lowest (RFC 8610's .bits)"
  before-now,datetime,"true: before the time of the check"
  after-now,datetime,"true: after the time of the check"
  within,datetime,"no further from the time of the check than the given duration, either way"
  resolution,"time/datetime/local-datetime/duration","no part finer than the given unit, :second, :millisecond, :microsecond or :nanosecond"
  offsets,datetime,"the value's offset is one of the given strings, Z or ±HH:MM"
  version,ip,"4 or 6: the value is that family"
  prefix,ip,"true: a prefix; false: an address"
```

`{:refine t %{k: v, ...}}`'s constraint map may combine any number of
these keys; a value must satisfy `t` itself *and* every listed
constraint.

**A constraint refuses a value it does not apply to** (Jan,
2026-10-20): `min-length` refuses an integer, `min` a string, `bits` a
negative integer. A constraint never raises, whatever it meets.

**Ranges compare values of one kind**: numbers with numbers, dates with
dates, times with times, datetimes as the instants they are (whatever
their offsets), local date-times with local date-times, durations as
their nanoseconds. A duration with years or months compares with
nothing, as their lengths vary; nor do two values of different kinds.

**`before-now`, `after-now` and `within` ask the clock**, once per
check, so the same value can pass one check and fail a later one. The
grammar-checked strings and named predicates of the other languages
(CDDL's `.abnf`, protovalidate's CEL) have no refine key: neither is
portable without a grammar engine or an expression language in every
implementation.

**`content` reads only DXN**: a `media-type` other than
`application/dxn` or `application/dxnb` beside it is a compile error, as
is `application/dxnb` without an `encoding`, since a string holds no raw
bytes. Without a `content`, any media type is a name and nothing more.
A document read for `content`, `encodes` or `encodes-seq` is its own:
its shared values and string references (§2.4) are not the enclosing
document's.

**Every argument is checked when the schema compiles**: a count is a
non-negative integer, a flag `true` or `false`, a bound a number, date,
time, datetime, local date-time or a duration without years or months,
`multiple-of` a number other than 0, `pattern` a regex, `version` 4 or
6, `offsets` a list of `"Z"` or `"±HH:MM"`, `bits` a list of
non-negative integers, `within` a duration without years or months,
`media-type` a `type/subtype`. A compile error writes the argument it
refuses in DXN.

**Every key is one of these**: an unknown key, a misspelt `min-lenght`,
is a compile error (`schema/compile`), as are `min-contains` and
`max-contains` without `contains`, a key that is no name, and a
`unique-by` or `resolution` that is no name or no unit.

**Two values are the same when their canonical forms are** (§1.5), for
`unique` and `unique-by`: `1` and `1.0` differ, as `%{a: 1}` and
`%{"a" => 1}` do.

**NaN lies outside every range** (Jan, 2026-10-20): `min`, `max` and
both `exclusive-` bounds refuse it, as every IEEE 754 comparison with NaN
is false; `Infinity` and `-Infinity` compare as the numbers they are.
`finite: true` refuses all three.

**`:timestamp` is sugar for a datetime in UTC**, `{:refine :datetime
%{offsets: ["Z"]}}`: DXN 0.2 had a timestamp type of its own, and a
schema naming it keeps its meaning (§1.2).

### 4.2a Formats (`format:`)

`{:refine :string %{format: :email}}` takes a string in that format
(Jan, 2026-10-20; JSON Schema's `format`, with Ion Schema's and
protovalidate's string rules). The set is closed: any other name is a
compile error (`schema/compile`). Every implementation checks a format
the same way: a format DXN has a tag for is read by that tag's reader,
so `format: :date` takes exactly the strings `@date "..."` takes; every
other format is the grammar below, a regular expression that PCRE,
JavaScript (with the `u` flag) and PHP read alike. **`$` is the
string's end**: PCRE and PHP compile the grammars with the `D` flag
(`PCRE2_DOLLAR_ENDONLY`), which JavaScript's `$` is already, so a final
newline is no part of a hostname. The tags' readers end there too:
`@time "12:00:00\n"` is `syntax`.

```toon
formats[22]{name,checked_as}:
  date,"@date's reader (§1.2)"
  time,"@time's reader"
  datetime,"@datetime's reader: an offset, Z or ±HH:MM, is required"
  local-datetime,"@local-datetime's reader: no offset"
  duration,"@duration's reader"
  uuid,"@uuid's reader: 8-4-4-4-12 hex digits, either case"
  ipv4,"@ip's reader: an IPv4 address, no prefix"
  ipv6,"@ip's reader: an IPv6 address, no prefix, no zone"
  hostname,"labels LABEL joined by dots, 253 codepoints at most"
  idn-hostname,"labels U-LABEL joined by dots, 253 codepoints at most"
  email,"LOCAL @ DOMAIN, split at the last @: LOCAL at most 64 bytes, DOMAIN a hostname, [IPv4] or [IPv6:address]"
  idn-email,"as email, with IDN-LOCAL and an idn-hostname"
  uri,"RFC 3986's URI, from the parts below"
  uri-reference,"a uri, or RFC 3986's relative-ref"
  iri,"a uri that may hold any character past ASCII where it holds an unreserved one"
  iri-reference,"an iri, or a relative-ref that may"
  uri-template,"RFC 6570's URI-Template, below"
  json-pointer,"RFC 6901, below"
  relative-json-pointer,"draft-handrews-relative-json-pointer, below"
  semver,"Semantic Versioning 2.0.0, below"
  mac,"six or eight pairs of hex digits, one separator, : or -, throughout"
  host-port,"HOST:PORT, split at the last colon: HOST a hostname, an IPv4 address or [IPv6], PORT 0 to 65535 without leading zeros"
```

The grammars:

```text
LABEL      [A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?
U-LABEL    [\p{L}\p{N}](?:[\p{L}\p{N}\p{M}-]{0,61}[\p{L}\p{N}\p{M}])?
ATEXT      [\-A-Za-z0-9!#$%&'*+/=?^_`{|}~]
QUOTED     "(?:[\x20\x21\x23-\x5B\x5D-\x7E]|\\[\x20-\x7E])*"
LOCAL      ^(?:ATEXT+(?:\.ATEXT+)*|QUOTED)$
IDN-LOCAL  as LOCAL, each ATEXT (?:ATEXT|[^\x00-\x7F])
PORT       ^(?:0|[1-9][0-9]{0,4})$, and at most 65535

json-pointer           ^(?:/(?:[^~/]|~[01])*)*$
relative-json-pointer  ^(?:0|[1-9][0-9]*)(?:#|(?:/(?:[^~/]|~[01])*)*)$
semver                 ^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)
                       (?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)
                       (?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?
                       (?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$
mac                    ^[0-9A-Fa-f]{2}([:-])[0-9A-Fa-f]{2}(?:\1[0-9A-Fa-f]{2}){4}
                       (?:(?:\1[0-9A-Fa-f]{2}){2})?$
uri-template           ^(?:LITERAL|%[0-9A-Fa-f]{2}|\{[+#./;?&=,!@|]?VARSPEC(?:,VARSPEC)*\})*$
  LITERAL  [^\x00-\x20"'%<>\\^`{|}\x7F]
  VARSPEC  VARCHAR(?:\.?VARCHAR)*(?::[1-9][0-9]{0,3}|\*)?
  VARCHAR  (?:[A-Za-z0-9_]|%[0-9A-Fa-f]{2})

The URI parts (RFC 3986 §3); for an iri, every PCT is
(?:%[0-9A-Fa-f]{2}|[^\x00-\x7F]):
  U          [\-A-Za-z0-9._~!$&'()*+,;=]     unreserved and sub-delims
  PCT        %[0-9A-Fa-f]{2}
  PCHAR      (?:[U:@]|PCT)                  U's characters, ":" and "@"
  NC         (?:[U@]|PCT)                   a PCHAR but ":"
  AUTHORITY  (?:(?:[U:]|PCT)*@)?(?:\[[^\]]*\]|(?:[U]|PCT)*)(?::[0-9]*)?
  TAIL       (?:\?(?:PCHAR|[/?])*)?(?:#(?:PCHAR|[/?])*)?
  uri        ^[A-Za-z][A-Za-z0-9+.-]*:(?://AUTHORITY(?:/PCHAR*)*
             |/(?:PCHAR+(?:/PCHAR*)*)?|PCHAR+(?:/PCHAR*)*|)TAIL$
  relative   ^(?://AUTHORITY(?:/PCHAR*)*|/(?:PCHAR+(?:/PCHAR*)*)?
             |NC+(?:/PCHAR*)*|)TAIL$
  and a [...] host is an IPv6 address (@ip's reader) or
  ^v[0-9A-Fa-f]+\.[A-Za-z0-9._~!$&'()*+,;=:-]+$ (IPvFuture).
```

A format takes only a string that is valid UTF-8; any other value it
refuses (§4.2). JSON Schema's `regex` format has no counterpart: whether
a pattern compiles depends on the engine, and not every implementation
has PCRE.

### 4.3 Required vs. optional fields

No separate flag: a field key ending in `?` is optional; any other key
is required. `?` is already a legal `ident_char` (§1.1) — no grammar
addition. The `?` itself is not part of the field's name.

**Optional means the field may be absent, not that it may be `nil`.**
An optional field that is present must match its type like any other,
so `nil` is refused unless the type admits it (`{:nilable t}`). Text
leaves an absent field out. A positional form must fill every position
— `.dxnb` always — so an encoder writes an absent field's default where
it has one, and otherwise refuses (`schema/missing-field`) rather than
writing `nil` the reader would refuse.

### 4.4 Struct schemas (`%schema(N){}`/`%field{}`)

```ebnf
schema_entry = identifier , ":" , schema_form ;
schema_form  = "%schema" , [ "(" , version , ")" ] , "{" , { field_entry } , "}" ;
version      = positive integer ;
field_entry  = ( identifier , [ "?" ] , ":" , type_expr )
             | ( identifier , [ "?" ] , ":" , field_form ) ;
field_form   = "%field{" , "type:" , type_expr ,
                 [ "default:" , value ] , [ "description:" , string ] ,
               "}" ;
```

```text
User: %schema(3){
  name: :string,
  email: %field{type: :string, description: "where mail goes"},
  id?: :uuid
}
```

**The body lists the fields directly, and the order they are written in
is the order of the fields**: the canonical position ↔ name mapping a
struct's positional wire form (§2.1) needs. A field named twice is an
error. A keyed `%Name{...}` *data* literal may still list its fields in
any order — names alone resolve those; the order requirement is on the
schema's body only.

**The header holds only the version** (§4.8). A schema written without
one, `%schema{...}`, is version 1.

`%field{type:, default:, description:}` is reached only when a field
needs metadata beyond a bare `type_expr` — a default value (used when
the field is absent; independent of `?`, which controls whether
*absence itself* is an error) or a human-readable description. It never
carries its own optionality flag — that's always the key's `?` suffix.

### 4.4a Shapes (`%shape{}`) and `{:case}`

```text
Envelope: %schema{
  type: :string,
  payload: {:case type %{"order.placed" => OrderPlaced, :else => :any}}
}
OrderPlaced: %shape{
  order_id: :uuid,
  currency: %field{type: :string, default: "EUR"},
  gift?: :boolean
}
```

**A shape is a named, unversioned map type** (Jan, 2026-10-20): its
body is a `%schema` body -- fields in order, `?` for optional,
`%field{}` for a default or a description -- and it matches a **plain
map** only, never a struct. `%shape(N){...}` and a positional
`%shape[...]` are refused: a shape has no version, and evolving one
compatibly is its author's business. A declared field is matched by
name whatever spelling its key has (`name:`, `"name" =>`, `:"name" =>`),
and a map giving one twice does not match. Every other key is an
extra, kept; a strict decode (§4.7) refuses extras. **A missing field
takes its default**: a map checked against a shape while decoding comes
out with each missing field's default filled in, under a keyword key,
as a struct's field does; encoding writes the map as it is given. A
map a shape refuses is a `schema/type-mismatch` of the field holding it.

**`{:case field %{value => type, ...}}` is the type its sibling chooses**:
`field` names a field of the nearest enclosing schema or shape, whose
value is compared with each key as `{:enum ...}` compares, and the type
of the equal key is the type. `:else` is the type when no key is equal,
or the sibling is absent; with no `:else`, that value is refused. A case
may stand anywhere in a field's type -- inside `nilable`, `list-of`,
`any-of` -- and a `field` naming no field of the schema or shape it is
written in is a compile error.

### 4.5 Named types

Any top-level entry whose value is not a `%schema{}` defines a **named
type**: a reusable name for a `type_expr`, e.g.
`PositiveInt: {:refine :integer %{min: 1}}`. It's referenced exactly
like a struct name — a bare symbol (§4.1's `reference` form) — since
both are resolved the same way: by name, against whatever this
document (or an already-known document, §4.6) defines.

A named type's own body MAY reference another named type, **including
one declared alongside it in the same document**, in any order: a
reader compiles every named type of a document before it resolves any
reference between them, so the top-level `map`'s order (which §1.4
does not give) never matters.

**A named type may refer to itself**, directly or through others
(Jan, 2026-10-20), when every such cycle passes a **guard**: a field of
a `%shape` or `%schema`, or the elements of a collection (`list-of`,
`list-items`, `set-of`, `map-of`, `tuple-of`, `tuple-of-all`,
`array-of`, `ordered-map-of`, `sorted-set-of`, `tagged`, and a refine's
`contains`, `content`, `encodes` and `encodes-seq`). `nilable`, `any-of`, `one-of`, `all-of`, `not`,
`refine`, `doc`, `if` and `case` check the same value again, so they are no guard:
`A: {:nilable A}` describes no value and is a compile error
(`schema/compile`). A guarded check always ends, since a DXN value is
finite (§2.5) and every guard steps into a smaller part of it:

```text
Comment: %shape{text: :string, replies?: {:list-of Comment}}
JsonValue: {:any-of :nil :boolean :integer :float :string
                    {:list-of JsonValue} {:map-of :string JsonValue}}
```

A cycle stays within one document: a reference to another file sees
only documents read before it (§4.6).

**A named type may take parameters** (Jan, 2026-10-20):
`{:generic [t ...] body}` is a named type whose `body` names each
parameter wherever a type goes, and `{:of Name type ...}` is one use of
it, each argument standing where its parameter stands. A generic is a
named type's whole definition, and is only ever used through `{:of}`:
a bare `Page`, a wrong number of arguments, or `{:of}` on a type that is
not generic, is a compile error. A generic may use itself, guarded as
above.

```text
Page: {:generic [t] %shape{items: {:list-of t}, next?: :string}}
Orders: {:of Page Order}
List: {:generic [t] {:any-of :nil %shape{head: t, tail: {:of List t}}}}
```

**A `%schema` cannot be generic**: a struct goes on the wire under its
one name, so two uses could not be told apart. A schema may use a
generic in its fields.

*Replaced (2026-10-20):* this section used to leave a same-document
sibling reference implementation-defined -- a reader MAY refuse it, MAY
resolve it by some deterministic pass, or MAY support forward
reference -- on the argument that a map has no order to resolve it
against. The argument only shows a reader must not resolve *in* map
order; two-phase compilation needs no order at all. Shapes (§4.4a)
name their siblings as a matter of course (`OrderCancelled` naming
`CancelReason` beside it), so resolution is now required.

### 4.6 Cross-file references

An `identifier` (§1.1) is segments joined by `.`, with at most one `/`
between a namespace and a name: `Foo.Bar/Baz`, `acme.billing/Invoice`.
The namespace is everything before the `/`, dots included. A name with a
`/` is the mechanism this document uses for referencing a struct schema
or named type defined in a separate `.dxns` file or unit.

Resolving a name to a document (a file path, a registry lookup, a
network fetch, ...) is reader-defined. **A reader that resolves names to
files follows this convention**, so that one set of schema files serves
every implementation. A struct of version `N` named `Foo.Bar/Baz` is
looked for, on each search path in order, in:

```toon
schema_files[4]{layout,version_1,version_N}:
  directories,"Foo/Bar/Baz.dxns or Foo/Bar/Baz-v1.dxns","Foo/Bar/Baz-vN.dxns"
  one directory per name,"Foo/Bar/Baz/v1.dxns","Foo/Bar/Baz/vN.dxns"
  flat,"Foo.Bar.Baz.dxns or Foo.Bar.Baz-v1.dxns","Foo.Bar.Baz-vN.dxns"
  namespace file,"the entry Baz in Foo.Bar.dxns","the same file, by its %schema(N)"
```

A name with no `/` is its own namespace: `Baz` is looked for as
`Baz.dxns`, `Baz-vN.dxns`, `Baz/vN.dxns`, and the entry `Baz` in
`Baz.dxns`. Its dots are directories all the same, and a file holds it
under its whole name: `Foo.Bar.Baz` is the entry `Foo.Bar.Baz` in
`Foo/Bar/Baz.dxns` or `Foo.Bar.Baz.dxns`. The rules:

- **The first search path that has the name at all decides**; later ones
  are not consulted for it.
- **A file's version is its schema's.** `Baz-v2.dxns` holds `Baz` as
  `%schema(2)`; one that holds another version is refused
  (`schema/compile`).
- **One version is found once.** Two files on one search path that both
  hold the same name and version (`Baz-v2.dxns` and `Baz/v2.dxns`, or
  either and the namespace file) are refused, naming both, rather than
  one being picked.
- **Every version found is loaded**, so that a struct written with an
  older one reaches the materializer (§4.8); a struct without a version
  is read as the highest found.

### 4.7 Enforcement

A struct value decoded without a schema for its name is an opaque
tagged value (§1.4) — never an error. Once a schema is known for a
given name, a conforming reader MUST enforce, for every value of that
struct:

- every required field (§4.3) is present;
- every present field's value matches its declared `type_expr`
  (§4.1/§4.2).

**A value matches only its declared type, and nothing is converted to
make it match.** An integer is not a string, however easy the
conversion; a map is not a struct. A field typed `User` accepts only a
`User` struct: a struct named `User` (checked against `User`'s schema,
or opaque when there is none, §1.4), or the application value a reader
has registered as `User`'s. Everything else is a type error, plain maps
included; whoever needs a struct writes it as one.

**Representation is not conversion.** A language without integers may
hold a DXN integer as a string; that is its representation. A language
that has integers and turns one into a string because a field says
`:string` converts. The test is normative: **a host value always means
the same DXN type, with or without a schema. A schema can accept or
reject a value, but never changes what it means.**

**A struct guarantees its declared fields and may carry more.** Code
relying on a struct is guaranteed only the declared fields; the rest are
its **extra fields**, which a reader keeps rather than drops:

- **In text** they are ordinary entries. A keyed struct's entries that
  its schema does not declare are extras, and so is any entry whose key
  is not a name (a keyword, symbol or string). A positional struct
  carries them as entries after its items,
  `%User(3)["a" "a@x" nickname: "b", 3 => :x]`: all items come first,
  an item is a value not followed by `=>`, and an item after an entry is
  a syntax error.
- **In `.dxnb`** they travel as one trailing item, a map from key to
  value under tag `T_EXTRA` (215): `["User(3)", "a", "a@x",
  215({"nickname": "b"})]`. Tag 215 appears nowhere else.
- **An extra field never shadows a declared one.** A name given both as
  a declared field and as an extra — `%User(3){name: "a", "name" =>
  "b"}`, or a positional field and a tag-215 entry of the same name — is
  an error (`schema/shadowed-field`).
- **An extra field's key follows the map-key rule** (§1.6).
- **A strict decode** — an option a reader MUST offer — refuses any
  extra field on a struct whose schema is known
  (`schema/undeclared-field`). A config loader reads strictly, to catch
  a typo in a hand-written file; a message consumer does not, so a
  newer producer's fields pass through it.

A struct with no schema keeps a keyed struct's named entries as its
fields, and its other entries — those keyed by something other than a
name, and a positional struct's trailing entries — as extras.

A violation MUST be reported as an error, distinctly from a value that
simply fails to parse at all — but *how* it's reported (exception,
error tuple, a validation-result value, ...) is implementation-defined;
its category (§5) is not.

### 4.8 Schema versions

**Each `.dxns` document describes one version of each schema it
holds**, written in the schema's header: `%schema(3){...}`, version 1
when there is no header. Versions are positive integers. A reader loads
any number of documents and keeps every schema by its name *and* its
version, so `User` versions 1, 2 and 3 can be loaded side by side, from
three documents.

- **Loading a version already loaded is an error**
  (`schema/duplicate-version`, §5): two documents that both claim to be
  `User` v3 are a mistake, not an update.
- **Replacing a loaded version is a separate, explicit operation** — the
  hot swap of a running system. It only ever replaces: naming a version
  that is not loaded is an error (`schema/not-loaded`), so a typo never
  quietly adds one.
- **A struct literal may carry the version it was written with**:
  `%User(3){...}`, `%User(3)[...]`. In `.dxnb` the version is part of
  the struct's type name, `"User(3)"` (§2.2), shared after its first
  occurrence like any type name (§2.4). A version that is not a
  positive integer is an error (`syntax`, or `binary` in `.dxnb`).

**Every struct an encoder writes against a schema carries the latest
loaded version of that schema** — `%User(3){...}`, and `%User(1){...}`
when version 1 is the only one, so a reader never has to guess. There
is no way to write an older version: whatever version a value says
itself, it is checked against the latest and written as the latest. A
struct whose name has no schema keeps the version it has, or none.

**A struct without a version** — `%User{...}`, which mostly means text
written by hand — **is read as the latest loaded version.** There is no
way to read it as another; a document written for an older version
says so with its tag, `%Config(2){...}`.

**A struct reference names no version.** A field typed `User` accepts
any version of `User`; the nested struct's own tag decides how it is
read. `User(2)` is not a type expression.

**Reading a struct by its version.** A reader compares the version a
struct was written with against the versions it has loaded:

- **No version, or the latest loaded:** the struct is read with the
  latest schema, exactly — in `.dxnb` its item count must match.
- **Newer than anything loaded:** the struct is read against the latest
  loaded version. Every field that version requires must be present with
  a matching type; optional fields that are missing are absent and take
  their defaults. Text matches fields by name. `.dxnb` **assumes
  positions are unchanged**: items beyond the reader's own fields are
  silently dropped, and fields beyond the items are missing.
- **Older than the latest, and loaded:** the struct is read with its
  own version's schema and handed to the schema's materializer, which
  upgrades it. Without a materializer it is an error
  (`schema/no-materializer`): reading old data as though it were the
  latest would be a guess.
- **Older, and not loaded:** an error (`schema/unknown-version`), even
  with a materializer — without the writer's schema there are no field
  names to hand it.

**One materializer per schema.** A reader may register, for each
schema, one function that builds the application's value from a
decoded struct. It is called for **every** decoded struct of its
schema, whatever the version, with the schema's name, the version the
fields were read with, and the fields keyed by field-name string;
nested structs are built first. It upgrades older versions,
materializes, refines and validates, and its result MUST be checked
against the latest loaded version: a refusal, or a result that version
rejects, is an error (`schema/materializer`). Without a materializer
the latest version comes back as the implementation's generic struct
value, at that version, its fields in the schema's order; an optional
field that was absent stays absent. Encoding checks the schema's types
only.

**The risk of reading forward is normative.** If a newer version
reordered, inserted or removed fields, an older reader of `.dxnb`
assigns values to the wrong fields, without an error whenever the types
agree. This is accepted as unavoidable: a schema whose older readers
must keep working only ever appends fields.

**Version discipline.** Implementations provide a check, for CI, that
compares a previous release's schemas with the current ones: a version
present in both whose content changed — a field added, removed or
moved, or one whose type, requiredness or default changed — is an
error, because two documents claiming to be `User` v3 must mean the
same thing; and a schema's latest version never goes down. It also
lists, for each schema, the older versions still loaded beside the
latest and which fields were added, removed and changed since: the
checklist for the materializer. There are no compatibility modes and
no append-only rule.

**Deploying a change.** A *compatible* change — fields appended at the
end, and nothing else — deploys in either order: a newer producer is
read by an older reader, which matches what it knows and ignores the
rest, and an older producer is read by a newer reader through the
materializer. A *breaking* change deploys **readers first**, then
producers. A schema that services both read and write is changed only
compatibly, or replaced by a new name (`UserV2`) beside the old one,
migrating one service at a time.

---

## 5. Errors

Implementations report errors in their own way (§4.7), but every error
a conforming reader, writer or schema compiler raises belongs to
exactly one **category**, and an implementation MUST expose it on the
error value. Categories are compared exactly; messages are not
normative.

```toon
categories[20]{category,raised_when}:
  syntax,"text does not parse"
  binary,"a .dxnb document is malformed: magic, version, a tag's payload"
  key/not-allowed,"a map or extra-field key has a type §1.6 does not allow"
  encode/unsupported,"a host value has no DXN meaning, or no form in the text being written -- a symbol whose name is not an identifier"
  schema/compile,"a .dxns document is not a valid schema"
  schema/duplicate-version,"a (name, version) is loaded twice"
  schema/not-loaded,"a replace names a (name, version) that is not loaded"
  schema/unknown-version,"a struct's version is older than the latest loaded and not loaded itself"
  schema/no-materializer,"an older version arrives and no materializer is registered"
  schema/field-count,"a positional struct's item count differs from its own version's field count"
  schema/missing-field,"a required field is absent, or a positional form has no value for an optional field without a default (§4.3)"
  schema/type-mismatch,"a field's value does not match its declared type"
  schema/undeclared-field,"a strict decode meets a field the schema does not declare"
  schema/shadowed-field,"an extra field has the name of a declared field"
  schema/materializer,"a materializer answers an error, or a value the latest schema rejects"
  schema/version-discipline,"the compatibility check: changed content under the same version, or a version going down"
  document/not-found,"an edit to a document (a reader that keeps comments) names a path that is not there"
  document/exists,"an insert names a key the map already has"
  document/ambiguous,"an update finds a deleted item followed by an inserted one -- a replace, or the two -- and its setting refuses to choose: always, or where the deleted item owns a comment"
  document/not-a-collection,"an edit's path goes into a value that holds no entries"
```

## 6. Media types and identification

How a program that receives a body or meets a file names DXN's three
forms, and decides cheaply whether a body is worth decoding as one. A
reader MAY offer this; one that does answers as below, so every
implementation sniffs the same way.

```toon
forms[3]{form,media_type,extension}:
  text,application/vnd.dxn,.dxn
  binary,application/vnd.dxnb,.dxnb
  schema,application/vnd.dxns,.dxns
```

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
