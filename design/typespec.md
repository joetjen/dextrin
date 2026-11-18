# TypeSpec in DXNS

Status: comparison and proposal, 2026-11-17 (T673); the gaps are
built (see Decisions), and the table below is what the T682 emitter writes
(refreshed 2026-11-18). The construct table is also the mapping the
TypeSpec-to-DXNS converter (T682) follows.

## Decisions (Jan, 2026-11-17)

- **Q1:** types only. The API layer is out.
- **Q2:** types are logical.
- **Q3:** a model is always a `%schema`, never a `%shape` by default.
  Rows below that say `%shape` for a model read `%schema` instead. What
  that needs is in the follow-up to Q3.
- **Q5:** `@format` names DXNS doesn't know are kept in `meta`.
- **Q6:** build every gap, G1 to G9, G7 and G8 included.
- **Q3 follow-up:** each instance of a generic model used becomes its
  own named `%schema`, named by `@friendlyName`, otherwise the template
  name followed by its arguments (`PageDog`). Inline anonymous models
  stay inline `%shape`, the one exception, so no names are invented.
- **Q7:** the converter is a TypeSpec emitter, an npm package.
- **Q4:** Way B, versioned named types (`%type(N)`); see "Way B" below.
- **G1:** body entries `* K => V` (typed extras) and `- *` (closed).
- **G10:** go as proposed, including deprecating one version of a schema.
- **G11:** a field may pin a version, written `Pet(1)`: DXN text for
  the tuple `{:at Pet 1}`, everywhere (see "G11" below).
- **Status:** G1, G10, G11 and Way B are built in Elixir (DXNS.md §4c,
  §1b, §5c), with two earlier rules replaced and recorded there: a
  struct reference may name a version, and a struct carrying a loaded
  older version is written at it (§8).

## The goal

Jan, 2026-11-17: "compare Dextrin Schemas to TypeSpec and make sure a
TypeSpec can be expressed exactly as Dextrin Schema."

Parity is one-way, as in [schema-superset.md](schema-superset.md): every
TypeSpec type must have a DXNS form that accepts and refuses the same
values. DXNS may say it differently.

## Method

The TypeSpec side is the documentation at typespec.io (version 1.18.0),
read on 2026-11-17:
- the language basics: built-in types, scalars, models, templates,
  unions, enums, intersections, literals, aliases, namespaces, values,
  operations, interfaces and visibility;
- the built-in decorators, read word for word;
- the versioning and HTTP decorator references, read as summaries.

Some facts were not on the pages read, and come from knowledge of
TypeSpec instead. They are marked †, and are checked before T682 is
built:
- `int32` and its siblings extend `integer`, which extends `numeric`;
- tuples `[A, B]`;
- `T | null`;
- templated unions;
- the `@encode` names beyond `rfc7231` and `unixTimestamp`;
- a property conflict in `A & B` is an error.

The DXNS side is DXNS.md on develop, including T666's `extends`,
`includes` and `- field`.

A verdict is one of:
- **exact**: the same values are accepted and refused;
- **approx.**: values are checked the same, but something is lost, and
  the row names it;
- **missing**: DXNS cannot say it today.

Two choices change many rows. They are questions Q2 and Q3 below, and
the table assumes the recommended answers:
- **types are logical**: a TypeSpec `utcDateTime` is a DXN datetime, not
  the JSON string a JSON emitter writes;
- **a model is a `%shape`**: a plain map, as on TypeSpec's JSON wire.

## 1. Scalars

