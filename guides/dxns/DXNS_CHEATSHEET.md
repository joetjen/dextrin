# DXNS Cheatsheet

DXNS, the schema language of DXN, on one page. The whole story is the
[reference](DXNS.md); a gentle start is the [tutorial](TUTORIAL.md).

## A schema document

A `.dxns` file is a DXN map from names to definitions:

```dxns
%{
  # A struct schema: a record that travels under its name, versioned.
  User: %schema(2){
    name: :string
    email: {:refine :string %{format: :email}}
    nickname?: :string                        # "?" makes a field optional
    role: %field{type: {:enum :admin :staff}, default: :staff, description: "What they may do"}
  }

  # A named type: a name for a type, used like any other.
  PositiveInt: {:refine :integer %{min: 1}}

  # A shape: a plain map with these fields, defaults filled in.
  Point: %shape{x: :float, y: :float, label: %field{type: :string, default: ""}}
}
```

## Primitive types

| Type | Matches |
|---|---|
| `:any` | any value |
| `:never` | no value |
| `:nil`, `:boolean` | `nil`; `true` or `false` |
| `:integer`, `:float`, `:decimal`, `:rational` | `42`; `1.5`; `19.99M`; `22/7` |
| `:string`, `:char`, `:symbol`, `:keyword` | `"text"`; `?c`; `name`; `:name` |
| `:bytes`, `:bits` | `@bytes "..."`; whole bytes, or `@bits {"..." n}` too |
| `:date`, `:time`, `:datetime`, `:local-datetime`, `:duration` | `@date "2026-10-21"`, `@time "..."`, `@datetime "...Z"`, ... |
| `:uuid`, `:objectid`, `:ip`, `:uri`, `:regex` | `@uuid "..."`, `@objectid "..."`, `@ip "..."`, `@uri "..."`, `@regex "..."` |
| `:list`, `:tuple`, `:map`, `:ordered-map`, `:set`, `:sorted-set`, `:array` | a collection of that kind, any elements |
| `:timestamp` | a datetime in UTC: `{:refine :datetime %{offsets: ["Z"]}}` |
| `:int32`, `:int64`, `:uint32`, `:uint64` | an integer in that range |
| `:float32` | a float that single precision holds exactly |
| `:number` | any integer, float, decimal or rational |

## Type forms

| Form | Matches |
|---|---|
| `Name` | the struct schema or named type `Name` (`ns/Name` in another file) |
| `{:list-of T}` | a list, every element a `T` |
| `{:list-items A {:repeat B 0 nil}}` | a list item by item: an `A`, then any number of `B` |
| `{:repeat {:group A B} 1 3}` | inside `list-items`: `A B` together, once to three times |
| `{:set-of T}`, `{:sorted-set-of T}`, `{:array-of T}` | that collection, every element a `T` |
| `{:tuple-of A B C}` | a tuple of exactly these, in order |
| `{:tuple-of-all T}` | a tuple of any length, every element a `T` |
| `{:map-of K V}`, `{:ordered-map-of K V}` | every key a `K`, every value a `V` |
| `{:enum a b c}` | exactly one of these literals |
| `{:const v}` | exactly the value `v` |
| `{:one-of A B}` | exactly one of `A` and `B` |
| `{:any-of A B}` | one or more of them |
| `{:all-of A B}` | all of them |
| `{:not T}` | anything that is no `T` |
| `{:nilable T}` | `nil` or a `T` |
| `{:if I T E}` | an `I` must be a `T`; anything else an `E` (`:any` when left out) |
| `{:refine T %{...}}` | a `T` that also meets the constraints below |
| `{:case field %{v => T, :else => U}}` | the type the sibling `field`'s value chooses |
| `{:tagged acme.money T}` | the custom tag `@acme.money` around a `T` |
| `{:doc T %{description: "..."}}` | a `T`, annotated (see below) |
| `{:generic [t] body}` | a named type with parameters |
| `{:of Name T}` | one use of a generic |
| `%shape{...}` | a plain map with these fields |
| `%schema(N){...}` | a struct schema, version `N` (1 when left out) |

## Refine constraints

