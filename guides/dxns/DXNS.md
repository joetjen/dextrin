# DXNS: DXN schemas

The reference for DXNS, the schema language of DXN: what a `.dxns`
document holds, every type form, refine key, format and annotation, and
how schemas are versioned, enforced and found across files. The DXN
format itself -- its grammar, values, binary form and errors -- is
[DXN.md](../dxn/DXN.md); a section number here is this document's, and
"DXN.md §1.3" is DXN.md's. These sections were DXN.md's §4.1 to §4.8.

For a first look, read the [tutorial](TUTORIAL.md); for a quick one, the
[cheatsheet](DXNS_CHEATSHEET.md); for whole schemas, the
[examples](DXNS_EXAMPLES.md).


A `.dxns` file is valid `.dxn` — DXN.md §1's grammar, unchanged, no schema
-specific syntax. What makes a document a *schema* document is purely
the shape of the value it decodes to: a `map` whose values are either
`%schema{...}` (a struct schema) or a `type_expr` (a **named type**,
§5) -- a `%shape{...}` (§4a) among them. `%schema{}`/`%shape{}`/`%field{}` (§4) are recognized by name directly,
the same way a built-in tag name is (DXN.md §1.2) — not looked up against a
schema of their own, which would be circular.

## 1. `type_expr` forms