| TypeSpec | DXNS | Verdict |
|---|---|---|
| `numeric` | `:number` | exact (DXN also has rationals; no TypeSpec value is one) |
| `integer`, `float`, `decimal` | `:integer`, `:float`, `:decimal` | exact |
| `int32`, `int64`, `uint32`, `uint64`, `float32` | the sized sugar of the same name | exact |
| `int8`, `int16`, `uint8`, `uint16` | the sized sugar of the same name (G9) | exact |
| `safeint` | `{:refine :integer %{min: .., max: ..}}` | exact |
| `float64` | `:float` | exact |
| `decimal128` | `{:refine :decimal %{max-precision: 34, min-exponent: -6176, max-exponent: 6111}}` | exact |
| `string`, `boolean`, `bytes` | `:string`, `:boolean`, `:bytes` | exact |
| `url` | `:uri` | exact |
| `plainDate`, `plainTime` | `:date`, `:time` | exact |
| `utcDateTime` | `:timestamp` (a datetime with offset Z) | exact |
| `offsetDateTime` | `:datetime` | exact |
| `duration` | `:duration` | exact |
| `null` | `:nil` | exact |
| `unknown` | `:any` | exact |
| `never` | `:never`; a property `x?: never` is a field that must be absent | exact |
| `void` | return types only (the API layer, Q1) | n/a |
| `scalar X extends Y` plus decorators | `X: {:refine Y %{...}}`, or `X: Y` with no constraint | exact |
| `scalar X;` (no base) | `X: {:doc :any %{title: "X"}}` | approx.: TypeSpec gives it no values, so its meaning is the emitter's |
| scalar `init` constructors | none; a value built with one is written as the DXN literal (`utcDateTime.fromISO("…")` is `@datetime "…"`) | approx.: the constructor's name is lost |
| templated scalar (`Unreal<T extends valueof string>`) | none: its parameters only feed decorators | approx.: the converter instantiates every use |
| inline `scalar extends float64` (experimental) | as `scalar X extends Y`, inline | exact |

## 2. Models

| TypeSpec | DXNS | Verdict |
|---|---|---|
| `model M { a: T; }` | `M: %shape{a: T}` | exact |
| `b?: T` | `b?: T` | exact; neither treats optional as nullable |
| `b?: T = v`, where `v` is a literal, `#{}` or `#[]` | `b?: %field{type: T, default: v}` | exact; DXNS also fills the default on decode, which TypeSpec leaves to emitters |
| a default that is a constructor call (`utcDateTime.now()`) | `%field{type: T, computed: :now}` (G8) | exact |
| `...M` (spread) | `includes M`, or M's fields copied in place | exact: a shape's field order means nothing, and a `%schema` gets the fields copied in place |
| `model D extends B` | `D: %shape extends B {...}` | exact, substitution included; TypeSpec's override must be assignable, and DXNS's substitution check refuses a wider one |
| `model A is B` | `includes B`; if B extends C, `includes B extends C` | exact: `is` copies B and keeps B's own base link |
| `model A is B<X>` (a template instance) | `includes BX`, the instance's own `%schema` (T673 Q3) | exact |
| `Record<T>` | `{:map-of :string T}` | exact |
| `model P is Record<T> { a: T2; }` and `...Record<T>` (typed extra properties) | `* :string => T - *` (G1, DXNS.md §4c) | exact |
| inline `{ a: string }` | an inline `%shape{a: :string}` | exact |
| inline `{ ...A; b: T }` | none: an inline built shape is refused | approx.: the converter names it, or flattens it (G6) |
| property decorators | see §6 | |
| `@encodedName("application/json", "x")` | the field is named `x` | approx.: the TypeSpec name goes to `meta` |

## 3. Templates

| TypeSpec | DXNS | Verdict |
|---|---|---|
| `model Page<T> {...}` | not written itself; each instance used is a named `%schema` (T673 Q3) | exact |
| `alias Foo<T> = ...` | `{:generic [t] ...}` | exact |
| a templated union † | `{:generic [t] {:any-of ...}}` | exact |
| a use, `Page<Dog>` | `PageDog`, its own `%schema`; `@friendlyName` names it otherwise | exact |
| a parameter default, `T = string` | the instance is written with it, and a defaulted trailing argument is left out of the name | exact |
| a parameter constraint, `T extends string` | none | approx. for values (every instance is checked as written); lost: the authoring check on arguments (G2) |
| named arguments, `Test<V = "x">` | none | exact: the converter puts them in order |
| `valueof` parameters | none | approx.: they only feed decorators, so the converter instantiates them |
| `@friendlyName("{name}List")` | the converter names the instance with it | exact |
| a generic used as a struct | `%schema` cannot be generic (§5) | exact with Q3's `%shape` |

