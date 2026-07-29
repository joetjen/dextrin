# Dextrin

[![Hex.pm](https://img.shields.io/hexpm/v/dextrin.svg)](https://hex.pm/packages/dextrin)
[![Documentation](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/dextrin)

Dextrin is an Elixir implementation of DXN (Data eXchange Notation): a
human-writable text format (`.dxn`), a compact binary format (`.dxnb`)
built on CBOR, and a schema format (`.dxns`) that's just more DXN data
— all three sharing one in-memory value representation and one
extension mechanism.

```elixir
{:ok, value} = Dextrin.decode(~s(%{x: 1, y: 2}))
Dextrin.encode(value)
#=> {:ok, "%{x: 1, y: 2}"}

{:ok, bytes} = Dextrin.encode_binary(value)
Dextrin.decode_binary(bytes)
#=> {:ok, %{%Dextrin.Keyword{name: "x"} => 1, %Dextrin.Keyword{name: "y"} => 2}}
```

A plain map's shorthand keys (`x:`) are themselves DXN `keyword`s, not bare
strings — `%{x: 1}` and `%{:x => 1}` are the exact same value. A
schema-backed `struct`'s fields are the one place names *do* come back
as plain strings — see the [tutorial](guides/TUTORIAL.md) — since a
schema always knows its field names up front.

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

## Why

Most serialization formats pick one point on a spectrum: JSON is
human-writable but loses precision (no distinct int/float boundary,
no dates, no bytes) and has no extension story; Protobuf/Avro are
compact and typed but need a separate schema-compiler step and aren't
meant for a human to read or hand-edit; EDN is expressive and
Elixir-friendly in spirit but has no first-party Elixir implementation
and no binary counterpart. DXN's premise is that a `.dxn` text
document and a `.dxnb` binary document should be the *same* value
space — 24 scalar/collection/temporal/extended types, precise enough
for money (`Decimal`), exact ratios (`Rational`), and arbitrary
precision integers, with `struct` and `custom-tag` as first-class,
schema-describable extension points — encoded however density or
readability happens to matter for a given use.

## Components

- **`Dextrin`** — the four-function public API: `decode/2`, `encode/2`
  (`.dxn` text) and `decode_binary/2`, `encode_binary/2` (`.dxnb`
  binary). One error type, `Dextrin.Error`, for both.
- **Value types** (`Dextrin.Symbol`, `Dextrin.Keyword`, `Dextrin.Tuple`,
  `Dextrin.OrderedMap`, `Dextrin.SortedSet`, `Dextrin.Struct`,
  `Dextrin.Array`, `Dextrin.Duration`, `Dextrin.Rational`,
  `Dextrin.Uuid`, `Dextrin.Uri`, `Dextrin.Bytes`, `Dextrin.Char`,
  `Dextrin.CustomTag`) — small wrapper structs for the DXN types
  Elixir has nothing native for without losing information. Everything
  else (integers, floats, strings, lists, plain maps, sets, dates,
  regexes, ...) decodes to the obvious native Elixir value.
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
  `Namespace/Name` references across separate `.dxns` files.
- **`Dextrin.Registry`** — the one extension point both `struct` and
  `custom-tag` share: register a tag decoder/encoder, a struct
  materializer, or a lazy schema resolver. Plain immutable data,
  threaded explicitly — never a process or ETS table.
- **`mix dextrin.*`** — `validate`, `encode`, `decode`, `format`,
  `gen.schema` (scaffold a `.dxns` file from an existing Elixir
  struct), and `gen.unicode` (regenerate the grammar's Unicode
  identifier ranges from the latest UCD data).

## Installation

Add `dextrin` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:dextrin, "~> 0.1.0"}
  ]
end
```

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

`ichor` and `ichor_runtime` aren't published to Hex separately yet —
`mix.exs` references both via `git:` (the `feature/runtime` branch of
[`ichor`](https://github.com/joetjen/ichor), `ichor_runtime` via
`sparse: "packages/ichor_runtime"`), so nothing extra needs to be
checked out locally:

```sh
mix deps.get
mix test
mix format --check-formatted
mix compile --warnings-as-errors
mix docs
```

`priv/grammar/dxn.aether`'s generated Unicode identifier ranges are
regenerated with `mix dextrin.gen.unicode` — a deliberate, reviewed
action on a Unicode version bump, never run automatically at build
time (see that task's own docs). Either way, changing the grammar
itself requires a `mix ichor.gen` step afterward — see
[CONTRIBUTION.md](CONTRIBUTION.md).

See [CONTRIBUTION.md](CONTRIBUTION.md) for how to propose changes, and
[CHANGELOG.md](CHANGELOG.md) for release history.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
