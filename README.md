# Dextrin

> [!WARNING]
> **Under heavy development: not for production use before `1.0.0`.**
> Things can and will break, and the specification can and will change,
> between any two releases until `1.0.0`. Do not use this library in a
> production system yet.

[![CI](https://github.com/joetjen/dextrin/actions/workflows/ci.yml/badge.svg)](https://github.com/joetjen/dextrin/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/dextrin.svg)](https://hex.pm/packages/dextrin)
[![Documentation](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/dextrin)
[![Docs (main)](https://img.shields.io/badge/docs-main-blue.svg)](https://joetjen.github.io/dextrin/)

Dextrin is an Elixir implementation of DXN (Data eXchange Notation): a
human-writable text format (`.dxn`), a compact binary format (`.dxnb`)
built on CBOR, and a schema format (`.dxns`) that's just more DXN data
— all three sharing one in-memory value representation and one
extension mechanism.

This is the reference implementation. [`node-dextrin`](https://github.com/joetjen/node-dextrin)
(Node.js, on npm) and [`php-dextrin`](https://github.com/joetjen/php-dextrin)
(PHP, on Packagist) are sibling ports of the same format — see
[Other language implementations](#other-language-implementations)
below.

```elixir
{:ok, value} = Dextrin.decode(~s(%{x: 1, y: 2}), trusted: true)
value
#=> %{x: 1, y: 2}

Dextrin.encode(value)
#=> {:ok, "%{x:1,y:2}"}

{:ok, bytes} = Dextrin.encode_binary(value)
Dextrin.decode_binary(bytes, trusted: true)
#=> {:ok, %{x: 1, y: 2}}
```

**Decoding is safe by default.** A plain map's shorthand keys (`x:`) are
themselves DXN `keyword`s — `%{x: 1}` and `%{:x => 1}` are the exact same
value — and a keyword decodes as `Dextrin.Keyword.t()`, never an atom, so
no input can exhaust the atom table:

```elixir
Dextrin.decode(~s(%{x: 1, y: 2}))
#=> {:ok, %{%Dextrin.Keyword{name: "x"} => 1, %Dextrin.Keyword{name: "y"} => 2}}
```

**Pass `trusted: true` for a source you control** — your own config, your
own application's data — and a keyword decodes as a real atom, its own
Elixir type per `DXN.md` §1.3, as in the first example. Like Jason's
`keys: :atoms`, it is opt-in; never pass it for network input. Encoding
takes a bare atom anywhere a `keyword` is expected either way —
`%{x: 1}` or `Dextrin.encode(:ok)` need no conversion first.

A schema-backed `struct`'s fields are the one place names *do* come back
as plain strings regardless of `trusted:` — see the
[tutorial](guides/TUTORIAL.md) — since a schema always knows its field
names up front.

`.dxn`'s text grammar is compiled by [Ichor](https://github.com/joetjen/ichor)
— write the grammar once (`priv/grammar/dxn.aether`), get a lexer,
parser, and (via `Dextrin.Text.Actions`) an evaluator with no
hand-written parsing code. That compilation happens ahead of time
(`mix ichor.gen`, checked in as generated source), not at
`dextrin`'s own build time, so only the small `ichor_runtime` support
library the generated code actually calls ships as a real dependency —
`ichor` proper (the Aether front-end, analysis, codegen) is dev-tooling
only. `.dxnb` has no grammar to speak of — it's a direct, hand-rolled
CBOR codec — so it's plain recursive Elixir working over the same
shared value type.

## Why use Dextrin?

Most serialization formats pick one point on a spectrum. JSON is
human-writable but has no dates, no bytes, no exact decimals and no
boundary between an integer and a float. Protobuf and Avro are compact
and typed but need a schema compiled ahead of time, and aren't meant for
a person to read or edit. CBOR and MessagePack are compact and
self-describing but binary only. YAML and TOML are made for people, and
have no binary form for machines.

DXN's premise is that a `.dxn` text document and a `.dxnb` binary
document are the *same* value space: 30 scalar, collection, temporal and
extended types ([reference](guides/dxn/DXN.md) §1.3). It is precise
enough for money (decimals), exact ratios (rationals) and integers of
any size, has `struct` and `custom-tag` as first-class, schema-describable
extension points, and its schemas (`.dxns`) are DXN too. You choose text
or binary by what matters where the data is going -- a person reading
it, or bytes on the wire -- and the value is the same either way.

### What each format can say

| | DXN | JSON | YAML | TOML | BSON | MessagePack | CBOR | Protobuf | Ion |
|---|---|---|---|---|---|---|---|---|---|
| Text a person writes | ✓ | ✓ | ✓ | ✓ | – | – | –¹ | –² | ✓ |
| Binary, same values | ✓ | – | – | – | ✓ | ✓ | ✓ | ✓ | ✓ |
| Comments | ✓ | – | ✓ | ✓ | – | – | – | – | ✓ |
| Schema, part of the format | ✓ | ~³ | – | – | – | – | – | –² | ~³ |
| Readable without a schema | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | – | ✓ |
| Integer and float kept apart | ✓ | – | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Integers beyond 64 bits | ✓ | ~⁴ | ~⁴ | – | – | – | ✓ | – | ✓ |
| Exact decimals | ✓ | – | – | – | ✓ | – | ✓ | – | ✓ |
| Exact ratios | ✓ | – | – | – | – | – | ✓ | – | – |
| Timestamps, dates, times, durations | ✓ | – | ~⁵ | ~⁶ | ~⁷ | ~⁷ | ~¹³ | ~⁸ | ~¹⁴ |
| Bytes | ✓ | – | ~⁵ | – | ✓ | ✓ | ✓ | ✓ | ✓ |
| UUIDs, URIs | ✓ | – | – | – | ~⁹ | – | ✓ | – | – |
| Sets, tuples | ✓ | – | ~⁵ | – | – | – | ~¹⁰ | – | – |
| Map keys that are not strings | ✓ | – | ✓ | – | – | ✓ | ✓ | ~¹¹ | – |
| Typed records (structs) | ✓ | – | – | – | – | – | – | ✓ | – |
| Types an application adds | ✓ | – | ✓ | – | – | ✓ | ✓ | – | ✓ |
| Versioned schemas, checked in CI | ✓ | – | – | – | – | – | – | ~¹² | – |

¹ CBOR has a diagnostic notation for reading, not for authoring.
² Protobuf's text format is for debugging; its schema is a separate
`.proto` file compiled ahead of time.
³ JSON Schema and Ion Schema are written in JSON and Ion, as separate
specifications.
⁴ The grammar allows any size; JavaScript's and PHP's parsers lose the
digits past 53 and 64 bits.
⁵ YAML 1.1 tags (`!!timestamp`, `!!binary`, `!!set`), dropped from 1.2's
core schema.
⁶ Dates, times and date-times; no durations.
⁷ An instant only: no local dates, times or durations.
⁸ The well-known `Timestamp` and `Duration` messages.
⁹ A UUID as binary subtype 4.
¹⁰ Sets by registered tag 258; no tuples.
¹¹ Integer and string keys only.
¹² Field numbers keep old readers working; nothing checks a change.
¹³ Instants (tags 0 and 1) and dates (RFC 8943); no times of day or
durations.
¹⁴ Timestamps of any precision, dates included; no times of day or
durations.

### How big it is

The same four payloads in each format, in bytes, raw and gzipped.
Reproduce it with `mix run bench/format_sizes.exs`; the script says how
each format writes the values it has no type for (a decimal or a date
as a string in JSON, for instance).

| | config file | API response, 100 records | time series, 1,000 points | record with a 4 KiB blob |
|---|---:|---:|---:|---:|
| DXN text | 279 / 199 | 19,402 / 4,218 | 63,159 / 13,895 | 5,516 / 4,222 |
| DXN text, pretty | 314 / 216 | 23,504 / 4,249 | 67,161 / 13,961 | 5,527 / 4,234 |
| `.dxnb` | 270 / 214 | 14,385 / 3,802 | 36,006 / 14,463 | 4,145 / 4,168 |
| `.dxnb`, shared | 270 / 214 | 9,417 / 3,749 | 29,017 / 14,035 | 4,145 / 4,168 |
| JSON | 306 / 207 | 19,202 / 4,201 | 56,159 / 13,692 | 5,514 / 4,216 |
| JSON, pretty | 403 / 229 | 26,253 / 4,287 | 74,160 / 14,182 | 5,527 / 4,231 |
| BSON | 312 / 231 | 17,621 / 4,448 | 36,903 / 15,700 | 4,161 / 4,184 |
| MessagePack | 237 / 199 | 12,271 / 3,840 | 25,003 / 11,165 | 4,136 / 4,159 |
| CBOR | 237 / 188 | 12,282 / 3,514 | 25,003 / 11,164 | 4,136 / 4,159 |
| Protocol Buffers | 141 / 111 | 8,552 / 3,702 | 19,000 / 10,832 | 4,122 / 4,145 |

- **DXN text is about JSON's size** -- keys need no quotes -- while
  carrying the types JSON drops. Data full of dates and times is the
  exception, about an eighth larger: each datetime names its type
  (`@datetime "..."`) where JSON writes a bare string.
- **`.dxnb` sits between JSON and the compact binaries.** Value sharing
  (`encode_binary(value, share: true)`) writes a repeated key or string
  once; on the API response that brings it within about 10% of Protocol
  Buffers, with no schema needed to read it.
- **Where it is larger, it is carrying more.** A `.dxnb` datetime keeps
  nanoseconds, its offset and its type, where CBOR's and MessagePack's
  carry whole seconds; a keyword key is tagged as a keyword rather than written as a
  plain string. Protocol Buffers is smallest because its schema, not the
  data, holds the field names.
- **Compressed, the gap narrows.** Gzipped, DXN text stays within about
  12% of `.dxnb`, and JSON within about a quarter of CBOR; past that,
  the choice is about what each format can say.

### What comes back, in each language

What a value is after a round trip through each language's own JSON
parser, and through Dextrin:

| Written | Elixir: JSON / Dextrin | Node.js: JSON / Dextrin | PHP: JSON / Dextrin | Praxis: JSON / Dextrin |
|---|---|---|---|---|
| `9223372036854775808` | integer / integer | **9223372036854776000** / `BigInt` | **float** / `DXNInteger` | integer / integer |
| `19.99` as an exact decimal | **float** / `Decimal` | **float** / `DXNDecimal` | **float** / `DXNDecimal` | **float** / `dextrin.decimal` |
| `1.0` | float / float | **1, an integer** / float | float, **written back as `1`** / float | float / float |
| a datetime | **string** / `DateTime` | **string** / `DXNDateTime` | **string** / `DXNDateTime` | **string** / a `praxis.time` instant |
| bytes | **base64 string** / `Dextrin.Bytes` | **base64 string** / `DXNBytes` | **base64 string** / `DXNBytes` | **base64 string** / `dextrin.bytes` |
| a map keyed by integers | **string keys** / integer keys | **string keys** / integer keys | **string keys** / integer keys | **string keys** / integer keys |
| a set | **list** / `MapSet` | **array** / `Set` | **array** / `DXNSet` | **vector** / set |

A bold entry is a value that did not come back as what was written. With
Dextrin, the same document means the same thing in all four, and every
implementation is held to that by the
[Dextrin Conformance Suite](https://github.com/joetjen/praxis/tree/develop/libs_prx/dextrin_conformance).

## Components

- **`Dextrin`** — the four-function public API: `decode/2`, `encode/2`
  (`.dxn` text) and `decode_binary/2`, `encode_binary/2` (`.dxnb`
  binary). One error type, `Dextrin.Error`, for both.
- **Value types** (`Dextrin.Symbol`, `Dextrin.Tuple`,
  `Dextrin.OrderedMap`, `Dextrin.SortedSet`, `Dextrin.Struct`,
  `Dextrin.Array`, `Dextrin.Duration`, `Dextrin.Rational`,
  `Dextrin.Uuid`, `Dextrin.Uri`, `Dextrin.Bytes`, `Dextrin.Char`,
  `Dextrin.CustomTag`) — small wrapper structs for the DXN types
  Elixir has nothing native for without losing information. `keyword`
  is the one exception with two faces: `Dextrin.Keyword` by default,
  a real atom when the input is trusted (`trusted: true`). Every
  other scalar/collection (integers, floats, strings, lists, plain
  maps, sets, dates, regexes, ...) decodes to the obvious native
  Elixir value.
- **`Dextrin.Text.Grammar`/`Actions`/`Printer`/`Formatter`** — the
  `.dxn` pipeline: an Ichor-compiled grammar (`Grammar` is a thin
  wrapper around the pregenerated `Grammar.Native`), an `Ichor.Actions`
  implementation that turns a parse into real values, a single-line
  printer (the reverse direction), and a multi-line pretty-formatter
  on top of it.
- **`Dextrin.Binary.Encoder`/`Decoder`/`Tags`** — the `.dxnb` pipeline:
  a direct recursive CBOR codec (not built on a generic CBOR library —
  see `Dextrin.Binary.Encoder`'s own moduledoc for why) plus the
  private tag block and bit-layout constants it needs.
- **`Dextrin.Schema`** and `Dextrin.Schema.*` — compiles a `.dxns`
  document (itself just DXN data — no new grammar) into a
  `Dextrin.Registry`, enforced automatically, decode- and encode-side,
  wherever a registered struct name appears. `Dextrin.Schema.Std` ships
  a small standard library of common named types (`PositiveInteger`,
  `NonEmptyString`, ...); `Dextrin.Schema.FileResolver` resolves
  `Namespace/Name` references across separate `.dxns` files;
  `Dextrin.Schema.Provider` lets a struct's *own* library ship its DXN
  schema without that library ever depending on `dextrin` itself.
- **`Dextrin.Registry`** — the one extension point both `struct` and
  `custom-tag` share: register a tag decoder/encoder, a struct
  materializer, or a lazy schema resolver; also carries the
  `trusted:`/`put_trusted/2` flag that decides how `keyword` decodes.
  Plain immutable data, threaded explicitly — never a process or ETS
  table.
- **`mix dextrin.*`** — `validate`, `encode`, `decode`, `format`,
  `compat` (the schema version discipline check, for CI), `gen.schema` (scaffold a `.dxns` file from an existing Elixir
  struct), and `gen.unicode` (regenerate the grammar's Unicode
  identifier ranges from the latest UCD data).

## Installation

Add `dextrin` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:dextrin, "~> 0.2.0"}
  ]
end
```

## Other language implementations

DXN's format spec (`guides/dxn/DXN.md`) is implementation-independent
— this library, `node-dextrin`, and `php-dextrin` all satisfy the same
document, and stay close to this project's own in-memory shape-per-type
choices wherever their host language allows, so recognizing one
implementation gets you most of the way to recognizing the others.

| Language | Package | Source |
| --- | --- | --- |
| Elixir (this project) | [`dextrin` on Hex.pm](https://hex.pm/packages/dextrin) | [joetjen/dextrin](https://github.com/joetjen/dextrin) |
| Node.js | [`@joetjen/dextrin` on npm](https://www.npmjs.com/package/@joetjen/dextrin) | [joetjen/node-dextrin](https://github.com/joetjen/node-dextrin) |
| PHP | [`joetjen/dextrin` on Packagist](https://packagist.org/packages/joetjen/dextrin) | [joetjen/php-dextrin](https://github.com/joetjen/php-dextrin) |

## Where to go next

- **[Tutorial](guides/TUTORIAL.md)** — a step-by-step walkthrough of
  this library's features, building up to a small, working example
  that decodes, validates against a schema, and re-encodes real data.
- **[Examples](guides/EXAMPLES.md)** — worked examples: config files,
  API payloads, event logs, and schema-validated records.
- **[Cheatsheet](guides/CHEATSHEET.md)** — quick reference for common
  `Dextrin` tasks.
- **[DXN tutorial](guides/dxn/TUTORIAL.md)** and
  **[DXN reference](guides/dxn/DXN.md)** — everything about the DXN
  *format itself*, independent of this Elixir implementation, plus
  **[DXN examples](guides/dxn/DXN_EXAMPLES.md)** and a
  **[DXN cheatsheet](guides/dxn/DXN_CHEATSHEET.md)**.

## Development

```sh
mix deps.get
mix precommit
```

`mix precommit` runs the full verification pass this project expects
before a commit: `mix format`, `mix compile --warnings-as-errors`,
`mix credo --strict`, `mix sobelow`, `mix test`, and `mix dialyzer`, in
that order (fast/cheap checks first, dialyzer — the slowest, especially
its first PLT build — last).

`priv/grammar/dxn.aether`'s generated Unicode identifier ranges are
regenerated with `mix dextrin.gen.unicode` — a deliberate, reviewed
action on a Unicode version bump, never run automatically at build
time (see that task's own docs). Either way, changing the grammar
itself requires a `mix ichor.gen` step afterward, since
`lib/dextrin/text/grammar/native.ex` is generated ahead of time, not
produced at `dextrin`'s own compile time (that's also what keeps
`ichor` itself, and everything it depends on for parsing/codegen,
`only: :dev, runtime: false` — only the small `ichor_runtime` package
ships in a release) — see [CONTRIBUTING.md](CONTRIBUTING.md).

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to propose changes, and
[CHANGELOG.md](CHANGELOG.md) for release history.

## License

Apache-2.0 — see [LICENSE](LICENSE).
