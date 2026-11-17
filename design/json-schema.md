# JSON Schema to DXNS (T674)

Status: built in Elixir, 2026-11-17 (`Dextrin.Convert.JsonSchema`,
`mix dextrin.from_json_schema`); node and PHP follow.

## Decisions (Jan, 2026-11-17)

All eight questions below as recommended:
- Q1: object schemas are `%shape`, `--structs` writes `%schema`.
- Q2: several `* K => V` entries; `- *` beside them closes the rest
  (DXNS.md §4c).
- Q3: `min-count` and `max-count` on maps, shapes and structs.
- Q4: unevaluated* worked out statically, the rest reported. Built:
  if/then/else, anyOf, oneOf and dependentSchemas at the top of a schema
  are written out with `{:if}` (up to six such branches), and `contains`
  counts as evaluating the items it matches.
- Q5: drafts 04, 06, 07, 2019-09, 2020-12 and MongoDB's.
- Q6: references only among the files given; nothing fetched.
- Q7: the suite is vendored (release 23.1.0) and run in CI; exceptions in
  test/fixtures/json-schema-exceptions.txt, by reason.
- Q8: ECMA-262 patterns translated (`\d`, `\w` ASCII, `$` at the very
  end, `\uXXXX`).

Found while building: from 2019-09, `format` and the content keywords
are annotations, so the converter checks them only for 04 to 07 or under
`--assert-formats`, and the logical types apply only where formats are
checked; in 2019-09 and 2020-12 the format goes to `meta`.

Jan, 2026-11-17: convert JSON Schema to DXNS with a mix task, an npm
script and a PHP command, MongoDB's `$jsonSchema` (`bsonType`)
included. YAML input is T675. The converter follows the decisions of
[typespec.md](typespec.md): logical types, unknown formats kept in
`meta`, deprecation, versions as Way B where they apply.

The goal is the one of [schema-superset.md](schema-superset.md): a
converted schema accepts and refuses the same values as the original.
Where it can't, the converter says so (see "What can't be exact").

## The tools

| Where | Command |
|---|---|
| Elixir | `mix dextrin.from_json_schema SCHEMA... [--out FILE] [--name Root] [--draft D] [--mongo] [--strict]` |
| Node | `npx dextrin from-json-schema ...`, the same options |
| PHP | `bin/dextrin from-json-schema ...`, the same options |
| Library | `Dextrin.Convert.JsonSchema.to_dxns(map, opts)` and its ports, returning the DXNS document and the list of what is not exact |

- The output is one `.dxns` document, written by the formatter.
- `--strict` exits non-zero when anything is not exact; without it,
  each such place is printed as a warning and kept in `meta`.
- The draft comes from `$schema`; without one, `--draft` says it, and
  the default is 2020-12. `bsonType` anywhere, or `--mongo`, reads the
  schema as MongoDB's draft-04 subset.

## Names

- `$defs` (`definitions` before 2019-09) entries become named entries.
  Their keys become identifiers: characters an identifier can't hold
  become `_`, and a clash gets a number.
- The root is named by `--name`, otherwise by `title`, otherwise
  `Root`.
- An object schema written inline stays an inline `%shape` (T673's
  rule), unless something refers to it by `$ref`
  (`#/properties/address`); then it is named from its path,
  `RootAddress`.
- `$id` and `$anchor` resolve references. An absolute `$id` is kept in
  `meta` as `json-schema-id`.

## The mapping

### Types and values

| JSON Schema | DXNS | Exact? |
|---|---|---|
| `true` / `false` schema | `:any` / `:never` | yes |
| `"type": "string"` | `:string` | yes |
| `"type": "integer"` | `:integer` | yes, for DXN values; see "numbers" below |
| `"type": "number"` | `:number` | yes |
| `"type": "boolean"`, `"null"` | `:boolean`, `:nil` | yes |
| `"type": "array"` | `{:list-of :any}`, refined below | yes |
| `"type": "object"` | a `%shape` or `%schema`, Q1 | yes |
| `"type": [a, b]` | `{:any-of a b}`; with `"null"`, `{:nilable ...}` | yes |
| `enum`, `const` | `{:enum ...}`, `{:const v}`; objects become maps, arrays lists, strings stay strings | yes |
| no `type` | each keyword applies only to values of its own kind, as JSON Schema says: `{:any-of ...}` over the kinds the keywords constrain, plus the rest as `:any` | yes |

