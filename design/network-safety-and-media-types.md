# Network safety and media types in Dextrin

Status: implemented, unreleased (0.3.0). Proposal from the ASCO workspace,
2026-10-19. Option A was taken for point 1 (untrusted by default, 1ee60d7);
point 2 is `Dextrin.Format` and DXN.md §6, with the text rule Jan set on
2026-10-20 (a first significant `%`; lists and scalars stay unrecognised);
point 3 is the compile guard and `compile_all/2` (8fb723a).
Target: Dextrin 0.3.0 (Elixir), with matching notes for node-/php-dextrin.

## Why

ASCO has a library `asco_dxn` that exists only because Dextrin leaves two
things to every caller:

1. **Trust.** `Dextrin.decode/2` and `decode_binary/2` default to
   `trusted: true`, which decodes every DXN `keyword` into a real atom.
   For network input that is an atom-table exhaustion vector. `asco_dxn`
   wraps both decoders so that they always pass `trusted: false`.
2. **Wire-form knowledge.** The media types, file extensions, mapping from
   content type to form and cheap body sniffing are in `asco_dxn`, not in
   Dextrin, although they follow from the DXN spec.

The JSON counterparts (`asco_*_json`) call Jason directly, because Jason is
safe by default (`keys: :atoms` is opt-in). ASCO wants its DXN transports to
call Dextrin directly in the same way and to retire `asco_dxn`. That only
works if Dextrin itself provides the two points above.

## Proposal

### 1. Safe decoding for untrusted input

Choose one option (A is the recommendation):

- **A. Flip the default (breaking).** `trusted: false` becomes the default
  for `decode/2`, `decode_binary/2` and `Dextrin.Document`. Trusted
  decoding becomes opt-in with `trusted: true` or
  `Registry.put_trusted(r, true)`. This is analogous to Jason's
  `keys: :atoms`. Schema compilation keeps its own trusted parsing of schema
  definition syntax (compiler.ex already separates the two).
- **B. Separate entry points (additive).** `Dextrin.decode_untrusted/2` and
  `decode_binary_untrusted/2` always force `trusted: false` and do not
  accept the option, so a caller cannot weaken them.

With either option:

- Document the atom risk at the top of the README and the moduledoc,
  next to the decode functions, the way Jason documents `keys: :atoms`.
- Treat `Dextrin.Symbol`'s behaviour separately. It stays the same
  regardless of `trusted`, as today.

### 2. Media types, extensions, form detection

A small module, for example `Dextrin.Format` or `Dextrin.MediaType`, whose
behaviour is specified in DXN.md so the ports implement it identically:

| Function | Behaviour (as in `ASCO.DXN` today) |
| --- | --- |
| `media_type(form)` | `:text` → `application/vnd.dxn`, `:binary` → `application/vnd.dxnb`, `:schema` → `application/vnd.dxns` |
| `extension(form)` | `.dxn` / `.dxnb` / `.dxns` |
| `form(media_type)` | the three exact types, plus any structured `+dxn` suffix (`application/vnd.acme.event+dxn`) → `{:ok, :text}`. No `+dxnb` suffix on purpose. Anything else → `:error`. The caller strips parameters (`; charset=…`). |
| `identifies?(body, form)` | a cheap prefix test, not a parse: binary = envelope magic `"DX"` + version byte (DXN.md §2.1); text/schema = after leading whitespace, starts with a legal top-level opener. Today that is `%{` or `%(`. **Check this against the 0.2.0 syntax:** do `%schema{…}`, `%Name{…}` struct literals or a leading comment count?) |

Proposed additions to DXN.md: a short "Media types" section (and possibly
an IANA-style registration template for later), plus the identification
rule as a normative MAY.

`mix dextrin.validate` already detects the format from the extension and
could then use `Dextrin.Format`.

### 3. Optional: schema validation convenience

`ASCO.DXN.Schema` (`compile/1`, `compile_all/1`, `compiled?/1`,
`validate/3`) is a thin layer over `Dextrin.Schema` and `Dextrin.Registry`.
Its extra logic is:

- `compile/1` rejects documents whose top level is not a plain map. A
  `Dextrin.Struct` or `Dextrin.Tuple` would pass `Schema.compile/3`'s
  `is_map/1` guard. **That is probably a bug in Dextrin itself** and
  belongs there.
- `compile_all/1` compiles several `.dxns` documents into one registry.

If Dextrin offers both (a guard fix plus a `compile_all`-like function),
ASCO no longer needs the layer at all.

## Effect on ASCO once released

Revised 2026-10-19: ASCO **keeps** `asco_dxn` as its single DXN gateway,
alongside a new `asco_json`. Both translate ASCO's neutral schema
definitions (a new `asco_schemas`) into DXNS or JSON Schema and register
them. The Dextrin changes above are still wanted, independent of that:

- `asco_dxn` replaces its own media-type and sniffing code with
  `Dextrin.Format`. It keeps forcing untrusted decoding, which is then the
  Dextrin default (A) or `decode_untrusted` (B).
- The schema-guard fix and `compile_all` replace `ASCO.DXN.Schema`'s
  workarounds.

Until then `asco_dxn` keeps passing `trusted: false` itself.

## Ports

- node-dextrin / php-dextrin: no atom problem, but the same
  `Format`/`MediaType` API and the same `identifies?` rule apply, so all
  three ports sniff the same way.