## 4. Unions, enums, literals

| TypeSpec | DXNS | Verdict |
|---|---|---|
| `A \| B` | `{:any-of A B}` | exact |
| `T \| null` † | `{:nilable T}` | exact |
| `union U { a: A, b: B }` (named variants) | `{:any-of {:doc A %{title: "a"}} {:doc B %{title: "b"}}}` | exact (G4: the variant name as its title, a convention) |
| `"a" \| "b"`, `union U extends string {"a", "b"}` | `{:enum "a" "b"}` | exact |
| literal types `"x"`, `1`, `true` | `{:const v}` | exact |
| string templates that resolve to a literal | `{:const "..."}` | exact |
| `enum E { A: "a", B: 2 }` | `{:enum "a" 2}`, member names as `values: %{"a" => %{title: "A"}}` | exact |
| `enum E { A, B }` (no values) | `{:enum "A" "B"}` | exact (the name is the value) |
| enum spread `...E` | the members copied | exact |
| `#deprecated` on a member | `values: %{v => %{deprecated: "..."}}` | exact |
| `@discriminator("kind")` on `Pet`, with `Cat extends Pet { kind: "cat" }` | the shared fields as `PetBase`; `Cat: %schema extends PetBase {kind: {:const "cat"}, ...}`; `Pet: {:doc {:one-of Cat Dog} %{discriminator: :kind}}` (G3) | exact, the base renamed |
| `@discriminated` union, envelope `"object"` | `%shape{kind: :string, value: {:case kind %{"cat" => Cat, ...}}}` | exact (property names from the options) |
| `@discriminated`, envelope `"none"` | `{:one-of}` over the variants, each with a `{:const}` discriminator field | approx., as for `@discriminator` (G3) |

## 5. Collections, intersections, names

| TypeSpec | DXNS | Verdict |
|---|---|---|
| `T[]`, `Array<T>` | `{:list-of T}` | exact |
| `@minItems`, `@maxItems` | `min-count`, `max-count` | exact |
| `[A, B]` † | `{:list-items A B}` | exact: a JSON array is a list, and DXN's tuple is another type |
| `A & B` | `%shape includes A B {}` when named; `{:all-of A B}` inline | exact; a conflicting property is an error † in TypeSpec, and two differing fields are a compile error in DXNS |
| `namespace A.B` | `A.B/Name` (§6 of DXNS.md) | exact |
| `using A.B` | none: the converter writes every name in full | exact for meaning |
| `import "./x.tsp"` | the converter follows it; files map to DXNS's file convention | exact |
| `alias X = T` | the named type `X: T` | exact |
| `const c = v` | none: the converter writes the value where it is used | approx.: the constant's name is lost |
| values `#{}`, `#[]` | DXN maps and lists | exact |

## 6. Decorators

