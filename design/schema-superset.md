# DXNS as a superset of the other schema languages

Status: proposal, 2026-10-20, for Jan to decide group by group. Nothing
here is implemented.

## The goal

Jan, 2026-10-20: DXNS must be able to say everything the schema
languages of the formats the README compares DXN with can say:

- JSON Schema, every draft from 03 to 2020-12, and every required and
  optional test of the official suite;
- MongoDB's `$jsonSchema`, for BSON;
- CDDL, for CBOR (RFC 8610, 9165 and 9682);
- Protocol Buffers: proto2, proto3 and editions;
- Ion Schema: ISL 1.0 and 2.0;
- whatever YAML, TOML and MessagePack can say.

The one exception is a feature that makes no sense for DXN, or has
little or no value. DXNS may say a thing differently, or better. Parity
is one-way: from those languages to DXNS.

## Method

Five research passes ran on 2026-10-20, one per schema language and
one for YAML, TOML, MessagePack, CBOR and BSON together. Each read
DXN.md §1–§4 and shapes-and-case.md, and listed every construct of its
language with the DXNS form or "missing".

The Ion, CDDL and JSON Schema passes read their specifications or test
listings online. The Protobuf and YAML/TOML/MessagePack passes worked
from what is known about those formats. Their gaps are plausible but
should be checked against protobuf.dev before they are built.

What is already covered needs no work. `one-of` as exactly one,
`any-of`, `not`, `:never`, the new collection element types, enums,
numeric ranges, `multiple-of`, lengths, `pattern`, required and
optional fields, defaults, unions, intersections, cross-file names,
versions, and now `%shape` and `{:case}` cover most of every language.

Some things are better in DXNS already:

- protobuf's `Any` is unnecessary, because a value names its own struct;
- wrapper types become `?` and `{:nilable}`;
- `oneof` over message types becomes `{:one-of}`;
- if/then/else is written with `any-of`, `all-of` and `not`.

## The gaps, grouped

Each group closes several languages' constructs with one DXNS form. In
the "Needed by" column, J is JSON Schema, M is MongoDB, C is CDDL, P is
Protobuf, I is Ion Schema, and Y is YAML, TOML or MessagePack.

### 1. Recursion and parameters (J C I P)

