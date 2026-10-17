# Implementation plan

**Status: agreed 2026-10-17, in progress.** Worked out from
[`comment-retention.md`](comment-retention.md) and
[`schema-evolution.md`](schema-evolution.md), and it **replaces most of
the latter**: the positional evolution rules in that document were
superseded during planning by versioned schemas. What was dropped, and
why, is recorded under "Superseded designs" at the end.

## Scope and order

Three phases, in this order:

- **A. Groundwork:** the spec additions every later case needs, and the
  Dextrin Conformance Suite that holds all implementations to them.
- **B. Schemas and values:** versioned schemas, a single materializer,
  open structs with extra fields, and three defects fixed on the way.
- **C. Comment retention:** a lossless syntax tree, built on a lossless
  mode in Ichor.

Each feature writes its conformance cases first. They fail in every
implementation, then turn green one implementation at a time.

## Where the work happens

| repository | role | published when done |
|---|---|---|
| `dextrin` (Elixir) | reference implementation; owns `DXN.md` | yes, hex |
| `node-dextrin` | port | yes, npm |
| `php-dextrin` | port | yes, Packagist |
| `ichor`, `ichor_runtime` (Elixir) | lossless mode for phase C | yes, hex |
| `praxis`: `libs_prx/dextrin`, `libs_prx/ichor`, `libs_prx/ichor_runtime` | Praxis ports | no |
| `praxis`: `libs_prx/dextrin_conformance` | the conformance suite | never a package |

- **Elixir leads, every port follows as soon as possible.** A port is
  never left behind until someone needs a feature.
- **One feature branch per repository**, `feature/dextrin-improvements`.
  This is outside the Praxis roadmap; it is not a milestone.
- **One release round.** Everything, phases A to C, is published
  together once it is green in all four implementations. A release
  after phase B alone was considered and dropped: it would be replaced
  by the next one shortly anyway.
- **Publishing covers the non-Praxis libraries only**, and is confirmed
  before anything leaves the machine. `ichor_runtime` is released only
  if lossless mode actually changes it.

## Phase A: groundwork

### A1. Spec additions (`DXN.md`)

- **A canonical printed form for decoded values.** Deterministic key
  order, number forms and spacing, so that two implementations' decode
  results compare as text.
- **Error categories, normative.** Messages differ between
  implementations; categories do not. Each error a conforming reader or
  writer raises belongs to one category, for example
  `schema/missing-field`, `schema/type-mismatch`,
  `schema/unknown-version`, `schema/no-materializer`,
  `schema/undeclared-field` (strict mode), `syntax/...`, `binary/...`.
  Every implementation exposes the category on its error value
  (`Dextrin.Error` and its equivalents gain a category field), so no
  adapter ever recognises an error by its message. The names above are
  placeholders; the list is fixed as the cases are written.
- **The Praxis port gets its own copy of `DXN.md`.** The conformance
  suite checks every copy against the canonical one, since it already
  knows where each implementation lives; a drifted copy fails the run.

### A2. The Dextrin Conformance Suite

- **Where:** `praxis/libs_prx/dextrin_conformance`, namespaces
  `dextrin.conformance.*`. Later its own public GitHub repository,
  `dextrin-conformance`, which you clone to run the checks.
- **Built to be moved out unchanged.** It depends on the Praxis
  standard library and cooper only. It does **not** depend on
  `libs_prx/dextrin`: every implementation, Praxis included, is reached
  the same way, through its adapter. Where each implementation lives is
  read from the suite's own cooper configuration.
- **Cases** are `.pxn` files: an operation (decode, encode, format,
  validate, compat, and later document edits), the input as a real
  `.dxn`, `.dxnb` or `.dxns` file beside it, and the expected outcome:
  the canonical printed form, exact bytes, or an error category.
- **Adapters:** each implementation gets a `conformance` subcommand
  that reads a file of many cases and writes a file of results, so a
  run pays BEAM or PHP startup once, not per case. Both batch files are
  **DXN**, which every implementation reads natively.
  - Elixir: `mix dextrin.conformance`
  - Node: `dextrin conformance` (`bin/dextrin.js`)
  - PHP: `dextrin conformance` (`bin/dextrin`)
  - Praxis: a `prx` task in `libs_prx/dextrin`. Its namespace must not
    be `dextrin.conformance`, which belongs to the suite.
- **The runner** calls each adapter, compares every result with the
  expected one and with the other implementations, and reports
  disagreements. Output is coloured unless `--no-color`, and supports
  `--ai`. It exits non-zero on any disagreement.
