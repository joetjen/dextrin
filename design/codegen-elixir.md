# Elixir code from DXNS (T684)

Status: first round built 2026-11-18 (`Dextrin.Codegen.Elixir`,
`mix dextrin.gen.elixir`); see "What the first round does" at the end.

Jan's inputs (T673, 2026-11-17):
- "generate/update the source code ... static functions to validate
  data ... (static, optimized code ..., not dynamically loading the
  schema definition)";
- "an update should keep hand-written parts";
- the generated reader and validator "should of course automatically
  support all known versions of the schema": a validator per version, a
  reader that dispatches on the version written, and a generated chain of
  upgrades to the latest, with hand-written parts where a change can't
  be upgraded mechanically;
- deprecation (G10): only the deprecated version's functions are marked.

T690 (asco_schemas) is the first user: TypeSpec -> DXNS (T682) -> Elixir
modules, regenerated whenever the TypeSpec changes.

## What it writes

For `mix dextrin.gen.elixir schemas/ --prefix AscoSchemas --out lib/`:

| DXNS | Elixir |
|---|---|
| `acme.shop/Order`, a `%schema` | `AscoSchemas.Acme.Shop.Order`: `defstruct` of the latest version's fields, `@type t`, `@enforce_keys` for the required ones |
| each version N of it | `validate_v(N, value)` and `read_v(N, fields)`: pure functions, one clause per field, every constraint inlined |
| the versions together | `read/1`: a decoded struct of any known version, dispatched on its version, upgraded step by step to `t()`; `validate/1`, `to_dxn/1` |
| a `%shape` | a module with `@type t :: %{...}` and `validate/1`; no struct (a shape is a map) |
| a named type | a private `valid_<name>?/1` in each module that uses it, and a public one in `AscoSchemas.Types` |
| `{:refine ...}` | guards and inline checks; a regex is compiled once, at compile time (`~r//` in a module attribute) |
| `format:` | a call to `Dextrin.Format.valid?/2`, the one runtime helper: a function, not a schema |
| `%type(N)`, pins | each pinned version has its own `valid_<name>_v<n>?/1` |
| `deprecated:` on a version | `@deprecated` on that version's `read_v/2`, `validate_v/2` and upgrade step; Dextrin's runtime warning (G10) when it is read |

Nothing loads a `.dxns` file or a `Dextrin.Registry` at run time. The
generated code depends on `dextrin` only for its value types
(`Dextrin.Keyword`, `Dextrin.Struct`, ...) and `Dextrin.Format`.

## Versions and upgrades

Between consecutive versions the generator compares the fields:

| Change | Upgrade step |
|---|---|
| an optional field added | generated: absent, or its default |
| a field removed | generated: dropped (kept in the struct's extras) |
| a field made optional | generated: nothing to do |
| a field renamed (TypeSpec `@renamedFrom`, kept in `meta`) | generated: moved |
| a type changed, a field made required, a required field added | **hand-written**: a callback the generated code calls, `upgrade_v1(fields)` |

A missing callback is a compile error naming the version and the fields,
so a new version can't ship half-upgraded.

## Hand-written parts

Two files per schema, never one file edited by both:

- `order.ex` -- **the user's**. Written once, as a stub that
  `use`s the generated module; never overwritten. Hand-written upgrade
  callbacks and any functions of the user's own live here.
- `order.gen.ex` -- **the generator's**. Rewritten on every run, a
  header saying so; `mix dextrin.gen.elixir --check` fails CI when it is
  out of date with the schemas.

Regenerating therefore never touches what was written by hand, and a
schema change that needs a new callback shows up as a compile error in the
user's module, not as lost code.

## Questions for Jan

1. **Two files per schema** (the user's stub, written once, and the
   generated file, rewritten), rather than marked regions inside one file?
   Recommended: two files -- no merging, nothing lost.
2. **Module names**: the DXNS namespace and name as an Elixir module under a
   `--prefix` (`AscoSchemas.Acme.Shop.Order`)? Recommended: yes.
3. **Decode integration**: the generated module also registers itself, so
   `Dextrin.decode(text, registry: AscoSchemas.registry())` answers its
   structs directly? Recommended: yes, through a generated
   `AscoSchemas.registry/0` built from the generated functions -- still no
   schema loaded at run time.
4. **Renames**: T682 writes TypeSpec's `@renamedFrom` into `meta`
   (`renamed-from`) so the upgrade step can move the field, rather than
   asking for a hand-written callback? Recommended: yes, a small addition to
   T682.
5. **The task**: `mix dextrin.gen.elixir SCHEMAS --prefix P --out DIR
   [--check]`, deterministic, beside the existing `gen.schema` (which goes
   the other way)? Recommended: yes.
6. **Scope of the first round**: structs, shapes, named types, refine
   constraints, formats, versions with generated and hand-written upgrades,
   deprecation; generics arrive monomorphized from T682. Left for later:
   `{:case}` and `{:if}` across sibling fields beyond one level, and
   `.dxnb` positional encoding. Recommended: as listed.

## Decisions (Jan, 2026-11-18)

- Q2, Q3: yes -- `--prefix` module names, and a generated `registry/0`.
- Q4: yes -- T682 writes `@renamedFrom` into `meta` (`typespec.renamed-from`).
- Q5, Q6: yes -- `mix dextrin.gen.elixir`, and the first-round scope.
- Q1, Jan: "Can we support marked regions in the generated file, and also
  use the two file set up? Can we also make sure that then the way a
  module name is written (switching lowercase/uppercase, splitting
  differently, etc.) is kept when updating?" -- both, as below.

## Q1: regions, two files, and names kept

**Feasible, all three.** How:

- **Two files, as before.** `order.ex` is the user's, written once:
  `defmodule AscoSchemas.Acme.Shop.Order do use AscoSchemas.Acme.Shop.Order.Gen ... end`.
  `order.gen.ex` is rewritten on every run and defines `...Order.Gen`,
  whose `__using__` gives the struct and every generated function.
- **Marked regions inside the generated file.** The generator writes
  fixed slots, each an empty region the user may fill:

  ```elixir
  # dextrin:keep upgrade_v1
  # dextrin:end upgrade_v1
  ```

  There is one slot after each upgrade step (`upgrade_vN`), one at the
  top of the module (`top`) and one at its end (`bottom`). Before
  rewriting the file, the generator reads the old one, takes every
  region's lines by its name, and puts them back into the slot of that
  name. The markers are comments, so the file stays plain Elixir; the
  names, not line numbers, are the anchors, so anything around them may
  change.
- **A slot that is gone** (a version removed, so `upgrade_v1` has no
  place): its code is never dropped. It is kept in a region
  `orphaned_upgrade_v1` at the end of the file, with a comment naming
  the slot it came from, the run prints a warning, and `--check` fails
  until someone moves or deletes it.
- **A region the user invents** (`# dextrin:keep my_helpers` where the
  generator has no slot) is kept too, at the place of the generated line
  just before it if that line is still there, otherwise as an orphan.
- **Names kept.** Both files start with a stable id, the schema's DXNS
  name:

  ```elixir
  # dextrin:schema acme.shop/Order
  ```

  On every run the generator first reads the `--out` directory for these
  ids. For a schema it has seen before, it keeps the module name exactly
  as the user's file writes it (`AscoSchemas.ACME.Shop.Order`,
  `Asco.AcmeShop.Order`, ...) and the file's path, and only derives a
  name and path for a schema it meets for the first time. Renaming a
  module is then done once, by hand, in the user's file; the generator
  follows. Two files with the same id are an error naming both.