| Gap | Proposed |
|---|---|
| A named type that refers to itself (trees, JSON's own value type `Value`, `$ref` cycles) | allowed when the recursion is guarded by a collection, shape or schema; refused only when it is unguarded (`A: A`) |
| `$dynamicRef`, CDDL generics `<t>` | parameterised named types: `Envelope: {:generic [t] %shape{payload: t}}`, used as `{:of Envelope OrderPlaced}` |
| Choices extended by another document (CDDL socket and plug) | `Alg: {:socket {:enum 1 -7}}`; another document adds `{:plug acme/Alg {:enum -35}}` |

### 2. Maps and shapes (J M C I P)

| Gap | Proposed |
|---|---|
| Closing one type (additionalProperties false, ISL closed, CDDL default) | `%shape{..., :closed => true}`, written as a keyword key in the body, so it can't be a field |
| Typed extras beside the fields (additionalProperties as a schema, CDDL `* tstr => int`) | `:rest => {:map-of K V}` in the body |
| Keys by pattern (patternProperties, CDDL computed keys) | `:rest => {:map-of {:refine :string %{pattern: @regex "^x-"}} T}`; several patterns with `{:all-of}` |
| Number of entries (min/maxProperties, ISL container_length, protovalidate min/max_pairs) | `min-count`/`max-count` extended to map, ordered-map, sorted-set and array |
| Key type of a shape (propertyNames) | `:keys => T` in the body |
| Dependencies (dependentRequired, dependentSchemas) | refine `requires: %{"a" => ["b"]}`, `when-present: %{"a" => T}` |
| Exclusive siblings (protobuf `oneof` over fields of the same type) | refine `exclusive: [[email phone]]` (at most one present), `one-required: [[email phone]]` (exactly one) |
| unevaluatedProperties | refine `unevaluated: T`: whatever no field, `:rest` or pattern matched in the passing branches |
| Including one shape in another (CDDL `~` unwrap) | `%shape{:include => [Base], ...}` (in `%schema` too); fields and defaults merge |
| Group choice inside a map (CDDL `//`) | `{:one-of A B}` over closed shapes; no new form needed once `:closed` exists |

### 3. Field keys (J C)

| Gap | Proposed |
|---|---|
| Field names that are not identifiers (`"foo\nbar"`, `""`, `"__proto__"`) | a quoted key as a field: `"foo bar" => T`. **Decision:** how is such a field optional, given that `%field{}` is meant never to carry optionality? |
| Integer keys (CDDL, COSE/CWT: `1 => alg`) | `alg: %field{key: 1, type: :integer}`: the name is what code uses, the key is what is written |
| Inline anonymous shapes (nested JSON objects) | allow `%shape{...}` wherever a `type_expr` goes. The compiler accepts it already; the spec says shapes are named. |
| A removed field keeping its position (protobuf `reserved`) | `old_email: %field{type: :never, reserved: true}`. Its position stays, written as `nil`, and the version check refuses reusing the name or the slot. **This is the most important Protobuf gap**: without it, removing a field moves every later field in `.dxnb`, and older readers misread them. |

### 4. Lists and sequences (J C I Y)

**Done** (Jan, 2026-10-20; DXN.md §4.1a, §4.2), as proposed below except
`unevaluated`: `{:list-items}` closes a list already, every item taken
by one of its parts, so `unevaluatedItems: false` is the list-items
itself and an open list ends in `{:repeat :any 0 nil}`. What was wrong
with proposing it: it carried JSON Schema's way of closing a *composed*
list over, where DXNS writes the items in one form instead. Unknown
refine keys became a compile error on the way.

| Gap | Proposed |
|---|---|
| A fixed head and a repeating tail (prefixItems/items, CDDL `[tstr, * int]`, ISL `ordered_elements`) | `{:list-items a b {:repeat c 0 nil}}`; `{:repeat {:group a b} min max}` for repeated groups |
| contains, minContains, maxContains (also ISL contains) | refine `contains: T`, `min-contains: n`, `max-contains: n` |
| Unique items (uniqueItems, ISL distinct, protovalidate unique) | refine `unique: true` |
| Unique by a field across a list of maps (Kwalify `ident`) | refine `unique-by: field` |
| Element type of a tuple of any length (Ion sexp) | `{:tuple-of-all T}` |
| unevaluatedItems | refine `unevaluated: T` on lists, as on maps |

### 5. Scalar constraints: new refine keys (J M C I P Y)

**Lengths, patterns, decimals, `float32`, `bits` and temporal ranges
done** (Jan, 2026-10-20; DXN.md §4.2). Two changes from the proposal:
a temporal's precision is `resolution: :millisecond` (no part finer),
since a DXN time carries no written precision for a `min-precision` to
read, and a refine key now refuses a value it does not apply to. Left
out: `grammar:` and `check:`, rated low value below. **`format:` done**
too (DXN.md §4.2a): every format of the row below but `regex`, whose
answer depends on the engine, plus `datetime`/`local-datetime` in
DXN's own names for JSON Schema's `date-time`. The encoding keys follow.

| Gap | Proposed |
|---|---|
| String formats (every draft's: date-time, date, time, duration, email, idn-email, hostname, idn-hostname, ipv4, ipv6, uri, uri-reference, iri, iri-reference, uri-template, json-pointer, relative-json-pointer, regex, uuid; also semver, mac and host-port) | refine `format: :email` and so on, from a closed set |
| contentEncoding, contentMediaType, contentSchema | refine `encoding: :base64`, `media-type: "..."`, `content: T` |
| Embedded encoded data (CDDL `.cbor`/`.cborseq`) | refine `encodes: T` (and `encodes-seq: T`) on bytes: the bytes are a `.dxnb` document matching T |
| Byte lengths (CDDL `.size`, ISL byte_length and utf8_byte_length, protovalidate min_bytes) | `min-length`/`max-length` extended to bytes (in bytes) and bits (in bits); `min-bytes`/`max-bytes` on strings (UTF-8) |
| Length and pattern on keyword and symbol (ISL symbol) | extend `min-length`, `max-length` and `pattern` to keyword and symbol |
| Pattern on bytes (protovalidate) | extend `pattern` to bytes |
| Decimal precision and exponent (ISL precision/exponent, decimal128) | refine `min-precision`, `max-precision`, `min-exponent`, `max-exponent` |
| Finite floats, single precision (protovalidate finite, protobuf float, ISL ieee754_float) | refine `finite: true`, `float32: true` |
| Allowed bits (CDDL `.bits`) | refine `bits: [0 1 4]` |
| Ranges on dates and times (ISL timestamp ranges, protovalidate, Yamale) | `min`, `max` and `exclusive-*` extended to date, time, timestamp, datetime and duration; plus `before-now`, `after-now` and `within: @duration "PT1H"` |
| Offsets and precision of times (ISL timestamp_offset/timestamp_precision) | refine `offsets: ["+01:00"]`, `min-precision`/`max-precision` on temporals |
| Grammar-checked strings (CDDL `.abnf`), named predicates (protovalidate CEL) | refine `grammar: "..."`, `check: :name`. Low value: neither is portable without a grammar engine or an expression language. |

### 6. Regex semantics (J C I)

`pattern` is unanchored today, as JSON Schema's and ISL's are; CDDL's
`.regexp` matches the whole value, which `^...$` writes. JSON Schema's
suite tests ECMA-262 behaviour: ASCII `\d` and `\w`, and Unicode `\s`.
DXN's regex is PCRE. **Decision:** keep PCRE and let the parity tool
translate, or define `pattern` as ECMA-262 with the `u` flag (an `e`
flag?). Also to write down: whether NaN lies inside a number range, as
ISL says it never does.

### 7. Typed custom tags (M C I Y)

| Gap | Proposed |
|---|---|
| A custom tag by name with a typed value (YAML local tags, MessagePack ext, BSON user binary, CBOR tags, Ion clob, ObjectId) | `{:tagged objectid {:refine :bytes %{min-length: 12, max-length: 12}}}` |

### 8. Annotations and metadata (J C I P)

| Gap | Proposed |
|---|---|
| title, description, examples, readOnly/writeOnly, deprecated anywhere, not just on fields | `{:doc T %{title:, description:, examples:, read-only:, write-only:, deprecated:}}` |
| Description and deprecation of a schema itself | a header map beside the version: `%schema(3, %{description: "...", deprecated: true}){...}` |
| Docs, deprecation and reservation of single enum values | `{:enum %{:red => %{description: "..."}, :old => %{deprecated: true}}}` |
| Custom options and user fields (protobuf options, ISL open content and user_reserved_fields) | `%field{meta: %{"acme.pii" => true}}`, and the same `meta:` in the schema header: kept and readable, with no meaning to the validator |
| Feature markers (CDDL `.feature`) | low value; `meta:` covers it |

### 9. Sugar (P M J)

`:int32 :int64 :uint32 :uint64` (protobuf, MongoDB), `:number`,
`{:const v}`, `{:if I T E}`. Built-in named types and forms; nothing
they say is new.

## Data model: DXN itself, not DXNS

These need a DXN type, or a rule, before a schema can say anything
about them. Each is a decision about the format. The format version
stays 1.0, so each would be an addition within 1.0.

| Gap | From | Proposed |
|---|---|---|
| Local date-time (no offset) | TOML, YAML, ISO | `~N[YYYY-MM-DD HH:MM:SS]`, a new binary tag, `:local-datetime` |
| Nanosecond time | TOML, protobuf Timestamp/Duration, MessagePack, CBOR 1001 | either widen time, timestamp, datetime and duration to nanoseconds, or write down that they are cut to microseconds |
| IP addresses and prefixes | CBOR tags 52/54, protovalidate, Yamale | `@ip "192.0.2.1"`, `@ip "2001:db8::/32"`; `:ip` |
| ObjectId | BSON | `@objectid "..."`, or a written custom-tag convention plus group 7 |
| Names for foreign tags | MessagePack ext, YAML global tags, BSON subtypes | a written convention for custom-tag names |
| Unknown trailing positions | protobuf keeps unknown fields | `.dxnb` keeps items past a reader's fields as extras instead of dropping them (open in schema-evolution.md) |
| Indefinite-length CBOR items | CBOR | §2 says a decoder accepts them and an encoder never writes them |
| Import cycles and diamonds | ISL | §4.6 says both are allowed and resolve |
| Annotations on any value | Ion | partly possible as nested custom tags; needs a written mapping, and then `{:tagged}` |

## Out on purpose

Wire encodings:
- protobuf's sint, fixed, packed, groups and delimited;
- CBOR major types, simple values and encoding hints;
- MessagePack's integer widths.

Things DXN rules out by design:
- YAML anchors, aliases and graphs (§2.5 makes cycles non-values), and YAML merge keys;
- complex and arbitrary-type map keys (§1.6);
- duplicate keys and repeated Ion fields.

Things specific to another system:
- BSON's MinKey/MaxKey, DBPointer, JavaScript code and replication Timestamp, `undefined`, and Ion's typed nulls and symbols with unknown text;
- protobuf's `json_name`, `import public`/`weak` and services/RPC (DXNS describes values, not operations);
- CDDL's `.plus`/`.cat`/`.det`, numeric tag numbers, and names on `&` enums;
- NaN's sign, and decimal NaN/Inf.

## What the parity test tool decides

These are mappings, not DXNS (Jan: they are the converter's business):
- whether JSON `1.0` is an integer (drafts 6 and later say yes);
- numeric equality in enum, const and unique;
- big numbers;
- whether object keys are strings or keywords;
- object to map, array to list;
- `true` is not `1`;
- object equality ignores key order;
- strings stay strings;
- the regex dialect;
- names for `$id`, anchors and nested schemas;
- which draft is in force;
- and comparing results with filled-in defaults ignored.

## Order proposed

1. Group 2 (maps) and group 4 (lists). They close the most constructs: about 17 JSON Schema keywords and CDDL's highest-value gaps.
2. Group 1 (recursion), because JSON Schema's suite, protobuf's `Struct` and CDDL need it.
3. Group 3's reserved position, for binary safety.
4. Groups 5, 7 and 8.
5. The data-model table, one decision at a time.
6. The parity test tool against JSON Schema's official suite, then a CDDL and an ISL corpus.