- **First check before writing the runner:** how
  `praxis.system/run` reports exit status and captured output. Only if
  Praxis cannot drive external processes does the runner move to
  Elixir.

## Phase B: schemas and values

### B1. Versioned schemas

**Each `.dxns` file describes one version of a schema.** Dextrin loads
any number of such files and caches schemas by `(name, version)`.

```
# user-v3.dxns
%{
  User: %schema(3){
    name: :string,
    email: %field{type: :string, description: "where mail goes"},
    id?: :uuid
  }

  Address: %schema{          # no version given: version 1
    street: :string,
    city: :string
  }
}
```

- **The body lists the fields directly, and their order is the
  positional order.** `fields:` and `@ordered` go away. A duplicate
  field name is an error. `%field{type:, default:, description:}` stays
  for a field that needs metadata.
- **The header holds only the version:** `%schema(3)`. No header means
  version 1. Versions are positive integers. `closed:`, `forbidden:`
  and `refine-fn:` are removed (see B4 and B5).
- **One file holds at most one version per name**, since a `.dxns` is a
  map keyed by name. Different versions live in different files.
- **Loading the same `(name, version)` twice is an error.** The
  registry has an explicit **replace** operation for hot-swapping an
  existing version in a running system; plain loading never replaces.
  Replace only replaces: naming a `(name, version)` that is not loaded
  is an error, so a typo in a hot swap never adds a version.
- **Named types** (`PositiveInteger: {:refine :integer %{min: 1}}`) and
  field-level `{:refine ...}` constraints are unchanged.

### B2. Versions in documents

- **Every encoded struct carries the version it was written with:**
  - text: `%User(3){name: "a"}` and `%User(3)["a", "a@x"]`;
  - binary: the struct's type-name string is `"User(3)"`, shared after
    its first occurrence like every type name today (§2.4).
- **Grammar:** the struct literal gains an optional `"(" INTEGER ")"`
  after the name. One line in `dxn.aether` (Elixir and Praxis), one
  place in each of the Node and PHP parsers. `(` is used nowhere else
  in DXN; `%schema:3` was rejected because `identifier:` lexes as a map
  key, and `@3` because `@` begins tags and sets.
- **Encoding always writes the latest loaded version** of each schema.
  There is no option to write an older one.
- **An untagged struct** (`%User{...}`, mostly hand-written text) **is
  always read as the latest loaded version.** There is no option to
  read it as another; a file written for an older version says so with
  its tag, `%Config(2){...}`.
- **Deployment, documented in the spec and the tutorials:**
  - a compatible change (fields appended only) deploys in either
    order: newer producers are read by older readers under the forward
    rule (B3), older producers by newer readers through the
    materializer (B4);
  - a breaking change deploys **readers first**, then producers;
  - for a schema that services both read and write, make only
    compatible changes, or introduce a new schema name (`UserV2`)
    beside the old one and migrate service by service.
- **Struct references are unpinned.** A field typed `User` accepts any
  version of `User`; the nested struct's own tag decides how it is
  read. `User(2)` inside a type expression is a syntax error for now.

### B3. Reading across versions

- **The writer's version is loaded:** the struct is read with exactly
  that schema. Item count and field names are exact.
- **The writer's version is older than the latest loaded:** the struct
  goes to the materializer (B4). Without one, it is an error
  (`schema/no-materializer`).
- **The writer's version is older but not loaded:** an error
  (`schema/unknown-version`, "User v1 is not loaded"), even when a
  materializer is registered: the materializer receives fields named by
  the writer's schema, and without that schema there are no names.
- **The writer's version is newer than anything loaded:** the struct is
  read against the latest loaded version.
  - Every field that version **requires** must be present with a
    matching type, otherwise it is an error. Optional fields that are
    missing are absent and take their defaults.
  - **Text** matches by name. Named fields the reader does not know
    become extra fields (B5).
  - **Binary assumes positions are unchanged.** Items beyond the
    reader's own fields are **silently dropped**. True extra fields
    travel named in the tag-215 item (B5).
  - **Documented risk, normative and in the tutorial:** if a newer
    version reordered, inserted or removed fields, an older reader
    assigns values to the wrong fields, without an error whenever the
    types agree. This is accepted as unavoidable; schema authors who
    need older readers append fields only.

### B4. One materializer per schema

**A single function per schema, in the registry, replaces the old
materializer, `refine-fn:` and the upgrade function from the
discussion.** It keeps the name *materializer*.

- **Signature:** `(schema-name, version, fields)` returning the
  application's latest-version value, or an error.
  - `fields` is a map keyed by field-name **strings** (no atoms from
    wire data), including any extra fields.