| Form | DXN shape | Meaning |
|---|---|---|
| `any` | `:any` | matches any value at all |
| `never` | `:never` | matches no value at all (JSON Schema's false) |
| `primitive` | `:integer / :string / ...` | one keyword per DXN.md §1.3 type name; :bits matches bits and bytes alike, :bytes only whole bytes |
| `reference` | `bare symbol, e.g. Address` | names a struct schema or a named type in this document (or Ns/Name, §6) |
| `list-of` | `{:list-of elem}` | list whose every element matches elem |
| `list-items` | `{:list-items a {:repeat b 0 nil}}` | a list's items in order: a type for one item, a repeat for several, §1a |
| `set-of` | `{:set-of elem}` | set whose every element matches elem |
| `tuple-of` | `{:tuple-of a b c}` | fixed-arity positional tuple, one type_expr per slot |
| `tuple-of-all` | `{:tuple-of-all elem}` | tuple of any length whose every element matches elem |
| `map-of` | `{:map-of key-type val-type}` | every key matches key-type, every value matches val-type |
| `array-of` | `{:array-of elem}` | array whose every element matches elem |
| `ordered-map-of` | `{:ordered-map-of key-type val-type}` | ordered map: every key matches key-type, every value matches val-type |
| `sorted-set-of` | `{:sorted-set-of elem}` | sorted set whose every element matches elem |
| `tagged` | `{:tagged acme.money T}` | a custom tag of that name whose value matches T; an application's value as its registered tag encoder writes it |
| `sized` | `:int32 :int64 :uint32 :uint64` | sugar: {:refine :integer %{min: ..., max: ...}} over that range; :float32 is {:refine :float %{float32: true}} |
| `number` | `:number` | sugar: {:any-of :integer :float :decimal :rational} |
| `const` | `{:const v}` | sugar: {:enum v}, the one value v |
| `if` | `{:if I T E}` | a value that matches I must match T, any other E (JSON Schema's if/then/else); E is :any when left out |
| `enum` | `{:enum lit lit ...}` | value must equal one of the given literals (any type) |
| `one-of` | `{:one-of a b}` | exactly one variant matches (JSON Schema's oneOf): none, or two or more, is a refusal |
| `any-of` | `{:any-of a b}` | union — one or more variants match (JSON Schema's anyOf) |
| `all-of` | `{:all-of a b}` | intersection — value must match every variant |
| `not` | `{:not t}` | value must not match t |
| `nilable` | `{:nilable t}` | sugar for {:any-of :nil t} |
| `refine` | `{:refine t %{constraints}}` | base type plus constraints, §2 |
| `struct` | `%schema{...}` | struct/record shape, §4 |
| `shape` | `%shape{...}` | a plain map with these fields, defaults filled, §4a |
| `case` | `{:case field %{value => type, :else => type}}` | the type the sibling field's value chooses, §4a |
| `doc` | `{:doc T %{description: ...}}` | T, annotated: a title, a description, examples and the like, §1b; takes what T takes |
| `generic` | `{:generic [t ...] body}` | a named type with parameters, §5 |
| `of` | `{:of Name type ...}` | one use of a generic, its arguments where its parameters stand, §5 |

A bare `type_expr` (no wrapping tuple/struct) is always a `primitive`
or a `reference` — the tuple form is only needed once a constructor
takes arguments.

`{:tagged name T}` takes the name as a symbol, a keyword or a string
(Jan, 2026-10-20). A built-in tag's name (DXN.md §1.3) is a compile error
there: `@uuid` is the type `:uuid`, no custom tag. An application's
value -- what a registered tag decoder made of the tag -- matches when
the registry's tag encoder for its module writes it under that name,
with a value that matches `T`; register both directions, as for a
struct (§7).

## 1a. A list's items (`{:list-items}`)

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
defaults (§4a) are filled the same way in each. A repetition that
takes no item is the last: each further one would take none either.
`{:repeat}` and `{:group}` stand only among a `{:list-items}`'s items;
anywhere else they are a compile error (`schema/compile`).

`list-items` closes the list (an item no `p` takes is a refusal), which
is why DXNS has no `unevaluatedItems`: a list that may go on ends in
`{:repeat :any 0 nil}`.

## 1b. Annotations (`{:doc}`)

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

| Key | Takes | Meaning |
|---|---|---|
| `title` | string | a short name for the type |
| `description` | string | what the type is for |
| `examples` | list | values the type takes, for a reader |
| `read-only` | boolean | the value is written by its owner only |
| `write-only` | boolean | the value is never read back |
| `deprecated` | boolean or string | true, or the reason, when the type is on its way out |
| `meta` | map | anything else, kept as written, meaning nothing to a check |
| `values` | map | on an enum: each of its values to that value's own annotations (no values of their own) |

Any other key is a compile error (`schema/compile`), as is a value of
the wrong kind; `meta` is where what DXNS does not name goes.
`Dextrin.Schema.annotations/2` reads a named type's or a schema's (its
latest version's); a field's stay on its type. A `doc` checks the value
`T` checks, so it is no guard (§5): `A: {:doc A %{}}` is a compile
error.

## 2. `refine` constraints

| Key | Applies to | Meaning |
|---|---|---|
| `min` | integer/float/decimal/rational/date/time/datetime/local-datetime/duration | value >= given value of the same kind |
| `max` | integer/float/decimal/rational/date/time/datetime/local-datetime/duration | value <= given value of the same kind |
| `exclusive-min` | integer/float/decimal/rational/date/time/datetime/local-datetime/duration | value > given value of the same kind |
| `exclusive-max` | integer/float/decimal/rational/date/time/datetime/local-datetime/duration | value < given value of the same kind |
| `multiple-of` | integer/float/decimal/rational | value is an exact multiple of given number |
| `min-length` | string/keyword/symbol/bytes/bits | length >= given integer: codepoints of a text or a name, bytes of bytes, bits under :bits |
| `max-length` | string/keyword/symbol/bytes/bits | length <= given integer, counted as min-length counts it |
| `min-bytes` | string/keyword/symbol | UTF-8 byte count >= given integer |
| `max-bytes` | string/keyword/symbol | UTF-8 byte count <= given integer |
| `pattern` | string/keyword/symbol/bytes | value matches given regex (DXN.md §1.3's regex type); bytes one character per byte |
| `format` | string | the string is in the format named, one of §2a's |
| `encoding` | string | the string is valid in RFC 4648's :base64 (padded), :base64url (padded or not), :base32 (padded, upper case) or :base16 (either case) |
| `media-type` | string | what the string holds, type/subtype; checks nothing, but tells content how to read it |
| `content` | string | the string, decoded by its encoding if it has one, is a DXN document whose value matches the given type: .dxnb under application/dxnb, text otherwise |
| `encodes` | bytes | the bytes are a .dxnb document whose value matches the given type (CDDL's .cbor) |
| `encodes-seq` | bytes | the bytes are .dxnb documents back to back, each with its envelope, each matching the given type; none at all too (CDDL's .cborseq) |
| `min-count` | list/set/tuple/sorted-set/array | element count >= given integer |
| `max-count` | list/set/tuple/sorted-set/array | element count <= given integer |
| `contains` | list/set/tuple/sorted-set/array | at least min-contains (1 when not given) and at most max-contains elements match the given type |
| `min-contains` | with contains | how many elements must match contains, at least |
| `max-contains` | with contains | how many elements may match contains, at most |
| `unique` | list/set/tuple/sorted-set/array | true: no two elements are the same value |
| `unique-by` | list/set/tuple/sorted-set/array | no two elements' given field is the same value; an element without it is compared with none |
| `finite` | float | true: neither NaN nor an infinity |
| `float32` | float | true: single precision holds the value exactly (NaN and the infinities it holds) |
| `min-precision` | decimal | the coefficient's digit count, as written, >= given integer (1.50M has 3) |
| `max-precision` | decimal | the coefficient's digit count <= given integer |
| `min-exponent` | decimal | the exponent >= given integer (1.50M's is -2) |
| `max-exponent` | decimal | the exponent <= given integer |
| `bits` | integer/bytes | only the bits numbered in the given list are set: a non-negative integer's from its lowest, bytes from the first byte's lowest (RFC 8610's .bits) |
| `before-now` | datetime | true: before the time of the check |
| `after-now` | datetime | true: after the time of the check |
| `within` | datetime | no further from the time of the check than the given duration, either way |
| `resolution` | time/datetime/local-datetime/duration | no part finer than the given unit, :second, :millisecond, :microsecond or :nanosecond |
| `offsets` | datetime | the value's offset is one of the given strings, Z or ±HH:MM |
| `version` | ip | 4 or 6: the value is that family |
| `prefix` | ip | true: a prefix; false: an address |

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
its shared values and string references (DXN.md §2.4) are not the enclosing
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

**Two values are the same when their canonical forms are** (DXN.md §1.5), for
`unique` and `unique-by`: `1` and `1.0` differ, as `%{a: 1}` and
`%{"a" => 1}` do.

**NaN lies outside every range** (Jan, 2026-10-20): `min`, `max` and
both `exclusive-` bounds refuse it, as every IEEE 754 comparison with NaN
is false; `Infinity` and `-Infinity` compare as the numbers they are.
`finite: true` refuses all three.

**`:timestamp` is sugar for a datetime in UTC**, `{:refine :datetime
%{offsets: ["Z"]}}`: DXN 0.2 had a timestamp type of its own, and a
schema naming it keeps its meaning (DXN.md §1.2).

## 2a. Formats (`format:`)

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

| Name | Checked as |
|---|---|
| `date` | @date's reader (DXN.md §1.2) |
| `time` | @time's reader |
| `datetime` | @datetime's reader: an offset, Z or ±HH:MM, is required |
| `local-datetime` | @local-datetime's reader: no offset |
| `duration` | @duration's reader |
| `uuid` | @uuid's reader: 8-4-4-4-12 hex digits, either case |
| `ipv4` | @ip's reader: an IPv4 address, no prefix |
| `ipv6` | @ip's reader: an IPv6 address, no prefix, no zone |
| `hostname` | labels LABEL joined by dots, 253 codepoints at most |
| `idn-hostname` | labels U-LABEL joined by dots, 253 codepoints at most |
| `email` | LOCAL @ DOMAIN, split at the last @: LOCAL at most 64 bytes, DOMAIN a hostname, [IPv4] or [IPv6:address] |
| `idn-email` | as email, with IDN-LOCAL and an idn-hostname |
| `uri` | RFC 3986's URI, from the parts below |
| `uri-reference` | a uri, or RFC 3986's relative-ref |
| `iri` | a uri that may hold any character past ASCII where it holds an unreserved one |
| `iri-reference` | an iri, or a relative-ref that may |
| `uri-template` | RFC 6570's URI-Template, below |
| `json-pointer` | RFC 6901, below |
| `relative-json-pointer` | draft-handrews-relative-json-pointer, below |
| `semver` | Semantic Versioning 2.0.0, below |
| `mac` | six or eight pairs of hex digits, one separator, : or -, throughout |
| `host-port` | HOST:PORT, split at the last colon: HOST a hostname, an IPv4 address or [IPv6], PORT 0 to 65535 without leading zeros |

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

The URI parts (RFC 3986 DXN.md §3); for an iri, every PCT is
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
refuses (§2). JSON Schema's `regex` format has no counterpart: whether
a pattern compiles depends on the engine, and not every implementation
has PCRE.

## 3. Required vs. optional fields

No separate flag: a field key ending in `?` is optional; any other key
is required. `?` is already a legal `ident_char` (DXN.md §1.1) — no grammar
addition. The `?` itself is not part of the field's name.

**Optional means the field may be absent, not that it may be `nil`.**
An optional field that is present must match its type like any other,
so `nil` is refused unless the type admits it (`{:nilable t}`). Text
leaves an absent field out. A positional form must fill every position
— `.dxnb` always — so an encoder writes an absent field's default where
it has one, and otherwise refuses (`schema/missing-field`) rather than
writing `nil` the reader would refuse.

## 4. Struct schemas (`%schema(N){}`/`%field{}`)

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
struct's positional wire form (DXN.md §2.1) needs. A field named twice is an
error. A keyed `%Name{...}` *data* literal may still list its fields in
any order — names alone resolve those; the order requirement is on the
schema's body only.

**The header holds only the version** (§8). A schema written without
one, `%schema{...}`, is version 1.

`%field{type:, default:, description:}` is reached only when a field
needs metadata beyond a bare `type_expr` — a default value (used when
the field is absent; independent of `?`, which controls whether
*absence itself* is an error) or a human-readable description. It never
carries its own optionality flag — that's always the key's `?` suffix.

## 4a. Shapes (`%shape{}`) and `{:case}`

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
extra, kept; a strict decode (§7) refuses extras. **A missing field
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

## 5. Named types

Any top-level entry whose value is not a `%schema{}` defines a **named
type**: a reusable name for a `type_expr`, e.g.
`PositiveInt: {:refine :integer %{min: 1}}`. It's referenced exactly
like a struct name — a bare symbol (§1's `reference` form) — since
both are resolved the same way: by name, against whatever this
document (or an already-known document, §6) defines.

A named type's own body MAY reference another named type, **including
one declared alongside it in the same document**, in any order: a
reader compiles every named type of a document before it resolves any
reference between them, so the top-level `map`'s order (which DXN.md §1.4
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
finite (DXN.md §2.5) and every guard steps into a smaller part of it:

```text
Comment: %shape{text: :string, replies?: {:list-of Comment}}
JsonValue: {:any-of :nil :boolean :integer :float :string
                    {:list-of JsonValue} {:map-of :string JsonValue}}
```

A cycle stays within one document: a reference to another file sees
only documents read before it (§6).

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
order; two-phase compilation needs no order at all. Shapes (§4a)
name their siblings as a matter of course (`OrderCancelled` naming
`CancelReason` beside it), so resolution is now required.

## 6. Cross-file references

An `identifier` (DXN.md §1.1) is segments joined by `.`, with at most one `/`
between a namespace and a name: `Foo.Bar/Baz`, `acme.billing/Invoice`.
The namespace is everything before the `/`, dots included. A name with a
`/` is the mechanism this document uses for referencing a struct schema
or named type defined in a separate `.dxns` file or unit.

Resolving a name to a document (a file path, a registry lookup, a
network fetch, ...) is reader-defined. **A reader that resolves names to
files follows this convention**, so that one set of schema files serves
every implementation. A struct of version `N` named `Foo.Bar/Baz` is
looked for, on each search path in order, in:

| Layout | Version 1 | Version N |
|---|---|---|
| directories | `Foo/Bar/Baz.dxns or Foo/Bar/Baz-v1.dxns` | `Foo/Bar/Baz-vN.dxns` |
| one directory per name | `Foo/Bar/Baz/v1.dxns` | `Foo/Bar/Baz/vN.dxns` |
| flat | `Foo.Bar.Baz.dxns or Foo.Bar.Baz-v1.dxns` | `Foo.Bar.Baz-vN.dxns` |
| namespace file | `the entry Baz in Foo.Bar.dxns` | `the same file, by its %schema(N)` |

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
  older one reaches the materializer (§8); a struct without a version
  is read as the highest found.

## 7. Enforcement

A struct value decoded without a schema for its name is an opaque
tagged value (DXN.md §1.4) — never an error. Once a schema is known for a
given name, a conforming reader MUST enforce, for every value of that
struct:

- every required field (§3) is present;
- every present field's value matches its declared `type_expr`
  (§1/§2).

**A value matches only its declared type, and nothing is converted to
make it match.** An integer is not a string, however easy the
conversion; a map is not a struct. A field typed `User` accepts only a
`User` struct: a struct named `User` (checked against `User`'s schema,
or opaque when there is none, DXN.md §1.4), or the application value a reader
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
- **An extra field's key follows the map-key rule** (DXN.md §1.6).
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
its category (DXN.md §5) is not.

## 8. Schema versions

**Each `.dxns` document describes one version of each schema it
holds**, written in the schema's header: `%schema(3){...}`, version 1
when there is no header. Versions are positive integers. A reader loads
any number of documents and keeps every schema by its name *and* its
version, so `User` versions 1, 2 and 3 can be loaded side by side, from
three documents.

- **Loading a version already loaded is an error**
  (`schema/duplicate-version`, DXN.md §5): two documents that both claim to be
  `User` v3 are a mistake, not an update.
- **Replacing a loaded version is a separate, explicit operation** — the
  hot swap of a running system. It only ever replaces: naming a version
  that is not loaded is an error (`schema/not-loaded`), so a typo never
  quietly adds one.
- **A struct literal may carry the version it was written with**:
  `%User(3){...}`, `%User(3)[...]`. In `.dxnb` the version is part of
  the struct's type name, `"User(3)"` (DXN.md §2.2), shared after its first
  occurrence like any type name (DXN.md §2.4). A version that is not a
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
