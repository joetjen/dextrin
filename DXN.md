# DXN Technical Reference

Implementation-ready grammar and binary encoding for DXN (Data eXchange
Notation), `.dxn` (text) and `.dxnb` (binary). This document is
normative and terse by design — for the reasoning behind each decision,
see `DXN_SPEC.md` (the design log). Nothing here should require reading
that document to implement a conforming parser, encoder, or decoder.

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

identifier   = ( letter | "_" ) , { ident_char } , [ "/" , ( letter | "_" ) , { ident_char } ] ;
reserved     = "nil" | "true" | "false" | "NaN" | "Infinity" ;

string_char  = ? any character except '"' or "\" ? | escape ;
escape       = "\" , ( '"' | "\" | "n" | "t" | "r" | "0" | "a" | "b" | "f" | "v"
             | ( "x{" , hex_digit , { hex_digit } , "}" ) ) ;
string       = '"' , { string_char } , '"' ;

char_body    = ? any single non-whitespace character ? | escape | "s" (* space, char-literal only *) ;
char         = "?" , char_body ;
```

Reserved sigils — none may begin a bare `identifier`: `#` comment, `@`
open tag, `%` map/struct, `~` closed sigil family, `?` char, `:` keyword.

### 1.2 Value grammar

```ebnf
value        = { skip } , value_body ;
skip         = comment | discard ;
discard      = "@_" , value ;                      (* parses and discards one value; produces nothing *)

value_body   = nil | boolean | number | string | char | symbol | keyword
             | list | tuple | map_lit | struct_lit | set_lit
             | sigil | tag_form ;

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
             | ( value , "=>" , value ) ;             (* arrow — any key type *)

struct_lit   = "%" , identifier ,
                 ( ( "{" , { map_entry } , "}" )      (* keyed *)
                 | ( "[" , { value } , "]" ) ) ;       (* positional *)

sigil        = date_sigil | time_sigil | instant_sigil | regex_sigil ;
date_sigil   = "~D[" , iso_date , "]" ;
time_sigil   = "~T[" , iso_time , "]" ;
instant_sigil= "~U[" , iso_date , " " , iso_time , "Z" , "]" ;
regex_sigil  = "~r/" , { regex_char } , "/" , [ regex_flags ] ;
regex_flags  = { "i" | "m" | "s" | "u" | "x" | "f" | "r" } ;

tag_form     = "@" , identifier , value ;             (* built-in tag name -> §1.3; else custom *)
```

Tag resolution: an `identifier` immediately following `@` is matched
against the built-in tag table (§1.3) first; any name not found there is
a **custom tag** — parses identically (`@tag value`), decodes to an
application-defined type via a registered decoder, per §2 goal 4 of the
design log.

### 1.3 Type reference

```toon
types[30]{type,category,dxn_syntax,notes}:
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
  date,temporal,"~D[YYYY-MM-DD]","ISO 8601"
  time,temporal,"~T[HH:MM:SS(.ffffff)?]","ISO 8601"
  timestamp,temporal,"~U[YYYY-MM-DD HH:MM:SSZ]","ISO 8601, UTC only"
  datetime,temporal,"@datetime ""...""","ISO 8601, offset required, non-UTC"
  duration,temporal,"@duration ""P...""","ISO 8601 duration"
  uuid,extended,"@uuid ""...""","RFC 4122"
  uri,extended,"@uri ""...""","RFC 3986"
  bytes,extended,"@bytes ""...""","base64"
  regex,extended,"~r/pattern/flags","PCRE-style via Erlang :re"
  custom-tag,extended,"@tag value","open extension point, any unrecognized tag name"
  header,meta,"@dxn ""1.0""","optional, first form only"
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

```toon
cbor_map[29]{type,cbor_major_or_tag,payload,integrity_note}:
  nil,"simple(22)","",""
  boolean,"simple(20/21)","","false/true"
  integer,"major0/1; tag2/3","two's complement bignum bytes past 64-bit","arbitrary precision preserved exactly"
  float,"major7","IEEE 754 double","NaN/Infinity encode natively, no tag needed"
  decimal,"tag4","[exponent,mantissa]",""
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
  sorted-set,"tag T_SORTED_SET","major4 items, sorted order",""
  struct,"tag T_STRUCT","[type-name-or-ref, field...]","positional only, §2.1"
  array,"tag T_ARRAY","major4 items",""
  date,"tag T_DATE","integer days since 1970-01-01","Unix epoch, day granularity"
  time,"tag T_TIME","integer microseconds since midnight",""
  timestamp,"tag1, integer form only","integer microseconds since epoch","MUST use integer, not float tag-1 form — float loses microsecond precision at scale"
  datetime,"tag T_DATETIME_OFFSET","[epoch-microseconds int, offset-minutes]","same integer-only requirement as timestamp"
  duration,"tag T_DURATION","bitmask byte + present fields, §2.3",""
  uuid,"tag37","16 raw bytes","not the 36-char text form"
  uri,"tag32","major3 text",""
  bytes,"major2","raw bytes","no base64 in binary"
  regex,"tag T_REGEX","[pattern text, flags byte]","flags bit layout in §2.3"
  custom-tag,"tag T_CUSTOM","[tag-name-or-ref, value]","binary form of the open extension point"
  header,"envelope, §2.1","magic+version bytes","not a CBOR item; metadata, not data"
```

### 2.3 Private tag assignments and bit layouts

```toon
private_tags[15]{name,number,wraps}:
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
  T_TIME,210,"integer"
  T_DATETIME_OFFSET,211,"array: [epoch-us, offset-min]"
  T_DURATION,212,"bitmask byte + fields"
  T_REGEX,213,"array: [pattern, flags-byte]"
  T_CUSTOM,214,"array: [tag-ref, value]"
```

Allocated from CBOR's one-extra-byte tag range (24–255), placed at
200–214 specifically to stay clear of the actively-managed low range
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
  6,microseconds,"count (fractional seconds folded in, matching time/timestamp precision)"
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
§2.3 (200–214) or with §2.4's tags (256, 25) — confirm both against
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
  meta:    @ordered %{created: ~U[1990-01-01 00:00:00Z]}
  address: %Point[51.05, 13.74]
  result:  {:ok, 200}
  handle:  ~r/^[a-z0-9_]{3,20}$/i
}
```

Every construct above is fully specified by §1.2 + §1.3; every field
round-trips through §2 without loss (§2.2's `integrity_note` column
records the two places — bignum and timestamp precision — where that
took a specific encoding choice to guarantee, per the design log's §7.8
audit).