| Key | Applies to | Means |
|---|---|---|
| `min`, `max`, `exclusive-min`, `exclusive-max` | numbers, dates, times, durations | a range, against a value of the same kind |
| `multiple-of` | numbers | an exact multiple |
| `finite` | float | `true`: no NaN, no infinity |
| `float32` | float | `true`: single precision holds it |
| `min-precision`, `max-precision` | decimal | digits of the coefficient, as written |
| `min-exponent`, `max-exponent` | decimal | the exponent (`1.50M` has -2) |
| `bits` | integer, bytes | only these bit numbers may be set |
| `min-length`, `max-length` | string, keyword, symbol, bytes, bits | codepoints; bytes; bits under `:bits` |
| `min-bytes`, `max-bytes` | string, keyword, symbol | UTF-8 bytes |
| `pattern` | string, keyword, symbol, bytes | matches `@regex "..."` |
| `format` | string | one of the formats below |
| `encoding` | string | `:base64`, `:base64url`, `:base32`, `:base16` |
| `media-type` | string | `"type/subtype"`, telling `content` how to read |
| `content` | string | holds a DXN document of the given type |
| `encodes`, `encodes-seq` | bytes | one `.dxnb` document, or several, of the given type |
| `min-count`, `max-count` | list, set, tuple, sorted set, array | how many elements |
| `contains`, `min-contains`, `max-contains` | those collections | how many elements are a given type |
| `unique`, `unique-by` | those collections | no two elements, or their field, the same |
| `offsets` | datetime | `["Z" "+01:00"]`: the allowed offsets |
| `resolution` | time, datetime, local datetime, duration | `:second`, `:millisecond`, `:microsecond`, `:nanosecond` |
| `before-now`, `after-now`, `within` | datetime | against the clock: `within: @duration "PT1H"` |
| `version`, `prefix` | ip | `4` or `6`; `true` a prefix, `false` an address |

An unknown key, or an argument of the wrong kind, is a compile error.
A constraint refuses a value it does not apply to.

## Formats

`date`, `time`, `datetime`, `local-datetime`, `duration`, `uuid`, `ipv4`,
`ipv6`, `hostname`, `idn-hostname`, `email`, `idn-email`, `uri`,
`uri-reference`, `iri`, `iri-reference`, `uri-template`, `json-pointer`,
`relative-json-pointer`, `semver`, `mac`, `host-port`.

## Annotations

| Key | Takes | Means |
|---|---|---|
| `title`, `description` | string | a name; what it is for |
| `examples` | list | values the type takes |
| `read-only`, `write-only` | boolean | written by its owner only; never read back |
| `deprecated` | boolean or string | on its way out, with the reason |
| `meta` | map | anything else, kept as written |
| `values` | map | on an enum: each value's own annotations |

## Fields

| Written | Means |
|---|---|
| `name: T` | required |
| `name?: T` | optional: may be absent |
| `name: %field{type: T, default: v}` | absent means `v` |
| `name: %field{type: T, description: "..."}` | documented |
| `name: {:nilable T}` | present, but may be `nil` |

## Versions

| Written | Means |
|---|---|
| `%schema{...}` | version 1 |
| `%schema(3){...}` | version 3; every loaded version is kept |
| `%User(3){...}` | data written against version 3 |
| `%User{...}` | data read as the latest loaded version |

Append fields only; anything else deploys readers first, each with a
materializer for the old version.

## Files

| File | Names its entries |
|---|---|
| `acme.shop.dxns` | `acme.shop/Entry` (a namespace file) |
| `acme/shop/Order.dxns` | `acme.shop/Order`, and `acme.shop.Order/Line` for another entry in it |
| `acme/shop/Order/v2.dxns`, `Order-v2.dxns` | version 2 of `acme.shop/Order` |

A bare `Name` means an entry of the same file; `ns/Name` an entry of
another.

## Errors

| Category | Means |
|---|---|
| `schema/compile` | the schema is wrong |
| `schema/type-mismatch` | a value is not of its type |
| `schema/missing-field` | a required field is absent |
| `schema/undeclared-field` | a strict decode met a field no schema declares |
| `schema/unknown-version` | data was written against a version not loaded |
| `schema/no-materializer` | an older version with nothing to upgrade it |
| `schema/duplicate-version` | two documents claim the same version |
| `schema/not-loaded` | replacing a version that was never loaded |
| `schema/field-count` | a positional struct with the wrong number of items |
| `schema/shadowed-field` | an extra field named like a declared one |
| `schema/materializer` | a materializer refused, or built a value its schema refuses |
| `schema/version-discipline` | a released version changed (the compatibility check) |
