# Contributing to Dextrin

Thanks for considering a contribution. This document covers what you
need to know before opening an issue or a pull request.

## Getting started

```sh
git clone <this repository>
cd dextrin
mix deps.get
mix test
```

That should complete with no failures on a clean checkout. If it
doesn't, please open an issue before doing anything else — that's a
bug in its own right.

## Project layout

- `lib/dextrin.ex` — the public API (`decode/2`, `encode/2`,
  `decode_binary/2`, `encode_binary/2`).
- `lib/dextrin/value/` — the small wrapper structs for DXN types
  Elixir has nothing native for (`Symbol`, `Tuple`, `OrderedMap`, ...).
- `lib/dextrin/text/` — the `.dxn` pipeline: `Grammar` (a thin,
  hand-maintained wrapper around `Grammar.Native`, the actual compiled
  lexer/parser — generated ahead of time from `priv/grammar/dxn.aether`
  by `mix ichor.gen`, not produced by `use Ichor` at `dextrin`'s own
  compile time; see "Changing the grammar" below), `Actions` (the
  `Ichor.Actions` implementation), `Printer`/`Formatter` (the reverse
  direction), `Escapes` (shared string/char escape decoding).
- `lib/dextrin/binary/` — the `.dxnb` pipeline: `Encoder`/`Decoder`
  (a direct, hand-rolled CBOR codec) and `Tags` (private tag/bit-layout
  constants).
- `lib/dextrin/schema.ex` + `lib/dextrin/schema/` — `.dxns` schema
  compilation and validation.
- `lib/dextrin/registry.ex` — the shared struct/custom-tag extension
  point.
- `lib/dextrin/unicode/range_generator.ex` — the pure text-processing
  core behind `mix dextrin.gen.unicode`.
- `lib/mix/tasks/dextrin/` — the `mix dextrin.*` task implementations.
- `priv/grammar/dxn.aether` — the hand-authored Aether grammar
  `.dxn` parsing is built on.
- `priv/schema/std.dxns` — `Dextrin.Schema.Std`'s source.
- `priv/unicode/` — the checked-in Unicode Character Database data
  `mix dextrin.gen.unicode` reads and updates.
- `test/` — one directory per concern (`text/`, `binary/`, `schema/`,
  `unicode/`), plus `test/conformance/` for shared, cross-pipeline
  fixtures and `test/support/` for test-only fixtures (e.g. a `Money`
  struct used by schema tests).
- `guides/` — the documentation under `guides/`, published via ExDoc
  alongside the generated module docs.

## Making a change

1. **Tests first, or at least alongside.** A grammar- or codec-level
   change should come with a test exercising actual input/output
   behavior, not just "does this parse." Several real bugs in this
   codebase's own history (the CBOR major-7 float header, the
   `MAP_KEY`/`AT_DISCARD` lexer hazards) only showed up once a value
   was hand-verified against a standards-conformant reference, not
   merely round-tripped through this library's own (sometimes equally
   wrong) code on both ends.
2. **Round-trip both directions, where it applies.** A change to the
   shared value representation (`Dextrin.Value`) or a wrapper struct
   should be checked against both `.dxn` and `.dxnb` — `decode(encode(v))
   == v` in each pipeline independently, plus cross-format equivalence
   where a schema makes that meaningful (see
   `test/conformance/worked_example_test.exs`).
3. **Run the full verification pass before opening a PR:**

   ```sh
   mix precommit
   ```

   Expands to `mix format`, `mix compile --warnings-as-errors`,
   `mix credo --strict`, `mix sobelow`, `mix test`, and
   `mix dialyzer`, in that order — fast/cheap checks first, dialyzer
   (slowest, especially its first PLT build) last. Run `mix docs`
   separately if you touched any documentation (moduledocs or the
   files under `guides/`) to confirm it still builds cleanly.

4. **Match the existing documentation style.** Default to no comments;
   when one is warranted, explain a non-obvious *why* (a hidden
   constraint, a subtle invariant, the specific bug class it prevents),
   not what the code already makes obvious by being well-named.
   Moduledocs should be self-contained — don't cite an external design
   document, since none exists in this repository; document the
   library as it actually is.

## Changing the grammar (`priv/grammar/dxn.aether`)

`lib/dextrin/text/grammar/native.ex` — the actual compiled lexer/parser
— is generated, checked-in source, not produced at `dextrin`'s own
build time. **Editing `priv/grammar/dxn.aether` has no effect until you
regenerate it:**

```sh
mix ichor.gen priv/grammar/dxn.aether \
  --module Dextrin.Text.Grammar.Native \
  --actions Dextrin.Text.Actions \
  --out lib/dextrin/text/grammar/native.ex
```

This requires the `ichor` dependency itself (the Aether front-end,
analysis, and codegen backends — `only: :dev, runtime: false` in
`mix.exs`, since nothing that ships needs it); `ichor_runtime` alone,
which the generated file actually calls at runtime, can't run this
task. There's no automatic staleness check between the checked-in file
and the grammar it came from — regenerating and reviewing the diff is
a manual step, same as `mix dextrin.gen.unicode`.

The grammar has a few deliberate, documented hazards (see the inline
comments around `MAP_KEY`, `AT_DISCARD`, and the `@dxn` header token)
that exist specifically to keep Aether's maximal-munch tokenization
from silently producing the wrong token at a few ambiguous-looking
positions. If you're touching the grammar:

- Re-run `mix ichor.tokens priv/grammar/dxn.aether` and check the
  token declaration order still matches what the comments describe.
- Add a regression test under `test/text/grammar_hazards_test.exs` if
  your change touches lexing near any of those positions.
- `priv/grammar/dxn.aether`'s generated Unicode identifier ranges
  (between the `BEGIN`/`END GENERATED UNICODE RANGES` markers) are
  machine-generated by `mix dextrin.gen.unicode` — never hand-edit
  them; regenerate instead. Regenerating those ranges still requires
  the `mix ichor.gen` step above afterward, same as any other grammar
  change.

## Reporting bugs

Please include: the input (`.dxn`/`.dxnb`/`.dxns` source, or a minimal
excerpt reproducing the issue), what you expected, and what actually
happened (including the full `Dextrin.Error`, if one was returned).
"Doesn't parse" and "doesn't work" are much harder to act on than a
specific input/expected/actual triple.

## License

By contributing, you agree that your contributions will be licensed
under the project's [MIT license](LICENSE).