### Strings

| JSON Schema | DXNS | Exact? |
|---|---|---|
| `minLength`, `maxLength` | `min-length`, `max-length` (code points, as JSON Schema counts) | yes |
| `pattern` | `pattern:` | Q8: the regex dialect |
| `format: date-time`, `date`, `time`, `duration`, `uuid`, `uri` | logical types `:datetime`, `:date`, `:time`, `:duration`, `:uuid`, `:uri` (T673 Q2) | yes, as logical types |
| `format` email, hostname, ipv4, ipv6, uri-reference, iri, json-pointer, ... | `{:refine :string %{format: :email}}` (DXNS.md §2a) | yes |
| an unknown `format` | `:string`, the name in `meta` (T673 Q5) | yes; JSON Schema checks nothing either |
| `contentEncoding: base64` (and no media type) | `:bytes` (logical) | yes, as a logical type |
| `contentEncoding`, `contentMediaType`, `contentSchema` otherwise | `encoding:`, `media-type:`; `contentSchema` in `meta` | yes; JSON Schema only annotates them |

### Numbers

| JSON Schema | DXNS | Exact? |
|---|---|---|
| `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum` (numbers; draft-04's booleans) | `min`, `max`, `exclusive-min`, `exclusive-max` | yes |
| `multipleOf` | `multiple-of` | yes |
| `1.0` is an integer (drafts 6 and later) | DXN keeps `1.0` a float, so `:integer` refuses it | no, by design: DXN values carry their kind |

### Arrays

| JSON Schema | DXNS | Exact? |
|---|---|---|
| `items` (one schema), `prefixItems` + `items` (2020-12), `items` array + `additionalItems` (before 2020-12) | `{:list-of T}`, `{:list-items a b {:repeat c 0 nil}}` | yes |
| `minItems`, `maxItems` | `min-count`, `max-count` | yes |
| `uniqueItems` | `unique: true` | yes |
| `contains`, `minContains`, `maxContains` | `contains`, `min-contains`, `max-contains` | yes |
| `unevaluatedItems` | the list-items form says it (DXNS.md §1a) | yes |

### Objects

| JSON Schema | DXNS | Exact? |
|---|---|---|
| `properties` + `required` | fields; one not required gets `?` | yes |
| `additionalProperties: false` | `- *` | yes |
| `additionalProperties: S` | `* :string => S` | yes |
| `patternProperties` | Q2 | not yet |
| `propertyNames` | Q2 | not yet |
| `minProperties`, `maxProperties` | Q3 | not yet |
| `dependentRequired`, `dependentSchemas`, draft-04's `dependencies` | `{:all-of S {:if %shape{a: :any} %shape{b: :any}}}` | yes for shapes; Q1 for schemas |
| `unevaluatedProperties` | Q4 | partly |
| `default` | `%field{default: v}`. A DXN reader fills it in on decode; JSON Schema only annotates | yes, for what is accepted |

### Composition and references

| JSON Schema | DXNS | Exact? |
|---|---|---|
| `allOf`, `anyOf`, `oneOf`, `not` | `{:all-of}`, `{:any-of}`, `{:one-of}`, `{:not}` | yes |
| `if` / `then` / `else` | `{:if I T E}` | yes |
| `$ref` within the document, recursion included | a named type; recursion is guarded by an object or an array, as JSON's is | yes |
| `$ref` to another file | Q6 | |
| `$recursiveRef` (2019-09), `$dynamicRef` (2020-12) | the common "extend a recursive schema" pattern becomes a `{:generic}`; anything else is reported | partly |
| `discriminator` (OpenAPI), when present | the `discriminator:` annotation | yes |

### Annotations

| JSON Schema | DXNS |
|---|---|
| `title`, `description`, `examples`, `readOnly`, `writeOnly`, `deprecated` | `{:doc T %{...}}`; `deprecated` now warns (G10) |
| `$comment`, unknown keywords | `meta` |

### MongoDB `bsonType`

MongoDB reads draft-04 without `$ref`, `definitions`, `default`,
`format` and `integer`, and adds `bsonType`:

| bsonType | DXNS |
|---|---|
| `double` | `:float` |
| `string`, `bool`, `null`, `array` | `:string`, `:boolean`, `:nil`, a list |
| `object` | as `type: object` |
| `objectId` | `:objectid` |
| `date` | `{:refine :timestamp %{resolution: :millisecond}}` |
| `int`, `long` | `:int32`, `:int64` |
| `decimal` | `{:refine :decimal %{max-precision: 34}}` (decimal128) |
| `binData` | `:bytes` |
| `regex` | `:regex` |
| `number` | `{:any-of :int32 :int64 :float :decimal}` |
| `timestamp`, `javascript`, `minKey`, `maxKey`, `dbPointer`, `symbol`, `undefined` | reported, as `:any`: no DXN value means them (schema-superset.md, "Out on purpose") |

## What can't be exact

- **`1.0` as an integer** (drafts 6 and later). A DXN value says what it
  is. Accepted.
- **The regex dialect** (Q8).
- **`$dynamicRef` beyond the common pattern**, and **`unevaluatedProperties`
  that depends on which branch passed** (Q4). Both are reported.
- **External `$ref` that is not given** (Q6).
- **BSON types with no DXN value**, listed above.
- **JSON Schema's annotation-only keywords**, `default` and
  `contentSchema`, mean more in DXNS: a default is filled in on decode.
  What is accepted is unchanged.

## Testing

- **Unit tests per construct**, in all three implementations. Elixir
  first, then node and PHP, as for T673.
- **The official JSON-Schema-Test-Suite** (MIT licence) as the parity
  test: each schema is converted and each instance turned into a DXN
  value, then checked. Every required test must pass, except a written
  list of the cases above (Q7).
- **Conformance cases** for the converters' shared output go in a later
  round.

## Questions for Jan

1. **An object schema in `$defs`: `%schema` or `%shape`?**
   - **Recommended: `%shape` by default**, with `--structs` writing
     `%schema` instead.
   - JSON data is maps. A `%schema` matches only structs (`%Name{...}`),
     so a JSON document converted to DXN would not match its own
     schema.
   - JSON Schema composes objects structurally: `allOf` of two object
     schemas, `if` over a sibling's presence, `dependentRequired`.
     Shapes do all of that today; structs need `extends` and new
     refine keys for the rest.
   - T673's "models become `%schema`" came from TypeSpec, whose models
     have names. JSON Schema has no models.
2. **`patternProperties` and `propertyNames`: build them on G1?**
   - **Recommended:** allow several `* K => V` entries in a body. A key
     no field declares must match V of every entry whose K accepts it.
     `- *` then means "nothing beyond the fields and the entries",
     rather than being refused beside them.
   - With that, every combination is exact:
     - each pattern becomes `* {:refine :string %{pattern: P}} => V`;
     - `additionalProperties: S` becomes `* {:all-of :string {:not P1} ...} => S`;
     - the converter folds patterns and `propertyNames` into the
       declared fields, whose names it knows.
   - This changes G1's "one `* K => V`, not both" rule in all three
     implementations, VS Code and the conformance cases.
   - The alternative is to report these as not exact.
3. **`minProperties` and `maxProperties`?**
   - **Recommended:** extend `min-count` and `max-count` to maps,
     shapes and structs, counting the entries present.
   - The alternative is to report them as not exact.
4. **`unevaluatedProperties`?**
   - **Recommended:** the converter works out which properties are
     evaluated where it can tell statically: `allOf`, `$ref`, and
     branches that declare the same properties. It reports the rest.
   - The alternative is a new DXNS refine key, `unevaluated:`, which
     schema-superset.md proposed and you left unbuilt.
5. **Which drafts?**
   - **Recommended:** 04, 06, 07, 2019-09 and 2020-12, with MongoDB's
     subset of 04.
   - Draft 03 is left out. Its `required: true`, `disallow`, `extends`
     and `divisibleBy` are rare now.
6. **A `$ref` to another file?**
   - **Recommended:** the converter reads every file given on the
     command line or under a `--schemas DIR`, matched by `$id` or by
     relative path. Nothing is fetched over the network. A reference
     to a file not given is an error.
7. **The parity test against the official JSON-Schema-Test-Suite?**
   - **Recommended:** vendor the suite's tests for the five drafts into
     `test/fixtures` (MIT, notice kept).
   - Elixir runs all of them.
   - node and PHP run the same set, read from the reference's copy
     beside them, rather than three copies.
8. **The regex dialect?** JSON Schema's regexes are ECMA-262, DXN's are
   PCRE.
   - **Recommended:** the converter translates what differs where it
     can (`\d` and `\w` as ASCII, `\p{...}`), and reports a pattern it
     can't translate.
