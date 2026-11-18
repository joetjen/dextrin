# TypeSpec emitter (T682)

Status: built 2026-11-18 (node-dextrin/packages/dextrin-typespec; the
mix, npm and PHP commands). Release step still open: the package depends
on the library as `file:../..`; at 0.5.0 that becomes `^0.5.0`, which it
needs (`%type(N)`, pins, several `* K => V`).

## Decisions (Jan, 2026-11-17)

All seven as recommended: a second npm package in the node-dextrin
repository, `@joetjen/dextrin-typespec` (no other name given; named in
the commit lines); the dextrin tree layout; the mix, npm and PHP
commands run `tsp compile --emit` through npx; generated files are never
edited and say so; deterministic output; one fixture per mapping row;
Node 22 for the emitter package only.

T673 Q7 chose an emitter: TypeSpec's own compiler resolves templates,
decorators, imports, `using` and versioning projections, and an npm
package turns its type graph into DXNS, following the construct table
in [typespec.md](typespec.md). T690 (asco_schemas) waits on it: schemas
written in TypeSpec as the single source, converted to DXNS, then to
Elixir modules (T684). So it must run from a mix project, give the same
output every run, and leave hand-written parts to the code generator.

## Facts (2026-11-17)

- `@typespec/compiler` 1.18.0 needs Node 22 or later; `@typespec/versioning`
  is 0.88.0. node-dextrin supports Node 18.18, 20 and 22 today, so the
  emitter's own Node floor is higher than the library's.
- The emitter API, checked in the 1.18.0 package: `$onEmit(context)`,
  `navigateProgram` to walk the types, `emitFile` to write, and the
  getters the construct table needs (`getDoc`, `getFormat`, `getPattern`,
  `getMinValue` and the other bounds, `getDeprecationDetails`,
  `getDiscriminator`, `getVisibilityForClass`, `isTemplateDeclaration`).
- Versioning 0.88 projects one version at a time with
  `createVersionMutator`; `getAllVersions`, `getAddedOnVersions`,
  `getRemovedOnVersions`, `getRenamedFrom`, `getTypeChangedFrom`,
  `getMadeOptionalOn` and `getMadeRequiredOn` say what changed, which is
  what Way B (`%schema(N)`, `%type(N)`, pins) is written from.

## Questions (answered above)

1. **Where does the emitter live, and what is it called?** A second npm
   package in the node-dextrin repository (one release flow), or a
   repository of its own. Its name follows "library names are words"
   unless an emitter is exempt as a plugin name.
2. **What does it write?** Recommended: the dextrin tree layout
   (DXNS.md §6), one file per TypeSpec namespace and one per schema
   version (`Customer-v2.dxns`), so `mix dextrin.check` reads it as is.
3. **How do the other languages run it?** Recommended:
   `mix dextrin.from_typespec`, `dextrin from-typespec` and
   `bin/dextrin from-typespec` each run `tsp compile --emit` through
   npx, and need Node 22 on that machine.
4. **Generated files are never edited.** Recommended: a header comment
   naming the source and saying so; hand-written parts belong to the code
   generator (T684), not to DXNS.
5. **Deterministic output.** Sorted entries, no timestamps, the
   formatter's layout; a test runs it twice and compares.
6. **Tests.** One TypeSpec fixture per row of the construct table, its
   DXNS compared exactly, and each compiled and checked with sample
   values.

7. **Node 22 for the emitter only?** Recommended: the emitter package
   declares Node 22 (TypeSpec's own floor); node-dextrin itself keeps
   18.18 and later.

## What building it found

- Templates follow T673 Q3: each instance used is a named `%schema`
  (`@friendlyName`, otherwise template and arguments, defaulted trailing
  arguments left out: `Page<Dog>` is `PageDog`); the template itself is
  not written. `model A is B<X>` includes that instance.
- `= utcDateTime.now()` is `%field{computed: :now}` (G8).
- `alias` is not kept by TypeSpec's compiler: a use arrives inlined, so
  `Pair<string>` is written `{:list-items :string :string}`, not a use of
  a generic named `Pair`.
- An inline intersection or spread is `{:all-of ...}`: an inline shape
  can't be built from others (DXNS.md §4b).
- `@typespec/versioning` 0.88 does not export the getter for
  `@madeRequired`, so a property made required counts as required in every
  version; the rest of the versioning decorators are read.
- Dextrin's tree layout did not know versioned named types: a `-vN` file
  holding `%type(N)`, or any versioned entry inside a `{:doc}`, was
  refused. Fixed in all three libraries (DXNS.md §6).
- In a versioned namespace each declaration is a file of its own, where
  only full names resolve, so references are written in full
  (`Test/Color(1)`).