| TypeSpec | DXNS | Verdict |
|---|---|---|
| `@minLength`, `@maxLength` | `min-length`, `max-length` | exact |
| `@minValue`, `@maxValue`, including dates and durations | `min`, `max` | exact |
| `@minValueExclusive`, `@maxValueExclusive` | `exclusive-min`, `exclusive-max` | exact |
| `@pattern(p)` | `pattern: @regex "p"` | exact: TypeSpec's regex subset is inside every DXNS engine |
| `@pattern(p, message)` | `{:doc ... %{messages: %{pattern: message}}}` (G5) | exact |
| `@format("uuid")`, a name in DXNS's closed set | `format: :uuid` | exact: DXNS checks it, as every TypeSpec JSON Schema consumer does |
| `@format("x")` for any other name | `meta: %{"typespec.format" => "x"}` | approx.: TypeSpec checks nothing either; the name is kept, but not as a format (Q5) |
| `@secret` | `secret: true` (G5) | exact |
| `@doc`, `@summary` | `description`, `title` | exact |
| `@example` | `examples` | approx.: an example's own title and description are lost |
| `#deprecated "why"` | `deprecated: "why"` | exact |
| `@key` | `key: true` (G5) | exact |
| `@visibility` / Lifecycle (`Create`, `Read`, `Update`, `Delete`, `Query`) | `visibility: [:read ...]` (G5) | exact |
| `Create<T>`, `Read<T>`, `Update<T>`, `@withOptionalProperties`, `@withoutOmittedProperties` and the other visibility transforms | the converter writes each instance as a built shape: `UserCreate: %shape includes User {- id}`, or overrides like `name?: T` for all-optional | exact |
| `@encode` (`rfc3339`, `rfc7231`, `unixTimestamp`, `seconds`, `base64`, `base64url`, `ISO8601` †, `@encode(string)` on an `int64`) | logical types: the type stays; the encoding goes to `meta` | approx.: lost is how a JSON writer spells the value (Q2, G7) |
| `@mediaTypeHint` | `media-type` on a string; otherwise `meta` | approx. |
| `@error`, `@errorsDoc`, `@returnsDoc`, `@list`, `@overload`, the pagination markers, `@tag`, `@service`, `@opExample` | none | the API layer (Q1) |
| a custom decorator (TypeSpec or JS) | `meta: %{"typespec.<name>" => args}` | approx.: its meaning lives in its JS |

## 7. Versioning

| TypeSpec | DXNS | Verdict |
|---|---|---|
| `@versioned(Versions)` on a namespace | `%schema(N)` per model, `%type(N)` per named type (Q4: Way B) | exact; the version names (`"2024-01-01"`) go to `meta` |
| `@added`, `@removed` on a model, property, enum member or variant | a new version of whatever holds it | exact |
| `@madeOptional`, `@madeRequired` | the projection's `?` | exact |
| `@typeChangedFrom` | the projection's type | exact |
| `@renamedFrom` | a new name, the old one in `meta` | approx.: only a materializer links the two |
| `@returnTypeChangedFrom` | the API layer | n/a |
| `@useDependency` | the converter picks the dependency's version | exact |

DXNS's own versions (§8) are per schema; Way B adds them to named types,
so an enum that gains a member in v3 is `%type(3)`.

## 8. The API layer

Covered by none of DXNS (Q1):
- operations, including `op is` and templated operations;
- interfaces, including `extends`;
- `@route`;
- HTTP verbs, `@path`, `@query`, `@header`, `@cookie`, `@body`,
  `@bodyRoot`, `@statusCode`, `@server`, `@useAuth` and `@sharedRoute`.

An operation's parameters form a model, and its return type is a type.
Both convert like any other model or type.

## The gaps and what is proposed

Each proposal names its effect on `.dxn` and `.dxnb`. Every DXNS change
lands in all three implementations (Elixir first, then node and PHP),
with the same tests, DXNS.md, the tutorial and the cheatsheet. A
grammar change also needs the VS Code grammar.

**G1. Typed extra properties** (`...Record<T>`, `model P is Record<T>`
with properties). Syntax decided by Jan, 2026-11-17.
- `* K => V` in a shape or schema body: every key no field declares
  must match K, its value V (`* :string => :integer`).
