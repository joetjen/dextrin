# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Dextrin.Schema.Provider`, a behaviour letting a struct's own library
  ship a DXN schema for it without that library ever depending on
  `dextrin` — the schema, the target struct module, and an optional
  materializer are declared on a small, separately-compiled companion
  module (meant to be guarded behind an `optional: true` dependency),
  and `Dextrin.Schema.register_provider/2` compiles and wires it into
  a `Dextrin.Registry` in one call from the consuming application.

### Fixed

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

### Changed

- `ichor` is now a Hex dependency (`~> 0.1.1`) instead of a sibling
  path dependency, now that it's published.
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

## [0.1.0] - 2026-07-28

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