**Recommended: all of it, as above.** The two files carry anything
larger; regions are for the few lines that must sit inside a generated
function (an upgrade's special case). With both, a user picks per case,
and neither ever loses code.

## What the first round does (2026-11-18)

Built as above, with these differences, found while building:

- **Q3: `P.Decoder.decode/2`, not `P.registry/0`.** A registry reads a
  struct through its compiled schema -- Dextrin calls a materializer only
  for a struct whose schema it holds, and checks it with the interpreter
  -- so a registry would load the schema at run time, which the generated
  code must not. `P.Decoder` decodes the DXN and reads every struct of a
  known schema with its module's generated `read/1`, wherever it stands.
- **The generated module is `X.Gen`, the struct is `X`'s.** `X` does
  `use X.Gen`, which defines the struct and delegates `read/1`,
  `validate/1` and `to_dxn/1`; `X.Gen` matches `%{__struct__: X}` rather
  than `%X{}`, so neither waits on the other to compile.
- **One function per version** (`read_v1/1`, `conform_v1/1`,
  `upgrade_v1/1`), so `@deprecated` marks exactly the deprecated version.
  The runtime deprecation warning (G10) came in a second round (T698,
  below).
- **Hand-written upgrades**: a step that needs one calls
  `X.upgrade_vN/1`; `X.Gen` declares it a `@callback` and `X` takes the
  behaviour, so a missing one is a compile warning (an error under
  `--warnings-as-errors`). The step's region may do it instead.
- **A region the user invents** where no slot is becomes an orphan at once
  (not placed after the line before it): simpler to reason about, and its
  code is still never lost.
- **Not generated yet** (the generator stops and names them): typed extras
  (`* K => V`), `{:case}`, `{:list-items}`, `{:tuple-of ...}`, sets,
  ordered maps, arrays, tagged values, generics written by hand, and the
  refine keys `contains`, `content`, `encodes`, `encodes-seq`. Shapes,
  named types (recursive ones included), references, enums, unions,
  `{:if}`, `{:not}`, `{:nilable}`, lists, maps and every other refine key
  are generated.

## Jan on the differences (2026-11-18)

- `P.Decoder.decode/2` instead of `P.registry/0`: accepted.
- The constructs not generated yet: accepted; each comes as a task when
  T690 needs it.
- The runtime deprecation warning, Jan: "code generated to parse
  something marked deprecated should also log a warning" -- built as
  T698.

## Deprecation warnings (T698)

Generated code warns as Dextrin's reader does (DXNS.md §1b) when data
goes through something deprecated: a struct read at a deprecated version,
any struct of a schema whose latest version is deprecated, and a value
accepted by a deprecated type, field type, variant or enum value. The
warning is `Dextrin.Schema.Deprecations`' own -- name, version, reason,
category `schema/deprecated` -- and so is its text.

- **Options**: `read/2` and `validate/2` of every generated module and
  `P.Decoder.decode/2` take `deprecations:` (`:once`, the default,
  `:every`, `:off`, `:error`) and `on_deprecated:` (a function, in place
  of `Logger.warning`).
- **Noted, then settled**: while a value is read, what it went through is
  noted; the outermost read settles the notes when it ends
  (`Dextrin.Codegen.Runtime.reading/2`). So a variant tried and refused
  stays silent -- its notes are dropped -- and `:error` refuses the whole
  value, whichever check noted it. A read that fails anyway reports
  nothing. The read's options and notes live in the process dictionary
  for as long as it runs, so the type functions keep one argument.
- **Once** is per generated module and deprecated thing, where the
  reader's is per registry: there is no registry. Each module with
  something deprecated numbers it when generated and keeps an `:atomics`
  array in `:persistent_term`, made by its `@on_load`; loading the module
  again starts it afresh. A named type used by two schemas can therefore
  warn once from each.
- Without options -- a generated function called outside `read/2`, such
  as `read_v1/1` directly -- a note is settled at once, as `:once`, to
  the log.
