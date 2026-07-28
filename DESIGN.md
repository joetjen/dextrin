# Dextrin — Technical Design

Implementation plan for a DXN library on top of [`ichor`](../ichor).
Normative source for the format is `DXN.md`; this document only covers
*how it gets built*, not what DXN means — no type semantics are
restated here except where they constrain an implementation choice.

## 1. Scope

- `.dxn` text: full grammar in `DXN.md` §1, all 30 types in §1.3.
- `.dxnb` binary: full CBOR mapping in `DXN.md` §2, including the
  private tag block, duration bitmask, regex flags byte, and both
  value-sharing extensions — string-only (decode-only requirement,
  §2.4) and the general arbitrary-value form (§2.5, also decode-only
  required; encode-side is opt-in, §7.3.1).
- Round-trip: any value produced by the text parser encodes to
  `.dxnb` and back to an equal value; any `.dxnb` document decodes to
  a value that encodes back to byte-identical `.dxnb` (byte-identical
  only when value-sharing / bignum-tag choices are themselves
  deterministic — see §7.4).
- `.dxns` schema documents (§4.4) — a schema-description vocabulary
  that is itself plain `.dxn`/`.dxnb` data, compiled into the same
  registry §4.3 already defines. No new grammar, no new file format at
  the parser level.
- Media types for HTTP/AMQP transport (§11) and a `mix dextrin.*` CLI
  toolset (§12) — validate, encode/decode, schema-scaffold generation,
  and formatting.