- **It is called for every decoded struct of its schema, whatever the
  version.** It upgrades older versions, materializes into the
  application's own struct or record, and refines and validates. How
  missing fields are filled is entirely its job.
- **Dextrin validates its result against the latest schema.**
- **Bottom-up:** nested structs are materialized first, so when
  `Event`'s materializer runs, its `user` field already holds the
  latest-version `User` produced by `User`'s materializer.
- **No materializer registered:** latest-version data comes back as a
  generic Dextrin struct value; an older version is an error.
- **Inside an application, a struct is always the latest version.**
- **Encode side:** encoding checks the schema's types only. Cross-field
  rules before encoding are the application's job; there is no encode
  hook until a real case asks for one.

### B5. Open structs and extra fields

**A struct guarantees its declared fields and may carry more.** Code
relying on a struct is guaranteed only the declared fields. Elixir
structs already behave this way (extra keys in the map); so do Praxis
records on the BEAM.

- **Text:** extra fields are ordinary keyed entries.
- **Binary:** extra fields travel as **one trailing item, a CBOR map
  from name to value, under new private tag 215 ("extra fields")**:
  `["User(3)", "a", "a@x", 215({"nickname": "b"})]`. Chosen over a
  names-list-then-values layout because it is never larger: same
  payload, fewer items in the struct's outer array.
- **An extra field never shadows a declared one.** A name present both
  as a declared field and as an extra is an error, whether in text
  (`%User(3){name: "a", "name" => "b"}`) or in the tag-215 item.
- **Extra-field keys follow the map-key rule** (B7).
- **Praxis records on the JavaScript backend** must be confirmed to
  keep extra keys before this relies on them; the BEAM backend does
  (checked 2026-10-17).
- **`closed:` is removed from schemas.** Its use, catching typos in
  hand-written files, depends on the reader, not the type: a decode
  option **`strict: true`** makes any undeclared named field an error
  (`schema/undeclared-field`). Without it, the field becomes an extra.
  A config loader passes `strict: true`; a message consumer does not.
- **`forbidden:` is removed.** It served the replaced evolution model;
  `strict` and the materializer cover what is left of it.

### B6. A struct is matched only by a struct

**A value matches only its declared type, and nothing is converted to
make it match.** An integer is not a string, however easy the
conversion; a map is not a struct.

- **Reference fields:** a field typed `User` accepts only a `User`
  struct value: a Dextrin struct or already-checked value named `User`,
  the registered application struct, or a decoded struct named `User`
  whose schema is unknown (§1.4). Everything else is a type error,
  plain maps included. Whoever needs a struct writes it as one.
  - Fixes the hole in all four implementations, where every non-struct
    value was accepted: Elixir `type_expr.ex:90`, Node
    `type-expr.cjs:133`, PHP `TypeExpr.php` `matchesReference`, Praxis
    `type_expr.prax:134-137` (whose deliberate "plain map taken as
    given" comment goes).
- **Representation is not conversion.** A language without integers
  may hold a DXN integer as a string; that is its representation. A
  language that has integers and turns one into a string because the
  field says `:string` converts. The test, normative in §4.7:
  **a host value always means the same DXN type, with or without a
  schema. A schema can accept or reject a value, but never changes what
  it means.**
- **Node and PHP replace their schema-driven coercion** with a fixed,
  schema-independent table of what each host type means, and the
  `coerce:` option is removed. Applied to Node's current table (PHP's
  follows the same reasoning):

  | today | under the test |
  |---|---|
  | `Date` → `timestamp`, `date` or `datetime` by field | a `Date` is an instant: always `timestamp`; the others take `DXNDate`, `DXNDateTime` |
  | array → `list`, `tuple`, `sorted-set` or `array` by field | always the one type the encoder writes without a schema; the others take their `DXN*` classes |
  | `Map` → `ordered-map`; `RegExp` → `regex`; `Symbol` → `symbol` | kept only if each always means that type, schema or not |
  | string → `uuid`, `uri`, `char` | conversion, removed: use `DXNUUID`, `DXNURI`, `DXNChar` |
  | number → `decimal`, `rational` | conversion (lossy from a float), removed: use `DXNDecimal`, `DXNRational` |

### B7. Map keys

**Allowed as a key, in every map and for extra fields alike:**
`string`, `keyword`, `integer`, `uuid`, `date`, `bytes`, `symbol`,
`char`. Everything else is an error in text, in binary and when
encoding, with its own category.

- **The rule:** a key is allowed when its identity is exact and
  obvious. Two keys are the same exactly when they have the same type
  and the same value, with no question of normalization, precision or
  scale. Duplicates merge, last one wins.
