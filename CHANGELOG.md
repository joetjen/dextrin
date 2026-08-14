# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `decimal` bumped `~> 2.1` -> `~> 3.0` -- `mix hex.audit` flagged the resolved `2.4.1` against a real, published MEDIUM-severity advisory (EEF-CVE-2026-32686, "unbounded exponent in decimal enables unauthenticated DoS") while adding a downstream consumer. This package parses untrusted `.dxn`/`.dxnb` input directly into `Decimal.new/1,3` (`lib/dextrin/text/actions.ex`, `lib/dextrin/binary/decoder.ex`) -- exactly the attack surface the advisory describes, not an incidental transitive path. Every `Decimal.*` call this package makes (`new/1`, `new/3`, `to_float/1`, `to_string/2`) is unchanged, stable core API across 2.x and 3.x -- confirmed by the full existing test suite passing unmodified against `3.1.1`.

## [0.1.2] - 2026-08-14

### Added

- `Dextrin`'s own moduledoc now names its two sibling ports
  (`node-dextrin` on npm, `php-dextrin` on Packagist) directly,
  alongside the existing README "Other language implementations"
  section and `mix.exs` package links.

### Fixed

- `Dextrin.Text.Formatter` (`encode/2`'s `pretty: true` path) rendered
  a map entry's *key* incorrectly in two cases, both traced to
  `render_entry/4` conflating "render this as a value" with "render
  this as a keyword key":
  - A string-typed key that happened to look like a bare identifier
    (e.g. `"id"`) rendered as keyword-shorthand (`id: 1`) instead of
    the quoted arrow form (`"id" => 1`) — silently changing the key's
    type from `string` to `keyword` on the next decode. This is also
    why a schema-materialized struct (whose field map is always
    string-keyed) round-tripped incorrectly once pretty-printed.
  - A map keyed by exactly the atom `:nan`, `:positive_infinity`, or
    `:negative_infinity` — the same atoms a *float* `NaN`/`Infinity`/
    `-Infinity` decodes to — rendered the key as the float sigil
    (`Infinity => ...`) instead of the keyword it actually was
    (`positive_infinity: ...`), because the key fell through to the
    same code path that (correctly, in *value* position) special-cases
    those three atoms.

  `Dextrin.Text.Printer` (the compact, non-pretty path) was not
  affected — only the multi-line formatter had this bug. Found via a
  cross-language round-trip check against `node-dextrin`/`php-dextrin`.

## [0.1.1] - 2026-08-03

### Changed

- Bumped `ichor_runtime` to `~> 0.2` (and dev-only `ichor` to `~> 0.3`, its
  matching release) for the fix to `Ichor.Actions`' `eval_all` sometimes
  evaluating sibling captures out of source order. Regenerated
  `lib/dextrin/text/grammar/native.ex` via `mix ichor.gen` and updated
  the private `@ordered`-map re-entry helper in `Dextrin.Text.Actions`
  for `ichor_runtime`'s breaking change to raw capture data: an ordered
  `[{name, value}]` list instead of a plain map. No user-visible
  behavior change.

## [0.1.0] - 2026-07-30

### Added

- **`.dxn` text**: full grammar support for all 30 types DXN.md §1.3
  defines, via a hand-authored Aether grammar (`priv/grammar/dxn.aether`)
  compiled at build time through Ichor's `Grammar.Native` backend.
- **`.dxnb` binary**: a hand-rolled CBOR codec (`Dextrin.Binary.Encoder`/
  `Decoder`) covering the full type mapping, the private tag block
  (200-214), the duration bitmask and regex flags byte, and both
  value-sharing extensions (string-only, tag 256/25; general arbitrary-
  value sharing, tags 28/29 — decode-only required, encode opt-in via
  `share: true`, gated by a size-aware threshold rather than a fixed rule).
- **`.dxns` schema documents**: `Dextrin.Schema.compile/3` compiles a
  decoded `.dxns` document (itself plain `.dxn` data, no new grammar)
  into a `Dextrin.Registry` — struct schemas with required/optional
  (`?`-suffixed keys)/closed/forbidden fields and `refine` constraints,
  plus reusable named types composed from the fixed 13-form type_expr
  vocabulary. Enforcement is automatic, fail-fast, and symmetric:
  `Dextrin.decode/2`/`decode_binary/2` check every registered struct
  name unconditionally on the way in; `Dextrin.encode/2`/
  `encode_binary/2` do the same automatic whole-tree check on the way
  out (`validate: false` opts out), plus an opt-in `schema:` check for
  a nameless top-level value.
- **`Dextrin.Registry`**: the shared extension point for both `struct`
  (schema-driven, `put_struct_materializer/3`/`put_struct_module/3`)
  and `custom-tag` (`put_tag/3`/`put_tag_encoder/4`), plus a lazy
  `put_resolver/2` hook for on-demand schema loading.
- **`Dextrin.Schema.Std`**: a small standard library of common named
  types (`PositiveInteger`, `NonEmptyString`, `Percentage`, ...),
  opt-in via `Std.registry/1`.
- **`Dextrin.Schema.FileResolver`**: one reasonable, swappable
  convention resolving `Namespace/Name` references to
  `<path>/Namespace.dxns` files on disk.
- **Value types**: `Dextrin.Symbol`, `Dextrin.Keyword` (never Elixir
  atoms — decoding untrusted data can't exhaust the atom table),
  `Dextrin.Tuple`, `Dextrin.Array`, `Dextrin.OrderedMap`,
  `Dextrin.SortedSet`, `Dextrin.Struct`, `Dextrin.Duration`,
  `Dextrin.Rational`, `Dextrin.Uuid`, `Dextrin.Uri`, `Dextrin.Bytes`,
  `Dextrin.Char`, `Dextrin.CustomTag` — small wrapper structs only
  where Elixir has nothing native that fits without losing information.
- **`Dextrin.Text.Formatter`**: multi-line, indented `.dxn` rendering
  (`pretty/2`), built on top of `Dextrin.Text.Printer`'s single-line
  default.
- **`mix dextrin.*` tasks**: `validate`, `encode`, `decode`, `format`,
  `gen.schema` (scaffold a `.dxns` file from an existing Elixir
  struct's field list), and `gen.unicode` (regenerate the grammar's
  Unicode `XID_Start`/`XID_Continue` identifier ranges from the latest
  Unicode Character Database — a deliberate, reviewed action, never
  run at build time).
- Conformance fixtures covering `DXN.md` §3's full worked example,
  per-type round-trip tests, cross-format equivalence tests, grammar
  hazard regression tests, and a fuzz/malformed-input pass over the
  binary decoder.

- `Dextrin.encode/2` gained `pretty:` and `indent:` opts — `pretty:
  true` produces multi-line, indented output (`indent:` sets spaces
  per level, default 2) instead of the single-line/compact default.
  Either way, schema validation runs the same; formatting and
  validation are independent concerns.
- `Dextrin.Schema.Provider`, a behaviour letting a struct's own library
  ship a DXN schema for it without that library ever depending on
  `dextrin` — the schema, the target struct module, and an optional
  materializer are declared on a small, separately-compiled companion
  module (meant to be guarded behind an `optional: true` dependency),
  and `Dextrin.Schema.register_provider/2` compiles and wires it into
  a `Dextrin.Registry` in one call from the consuming application.
- Property-based tests (`stream_data`/`ExUnitProperties`, already a
  declared dependency but previously unused): a shared
  `Dextrin.Generators` module, round-trip properties covering
  `encode/2`/`decode/2`, `encode_binary/2`/`decode_binary/2`,
  `share: true`, and `pretty: true` against randomly generated values,
  a `Dextrin.Binary.FuzzTest` asserting `decode_binary/2` never raises
  or hangs on arbitrary or bit-flipped input, and a per-type property
  suite (`Dextrin.RoundTripByTypeTest`) covering every DXN type
  individually rather than mixed into one nested-structure generator.
  These found several of the bugs listed below on their very first run.
- `Dextrin.encode/2`/`encode_binary/2` accept a bare Elixir atom
  anywhere a `keyword` value is expected — as a map key (`%{x: 1}`,
  matching the shorthand's own colon syntax) or standalone
  (`Dextrin.encode(:ok)`) — exactly as if it were
  `Dextrin.Keyword.new(Atom.to_string(atom))`. `DXN.md` §1.3's own type
  table documents `keyword`'s Elixir counterpart as "Elixir atom".
  `nil`/`true`/`false` are unaffected — those stay their own literals.
- `Dextrin.decode/2`/`decode_binary/2` gained a `trusted:` opt
  (default `true`) mirroring the above on the way in: `keyword` decodes
  as a real Elixir atom by default, the same natural type `encode/2`
  now accepts. Pass `trusted: false` — per call, or once on a reused
  registry via the new `Dextrin.Registry.put_trusted/2` — for any
  source you don't fully control; only then does `keyword` fall back
  to `Dextrin.Keyword.t()`, so a `String.to_atom/1` call is never
  reachable from attacker-controlled text. `symbol` is unaffected
  either way — it stays `Dextrin.Symbol.t()` regardless of `trusted`,
  mirroring `encode/2`'s own choice to treat a bare atom as a stand-in
  for `keyword` only, never `symbol`.

### Changed

- **Breaking:** `Dextrin.Registry.new/0`'s `trusted` field — and so
  `decode/2`/`decode_binary/2`'s effective default — is `true`, not
  `false`. Any code relying on the previous behavior (`keyword`
  decoding as `Dextrin.Keyword.t()` with no opt given at all) needs
  `trusted: false` added explicitly. This is deliberate: `keyword`'s
  wrapper only ever existed to keep untrusted input from reaching
  `String.to_atom/1` unbounded; assuming a trusted source (your own
  config, your own application's data) by default matches how the
  type is documented (`DXN.md` §1.3) and how most callers actually use
  this library, at the cost of needing an explicit opt-out for
  genuinely untrusted/network input.

- **Breaking:** `Dextrin.Text.Printer`'s (and so `Dextrin.encode/2`'s
  default, non-`pretty:` output) is now maximally compact: no space
  after a map/struct entry's `:`, no space around `=>`, and entries/
  positional-struct fields are comma-joined with no trailing space
  (`%{x:1,y:2}`, `%Point{x:1,y:2}`, `%{1=>"one"}`) rather than the
  previous `%{x: 1, y: 2}`-style spacing. DXN's own grammar treats
  whitespace and commas as insignificant everywhere, so this loses no
  information and every value still round-trips identically through
  `decode/2`; only the default *rendering* got smaller. List/tuple/
  set/array element separators and `@tag value`'s space are unchanged
  (the former have nothing to gain — comma and space are both a
  single byte — and the latter's space can't be dropped in general for
  a custom tag whose value could start with an identifier character).
- **Breaking:** `Dextrin.Text.Formatter.pretty/2` now returns
  `{:ok, String.t()} | {:error, Dextrin.Error.t()}`, matching
  `Dextrin.Text.Printer.print/2`'s contract, instead of a bare
  `String.t()` that raised `ArgumentError` on an unencodable value.
  Also gained the same `indent:` opt `Dextrin.encode/2`'s new
  `pretty:`/`indent:` opts use internally (default 2 spaces per
  nesting level, previously a fixed, non-configurable 2).
- Adopted ichor's new `mix ichor.gen`/`ichor_runtime` split: the `.dxn`
  lexer/parser is now generated ahead of time into
  `lib/dextrin/text/grammar/native.ex` (checked in, regenerated via
  `mix ichor.gen` whenever `priv/grammar/dxn.aether` changes) instead
  of being produced by `use Ichor` at `dextrin`'s own compile time.
  `Dextrin.Text.Grammar` is now a thin, hand-documented wrapper around
  the generated `Grammar.Native`. This lets `mix.exs` depend on the
  small `ichor_runtime` package (the only thing the generated code
  actually calls) as an ordinary runtime dependency, while `ichor`
  proper (the Aether front-end, format importers, `Grammar.Analysis`,
  both codegen backends) moves to `only: :dev, runtime: false` — the
  bulk of Ichor no longer ships in a `dextrin` release. Both are now
  published to Hex separately (`ichor ~> 0.2.1`, `ichor_runtime ~>
  0.1.0`) and referenced as ordinary Hex dependencies — no `git:`/
  `sparse:`/`override:` needed, since `ichor`'s own `mix.exs` now
  depends on `ichor_runtime` the same way. Migrating surfaced a genuine
  gap in that split, fixed upstream: the raw-capture-node re-evaluation
  entry point needed by `Dextrin.Text.Actions` at actual decode time
  (for `@ordered %{...}`) had stayed on the top-level, dev-only `Ichor`
  module instead of moving to `ichor_runtime`; it's now
  `Ichor.Actions.evaluate_node/3`.
- Added `credo`, `dialyxir`, `sobelow`, and `excoveralls` as dev/test
  tooling, plus a `mix precommit` alias (`format`, `compile
  --warnings-as-errors`, `credo --strict`, `sobelow`, `test`,
  `dialyzer`) run before every commit. Fixed everything it surfaced:
  canonical module layout (`moduledoc`/`use`/`alias`/...) across the
  mix tasks and text pipeline modules; `Dextrin.decode/2`'s spec
  under-declared its own return type (the underlying grammar engine
  can report a list of errors, not just one) — widened to match, which
  also resolved three "dead code" warnings in the mix tasks' own error
  handling; removed a dead `Duration.microsecond || {0, 0}` fallback
  (that field is never `nil`).
- Every hand-rolled "walk a collection, thread an accumulator, halt on
  the first non-`{:ok, _}` step result" reduce across
  `Dextrin.Schema.Compiler`, `Dextrin.Schema.Validator`,
  `Dextrin.Binary.Encoder`, `Dextrin.Text.Printer`, and
  `Dextrin.Text.Actions` now uses `Ichor.Toolkit.Result.reduce_ok/3`/
  `map_ok/3` instead of a hand-rolled `Enum.reduce_while/3`.
- Documentation reworked throughout: every module's docs are now
  self-contained (no references to an external design document), and
  the normative `DXN.md` format specification moved under
  `guides/dxn/DXN.md`, alongside a full set of tutorials, examples,
  and cheatsheets for both this library and the DXN format itself.
  `DXN.md` itself gained a new normative §4, "Schema documents
  (`.dxns`)" — the `type_expr`/`refine`-constraint vocabulary,
  `%schema{}`/`%field{}` shape, named types, cross-file references, and
  enforcement semantics, written implementation-independent (this
  library's own choices stay documented separately, in
  `Dextrin.Schema`'s own module docs) — closing a gap where `.dxns`
  was documented everywhere *except* the one place meant to be
  the authoritative, cross-implementation reference for it.

### Fixed

- Struct literal parsing (`%Point{x: 1, y: 2}`) and `.dxns` schema
  compilation both depended, internally, on `keyword`/map-key text
  always decoding as `Dextrin.Keyword`/`Dextrin.Symbol` — exposed as a
  real regression the moment `trusted: true` became the default, not
  merely a test-assertion mismatch: struct literals failed to parse at
  all, and any schema whose own `.dxns` source was decoded trusted
  failed to compile. Fixed at the boundaries that actually needed it:
  `Dextrin.Text.Actions`'s struct-field-name resolution now accepts a
  bare atom the same way it already accepted `Dextrin.Keyword`
  /`Dextrin.Symbol`; `Dextrin.Schema.Compiler.compile/3` normalizes a
  decoded `.dxns` document's atoms back to `Dextrin.Keyword` once, up
  front (mirroring `Dextrin.Schema.Validated.strip/1`'s exact
  recursive-walk shape), so its own `.dxns`-vocabulary pattern
  matching needs no changes at every site; a schema's `enum` literals
  and a `:keyword`-typed field's actual data can now be either shape
  independently, compared correctly either way instead of only ever
  matching the untrusted shape. `default: nil`/`true`/`false` field
  values are deliberately *not* touched by that normalization (only
  `.dxns` syntax positions are) — and `x: :nil` as a schema field's
  *type* (the `"nil"` primitive) has its own dedicated fix, since
  `String.to_atom("nil")` and the bare literal `nil` are, once
  decoded, the exact same unrecoverable Elixir value.
- `Dextrin.Binary.Decoder`'s handling of the `time` tag (210) had no
  fallback clause — a malformed payload that wasn't an integer crashed
  with `FunctionClauseError` instead of a clean `{:error, _}`, the one
  tag missed in the earlier decoder-hardening pass. Found by the
  property-based fuzz test firing again after the `trusted:` default
  flip added more generated shapes to exercise it with.

- `Dextrin.Text.Printer`/`Dextrin.Text.Formatter` no longer produce
  unparseable text for a map entry or struct field whose
  `Dextrin.Keyword`/field name isn't a bare `identifier` (empty,
  containing spaces, ...) — `map_entry`'s colon-shorthand (`DXN.md`
  §1.2) only exists for an `identifier`; both printers now fall back
  to the arrow form (`:"name" => value`) for anything else, instead of
  emitting invalid syntax like `%{"":0}` or a bare `: 0` that failed to
  parse back at all. `Dextrin.Text.Printer.bare_identifier?/1` is now
  public so both printers share one rule.
- `Dextrin.Binary.Decoder` no longer crashes (raises) on a malformed
  `.dxnb` document that places a `tuple`/`array`/`set`/`sorted-set`
  tag around a non-array payload, a bignum/`uuid` tag around a
  non-bytes payload, a `uri`/`symbol`/`keyword` tag around non-text, a
  `char` tag around a non-codepoint or out-of-range value, a `date`
  tag around a non-integer, or a `timestamp`/`datetime` epoch outside
  the representable range — every one of these now returns a clean
  `{:error, %Dextrin.Error{}}` instead of an unhandled
  `FunctionClauseError`/`ArgumentError`/`CaseClauseError`. Found by the
  new property-based fuzz test, not a hand-picked case.
- `Dextrin.Text.Printer.print/2` no longer crashes on a value with no
  DXN representation at all (a PID, a port, a reference, a function, a
  raw Elixir tuple that isn't `Dextrin.Tuple`, ...) — a clean
  `{:error, %Dextrin.Error{}}` now, matching `encode/2`'s own typespec,
  instead of an unhandled `FunctionClauseError`.
- `@ordered %{}` (an *empty* ordered map) failed to parse at all
  (`"@ordered requires a map literal argument"`), even though `%{}` on
  its own decodes fine — the action handler required its raw capture
  tree to have a `:map_entry` key present, which a zero-entry map
  simply doesn't have (the same reason the ordinary, non-`@ordered`
  `map_lit` handler already defaults it to `[]`). Found by the new
  per-type property suite.
- `Dextrin.Binary.Decoder` now accepts `DXN.md` §2.4's CBOR string
  -reference sharing extension (tags 256/25) — previously an
  otherwise-well-formed `.dxnb` document using it (to compactly
  represent repeated `symbol`/`keyword` text or repeated struct type
  names) failed to decode at all (`"unrecognized CBOR tag 25"`), which
  violated §2.4's "a conforming decoder MUST accept it" requirement.
  `dextrin`'s own encoder still never produces tags 256/25 (that
  remains out of scope, same as before) — this is decode-side
  acceptance only, same stance as §2.5's tag 28/29 support.
- `Dextrin.encode/2`/`encode_binary/2` can now encode a registered
  application struct (`Dextrin.Registry.put_struct_module/3`) directly
  — previously, only a hand-built `Dextrin.Struct` could actually be
  serialized; a real struct registered via `put_struct_module/3` was
  recognized by automatic encode-time *validation* but had no path to
  actually being written out, forcing callers to reconstruct a
  `Dextrin.Struct` from the real struct's own fields by hand before
  encoding. `Dextrin.Text.Printer`/`Dextrin.Binary.Encoder` now rebuild
  the equivalent `Dextrin.Struct` automatically, in the compiled
  schema's own canonical field order.