- Out of scope for v1: comment-preserving pretty-printing (§12.4 —
  the current grammar structurally cannot recover comments once
  parsed, a real constraint, not a deferred nice-to-have);
  streaming/incremental parsing (whole-document only, matching
  `Grammar.Native.parse/1`'s own shape); multi-file schema
  loading/resolution (§4.4.6).

## 2. Architecture

Two independent pipelines sharing one in-memory value representation
(§4). Ichor only touches the left-hand side — CBOR has no grammar, so
it's hand-rolled Elixir working directly over that same shared type.

```text
  .dxn text                              .dxnb bytes
      │                                       │
      ▼                                       ▼
  Dextrin.Text.Grammar (.aether)      Dextrin.Binary.Decoder
  compiled via `use Ichor`  ──┐              │
      │                       │               ▼
      ▼                       │        magic/version check,
  Dextrin.Text.Actions        │        CBOR item walk, tag
  (Ichor.Actions callbacks)   │        dispatch (§2.2/§2.3)
      │                       │               │
      └───────────┬───────────┴───────────────┘
                   ▼
         shared value representation (§4)
                   │
                   ▼
         Dextrin.Binary.Encoder ──► .dxnb bytes
         Dextrin.Text.Printer  ──► .dxn text   (round-trip only,
                                                 not pretty-printing)
```

**`Grammar.Native`, not `Grammar.VM`.** Ichor offers both an
interpreted backend and compile-time codegen (`use Ichor`); the
tradeoff only matters when a grammar is loaded at runtime from
somewhere the compiler can't see. `Dextrin.Text.Grammar` is fixed at
`dextrin`'s own compile time — there's no scenario where a caller
supplies a different grammar — so `use Ichor, grammar: ...` (Native)
is the only backend worth using here, for the ~2x speed the ichor
README already documents it gets from skipping bytecode
interpretation entirely.

Why not run `.dxnb` through Ichor too: Ichor compiles *grammars* —
context-free, character-level syntax. CBOR's structure is
self-describing binary (major type + length prefix), not something a
PEG grammar over characters gains anything by describing; a plain
recursive Elixir function reading `major type -> arity -> recurse` is
both simpler and correct by construction. Ichor's own scope is
explicitly "Lexer + Parser [+ Executor]" for character-level grammars
(`ichor/README.md`); binary TLV formats are a different problem.

## 3. Project layout

```text
dextrin/
  mix.exs
  lib/
    dextrin.ex                    # public API (§8)
    dextrin/
      text/
        actions.ex                # Ichor.Actions impl, §6
        unicode_ranges.ex         # generated, §5.2
      binary/
        encoder.ex                # §7
        decoder.ex                # §7
        tags.ex                   # private tag + bit layout constants, §7.2
      value/
        symbol.ex keyword.ex tuple.ex ordered_map.ex sorted_set.ex
        struct.ex array.ex duration.ex rational.ex custom_tag.ex
        registry.ex                # struct-schema + custom-tag decoders, §4.3
      schema.ex                   # Dextrin.Schema.compile/2, validate/3, §4.4
      schema/
        compiler.ex                # type_expr -> validator/constructor, §4.4.1
        constraints.ex             # §4.4.3's refine_keys table
      error.ex                    # wraps Ichor.Error + binary-side errors
  lib/mix/tasks/dextrin/
    validate.ex encode.ex decode.ex gen_schema.ex format.ex   # §12
  test/
    text/                         # grammar/actions tests
    binary/                       # codec tests
    conformance/                  # shared fixtures, both directions, §9
      fixtures/*.dxn *.dxnb.bin *.json (expected value, as Elixir terms)
  priv/
    grammar/dxn.aether                  # hand-authored, §5
    unicode/DerivedCoreProperties.txt   # UCD input for §5.2's generator
    unicode/VERSION                     # last-processed Unicode version
  lib/mix/tasks/dextrin/gen_unicode.ex  # mix dextrin.gen.unicode, §5.2
```

`mix.exs` deps: `{:ichor, path: "../ichor"}` (switch to a Hex
requirement once ichor publishes), `{:decimal, "~> 2.1"}` for exact
fixed-point (§4), `{:ex_doc, "~> 0.40", only: :dev, runtime: false}`.
Nothing else — CBOR, base64, UUID formatting, and ISO 8601 parsing are
all either hand-rolled (CBOR, UUID — small and precision-sensitive
enough that a generic dependency buys nothing, see §7.1) or already in
stdlib (`Base`, `Date`/`Time`/`DateTime`).

## 4. Shared value representation

One Elixir shape per DXN type. Preference order: native Elixir/stdlib
type, then a minimal Dextrin struct, only when nothing native fits.

```text
value_map[28]{dxn_type,elixir_representation,note}:
  nil,nil,""
  boolean,boolean,""
  integer,integer,"BEAM integers are already arbitrary-precision"
  float,"float() | :nan | :positive_infinity | :negative_infinity","see note below — Erlang/Elixir float() cannot represent non-finite values at all"
  decimal,Decimal.t(),"Decimal (hex pkg) — exact, matches CBOR tag4 shape directly"
  rational,Dextrin.Rational.t(),"{numerator, denominator}, stored exactly as given, not reduced — §4.1"
  string,String.t(),""
  char,Dextrin.Char.t(),"wraps one integer codepoint; see §4.2 for why not a 1-grapheme String.t()"
  symbol,Dextrin.Symbol.t(),"wraps a String.t() — NOT an atom, see §4.2"
  keyword,Dextrin.Keyword.t(),"wraps a String.t() — NOT an atom, see §4.2"
  list,list(),""
  tuple,Dextrin.Tuple.t(),"wraps a list — NOT an Elixir tuple, see §4.2"
  map,map(),"plain Elixir map — no ordering guarantee, matches spec exactly"
  ordered-map,Dextrin.OrderedMap.t(),"wraps an ordered list of {k,v} pairs"
  set,MapSet.t(),""
  sorted-set,Dextrin.SortedSet.t(),"wraps a list kept sorted as a hard invariant at every construction site (decode, encode, public API) — `==` is only valid set-equality because of that invariant, not because Elixir gives it for free"
  struct,Dextrin.Struct.t(),"{name, fields} — or a real struct if a schema is registered, §4.3"
  array,Dextrin.Array.t(),"wraps a tuple (fixed-size, indexed — Elixir tuple fits *this* one)"
  date,Date.t(),""
  time,Time.t(),""
  timestamp,DateTime.t(),"utc_offset: 0, time_zone: \"Etc/UTC\""
  datetime,DateTime.t(),"non-zero utc_offset, no tz database lookup needed (offset is explicit)"
  duration,Dextrin.Duration.t(),"7 integer fields per DXN.md §2.3's bitmask, none reducible to the others"
  uuid,Dextrin.Uuid.t(),"wraps 16 raw bytes, not the 36-char string"
  uri,Dextrin.Uri.t(),"wraps the raw string; not parsed into URI — see §4.2"
  bytes,Dextrin.Bytes.t(),"wraps a binary() — string is *also* plain binary() in Elixir (String.t() isn't a distinct runtime type), so bytes needs its own wrapper for the same reason char/symbol/keyword do (§4.2); found while implementing the encoder, not in original design"
  regex,Regex.t(),"Elixir's own — its modifier letters (i m s u x f r) already match DXN's 1:1"
  custom-tag,Dextrin.CustomTag.t(),"fallback wrapper when no decoder registered, §4.3"
```

### 4.0 Float cannot represent NaN/Infinity — verified, not assumed

Discovered while implementing, not while designing: Erlang/Elixir's
`float()` cannot hold a non-finite IEEE-754 value under any
circumstance, not only through arithmetic (`1.0/0.0` raises
`ArithmeticError`, deliberately) but at the term-construction level
itself — even reconstructing the exact NaN/Infinity bit pattern via
`:erlang.binary_to_term/1` is rejected outright ("invalid external
representation of a term"). This is a hard BEAM guarantee, not a
library-level restriction to work around. Consequently, ordinary
finite DXN floats stay a plain `float()`, but `NaN`/`Infinity`/
`-Infinity` are represented as the atoms `:nan`/`:positive_infinity`/
`:negative_infinity` instead — a small closed union, not another
wrapper struct, since the finite case is the overwhelming common one
and shouldn't pay for this. `Dextrin.Binary.Encoder` writes the
correct IEEE-754 bit pattern for the three special atoms directly
into the CBOR bytes (CBOR's own major-7 float representation has no
trouble with non-finite values, per §2.2 — only the Erlang *term*
representation does), and the decoder does the reverse.

### 4.1 Rational is stored as given, not reduced

`22/7` and `44/14` are distinct DXN values unless a decoder chooses to
normalize. `DXN.md` calls rational "exact ratio," not "exact reduced
ratio" — reducing on parse would be a silent, opinionated
transformation. `Dextrin.Rational` stores numerator/denominator
verbatim; a `Dextrin.Rational.reduce/1` helper is offered but never
called implicitly.

### 4.2 Why several types get a wrapper struct instead of the obvious native type

- **Symbol/keyword are not Elixir atoms.** The type table in
  `DXN.md` §1.3 calls a keyword "an Elixir atom," which is true of
  *Elixir's own* `:foo` syntax but wrong to imitate literally here:
  atoms are never garbage-collected on the BEAM, and `.dxn`/`.dxnb`
  are data-exchange formats — a decoder fed adversarial or merely
  large third-party input must not be able to exhaust the atom table
  by decoding enough distinct symbols/keywords. `Dextrin.Symbol`/
  `Dextrin.Keyword` wrap a plain `String.t()`; a caller who trusts
  their input and wants real atoms can convert explicitly.
- **Tuple is not an Elixir tuple.** DXN tuples are heterogeneous,
  arbitrary-length, structural-equality collections — closer to an
  immutable list than to Elixir's fixed-arity tuples (which
  `Dextrin.Array` already claims for the one DXN type that's actually
  fixed-size/indexed). Backing `Dextrin.Tuple` with a list avoids the
  arity-in-the-type-system mismatch a raw Elixir tuple would invite.
- **Char is not a 1-codepoint `String.t()`.** DXN's `char` and
  `string` are distinct types (`?a` vs `"a"`) that must not collapse
  to the same Elixir value and then fail to round-trip. A one-field
  wrapper keeps them distinguishable.
- **Uri stores the raw string, not a parsed `URI.t()`.** Elixir's
  `URI.parse/1` is lenient in ways RFC 3986 isn't, and
  `URI.to_string/1` doesn't always reproduce the original text
  byte-for-byte (e.g. component re-escaping). Since `DXN.md` requires
  round-tripping, not URI algebra, storing the string as given and
  leaving parsing to the caller is the safer default.

### 4.3 Extension points: struct schemas and custom tags

`struct` and `custom-tag` are both open-ended (§1.3/§1.2), but they're
no longer symmetric in this design — they've diverged since §4.4 got
fleshed out, and that divergence is deliberate, not an oversight:

**Struct is schema-dependent, full stop.** `DXN.md` §1.4 already says
so ("struct interpretation requires a schema... a reader lacking the
schema... returns an opaque tagged value rather than failing") — the
operating assumption for this design is that any two systems
exchanging struct-bearing `.dxn`/`.dxnb` data have both compiled the
*same* `.dxns` schema out of band (shipped alongside the code, fetched
from a shared schema store, whatever each system's own deployment
looks like — `Dextrin` takes no position on *how* the schema gets to
either side, only that it needs to be there). The opaque
`Dextrin.Struct{name, fields}` fallback is what `DXN.md` mandates for
the case where it *isn't* there — a defensive degradation, not the
normal path. Concretely: a compiled schema (§4.4) gives field
*names*, *order*, and *types* for a given struct name, which is
exactly what's needed to convert both directions — positional
`.dxnb` fields (no names on the wire) into a named value, and back —
so schema compilation is what actually closes the round-trip gap for
structs, not a hand-written Elixir function. A hand-written
materializer (`put_struct_materializer/2`, optional) only decides
what nicer *decoded shape* to produce (a real `%MyApp.Point{}` instead
of the schema-compiler's own generic field map) — it's layered on top
of an already-compiled schema, never a substitute for one.

**Custom tag has no schema concept at all** — it's `@tag value`, one
opaque value, not a field-structured record, so there's nothing for a
schema to describe. Its extension point is a `Dextrin.Registry`
decoder function per tag name (`put_tag/3`), plus — implemented after
this was flagged as a gap in an earlier draft of this section —
`put_tag_encoder/4`, the reverse: an application struct (keyed by its
module) back to `@name value`. Symmetric with `put_tag/3` across both
directions and both pipelines: `Dextrin.encode/2`,
`Dextrin.Text.Formatter.pretty/2`, and `Dextrin.encode_binary/2` all
consult it for any struct none of their own built-in clauses
recognize. Given struct's story is also complete, the practical
guidance stands regardless: **prefer a schema-backed struct over an
ad-hoc custom tag for anything with real field structure**; reserve
custom tags for simple scalar-wrapping (an app-specific unit type
around one value), where a full schema would be overkill.

```elixir
Dextrin.Registry.new()
|> Dextrin.Registry.put_tag("my-app/money", &MyApp.Money.decode/1)
|> Dextrin.Schema.compile!(money_schema_doc)   # populates struct entries, §4.4.5
```

No entry for a given struct name or tag name → falls back to
`Dextrin.Struct{name, fields}` / `Dextrin.CustomTag{name, value}`
respectively, per §1.3's "opaque tagged value" language. This mirrors
how `Ichor.Actions` itself falls back to `Ichor.Node` for anything a
grammar's actions module doesn't specially handle — same shape of
decision, applied one level up.

**Callback contracts.** Two different kinds of registry callback,
deliberately different shapes:

```elixir
@type tag_decoder :: (Dextrin.Value.t() -> {:ok, term()} | {:error, term()})
@type struct_materializer :: (%{atom() => term()} -> {:ok, term()} | {:error, term()})
```

Both are *value-transforming* — arity 1, receiving an already-decoded
inner value (a tag's payload, or a struct's field map) and producing
the app's own type. `{:ok, term()} | {:error, term()}` isn't a new
convention invented here — it matches §5.7's sigil validation, which
already surfaces `{:error, reason}` as a `Dextrin.Error` (stage
`:action`). The materializer's field map uses **atom keys**,
deliberately breaking §4.2's "never atomize data-borne symbols/
keywords" rule — on purpose, because a struct's field names come from
the *schema* (compiled once, by the local system), not from the
arbitrary data being decoded. That's a bounded, trusted set of atoms,
converted once at schema-compile time rather than once per decoded
value, so it doesn't reopen the atom-exhaustion concern §4.2 exists
to prevent.

`refine-fn` (§4.4.4) is a third, different kind — a pure validity
check, never a transform:

```elixir
@type refine_fn :: (%{atom() => term()} -> :ok | {:error, term()})
```

`:ok`, not `{:ok, term()}` — deliberately not the same shape as the
two above, so it's obvious at a glance that a refine-fn can accept or
reject a value but can never smuggle in a value transformation the
way a materializer legitimately can.

*(An earlier version of this design proposed a `Dextrin.Encoder`/
`Dextrin.Decoder` protocol pair dispatching on Elixir module atoms, to
solve struct round-tripping across independent VMs with no shared
registry. That's superseded by the paragraph above — a compiled
`.dxns` schema is what independent VMs actually need to share, and
it's already language-neutral data, not an Elixir-specific mechanism.
The protocol idea is dropped, not merely unmentioned.)*

**Loaded up front vs. on demand is a per-system choice, not
`Dextrin`'s to make.** `Dextrin.Registry` accepts either a fully
pre-compiled registry (the "up front" case — `Dextrin.Schema.compile/2`
called once at startup) or an optional lazy resolver — a function
`(struct_name :: String.t() -> {:ok, compiled_schema} | :unknown)`
called on first encounter with a name the registry doesn't already
have, with the result memoized for the rest of that decode. What that
resolver actually does (read a local file, call a schema service,
whatever) is entirely the calling system's business — `Dextrin` only
defines the hook, not a schema-distribution protocol.

### 4.4 Schema documents (`.dxns`)

A `.dxns` file is valid `.dxn` (or `.dxnb`) — same grammar, same
parser, no new file format at the syntax level. What makes it a
*schema* document is purely the shape of the value it parses to: a
map from name to **type expression**, where a type expression is
built entirely from DXN's own existing values (keywords, tuples,
symbols, struct literals). `Dextrin.Schema.compile/1` walks that
already-parsed value and produces `Dextrin.Registry` entries — no
grammar change, no second Ichor pipeline.

`%schema{...}`/`%field{...}` are themselves struct literals, which
raises the obvious bootstrapping question: doesn't parsing a `.dxns`
file need a schema for *its own* `schema`/`field` structs? No —
these two shapes are built into `Dextrin.Schema.Compiler` directly,
the same way built-in tags (`@uuid`, `@duration`, ...) are recognized
by name in `Dextrin.Text.Actions` rather than looked up in a registry
(§6). They're not user-registrable and never go through the
"needs a compiled schema" path §4.3 describes for every other struct
— exactly the same move JSON Schema itself makes (expressed in JSON,
but the JSON-Schema-describing vocabulary is fixed tooling knowledge,
not itself validated against a schema).

The closest prior art is Clojure's [Malli](https://github.com/metosin/malli)
— schemas as plain EDN data (`[:map [:x :int] [:y {:optional true} :int]]`)
rather than a bespoke DSL with its own parser. `.dxns` is the same
move applied to DXN: a tuple with a leading keyword acts as a type
*constructor* (`{:list-of :integer}`), exactly where Malli uses a
vector with a leading keyword — DXN's tuple is the one collection
type that's already "ordered, heterogeneous, fixed shape," which is
exactly what a `(constructor, args...)` form needs.

#### 4.4.1 Type expressions

```text
type_expr[13]{form,dxn_shape,meaning}:
  any,":any","matches any value unconstrained — escape hatch, also what mix dextrin.gen.schema (§12.3) emits for a field it can't confidently infer"
  primitive,":integer / :string / :boolean / ...","one keyword per DXN.md §1.3 type name"
  reference,"bare symbol, e.g. Address","names a struct schema *or* a named type in this document (or Ns/Name, §4.4.6)"
  list-of,"{:list-of elem}","list whose every element matches elem"
  set-of,"{:set-of elem}","set whose every element matches elem"
  tuple-of,"{:tuple-of a b c}","fixed-arity positional tuple, one type_expr per slot"
  map-of,"{:map-of key-type val-type}","every key matches key-type, every value matches val-type"
  enum,"{:enum :usd :eur :gbp}","value must equal one of the given literals (any type)"
  one-of,"{:one-of :integer :string}","union — value must match at least one variant"
  all-of,"{:all-of base {:refine ...}}","intersection — value must match every variant"
  nilable,"{:nilable :string}","sugar for {:one-of :nil :string}"
  refine,"{:refine :integer %{min: 0, max: 100}}","base type plus constraints, §4.4.3"
  struct,"%schema{fields: @ordered %{...}}","struct/record shape, §4.4.2"
```

A bare type expression (no wrapping tuple/struct) is always a
`primitive` or a `reference` — the tuple form is only needed once a
constructor takes arguments, matching the rest of DXN's own economy
(no construct exists purely to be a container for one child).

##### Named types: the vocabulary is closed, the schema author's use of it isn't

The 13 forms above are fixed — not a registry, not extensible from
inside `Dextrin.Schema.Compiler` without an actual library change
(§10 used to list this as an open question; seeing an actual need for
it turned out to be the resolution). What *is* extensible, without
writing a single line of Elixir (or JS, or PHP, or whatever language a
future dextrin port targets), is composing the 13 fixed forms into a
new, reusable, *named* type — entirely as `.dxns` data:

```text
PositiveInt: {:refine :integer %{min: 1}}
Percentage:  {:refine :float %{min: 0.0, max: 100.0}}
Tag:         {:refine :string %{min-length: 1, max-length: 20}}

Money: %schema{
  fields: @ordered %{
    amount:   PositiveInt
    discount: Percentage
    tags:     {:list-of Tag}
  }
}
```

**Mechanically, this needs no new syntax at all.** Any `.dxns` document
entry whose value isn't a `%schema{...}` is compiled as a type_expr and
registered under its name (`Dextrin.Registry.put_type_alias/3`);
`PositiveInt`/`Percentage`/`Tag` above are exactly that. Using one is
exactly the existing `reference` form (a bare symbol) — the compiler
checks the registry's named types before falling back to today's
"struct name" interpretation, so no new grammar, no new type_expr
form, nothing a schema-reading implementation in another language
needs bespoke code for beyond what it already needs for `refine`/
`list-of`/etc.

**Why this is enough, and what it deliberately doesn't do.** The
premise (confirmed with the user rather than assumed) is that a new
"field type" is always *some existing type_expr, restricted or
combined* — never a wholesale new primitive with its own runtime
representation (that genuinely would need code in every language's
decoder, which is exactly what this avoids). Given that premise, named
types are a pure naming/reuse convenience over the existing algebra,
not a new capability:

- **A named type can't reference another named type declared in the
  same document.** `.dxns`'s own map type has no ordering guarantee
  (DXN.md), so resolving forward/sibling references would need real
  dependency-resolution machinery (topological ordering, cycle
  detection) for a case no real schema has needed yet. Concretely: a
  bare symbol inside a named type's own definition resolves only
  against types `compile/3` already knew about *before* this document
  (chained in via `base_registry`, the same mechanism structs already
  use for cross-file references, §4.4.6) — never a sibling in the same
  document, which falls back to being an (opaque) struct reference
  instead, deterministically, not by accident of map iteration order.
  A schema's *fields* are unaffected — they're compiled after all of a
  document's own named types, so a field can freely use any of them.
- **No user-registered callback functions** — deliberately, so a named
  type is something every dextrin port can read identically, not
  something that only works if the reader also happens to load the
  same Elixir function. `refine-fn` (§4.4.4) still exists for
  validation logic that genuinely can't be expressed as data; it's a
  different, narrower escape hatch, not a substitute for named types.

##### A small standard library of common named types

`priv/schema/std.dxns` (`Dextrin.Schema.Std`) ships a handful of named
types built the same way any consumer's own would be — nothing about
them is special-cased in the compiler:

```text
PositiveInteger, NonNegativeInteger, NegativeInteger, NonPositiveInteger
PositiveFloat, NonNegativeFloat, Percentage
NonEmptyString
NonEmptyList, NonEmptySet
```

Opt-in, via `base_registry`, same as any other named-type source:

```elixir
{:ok, registry} = Dextrin.Schema.compile(my_doc, Dextrin.Schema.Std.registry())
```

Deliberately excluded: anything domain-specific (email, phone number,
URL-shaped string). What counts as a valid one is an application
decision this library shouldn't guess at, and DXN already has native
`uri`/`uuid` primitives for the cases that would otherwise tempt a
regex reimplementation — `{:refine :string %{pattern: ~r/.../}}` is
already available directly for anything an application needs beyond
this list.

#### 4.4.2 Struct schemas: required, optional, closed, forbidden

```text
Point: %schema{
  fields: @ordered %{
    x: :integer
    y: :integer
  }
}

Money: %schema{
  closed:    true
  forbidden: [legacy_amount_cents]
  fields: @ordered %{
    amount:   :decimal
    currency: {:enum :usd :eur :gbp}
    note?:    :string
    count?:   %field{type: :integer, default: 0}
  }
}
```

`fields:` is deliberately `@ordered %{...}`, not a plain `%{...}` —
`DXN.md`'s own `map` type is explicitly unordered ("no ordering
guarantee" even though entries sit sequentially in source text, §1.4),
but a struct's field order *is* semantically load-bearing here: it's
the canonical position ↔ name mapping `.dxnb`'s always-positional
struct encoding needs (§2.1). Getting this wrong would've meant a
schema that can validate a keyed `.dxn` struct but can't actually tell
`Dextrin.Binary.Encoder` which field goes in which positional slot.
This canonical order only constrains the *binary* encoding — a keyed
`.dxn` struct literal may still list its fields in any order in the
source text, since names alone are already enough to resolve them
there.

- **Required vs. optional** uses DXN's own identifier grammar, not a
  new flag: a field key ending in `?` (already a legal `ident_char`
  per `DXN.md`'s lexical grammar, no syntax added) is optional; any
  other key is required. This is the same move as §5.6's `AT_DISCARD`
  and §5.5's `MAP_KEY` — reuse a grammar feature that already exists
  rather than add one.
- **`closed: true`** — no field outside the ones listed in `fields`
  may be present at all (JSON Schema's `additionalProperties: false`,
  Malli's `:closed`). Default is `false` (open — unlisted fields are
  preserved on the decoded `Dextrin.Struct`/registered struct, not
  silently dropped, matching §1.3's "opaque tagged value" spirit for
  the *portion* of the data no schema covers).
- **`forbidden: [...]`** is a distinct concept from `closed`: an
  explicit deny-list of field names that must never appear, checked
  even on an *open* schema. The distinction matters because the two
  produce different, more useful errors — `closed` alone would report
  a deprecated field the same generic way as any other unknown field;
  `forbidden` reports it by name (`"legacy_amount_cents was removed in
  v2, use amount"`), which is the actual reason a field gets banned
  outright rather than just left undeclared.
- **`%field{type:, default:, description:}`** is the escape hatch for
  a field that needs metadata beyond a bare type_expr. Only reached
  for `default`/`description` — optionality is already covered by the
  `?` key suffix, so `%field{}` never carries an `optional:` flag of
  its own (one mechanism per concern, not two ways to say the same
  thing).

#### 4.4.3 Refinements

```text
refine_keys[10]{key,applies_to,meaning}:
  min,"integer/float/decimal/rational","value >= min"
  max,"integer/float/decimal/rational","value <= max"
  exclusive-min,"integer/float/decimal/rational","value > exclusive-min"
  exclusive-max,"integer/float/decimal/rational","value < exclusive-max"
  multiple-of,"integer/float/decimal","value is an exact multiple"
  min-length,"string","codepoint count >= min-length"
  max-length,"string","codepoint count <= max-length"
  pattern,"string","value matches a DXN regex literal, e.g. ~r/^[a-z]+$/ — reused as-is, no new pattern syntax"
  min-count,"list/set/tuple","element count >= min-count"
  max-count,"list/set/tuple","element count <= max-count"
```

`pattern`'s value is an ordinary `.dxn` `~r/.../` literal — refine
constraints are themselves just more DXN data, so this table is the
full extent of what `Dextrin.Schema.compile/1` recognizes in v1;
unrecognized keys are a compile-time error (an unknown constraint
silently ignored would be worse than one that fails loudly).

#### 4.4.4 Cross-field / whole-value invariants

A `type_expr` can only describe shape, not "field A implies field B" —
that needs a real predicate. `%schema{}` accepts an optional
`refine-fn:` naming a function from `Dextrin.Registry`'s existing
custom-tag/struct decoder mechanism (§4.3) — the same "escape to
registered Elixir" extension point, not a third one:

```text
Money: %schema{
  refine-fn: money/currency-amount-check
  fields: @ordered %{ amount: :decimal, currency: {:enum :usd :eur :gbp} }
}
```

`money/currency-amount-check` is a bare (namespaced) symbol resolved
against the registry passed to `Dextrin.Schema.compile/1`, exactly
like a custom tag's decoder — kept out of `.dxns` itself deliberately,
since a schema document being *pure data* (no embedded code) is the
property that makes it portable and safely loadable from untrusted
sources in the first place.

#### 4.4.5 Compiling and validating

```elixir
{:ok, schema_doc}    = Dextrin.decode(dxns_source)
{:ok, registry}       = Dextrin.Schema.compile(schema_doc, base_registry)
{:ok, value}          = Dextrin.decode(data_source, registry: registry)
:ok = Dextrin.Schema.validate(value, registry, "Point")
```

`compile/2` does the one-time walk from schema-document value to a
populated `Dextrin.Registry` (struct constructors that enforce
required/closed/forbidden/refine, resolving `reference`s against
sibling entries in the same document — including recursive/mutually-
recursive ones, since compilation builds all constructors before any
of them run, the same forward-reference tolerance `AETHER.md` already
allows for grammar rule definitions).

**Enforcement is decode-time and fail-fast, by default and without an
escape hatch.** The third line above isn't "decode, then separately
check" — `Dextrin.decode/2`/`decode_binary/2` run the full schema
check (required/closed/forbidden/refine/refine-fn) as part of
constructing a registered struct, and a violation comes back as an
ordinary `{:error, %Dextrin.Error{stage: :action, ...}}` — the same
channel a syntax error already uses, so a caller never needs to
special-case "bad syntax" versus "valid syntax, invalid per schema."
For `.dxnb`'s positional struct encoding this isn't optional anyway:
decode already has to consult the schema just to assign values to
field names, so there's no meaningful "structural decode without the
schema" to fall back to once one is registered. There is deliberately
no lenient/`on_schema_violation:`-style opt to get the materialized
value anyway — a registry that doesn't actually get enforced would
defeat the reason to pass one.

`Dextrin.Schema.validate/3` (the fourth line) exists for the cases
that aren't "check while decoding": validating a value built directly
in Elixir before encoding it, re-checking an already-decoded opaque
`Dextrin.Struct` once a schema becomes available later (on-demand
resolution, §4.3), or checking a value against a schema other than
the one it was originally decoded against.

#### 4.4.6 Deferred to a later iteration

- **Cross-file `Namespace/Name` references** — the identifier grammar
  already supports the syntax (§1.1's `identifier` production), but
  resolving it across separate `.dxns` files needs a load-order/path
  convention this design doesn't fix yet. v1 resolves references only
  within a single compiled document; cross-file loading is additive,
  not a breaking change, when it lands.
- **Schema versioning/migration** (e.g. "this field replaced that
  one, migrate automatically") is a real need `forbidden` only
  partially covers (it rejects, it doesn't rewrite) — left for a
  follow-up once real schemas exist to migrate.

## 5. Text grammar (`Dextrin.Text.Grammar`)

Hand-authored Aether, not imported from `DXN.md`'s own EBNF via
`Ichor.EBNF.ISO`. Two reasons: (1) `DXN.md`'s EBNF is scannerless and
leans on prose non-terminals Aether can't execute (`? any character
with Unicode property XID_Start ?`, `? any single non-whitespace
character ?`) — those need real definitions, not a mechanical import;
(2) Aether's own lexer/parser split (`AETHER.md` "Tokens vs. rules")
requires re-deriving which productions are lexical (`identifier`,
`number`, `string`) versus structural (`list`, `map_lit`) — a
judgment call the ISO importer has no way to make automatically. The
EBNF stays the normative source; the `.aether` file is checked against
it by the conformance fixtures (§9), not generated from it.

### 5.1 Pragmas

```text
@grammar "dxn"
@root document
@skip TRIVIA
```

`TRIVIA := (SPACE | COMMENT)*` with `SPACE` redeclared to include `,`
(before any use, per `AETHER.md`'s predefined-token override rule) —
this is the single mechanism that realizes `DXN.md`'s "`ws` ...fully
insignificant, everywhere" for whitespace *and* commas at once,
identical to the `TRIVIA`/`SPACE` pattern the LISP example already
uses for its own comma-as-whitespace rule. `COMMENT` folds `#`-comments
into the same auto-spliced trivia, so no grammar rule ever mentions
comments explicitly — they disappear at the lexer layer, the same way
whitespace does. (`DXN.md`'s own EBNF models `comment` as a per-value
`skip` alternative rather than universal trivia; that's the right
shape for a scannerless formal grammar, but not for one with a real
lexer — see §5.5 for why `discard` still needs to be a rule, not
trivia.)

### 5.2 Identifiers: generated Unicode ranges, not hand-written classes

`DXN.md`'s `letter`/`ident_char` are defined via Unicode's
`XID_Start`/`XID_Continue` properties (UAX #31) — hundreds of
codepoint ranges, not expressible as a short hand-written character
class. Aether's char-class escape grammar supports `\u{H+}` inside
`[...]` (shared escape-decoding code path with string literals, per
`Aether.Lexer`), so the ranges themselves *are* expressible — just not
by hand. `mix dextrin.gen.unicode` fetches
`priv/unicode/DerivedCoreProperties.txt` (Unicode Character Database)
from unicode.org, compares its version against `priv/unicode/VERSION`
(the last one processed), and — only if it's newer, or `--force` is
given — emits two token bodies as generated, checked-in Aether source
(spliced into `dxn.aether` via a marked region), updates the checked-in
UCD data file, and records the new version. Not run at build time —
Unicode version bumps are a deliberate, reviewed action; `--file PATH`
supports running against a local file instead of fetching:

```text
IDENT_START := [_\u{0041}-\u{005A}\u{0061}-\u{007A}\u{00AA}...]   ; XID_Start ranges + "_"
IDENT_CONT  := IDENT_START | [\u{...}-\u{...}...-?!]              ; XID_Continue ranges + "-?!"
IDENTIFIER  := IDENT_START IDENT_CONT* ("/" IDENT_START IDENT_CONT*)?
```

v1 targets one pinned Unicode version (documented in the generated
file's header comment); this is the project's one real maintenance
liability and is called out again in §10.

### 5.3 Reserved words beat `IDENTIFIER` by declaration order, not by rule logic

`nil`, `true`, `false`, `NaN`, `Infinity` are all syntactically valid
`IDENTIFIER` matches too. Aether's maximal-munch tie-break is
declaration order (`AETHER.md` "Maximal munch"), so the fix is
structural, not a grammar-level exclusion list: declare `NIL`, `TRUE`,
`FALSE`, and the `NaN`/`Infinity` literals inside `FLOAT`'s own token
definition, all *before* `IDENTIFIER` in the file. Every reserved word
in `DXN.md`'s `reserved` production maps to exactly one token declared
earlier than `IDENTIFIER` — one mechanism, no exceptions, easy to
audit with `mix ichor.tokens grammar.aether` (lists tokens in
tie-break order).

### 5.4 Numeric literals need no ordering tricks

`integer` / `float` / `decimal` / `rational` share a `DIGIT+` prefix
but are never actually ambiguous: maximal munch picks the *longest*
full match at a position, and `19.99M` (decimal, 6 chars) is strictly
longer than the same text's `float` match (`19.99`, 5 chars, since
`M` isn't part of `float`'s own grammar) or `integer` match (`19`, 2
chars). Same reasoning covers `rational` (`22/7`) against a bare
`integer` prefix (`22`). No declaration-order dependency here at
all — length alone resolves it, for every case `DXN.md` §1.2 defines.

### 5.5 `map`/`struct` shorthand keys are one fused token, not `IDENTIFIER` + `COLON`

This is the one real hazard in the grammar, and it's a direct
consequence of Aether's lexer working position-by-position, blind to
what the *parser* will eventually want at that spot. `DXN.md`'s
`map_entry` shorthand is `identifier ":" value` (key colon trails the
identifier); `keyword` in value position is `":" identifier` (colon
leads). If `":"` were its own standalone `COLON` token, then at
`name:value` (no space — legal per the spec's own "`ws`...
everywhere" looseness) the lexer's candidate set at the `:` position
would include both `COLON` (1 char) and `KEYWORD` (`":" IDENTIFIER`,
here matching `:value`, 6 chars) — maximal munch takes the longer one
and silently produces `IDENTIFIER "name"` followed by a bare
`KEYWORD ":value"` token, never a `COLON`, breaking the shorthand
entirely.

Fix: a dedicated `MAP_KEY := IDENTIFIER ":"` token, used only in
`map_entry`'s shorthand alternative, with no standalone `COLON` token
declared anywhere in the grammar at all (the arrow form uses `"=>"`,
never a bare colon). `MAP_KEY` and `KEYWORD` have disjoint first
characters (`IDENTIFIER`'s first char is never `:`), so they can never
compete for the same span — the ambiguity is eliminated, not just
resolved by ordering.

Consequence, stated as a deliberate restriction rather than an
oversight: **a shorthand key's colon must not be preceded by
whitespace** (`name:` is a map-entry key, `name :` is not — the space
prevents `MAP_KEY` from matching at all, and there is no fallback
production for "identifier, then, elsewhere, a colon"). Every worked
example in `DXN.md` §3 already writes keys this way; the restriction
also matches Elixir's own `key: value` map-literal shorthand, which
draws the identical line for the identical reason.

### 5.6 `@_` (discard) is a fixed 2-character token, not `AT` + `IDENTIFIER("_")`

`"_"` alone is a syntactically valid `IDENTIFIER` (`letter = "_"` is
allowed with zero following `ident_char`s), so `@_foo` is ambiguous
between "discard the value `foo`" and "custom tag named `_foo`" *only
if* the lexer is free to choose where the identifier starts. Declaring
a fixed literal token `AT_DISCARD := "@_"` (exactly two characters,
not `"@" "_" ident_char*`) removes the freedom: at `@_foo`, `AT_DISCARD`
matches 2 chars and plain `AT` matches 1 — `AT_DISCARD` always wins on
length, regardless of what follows, so `@_foo` always lexes as
`AT_DISCARD` + `IDENTIFIER "foo"`. Net effect, worth documenting since
it's not obvious from the EBNF alone: **no custom tag name may begin
with `_`** — any `@_...` is unconditionally discard-of-the-rest, never
a tag literally named `_...`. This is a deterministic consequence of
the token declaration, not a special case the parser or actions module
has to check for.

```text
discard := AT_DISCARD value ;   ; matches DXN.md's own "discard = '@_', value"
value   := discard* value_body ;
```

`tag_form`'s own `identifier` (matched via plain `AT` + `IDENTIFIER`)
therefore never needs to special-case `"_"` — it's already
unreachable for that spelling by construction.

### 5.7 Sigils delegate validation to stdlib, not to more grammar

`~D[...]`, `~T[...]`, `~U[... ...Z]` each capture their bracketed body
as one token (`(!"]" .)*` style, the same technique the LISP
example's `STRING` token already uses for `(!"\"" .)*`) rather than
encoding ISO 8601's numeric grammar in Aether. `Dextrin.Text.Actions`
then calls `Date.from_iso8601/1` / `Time.from_iso8601/1` /
`DateTime.from_iso8601/1` on the captured text and surfaces any
`{:error, reason}` as an `Ichor.Error` (stage: `:action`). Smaller
grammar, and correctness for calendar edge cases (leap years, leap
seconds if ever relevant) comes from a battle-tested stdlib parser
instead of a hand-rolled one.

`~r/pattern/flags` similarly captures pattern text with a
`(ESCAPED_SLASH | !"/" .)*`-style token (never a real regex engine —
this is exactly the same shorthand `AETHER.md`'s own "Regex literals"
section describes, since `.dxn`'s sigil and Aether's `/pattern/` token
shorthand happen to share a delimiter convention, not an
implementation). Flags are validated against `DXN.md` §1.2's
`regex_flags` set and handed to `Regex.compile/2` as-is — Elixir's own
modifier letters (`i m s u x f r`) are already identical to DXN's, so
no translation table is needed at all.

### 5.8 `%{` vs `%Name{` vs `%Name[` need no special token

All three start with a single `%` (`PERCENT`, one token, no
competitor starting with `%`) followed by either `{` or an
`IDENTIFIER`. Ordinary ordered-choice at the rule level handles it:

```text
value_body := ... | map_lit | struct_lit | ... ;
map_lit    := PERCENT "{" map_entry* "}" ;
struct_lit := PERCENT name:IDENTIFIER (("{" map_entry* "}") | ("[" value* "]")) ;
```

putting `map_lit` first in `value_body`'s choice is enough — PEG
ordered choice only needs `map_lit` to *fail fast* on seeing an
identifier instead of `{`, which it does immediately.

### 5.9 `@dxn` can only ever be the header — a fourth grammar restriction, same shape as §5.5/§5.6

`header := "@dxn" version:STRING` uses one fixed 4-char literal
(`"@dxn"`, an anonymous token) rather than `AT identifier:IDENTIFIER`
— it wins over plain `AT` (1 char) by length at *every* position in
the document, not only at document start, since Ichor tokenizes the
whole input in one global pass before parsing begins (`AETHER.md`) —
tokenization has no concept of "only try this where a rule expects
it." Consequence: `@dxn` can never be parsed as an ordinary custom
tag anywhere in a document, not just where `document := header?
value` actually expects a header — a nested `[@dxn "x"]` fails to
parse at all, rather than being read as a custom tag literally named
`"dxn"`. Low-risk in practice (`"dxn"` is the format's own name, an
unlikely real-world custom tag choice) but a real, deliberate
restriction, the same shape as §5.5's `MAP_KEY` fusion and §5.6's
`AT_DISCARD` — found while writing the grammar, initially only noted
inline there, written up here to close that loop.

The header's version string itself is captured and then discarded
unconditionally (`Dextrin.Text.Actions`'s `eval_header/2`) — no
compatibility check against a known-version list. Deliberate, not an
oversight: `DXN.md` defines exactly one version ("1.0") and says
nothing about what a *different* version string should mean for a
reader (reject? warn? best-effort parse anyway?), so inventing a
compatibility policy here would be answering a question `DXN.md`
itself hasn't asked yet. Revisit once a second format version exists
and `DXN.md` says what "compatible" means.

## 6. `Dextrin.Text.Actions`

Implements `handle_token/3` for every scalar (numbers via
`String.to_integer`/`String.to_float`/`Decimal.new`/manual rational
split; strings/chars via the shared escape-decoding already used for
identifiers' `\u{}` — factor into one `Dextrin.Text.Escapes` helper so
string bodies and char-class-derived tokens never duplicate escape
logic) and `handle_rule/3` for every collection and for `tag_form`
(dispatch table: built-in tag names from `DXN.md` §1.3's `dxn_syntax`
column → hardcoded handlers; anything else → `Dextrin.Registry` lookup
→ `Dextrin.CustomTag` fallback, per §4.3).

`context` carries the `Dextrin.Registry` (read-only — text parsing
never mutates it) plus an accumulating error list, following the same
"thread `context` through, `finalize/1` checks it at the end" pattern
`Ichor.Actions` already documents for multi-form sources. `document`
is the `@root`; a single top-level `value` per file, matching
`DXN.md`'s own `document = [header], value` (no `run_sequence/4`
needed — DXN is one value per document, unlike LISP's many
top-level forms).

`discard` (§5.6) evaluates its inner `value` capture (so a malformed
discarded value is still a real parse error, per `DXN.md`'s own
framing of `@_` as "parses ... produces nothing," not "raw bytes
skipped blind") and returns a private `:__dextrin_discard__` sentinel;
`value`'s own `handle_rule` filters that sentinel out of its
`discard*` capture list before returning `value_body`'s result. This
sentinel never escapes `Dextrin.Text.Actions` — it's an internal
detail of folding `discard*` away, not a value any public function
returns.

## 7. Binary codec (`Dextrin.Binary.{Encoder,Decoder}`)

### 7.1 Why hand-rolled instead of a Hex CBOR library

Every generic CBOR library optimizes for *generic* CBOR. `.dxnb` needs
several things no such library is likely to get right by default,
each one a place `DXN.md` explicitly calls out as an integrity
concern (§2.2's `integrity_note` column):

- Bignums past 64 bits *must* use tag 2/3 two's-complement byte form —
  a generic encoder is more likely to default to a float or to refuse
  arbitrary-precision integers outright.
- Timestamps/datetimes *must* use the integer form of tag 1 —
  never the float form, which loses microsecond precision at scale.
  A generic library defaulting to "float if it fits" silently
  violates this.
- Private tags 200–214 and the string-reference extension (tag
  256/25, §2.4) are not things a generic library has any built-in
  concept of; they'd need to be bolted on via whatever extension
  mechanism that library offers anyway, at which point most of the
  library's own value (automatic type mapping) is unused.

Given both directions are being written regardless, a ~300-line
recursive encoder/decoder pair working directly over CBOR's major
types (0–7) plus a fixed tag dispatch table is less code, and less
risk, than adapting a general-purpose library to every one of these
constraints.

### 7.2 Structure

```elixir
# Dextrin.Binary.Tags — pure constant + bit-layout module, mirrors DXN.md §2.3 verbatim
@t_char 200
@t_symbol 201
# ... through @t_custom 214, plus duration_bits/0 and regex_bits/0 keyword lists

# Dextrin.Binary.Encoder
@spec encode(value :: term(), opts :: keyword()) :: binary()
# opts: registry: Dextrin.Registry.t() (to encode structs/custom tags back out),
#       share: boolean() (default false — §7.3.1's general value sharing; see note below)

# Dextrin.Binary.Decoder
@spec decode(binary(), opts :: keyword()) :: {:ok, term()} | {:error, Dextrin.Error.t()}
# always accepts both §2.4 (tag 256/25) and §2.5 (tag 28/29) on decode, regardless of `share:` above
```

One `share:` option, not two. §2.4's string-only sharing and §2.5's
general sharing overlap in practice — tag 28/29 can already wrap a
plain string, so there's no real case where you'd want the narrower
mechanism but not the general one. `Dextrin.Binary.Encoder` only ever
produces tag 28/29 when `share: true`; it never bothers emitting
tag 256/25 at all. The decoder still accepts both unconditionally
(§2.4's and §2.5's own "MUST accept" requirements are both real,
independent of what this encoder chooses to produce), since other
`.dxnb` producers are free to use either.

Envelope (`magic` `version` `cbor_item`, §2.1) is checked/written once,
at the outermost `encode/2`/`decode/2` — everything below that is a
single recursive `encode_item/2` / `decode_item/2` pair keyed on CBOR
major type first, then on tag, matching §2.2's table row order.

### 7.2.1 Major 7 needs its own path — verified, not assumed, and the bug was real

Found while double-checking DXN.md's registered-tag choices (1, 2, 3,
4, 30, 32, 37) against the actual IANA CBOR tags registry for an
unrelated open question (§10), then hand-testing the decoder against
a standards-conformant hand-built float rather than only against this
same encoder's own output: for every major type *except* 7, the
additional-info value (24/25/26/27) is purely "how many extra bytes
encode this number" — the decoded integer is all that matters
afterward, so running it through one generic "minimal-byte integer
head" helper is correct. Major 7 is different: the info value *itself*
distinguishes booleans/nil (20/21/22) from a 16/32/64-bit float
(25/26/27), not an encoding-length detail. The first implementation
used the generic helper for floats too (`head(7, 27)`), which doesn't
know 27 is a fixed marker here, not a value to minimally encode —
`27 < 256` sent it through the "1 extra byte" path, producing a
non-canonical, one-byte-too-long float header. Since the decoder was
written to expect that same (wrong) shape, every prior round-trip
test passed anyway: both sides agreed on the same bug, and nothing
ever decoded a float this encoder hadn't itself produced.

Fixed by special-casing major 7 entirely, in `decode_item/2`, ahead of
the generic `read_head`/`decode_by_major` split (matched directly on
the raw bits, `<<7::3, 27::5, bits::64, rest::binary>>` and siblings),
and by giving the encoder a dedicated `float_head/0` that always
emits the literal marker byte, never routed through the minimal-integer
helper. Picked up single-precision (32-bit) float decoding for
interop with other producers along the way (Erlang's `::float-32`
binary size is free); half-precision (16-bit) is rejected with a
clear error rather than silently mishandled, since dextrin itself
never needs to produce or consume it. Regression coverage:
`test/binary/cbor_float_interop_test.exs`, specifically decoding a
hand-built canonical single-byte float header rather than relying on
this encoder's own (previously wrong) output.

### 7.3 Bignum encoding sketch

```text
integer i, -2^63 <= i < 2^64  -> native major 0/1 (no tag)
otherwise                     -> tag (2 if i >= 0 else 3),
                                  byte string of |i| (or -1-i for tag 3)
                                  in big-endian, minimal-length, unsigned form
```

`:binary.encode_unsigned/1` already produces minimal-length big-endian
bytes for a non-negative integer; tag 3's `-1-i` transform for negative
bignums is the one piece of arithmetic worth a unit test with a couple
of boundary values (`-2^64`, `-2^64 - 1`) rather than trusting it by
inspection.

### 7.3.1 General value sharing (`DXN.md` §2.5)

Generalizes §2.4's string-only sharing to arbitrary repeated
subtrees (a map/list/struct appearing three times encodes to bytes
once plus two small references) — via CBOR tags 28/29, transparent on
decode: a shared value decodes to an ordinary independent copy,
`==`-equal to what an unshared encoding of the same document would
produce. No new `Dextrin` value type — this lives entirely inside
`Dextrin.Binary.{Encoder,Decoder}`, invisible above that layer.

- **Decoder**: mandatory, small addition — tag 28 records the marked
  item at the next shared-index slot (a plain growable list built
  during the decode walk); tag 29 looks up an index and deep-copies
  it. A tag-29 index that's out of range, or that would require
  representing a cycle, is a decode error (`DXN.md` §2.5's own "MUST
  reject" — `.dxnb` values are trees; a decoder that instead built a
  graph would violate every other assumption downstream, starting
  with "equal values are structurally comparable via `==`").
- **Encoder**: optional and off by default (`share: false`) — finding
  repeated subtrees needs a counting pass over the whole value first
  (an occurrence count per distinct value, using Elixir's own
  structural `==`/hashing — any term can be a map key), which is real
  added work for what's a pure space optimization, not a correctness
  requirement. `share: true` opts in; leaving it off keeps the default
  encode path a single straightforward recursive walk, matching §7.4's
  own "byte-for-byte reproducibility isn't a goal" stance — a
  `share: true` and a `share: false` encoding of the same value are
  both conformant, just different sizes.
- **The threshold is calculated, not tuned.** Tag 28's header is
  always exactly 2 bytes; a tag-29 reference costs 2 bytes plus
  however many bytes its index needs (1 byte while fewer than 24
  distinct values have been shared so far, 2 bytes up to 256, and so
  on — the same rule as encoding any other CBOR integer). A value's
  own encoded size is already known once it's been encoded. So for a
  value occupying `item_size` bytes and appearing `count` times,
  sharing is only emitted when
  `item_size + 2 + (count - 1) * (2 + index_size) < count * item_size`
  — every quantity is something the encoder already has in hand at
  that point, not a constant to guess. (An earlier version of this
  doc treated this as needing real-world documents to tune against;
  that was wrong, not just unfinished — see §10 for how that got
  caught and corrected.) One consequence worth calling out: this
  replaces an earlier, cruder rule that categorically excluded plain
  strings from sharing at all — a long, frequently-repeated string is
  now correctly shareable when the same arithmetic favors it, which is
  what actually lets this mechanism subsume DXN.md §2.4's string-only
  sharing, as intended above.

### 7.4 Determinism is explicitly not a goal for v1

`DXN.md` doesn't require canonical/deterministic CBOR (no mention of
sorted map keys, shortest-form-always, etc.), and neither map key
order nor value-sharing decisions are semantically meaningful per the
type table (`map` has "no ordering guarantee" by definition). So:
`encode/2` makes reasonable choices (shortest integer form, no forced
map key sorting, `share_strings: false` by default) but two different
correct encoders — or the same encoder given a `Dextrin.OrderedMap`
built in a different order — are not expected to produce identical
bytes for equal values. Round-trip (`decode(encode(v)) == v`) is the
contract; byte-for-byte reproducibility across encoder runs is not.

## 8. Public API

```elixir
Dextrin.decode(text, opts \\ [])         # .dxn  -> {:ok, value} | {:error, Dextrin.Error.t()}
Dextrin.encode(value, opts \\ [])        # value -> {:ok, .dxn text} | {:error, Dextrin.Error.t()}
Dextrin.decode_binary(bytes, opts \\ [])
Dextrin.encode_binary(value, opts \\ [])

Dextrin.Schema.compile(schema_doc, base_registry \\ Dextrin.Registry.new())
Dextrin.Schema.validate(value, registry, schema_name)          # decode-side
Dextrin.Schema.validate_encode(value, registry, schema_name)   # encode-side, one named schema
Dextrin.Schema.validate_encode_tree(value, registry)           # encode-side, automatic/whole-tree
```

`opts` in both decode functions: `registry:` (§4.3 — `.dxns`-compiled
or hand-built, indistinguishable to `decode`/`decode_binary`). Both
encode functions additionally accept `schema:` (validates `value`
itself against one named schema) and `validate:` (default `true` —
`false` disables the automatic whole-tree check, §8.1). `Dextrin.
encode/2` returning `{:ok, _} | {:error, _}` (not a bare `String.t()`,
its original v1 shape) is what made schema validation possible without
a second, inconsistent return contract from the two encode functions —
`encode_binary/2` already had one.

`Dextrin.encode/2`
is the one function needing real design attention beyond "reverse the
parse" — it's a printer, not a formatter (no line-wrapping/indentation
policy is specified anywhere in `DXN.md`, so it emits single-line,
minimal-whitespace output). Multi-line, indented output is
`Dextrin.Text.Formatter.pretty/2` (§12.4) — implemented, not deferred;
only *comment-preserving* pretty-printing remains out of scope for v1
(§1), since comments never survive past the lexer to be reprinted.

### 8.1 Encode-time schema validation is automatic and name-driven, matching decode

First shipped as an opt-in-only `schema:` param (validate one named
schema, only as deep as its own field types reach), then deliberately
widened: decode checks *every* named struct unconditionally, wherever
it appears, driven purely by "does this name have a registered
schema" — never by what an enclosing field declared. An opt-in-only
encode side didn't match that, and the mismatch is exactly what makes
it easy to forget: a nested struct sitting behind an `:any` field, or
in a plain undeclared list, was invisible to `schema:`'s own check
even when named correctly elsewhere. The two silent-failure directions
aren't symmetric, either — forgetting to opt *in* ships bad data;
forgetting to opt *out* just fails loudly. That asymmetry, more than
anything, is why automatic-by-default won over opt-in.

So `Dextrin.encode/2`/`encode_binary/2` now do two independent checks:

- **Automatic, whole-tree** (`Dextrin.Schema.validate_encode_tree/2`,
  on by default): walks `value` and checks *every* `Dextrin.Struct` —
  by its own name — or registered application struct — by
  `Registry.fetch_schema_name_for_module/2`, the reverse of
  `put_struct_module/3` — against its own schema, wherever it turns
  out to be. `validate: false` opts out, for the legitimate cases
  automatic checking would otherwise get in the way of: deliberately
  building non-conforming wire data (test fixtures, conformance
  cases, testing that a *receiver* rejects bad input) or a pass
  -through/relay that shouldn't second-guess data it isn't the origin
  of.
- **`schema:`, one named schema** (`Dextrin.Schema.validate_encode/3`,
  opt-in, unchanged from its original design): still the only way to
  validate a *nameless* top-level value — a plain map or an
  unregistered application struct has nothing for the automatic walk
  to key off of at all.

Neither check ever transforms `value` — a `Dextrin.Struct` is the one
shape that round-trips to `%Name{...}` struct-literal wire syntax; a
plain map or unregistered struct still encodes to whatever its own
natural DXN shape is (a plain map, or via a registered `tag_encoder`,
§4.3) even after passing validation.

**One validation implementation, not two.** `{:reference, name}`
fields need a different *source of identity* than decode's — there's
no wire tag or `Validated` marker to have been stamped on data that
hasn't been encoded yet. But rather than a second, parallel
type-checking function for that one difference, encode-time validation
(`Dextrin.Schema.Validator.wrap_and_check/2`) recursively wraps every
struct it recognizes — by `Dextrin.Struct`'s own name, or by
`Registry.fetch_schema_name_for_module/2` for a registered application
struct — in the exact same `Dextrin.Schema.Validated` marker decode's
`materialize/4` already produces, *before* checking anything. From
that point on, `resolve_fields/3` and `TypeExpr.matches?/3` — the
literal same functions `materialize/4` calls — check it, with no
encode-specific branch except one: a real, *unwrapped* application
struct (no schema of its own to be wrapped by) still needs `__struct__`
checked against whatever module was registered for the expected name
via `put_struct_module/3`, since nothing else could have wrapped it.
Only a plain map (no name, no `__struct__`) or an unregistered name has
nothing to check, and is trusted — the same shape of residual limit
`{:reference, name}` already had, now identical on both sides instead
of independently re-derived.

This unification is also what makes encode-time reference checking
*fully* recursive, not shape-only the way it first shipped: checking
a `{:reference, "Address"}` field now means `wrap_and_check/2` already
ran `Address`'s own schema against the referenced value — via the same
`check_compiled/3` any struct goes through — before wrapping it, so a
struct with the *right* name but *invalid* fields of its own is caught
exactly as it would be by decode, not just confirmed to be the right
type.

## 9. Testing strategy

- **Per-type round-trip**: for each of the 30 types in §1.3, a small
  property (via `StreamData` or hand-picked edge values — `NaN`,
  `-0.0`, the empty string, a rational with a negative denominator, an
  empty set/map/tuple) asserting `decode_binary(encode_binary(v)) ==
  v` and, where the text grammar can express the value unambiguously,
  `decode(encode(v)) == v` too.
- **Conformance fixtures** (`test/conformance/fixtures/`): `DXN.md`
  §3's worked example, checked in as a `.dxn` file, decoded once and
  compared field-by-field against a hand-written expected value —
  this is the one test that exercises every type in a single document
  the way a real consumer would.
- **Cross-format equivalence**: parse a fixture's `.dxn`, encode to
  `.dxnb`, decode that, and diff against parsing the `.dxn` directly —
  catches any place the two pipelines quietly disagree about what a
  type means. For `struct` fixtures specifically, this only holds
  (and is only tested) with the relevant schema compiled and passed
  in — without one, `.dxn`'s keyed field names have nowhere to go
  through `.dxnb`'s always-positional wire shape (§2.1) and back, by
  spec, not by bug. A separate, smaller fixture covers the no-schema
  case explicitly: assert it decodes to an opaque `Dextrin.Struct`
  rather than failing (§1.4's own contract), not that it round-trips.
- **Grammar hazards**: explicit regression tests for §5.5
  (`name:value` vs `name: value` vs `name : value`) and §5.6 (`@_foo`
  vs a hypothetical `@_foo`-named custom tag) — these are exactly the
  two places a future grammar edit is most likely to reintroduce
  ambiguity silently.
- **Fuzz/malformed-input pass**: truncated `.dxnb` (envelope present,
  CBOR item cut short), invalid UTF-8 inside a `string`/`symbol`
  major-3 item, an out-of-range private tag, an out-of-range tag-29
  index, and a hand-crafted cyclic tag-28/29 reference — decoder must
  return `{:error, ...}`, never raise or hang, for every case.
- **Value sharing round-trip** (§7.3.1): encode a value containing
  the same non-trivial map three times with `share: true`, confirm
  the output is smaller than `share: false`'s, and confirm both decode
  to `==`-equal values — the transparency property is the point, not
  just that it decodes at all.
- **Schema conformance** (§4.4): one fixture per `type_expr` form
  (§4.4.1) and one per `refine` key (§4.4.3), each with a passing and
  a failing value; a closed-schema fixture with an extra field, a
  `forbidden`-field fixture, and a mutually-recursive pair of struct
  schemas (to exercise §4.4.5's forward-reference compilation) round
  out the set.

## 10. Open questions / risks

- ~~**`custom-tag` has no encode-side registry entry**~~ — closed:
  `Dextrin.Registry.put_tag_encoder/4` (§4.3), consulted by
  `Dextrin.encode/2`, `Dextrin.Text.Formatter.pretty/2`, and
  `Dextrin.encode_binary/2` alike for any struct their own built-in
  clauses don't recognize. Verified for both the "encoder present"
  and "no registry given" (clear error, not a crash) paths, plus a
  registered encoder itself returning `{:error, reason}` — all three
  surface correctly rather than silently swallowing the failure.
- ~~**Unicode version pinning** (§5.2): `IDENT_START`/`IDENT_CONT`'s
  generated ranges are frozen at whatever UCD version
  `gen_unicode_ranges.exs` was last run against; a future Unicode
  release won't be recognized until someone remembers to re-run the
  generator by hand~~ — partially closed: `mix dextrin.gen.unicode`
  (`lib/mix/tasks/dextrin/gen_unicode.ex`) fetches the current UCD
  data, compares its version against the checked-in
  `priv/unicode/VERSION`, and only touches `dxn.aether`/the UCD data
  file/the version marker when it's actually newer (or `--force`).
  What's still true, deliberately: this is never run automatically —
  nothing polls unicode.org or gates CI on it — a human still has to
  invoke the task and review the resulting grammar diff before
  committing, same as any other dependency version bump.
- ~~**`.dxns` type_expr vocabulary is fixed, not extensible, in v1**
  (§4.4.1's 13 forms are hardcoded in `Dextrin.Schema.Compiler`, not a
  registry of their own). If real schemas need a constructor outside
  that list, it either grows the fixed vocabulary (a library change)
  or falls back to `refine-fn` (§4.4.4)'s escape hatch~~ — closed:
  the vocabulary of *forms* is still fixed (unchanged, and the right
  call — a form like `refine`/`list-of` genuinely does need matching
  code in every language's decoder), but what actually needed to be
  extensible was schema *authors'* ability to name and reuse a
  combination of those forms, which doesn't need a 14th form at all.
  Any `.dxns` entry that isn't a `%schema{}` now defines a named type
  (§4.4.1's new "Named types" section) — e.g. `PositiveInt: {:refine
  :integer %{min: 1}}` — referenced exactly like a struct name (a bare
  symbol), resolved by `Dextrin.Registry.put_type_alias/3`/
  `fetch_type_alias/2`. Deliberately data-only: no registered Elixir
  callback, so a JS/PHP port needs nothing beyond what it already
  needs to implement `refine`/`list-of`/etc. themselves. Scope
  boundary, not a gap: a named type can't reference a sibling named
  type in the same document (only ones already known via
  `base_registry`) — `.dxns`'s map has no ordering guarantee to
  resolve same-document forward references against, and no real
  schema has needed that yet.
- ~~**Cross-file schema references** are real, undesigned work~~ —
  closed, in two parts. *Composing* multiple compiled schemas into one
  registry needed no new mechanism at all: `Dextrin.Schema.compile/3`'s
  `base_registry` parameter threads across repeated calls, and
  `put_resolver/2`'s lazy-loading hook (designed early, in §4.3, but
  never actually exercised by a test until now) correctly loads on
  first encounter and memoizes — confirmed with a call-counting
  resolver against a document containing the same struct name twice.
  *Automatically* resolving a bare `Namespace/Name` to a file path —
  the part that genuinely needed a policy decision, not just an
  implementation — now has one answer, `Dextrin.Schema.FileResolver`
  (`Namespace/Name` → `<path>/Namespace.dxns`, entry `Name`), built
  and documented explicitly as *one reasonable, swappable convention*,
  not a mandated one baked into the core `Registry`/`Schema` API —
  anyone who wants a different convention writes their own
  `struct_resolver` directly.
- ~~**`{:reference, name}` type-checking, partially closed.** Was an
  unconditional `true` (§4.4.6's "not implemented in v1"); ... Anything
  already materialized through a registered materializer (which can
  produce any shape at all, discarding which schema it came from) is
  still trusted unconditionally — genuinely can't be checked without
  ... tracking schema provenance some other way~~ — closed, via
  exactly that: `Dextrin.Schema.Validator.materialize/3` now wraps
  every successfully-validated struct's result in an internal
  `Dextrin.Schema.Validated{name:, value:}` — regardless of whether
  the materializer produced a plain map, a real Elixir struct, or
  anything else — so an outer `{:reference, name}` check
  (`Dextrin.Schema.TypeExpr.matches?/2`) can verify the *originating
  schema's* name directly, not the value's shape. The wrapper is
  purely internal bookkeeping: stripped as soon as a field's type
  isn't itself a reference (so a materializer never sees it in its
  own input), and stripped once more at the true top of decoding
  (`Dextrin.decode/2`/`decode_binary/2`) for a struct that was never
  anyone's field to begin with — confirmed both don't leak via a
  materializer that returns a real Elixir struct nested inside a
  `{:list-of Address}` field, and a bare struct at the document root
  with no enclosing schema at all. The one limit that remains is
  unavoidable, not a gap: a value that never went *through*
  `Dextrin.decode`/`decode_binary` (built directly in Elixir and
  handed to `Dextrin.Schema.validate/3`) has no wire data to have
  tagged it, so there's nothing left to check beyond what was already
  checkable before.
- ~~**`share: true`'s sharing threshold is repetition-count-only, not
  size-aware... needs real-world documents to tune against**~~ — this
  was wrong, not just incomplete: whether a given repeated value is
  worth sharing is *fully calculable* from CBOR's own encoding rules,
  not something that depends on what real documents look like. Tag
  28's header is always exactly 2 bytes, a tag-29 reference costs 2
  bytes plus however many bytes its index needs, and a value's own
  encoded size is already computed while encoding it — so for a value
  of `item_size` bytes appearing `count` times, sharing wins exactly
  when `item_size + 2 + (count - 1) * (2 + index_size) < count *
  item_size`. Every quantity is known at encode time; there's no
  unknown to tune against. Implemented (§7.3.1) — a value only gets
  wrapped in tag 28/29 when this comparison actually favors it, and
  the encoder never produces a larger result than `share: false`
  would, confirmed by test across a range of sizes and repetition
  counts (including the exact crossover point matching the arithmetic).
  Also fixed something this uncovered: an earlier version categorically
  excluded plain strings from sharing consideration, which was actually
  inconsistent with this mechanism's own stated purpose of subsuming
  DXN.md §2.4's string-only sharing — a long, frequently-repeated
  string is now correctly shareable too, decided by the same math.
- ~~**Tag numbers 28/29** cited from memory, worth confirming~~ —
  confirmed directly against `iana.org/assignments/cbor-tags/tags.csv`:
  28 is registered as "mark value as (potentially) shared," 29 as
  "reference nth marked value" (both `Marc_A._Lehmann`,
  cbor.schmorp.de/value-sharing) — exactly the family DESIGN.md
  described. Also confirmed 25/256 (stringref) and dextrin's other
  registered-tag choices (1, 2, 3, 4, 30, 32, 37) against the same
  table while checking this.
- ~~**CBOR private tags 200–214 are not IANA-registered** — `DXN.md`
  itself flags this (§2.3): collision-free only within
  `dextrin`-produced documents. Not this library's problem to solve,
  but worth surfacing in `Dextrin`'s own moduledoc~~ — closed: noted
  directly in `Dextrin`'s moduledoc.
- ~~**`Decimal` dependency**: pulls in `decimal` (small, no transitive
  deps) purely for exact fixed-point arithmetic semantics — confirm
  this is an acceptable dependency~~ — confirmed, acceptable.
- ~~**`Dextrin.Text.Printer.print/2` still raises for its own
  pre-existing failure** (no `tag_encoder` registered for a struct, or
  a registered one itself returning `{:error, _}`) instead of
  returning `{:error, _}` the way `Dextrin.Binary.Encoder`'s
  equivalent path already did~~ — closed: `print/2` now returns
  `{:ok, String.t()} | {:error, Dextrin.Error.t()}`, threaded through
  every recursive clause (`print_all/2`/`print_entries/2` mirror
  `Dextrin.Binary.Encoder`'s own `encode_all/2`/`encode_pairs/2`).
  `Dextrin.encode/2` returns `print/2`'s result directly. `Dextrin.
  Text.Formatter.pretty/2`'s own contract (a bare `String.t()`) was
  deliberately left unchanged — not part of what was asked — but it
  depends on `print/2` internally, so it now explicitly unwraps
  (`print!/2`) and raises on failure, preserving exactly the behavior
  it always effectively had.
- ~~**Encode-time reference checking is shape-only**: it confirms a
  referenced field's value is an instance of the right module, but
  doesn't recursively re-validate that value against *its own* schema
  the way decode's fully-recursive materialization does~~ — closed
  (§8.1), and not by adding recursion to a separate encode-specific
  checker: encode-time validation now wraps every struct it recognizes
  in the same `Dextrin.Schema.Validated` marker decode uses, then
  reuses decode's own `resolve_fields/3`/`TypeExpr.matches?/3`
  unchanged. Checking a reference now means the referenced value's own
  schema already ran (`check_compiled/3`) before it was ever wrapped —
  genuinely as thorough as decode, via one shared implementation
  rather than two that could drift out of sync.

## 11. Media types

```text
media_types[3]{extension,media_type,note}:
  .dxn,"application/vnd.dxn; charset=utf-8","text — always UTF-8, always state it explicitly (unlike text/*, application/* has no default charset in HTTP)"
  .dxnb,"application/vnd.dxnb","binary — see below for why this isn't application/dxn+cbor"
  .dxns,"application/vnd.dxns; charset=utf-8","schema documents — see below; always .dxn-syntax text, no binary variant"
```

**Why not the `+cbor` structured syntax suffix for `.dxnb`.** It's the
obvious-looking choice — `.dxnb` *is* CBOR underneath — but RFC 8949's
own registration of `+cbor` requires the media type's body to *be* a
single, well-formed CBOR data item, nothing else. `.dxnb`'s envelope
(§2.1: `magic` `version` `cbor_item`, a 3-byte prefix *before* the
actual item, kept specifically for cheap magic-number sniffing) means
the byte stream isn't a bare CBOR item from byte 0 — generic
CBOR-aware tooling that trusts the `+cbor` suffix's contract would
choke on those 3 bytes. Using the suffix anyway would be a
technically-incorrect registration, not just an unconventional one, so
`.dxnb` gets its own plain vendor type instead of borrowing CBOR's.

**Vendor tree (`vnd.`), not a bare `application/dxn`.** Per RFC 6838,
an unregistered, from-scratch format like this belongs in the vendor
tree — lighter registration (IANA Expert Review, not a full
standards-track RFC) than claiming the unprefixed `application/dxn`
would require, and it's honest about DXN not (yet) being an adopted
external standard. `application/vnd.dxn`/`application/vnd.dxnb` work
perfectly well over HTTP/AMQP unregistered, today; formal IANA
registration is a real but optional later step, mainly useful for
avoiding a future name collision, not a functional requirement for
using the type in the wild.

**Revising the earlier call: `.dxns` does get its own media type**,
even though §4.4's premise still holds — it's still ordinary `.dxn`
syntax, no new grammar. A media type doesn't have to track a *syntax*
difference to be worth having; it can just as legitimately signal
*profile/intent* on top of an identical syntax, the same relationship
`application/vnd.api+json` has to plain `application/json` — same
JSON underneath, but the vendor type tells a generic client "expect
the JSON:API conventions" without opening the body first. That's
exactly what's needed for schema transfer over HTTP/AMQP: a consumer,
router, or gateway needs to recognize "this is a schema" *before*
decoding it, so it can be cached, versioned, or routed to a schema
store differently from ordinary data traffic — even if that traffic
is rare. `application/vnd.dxns` gives them that without requiring a
new wire format; it's `application/vnd.dxn` with a different name,
nothing more.

No binary counterpart (`.dxnb`-syntax schema) — schemas are meant to
be authored, diffed, and reviewed by humans, so `.dxns` is always
`.dxn`-syntax text. Someone who genuinely wants a compiled/binary
schema payload can still binary-encode the same value as ordinary
`application/vnd.dxnb` — it decodes to a `%schema{}`-shaped value like
any other, just without the transport-level "by the way, this is a
schema" hint, which is an acceptable trade-off for what should be a
rare case.

**HTTP**: set `Content-Type: application/vnd.dxn; charset=utf-8`,
`application/vnd.dxnb`, or `application/vnd.dxns; charset=utf-8` on
responses; `Accept` negotiation between them is a normal
`Plug`/router concern, not something `Dextrin` itself needs to
arbitrate. This is also a natural fit for §4.3's on-demand schema
resolver hook: a lazy resolver can be nothing more than "`GET
/schemas/:name`, expect `application/vnd.dxns` back, compile the
body" — the resolver's own business, not something `Dextrin`
prescribes, but the media type is what makes that a well-defined
request to make in the first place.

**RabbitMQ/AMQP**: no broker-side registration needed — set the
message's `content_type` property to the matching string
(`"application/vnd.dxn"` / `"application/vnd.dxnb"` /
`"application/vnd.dxns"`) when publishing. A schema update — a
service occasionally publishing its current schema to a fanout
exchange when it changes, or answering an RPC-style "send me your
schema" request — is just a message like any other, identifiable by
`content_type` alone without a subscriber needing to inspect the
payload first; a consumer dispatches on that property before calling
`Dextrin.decode/2` or `Dextrin.Schema.compile/2` accordingly.

## 12. Mix tasks

Namespaced `mix dextrin.*`, mirroring `ichor`'s own
`mix ichor.tokens` precedent (`Mix.Tasks.Ichor.Tokens`,
`lib/mix/tasks/ichor.tokens.ex`) — same placement convention,
`lib/mix/tasks/dextrin/*.ex` here.

### 12.1 `mix dextrin.validate PATH`

Decodes `PATH` (`.dxn`/`.dxnb`, sniffed from the extension or `--format`),
reports success or a rendered `Dextrin.Error` (reusing `Ichor.Error`'s
caret-annotated context, §5.6/§6). `--schema SCHEMA.dxns --as NAME`
additionally compiles that schema and runs `Dextrin.Schema.validate/3`
against it. Exit code 0/1 — meant for CI, not just interactive use.

### 12.2 `mix dextrin.encode PATH` / `mix dextrin.decode PATH`

`encode`: `.dxn` text → `.dxnb` (`--out PATH`, defaults to stdout;
`--share` toggles §7.3.1's value sharing). `decode`: `.dxnb` → `.dxn`
text, printed through the formatter's pretty mode (§12.4) by default —
a CLI decode is a human reading the result, so the encoder's own
default single-line/minimal-whitespace output (§8, correct for
`Dextrin.encode/2`'s own API default) isn't the right default *here*.

### 12.3 `mix dextrin.gen.schema Module`

Introspects an already-compiled Elixir struct module — its field list
always, plus a best-effort mapping from `@type t()` typespecs when
present (`String.t()` → `:string`, `integer()` → `:integer`,
`t() | nil` → `{:nilable, ...}`, and so on for the handful of shapes
that map cleanly) — and emits a `.dxns` scaffold. Anything it can't
confidently map becomes `:any` (§4.4.1), not a guess. This is
explicitly a starting point for a human to review and tighten, not a
claim that typespec → DXN type_expr translation is lossless — Elixir's
typespec language is considerably richer than `.dxns`'s deliberately
small 13-form vocabulary (§4.4.1), and no heuristic closes that gap
honestly.

### 12.4 `mix dextrin.format PATH`

`--mode pretty` (multi-line, indented, matching `DXN.md` §3's own
worked-example style) or `--mode condense` (single-line, minimal
whitespace — what `Dextrin.encode/2` already produces by default).
`--in-place` rewrites the file; otherwise prints to stdout.

**Comments cannot be preserved, in either mode, as this design
currently stands — not "stripped by default," structurally gone.**
§5.1 folds `#`-comments into the same auto-spliced `@skip TRIVIA` as
whitespace: the lexer consumes and discards them before the parser
(and therefore `Dextrin.Text.Actions`) ever sees them, and Ichor's
`@skip` splicing has no mechanism to retain what it skips (it's
invisible plumbing between sequence elements, not a capture). A
formatter built on `decode` → reprint, as this whole design is, has
no comment text left to put back — "optional removal" isn't
meaningfully optional in v1, it's unconditional.

A genuine comment-preserving formatter needs a second, independent
pipeline that never goes through the value-producing parse at all —
a re-lexer that tokenizes source text while explicitly retaining
comment spans, then reprints around them, the same shape of thing
`Code.string_to_quoted_with_comments/2` is for Elixir's own `mix
format`. That's real, separate design and implementation work, not a
flag on the existing pipeline — worth doing only if comment
preservation turns out to matter in practice, not built speculatively
now. Confirm before I write it into `mix dextrin.format`'s spec as a
real goal, or whether v1 should just say plainly that formatting
always drops comments.