- **Excluded, and why (stated in the spec):**
  - `float`, `decimal`, `rational`: `1` vs `1.0`, `0.0` vs `-0.0`,
    `NaN`, `1.0M` vs `1.00M`, `2/4` vs `1/2`; every language answers
    these differently, and the BEAM has no `NaN` or infinities.
  - `time`, `timestamp`, `datetime`, `duration`, `uri`: precision,
    offsets, `P1D` vs `PT24H`, URI normalization.
  - `regex`, custom tags, and every collection.
  - **`nil` and `boolean`**, documented with a remark: they conflict
    in some languages (in PHP, `nil` collides with `""` and `true` with
    `1` as array keys), and they are rare as keys anyway.
- **Elixir and Praxis:** all eight are native terms or structs whose
  structural equality is the rule; nothing to change for keys.
- **Node:** `bigint`, `string` and keywords (`Symbol.for`) compare
  correctly as native `Map` keys; `DXNChar`, `DXNSymbol`, `DXNUUID`,
  `DXNDate` and `DXNBytes` compare by identity today, so a duplicate is
  not merged and a lookup with an equal value finds nothing (confirmed
  2026-10-17). Fix: a `DXNMap` keyed internally by each key's canonical
  form, used for every decoded map.
- **PHP:** a map stays a native array when every key is an integer, a
  keyword (existing NUL-byte marker) or a string, and no integer-like
  string collides with an integer. Otherwise it decodes to a new
  `DXNMap` keyed by the canonical form: big integers, `char`, `symbol`,
  `uuid`, `date`, `bytes`, or a colliding pair. Today PHP silently
  turns a `1.5` key into `1`, `true` into `1` and `nil` into `:""`
  (confirmed 2026-10-17); with these types no longer allowed, that
  loss becomes impossible.
- **Elixir: keywords from untrusted input stop becoming atoms.** Today
  every decoded keyword is an atom, so a hostile document can exhaust
  the atom table. The Praxis port already returns a record for
  untrusted input; Elixir does the same.
- **Conformance cases:** each allowed type as a key; each disallowed
  type rejected; duplicates of each merged; and the pairs that must stay
  distinct, `1` vs `"1"` and `:x` vs `"x"`.

### B8. Version discipline check

A slim check, as a library function in every implementation and a
command in each CLI (`mix dextrin.compat OLD NEW` and equivalents):

- a schema whose content changed must have a new version;
- a version never goes down;
- informational: which older versions the latest one needs a
  materializer branch for, with what changed, as a checklist.

There are no compatibility modes and no append-only rule. CI compares
against the previous release's schema files.

### B9. Order of work, per feature

Elixir first, then the Praxis port, Node and PHP, each against the same
conformance cases. Removing the exact-field-count checks
(`validator.ex:59` and `:192`, `validator.cjs:82` and `:281`,
`Validator.php:109` and `:327`, `validator.prax:93`) falls out of B3. The Node and PHP map fixes in B7 come before extra fields (B5), which build on them.

### B10. Documentation

- `DXN.md`: §1.1/§1.2 (the `(N)` syntax), §2.1 and §2.3 (tag 215,
  versioned type names), §4.4 (the schema body and header), §4.7
  (enforcement, no conversion, strict mode), and a new §4.8 "Schema
  versions" covering B1–B5, including the documented positional risk.
- Each implementation's tutorial gets an "Evolving a schema" section
  with a worked example of the risk; README, cheatsheet, changelog.

## Phase C: comment retention

As designed in [`comment-retention.md`](comment-retention.md): a
full-fidelity tree with the value as a projection, explicit edits, the
diff wrapper with `on_ambiguity: :safe`, trivia ownership by
`above`/`between`/`trailing`.

1. **Lossless mode in Elixir Ichor.** The generated parser keeps what
   `@skip` discards (comments, whitespace) as tokens with source spans
   and produces a full-fidelity tree for any grammar. Because the tree
   comes from the same `dxn.aether`, Elixir and Praxis have no second
   representation to keep in step. It gets its own design document in
   `ichor`, written before the code, and its own minor release.
2. **`Dextrin.Document` in Elixir:** `parse`, `to_value`, `render`,
   with the byte-identical round-trip as the main property. The
   formatter is rebuilt on it, so `dextrin format` stops deleting
   comments. Then the explicit edits, then the diff-based `update`.
3. **Praxis:** lossless mode in `libs_prx/ichor` and
   `libs_prx/ichor_runtime`, then the document in `libs_prx/dextrin`.
4. **Node and PHP:** their parsers are hand-written, so each builds the
   tree first and derives the value from it, instead of keeping two
   parsers side by side. The conformance suite's comment-retention
   cases (byte-identical rendering, edits, trivia ownership on delete)
   hold all four to the same outputs.