- `- *` in a body: the body is closed, every extra is refused (a
  schema's even without a strict decode).
- `:rest =>` was the first proposal; it reads as a field named `rest`,
  the same key, so it was dropped.
- Both are inherited from bases; the body's own replace them; two bases
  that disagree are a compile error unless the body settles it;
  extending a closed base with a field of its own is a compile error.
- `P is Record<T> { a: T2 }` adds that TypeSpec checks `T2` is
  assignable to T. The converter checks this; DXNS need not.
- Effect on `.dxn`: two new body entries, in `%schema` and `%shape`
  bodies only (like `- field`). `.dxnb`: none; a struct's extras
  already travel in `T_EXTRA`.

**G2. Template defaults and constraints.**
- A parameter becomes `t`, `{t bound}` or `{t bound default}`, as in
  `Page: {:generic [t {size :integer :integer}] ...}`.
- A default lets `{:of}` leave trailing arguments out.
- A bound is checked when `{:of}` compiles, by a conservative rule. An
  argument passes when it:
  - is the bound itself;
  - is a reference to a refine of the bound;
  - is a schema or shape that `extends` the bound;
  - is a `{:const}` or `{:enum}` whose values the bound accepts.
- Anything else is a compile error. A full subtype check is out of
  reach in DXNS.
- Effect: schemas only.

**G3. The discriminator hint.**
- Add the annotation key `discriminator: :kind` to `{:doc}`, on an
  `any-of` or `one-of`. It checks nothing; it tells readers and code
  generators which field chooses the variant.
- It also allows a better error: "kind \"cow\" names no variant",
  instead of every variant's refusal.
- Effect: none on `.dxn` or `.dxnb`.
- The renamed base (`PetBase`) stays a converter choice.

**G4. Names of union variants.**
- The convention is `title`, so no change is needed. DXNS.md gets one
  sentence saying a variant's title is its name.

**G5. New annotation keys.** None checks anything, and none touches
`.dxn` or `.dxnb`.

| Key | Value | Meaning |
|---|---|---|
| `secret` | boolean | the value must not be logged or shown |
| `key` | boolean or string | the field identifies its value (TypeSpec's `@key`, with an optional other name) |
| `visibility` | list of `:create`, `:read`, `:update`, `:delete` and `:query` | the stages that see the field; `read-only: true` stays and means `[:read]` |
| `messages` | map from a refine key to a string | the message to report when that constraint refuses, as in `%{pattern: "lower case only"}` |

**G6. Bases that are named types.**
- A base may be a named type whose definition is a reference to a shape
  or schema, or a `{:of}` that yields a shape.
- Then `model DogPage is Page<Dog> { x: T }` becomes
  `DogPageOf: {:of Page Dog}` and
  `DogPage: %shape includes DogPageOf {x: T}`.
- An inline built shape stays refused, so the converter names it.
- Effect: schemas only.

**G7. HTTP dates.**
- Add `format: :http-date` (RFC 7231's IMF-fixdate). It is needed only
  if Q2 chooses the JSON wire.

**G8. A default computed when it is used** (`= utcDateTime.now()`).
- Recommend leaving it out. A value that depends on the time of decode
  breaks "a schema never changes what a value means" (DXNS.md §7) more
  than `before-now` does.
- The converter writes the field without a default, and puts the
  expression in `meta`.

**G9. Sugar for small integers.**
- Add `:int8`, `:int16`, `:uint8` and `:uint16` beside the existing
  sized sugar.
- Without it the converter writes `{:refine}`, which is just as exact.
- Effect: schemas only.

**G10. Deprecation warnings** (Jan, 2026-11-17: "mark Schemas in
Dextrin as deprecated, and generate a warning when they are used").
This is a proposal, open with Jan.

What exists already: the annotation `deprecated: true | "why"` can
stand on a schema or shape, a version of a schema, a named type, a
field's type, an enum value (`values:`), and a union variant
(`{:doc}` around it). It only documents; nothing warns.

What is proposed:
- **At compile time:** a schema that refers to something deprecated
  gets a warning. That covers a field type, a base, and an `{:of}`. A
  deprecated thing referring to another deprecated thing stays silent.
  - The registry keeps the warnings.
  - `mix dextrin.check` prints them.
  - `--warnings-as-errors` fails the check.
- **At run time:** decode, encode, `check` and `conform` warn when a
  value goes through something deprecated:
  - a value of a deprecated schema or shape;
  - a struct written with a deprecated version;
  - a present deprecated field;
  - an enum value that is deprecated;
  - a value accepted through a deprecated variant.
- **How often:** once per registry per deprecated thing, by default.
  The option `deprecations:` takes `:once`, `:every`, `:off` or
  `:error`. With `:error`, a use is an error of the new category
  `schema/deprecated` (DXN.md §5).
- **How each language reports it:**
  - Elixir: `Logger.warning`, with metadata naming the thing and the
    message.
  - node: `process.emitWarning(message, {type: "DeprecationWarning",
    code: "DXN_DEPRECATED"})`, falling back to `console.warn` where
    there is no `process`.
  - PHP: `trigger_error($message, E_USER_DEPRECATED)`.
  - In all three, an `on_deprecated` callback replaces the default.
- **Generated code (T684–T686)** carries the host language's own mark,
  so the host compiler warns:
  - Elixir: `@deprecated`;
  - JavaScript: JSDoc `@deprecated`;
  - PHP: `#[\Deprecated]` (8.4) and `@deprecated`.
- **TypeSpec:** `#deprecated "why"` maps to `deprecated: "why"` on
  whatever it stands on. This is exact.
- **Effect on `.dxn` and `.dxnb`:** none.

**G11. A field pinned to a version** (Jan, 2026-11-17: "pin a field
to a specific version, but the default should be that the field is just
using the latest version").
- Unpinned (`pet: Pet`), as today: a struct of any loaded version is
  read and upgraded to the latest; an encoder writes the latest.
- Pinned (`pet: Pet(1)`): only version 1 is accepted, it is not
  upgraded, and an encoder writes version 1. A pinned base
  (`includes Pet(1)`) already exists; this brings the same to type
  positions.
- Way B needs the same pin for named types (`color: Color(1)`), so one
  spelling serves both.

How `Pet(1)` could be written in a type position:
- A `.dxns` file has no grammar of its own: it is a DXN document, read by
  the DXN parser, and the schema compiler reads the values. The parser
  cannot tell a type position from data, so "only in type positions" is
  not possible in the grammar. `extends User(3)` works only because it
  sits in a struct head, which has its own rule.
- `(` begins nothing in DXN values today, so `Name(N)` is free: it is a
  syntax error now and would mean nothing else.
- **Recommended: text sugar.** `Name(N)` in DXN text reads as the tuple
  `{:at Name N}`, wherever it stands; the printer writes that tuple back
  as `Name(N)`.
  - `.dxn` data: `Pet(1)` becomes legal and is that tuple. Nobody writes
    it in data; it does nothing there.
  - `.dxnb`: no change, the tuple is encoded as any tuple.
  - The compiler sees `{:at Pet 1}` either way; both spellings work.
  - Cost per implementation: one grammar or parser rule, one printer
    rule, tests, DXN.md §1 and DXNS.md. Elixir and the Praxis port
    regenerate their parsers from `dxn.aether`; node and PHP parse by
    hand. The VS Code grammar highlights it. Conformance cases are added.
- Not recommended:
  - a versioned symbol as a new kind of value: it changes the value
    model in four implementations and needs a new `.dxnb` encoding, for
    no gain;
  - a separate parse mode for `.dxns`: a second grammar in every
    implementation.

## Way B: versioned named types (Q4)

Jan chose Way B: TypeSpec's `@versioned` maps onto `%schema(N)` per
model and `%type(N)` per named type, with no namespace per version.

- **Writing one:** `Color: %type(2)[{:enum :red :green :blue}]`. A
  positional struct with one item, the type. `Color: T` stays as it is
  and means version 1, as `%schema{...}` does. Each version lives in its
  own document, as schema versions do.
- **Referring to one:** `Color` means the latest loaded version;
  `Color(1)` (or `{:at Color 1}`) pins one (G11).
- **Values carry no version.** A struct says which version wrote it; a
  named type's value does not. So an unpinned reference checks against
  the latest version only, and there is no materializer for named
  types. Old data stays valid through its schema version: the converter
  writes `%schema(1){color: Color(1)}`, so `%Pet(1)` still reads with
  `Color(1)`, and Pet's materializer maps the value when it upgrades.
- **Version discipline (DXNS.md §8, `mix dextrin.compat`):** the same
  rules as for schemas. A version present in both releases must not
  change, and the latest never goes down.
- **Deprecation (G10):** `{:doc %type(1)[...] %{deprecated: "why"}}`
  deprecates that version, like a schema version.
- **The TypeSpec mapping:**
  - `@added` / `@removed` on a model, property, enum member or variant
    give a new version of whatever holds it;
  - `@typeChangedFrom`, `@madeOptional` and `@madeRequired` become the
    field in each version;
  - `@renamedFrom` on a model or named type makes a new name, with the
    old name in `meta` (`renamed-from`); only a materializer links the
    two;
  - version names (`"2024-01-01"`) are kept in `meta` on each version.
- **What it costs:** in the compiler (versions of named types, pinned
  references, resolving to the latest), in compat, and in each
  implementation's docs; the converter T682 numbers versions only where
  something changed. `.dxn` and `.dxnb`: no change beyond G11's sugar.

Left out on purpose, with nothing lost in values:
- scalar constructors and abstract scalars;
- `valueof` template parameters;
- `using` and `const`;
- custom JS decorators, which go to `meta`;
- the API layer, unless Q1 says otherwise.

## Questions for Jan

1. **Is the API layer in scope?** That is operations, interfaces,
   routes and HTTP.
   - **Recommended: no, the type system only.** DXNS describes values,
     not operations, which is how protobuf's services were left out in
     schema-superset.md.
   - The converter still converts every model and type an operation
     uses, and can write each operation's parameters as a shape
     (`readPet.params`) if wanted.
   - Including it means designing an operation language next to DXNS.
2. **Logical types or the JSON wire?**
   - **Recommended: logical.** A `utcDateTime` becomes a datetime,
     `bytes` becomes bytes, an `int64` stays an integer. DXN carries all
     of them natively, and `@encode` is kept in `meta`.
   - The alternative describes TypeSpec's JSON output: strings with
     `format: :datetime`, `encoding: :base64`, integers in strings. It
     is exact for JSON documents, but makes DXN data carry strings
     where DXN has real types. G7 is needed only for this option.
3. **Is a model a `%shape` or a `%schema`?**
   - **Recommended: `%shape`** (a plain map, as on TypeSpec's JSON
     wire, generics allowed).
   - A converter option `--structs` writes `%schema` instead, for data
     that should carry its type name in DXN. That option refuses a
     generic model.
4. **How does `@versioned` map?**
   - **Recommended: A, one namespace per version**, e.g.
     `petstore.v2/Pet`. It is exact for every element, including enums,
     unions, scalars and renames, because each version is a complete
     projection.
   - Option B writes each model's projections as `%schema(1..n)`,
     numbered only where the model changed. It uses DXNS's materializers
     and version discipline, but cannot version named types, and a
     renamed model breaks the link between its versions.
5. **What happens to `@format` names DXNS doesn't know?**
   - **Recommended: keep the name in `meta`** and check nothing, as
     TypeSpec itself does.
   - The alternative is to refuse the conversion.
6. **Which gaps should be built?**
   - **Recommended:** G1 (with `:closed`), G2, G3, G5, G6 and G9; G4 as
     a sentence in the spec; G7 only with Q2's wire option; G8 left
     out.
7. **How does the T682 converter read TypeSpec?**
   - **Recommended: a TypeSpec emitter**, an npm package in node-dextrin
     built on `@typespec/compiler`. TypeSpec's own compiler then
     resolves templates, decorators, imports, `using`, versioning
     projections and JS-defined decorators. Reimplementing those three
     more times would never match it exactly.
   - The mix task, the PHP command and the Praxis task run
     `tsp compile --emit` and need Node for that one source format.
   - The alternative is a TypeSpec parser in each language: four
     parsers, each only approximating the compiler.