**Decisions beyond `comment-retention.md`:**

- **Elixir and Praxis keep a fast decode path.** The design document
  starts with parse-then-strip to avoid two drifting parsers; with both
  the ordinary and the lossless parser generated from one grammar, that
  risk is gone, so `decode` keeps today's parser and only `Document`
  uses the lossless one. Node and PHP do derive `decode` from the tree;
  a value-only path is added there only if measurements call for it.
- **The formatter is the first consumer.** Today it deletes comments in
  all four implementations.
- **Style of inserted entries:** inferred by sampling the document
  (indent width, comma convention), with the pretty printer's defaults
  as the fallback.
- **Equal but differently written** (`1.0` vs `1.00`, one line vs
  three): `update` compares values and leaves the text alone when they
  are equal, so a no-op update never reformats a file.
- **`.dxns` schemas** get this for free; a test confirms schema
  compilation assumes nothing about comments.
- **The new syntax is unaffected:** a `(N)` version tag is part of the
  struct literal's tokens, extra fields are ordinary entries in text,
  and tag 215 exists only in binary, which has no comments.

Nothing in phase C changes the format, so `DXN.md` only gains a note
that comments have no meaning to a reader.

## Versions

One release round, all 0.x, so minor bumps; breaking, with a
changelog entry for each break:

| library | from | to |
|---|---|---|
| `dextrin` | 0.1.3 | 0.2.0 |
| `node-dextrin` | 0.1.0 | 0.2.0 |
| `php-dextrin` | 0.1.0 | 0.2.0 |
| `ichor` | 0.3.1 | 0.4.0 |
| `ichor_runtime` | 0.2.0 | 0.3.0, if lossless mode touches it |
| `libs_prx/dextrin` | 0.5.0 | 0.6.0 (unpublished) |
| `libs_prx/ichor`, `libs_prx/ichor_runtime` | 0.6.0, 0.4.0 | next minor (unpublished) |
| `libs_prx/dextrin_conformance` | new | 0.1.0 (never a package) |

## Superseded designs

Kept so the reasoning is not lost, including what was wrong with it.

- **Positional evolution with an append-only rule** (`schema-evolution.md`
  §1–2): fewer items than fields valid if the rest are optional, more
  items ignored on open schemas, rejected on closed ones; a
  compatibility check with `full`/`backward`/`forward` modes. Replaced
  by versioned schemas. Its argument against per-struct versions,
  "would need negotiation and a place to look versions up", holds only
  if a reader must *fetch* the writer's schema; loading versions from
  files and tagging structs needs neither.
- **A `since:` per field**, so a reader could derive every past
  version's field count. Unnecessary once old versions load from their
  own files.
- **Keeping unknown positional items** on a decoded struct for lossless
  relaying, with a positional text form for mixed cases. Replaced by
  dropping them: a newer struct is read against the latest known
  version, and only named extras travel.
- **Matching a conforming plain map as a struct**, then converting it on
  encode. Rejected: a map is not a struct, as an integer is not a
  string.
- **Filling a declared field from a same-named extra** as a migration
  path. Replaced by the materializer, which sees every field and
  decides.
- **`closed:`, `forbidden:`, `refine-fn:` and `version:` as schema
  entries**, and `%schema{version: 3, fields: @ordered %{...}}`.
  Replaced by the `(N)` header, the field body, the `strict` decode
  option and the materializer.
- **Any value as a map key**, as `DXN.md` §1.2 allowed. Replaced by
  the eight-type key rule (B7): composite and numeric keys have no
  identity the languages agree on, and Node and PHP already broke on
  them.
- **Scalars only as map keys**, briefly considered. Replaced because
  three scalars have ambiguous identity (`float`, `decimal`,
  `rational`) while three non-scalars are exact and common keys
  (`uuid`, `date`, `bytes`).
- **Two release rounds** (A and B first, C later). Dropped: the interim
  release would have been replaced shortly anyway.
- **A separate upgrade function beside the materializer.** Merged: one
  function does checking, refining, upgrading and materializing.
- **Explicit versions for the encoder and the decoder**
  (`versions: %{"User" => 2}`): writing an older version during a
  rolling deploy, reading untagged structs as an older version, with a
  document's tag overriding the option. Dropped: readers-first deploys
  plus the materializer cover breaking changes, compatible changes
  deploy in either order, and the one remaining case, a breaking change
  to a schema that services both read and write, is better served by a
  new schema name. Supporting it would invite deliberately writing
  outdated data for no case that needs it.
