# Schema evolution

**Status: superseded by [`implementation-plan.md`](implementation-plan.md)** (2026-10-17): versioned schemas replaced the positional evolution rules below; the reference fix (§3) and a slimmer compatibility check survive there. Kept for the record.

**Original status: design, not implemented.** Nothing described here exists in
`dextrin` yet. Written 2026-10-17 from what the ASCO workspace (the
`asco_rabbitmq_event` event envelope, `asco_dxn`, `asco_rabbitmq_dxn`)
ran into; work through it in its own session. The spec text is
normative for every implementation, so `node-dextrin` and `php-dextrin`
follow the same changes (see "Other implementations").

## The problem

A `.dxns` schema cannot change without breaking every `.dxnb` document
written against its previous version, and every reader still on that
version.

- `.dxnb` encodes a struct **only positionally**,
  `[type-name-or-ref, field-1, field-2, ...]` (DXN.md §2.1). Field names
  never travel; the schema's `@ordered` `fields:` is the position ↔ name
  map (§4.4).
- The reference implementation demands an **exact field count** in both
  directions: decoding (`Dextrin.Schema.Validator.to_name_map/2`,
  `lib/dextrin/schema/validator.ex:53-60`) and encoding
  (`to_name_map_for_encode/2`, `:185-193`) fail with
  `"expected N positional field(s), got M"` whenever M ≠ N.
- So even the least invasive change, **appending one optional field**,
  splits the world: a document written with the old schema (M = N − 1)
  fails against the new one, and a document written with the new schema
  (M = N + 1) fails against the old one.

For a configuration file that is a nuisance. For a **message format** it
is disqualifying: during any rolling deploy, old and new processes share
one broker and must read each other's messages. Every serialization
format used on a wire (Protobuf, Avro, Thrift, Cap'n Proto) has an
evolution rule for exactly this reason; DXN has none yet.

The concrete case: ASCO's event envelope appended `id?: :string` to its
`User` struct (ONS MQ-30). Text DXN and keyed literals are fine, since
names resolve them; positional `.dxnb` would not interoperate across the
change. No `.dxnb` events are produced yet, which is why this is a design
task and not an incident.

### Two smaller defects found on the way

1. **A reference field accepts any non-struct value.**
   `Dextrin.Schema.TypeExpr.matches?/3`'s last `{:reference, _}` clause
   (`lib/dextrin/schema/type_expr.ex:90`) returns `true` for every value
   that is not a `Dextrin.Struct`, a `Validated` or a registered struct
   module, so an integer or a plain map passes a field declared as
   `User`. DXNS.md §7 requires that "every present field's value matches
   its declared `type_expr`". Seen in ASCO: validating an `Event` value
   whose `user` is an integer succeeds. (On the decode path the nested
   struct is usually already a `Validated`, which hides the hole.)
2. **No tool says whether a schema change is safe.** A reviewer has to
   know the rules below by heart; nothing in CI enforces them.

## What this is not

- **Not keyed structs in `.dxnb`.** Sending names would fix evolution by
  giving up the compactness that is `.dxnb`'s reason to exist, and would
  add a second binary shape per struct (§2.1 promises one).
- **Not a schema registry or a version number per struct.** The
  `.dxnb` envelope's `version` byte stays the *format* version. A
  per-struct schema version would need negotiation and a place to look
  versions up, which is exactly the machinery the evolution rule makes
  unnecessary. (ASCO versions breaking payload changes with its own
  `schema_version` message header, outside DXN; that stays separate.)
- **Not "anything goes".** Removing, reordering, renaming or retyping a
  field remains a breaking change; this design makes the safe subset
  explicit and checkable, not larger.

## Design

### 1. The evolution rule (spec, new DXNS.md §8)

A struct schema evolves **append-only at the end, with optional fields
only**:

- **Allowed:** appending a field whose key ends in `?` after the last
  existing field.
- **Allowed:** adding `default:` or `description:` to an existing field;
  adding a field name to `forbidden:` (to retire a name, see below).
- **Breaking:** removing, reordering or renaming a field; changing a
  field's `type_expr` (except widening to `:any`, open question);
  appending a *required* field; making an optional field required;
  switching `closed: false` → `true`.
- **Retiring a field** keeps its slot: the field becomes optional, a
  writer sends `null`/absent for it, and its name may go into
  `forbidden:` so a keyed text literal naming it is reported specifically.
  A slot is never reused for a different meaning.

### 2. Reading and writing across versions (spec §2.1 and §4.7)

Let N be the schema's field count and M the positional item count.

- **M < N (older writer):** valid if every field at positions M+1..N is
  optional. Those fields are *absent* (their `default:`, if any, applies,
  exactly as for an absent keyed field). If any of them is required, the
  existing "required field missing" error applies, naming the field.
- **M > N (newer writer):**
  - schema `closed: false` (the default): valid; items N+1..M are
    **ignored** for validation and materialization. An implementation
    MAY keep them for a lossless re-encode (open question).
  - schema `closed: true`: error, reported as a closed-schema violation
    ("unexpected trailing positional field(s)").
- **M = N:** unchanged.
- **Writing:** a writer emits exactly N items for its own schema version.
  It MAY drop *trailing* absent optional fields to save bytes (M < N is
  valid by the rule above); it MUST NOT drop a non-trailing one (there is
  no way to mark a hole except `null`).
- `null` in a positional slot of an optional field means absent; in a
  required field's slot it is a type error unless the type admits `nil`.

§4.7's enforcement list gains the trailing-field rules; §2.1's "always
positional" paragraph points to §4.8.

### 3. Reference fields (spec §4.7 clarification, implementation fix)

A field declared as a struct reference matches only a value of that
struct: a `Dextrin.Struct`/`Validated` of that name, or an instance of
the registered struct module. Any other value (integer, string, plain
map) is a type error. If the referenced schema is unknown to the
registry, behaviour stays as today for *decoded opaque structs* (§1.4:
never an error) but a non-struct value is still rejected. Fix in
`TypeExpr.matches?/3` (`:90`), plus a test per value kind.

### 4. Compatibility check: `mix dextrin.compat`

```
mix dextrin.compat OLD.dxns NEW.dxns [--struct Name ...]
```

Compiles both documents and, per struct present in both, reports every
breaking change from rule 1 with the field name and position; exit
status non-zero on any. Named types: a changed `type_expr` is breaking
unless identical after resolution. A struct only in OLD (removed) is
breaking; only in NEW is fine. Library form:
`Dextrin.Schema.compatible?(old, new) :: :ok | {:error, [violation]}`
so a consumer's test suite can call it directly.

Intended use: a library that owns a `.dxns` keeps the last released
version of the schema next to the current one (or fetches it from its
previous tag) and runs the check in CI.

### 5. Golden fixtures across versions

The test suite keeps `.dxnb` files written with *older* schema versions
(`test/fixtures/evolution/<schema>-v<N>.dxnb`) and asserts:

- each old document decodes against the current schema (M < N rule);
- a document written with the current schema decodes against each old
  schema (M > N rule), for open schemas;
- the same against a `closed: true` variant fails with the documented
  error.

Property test (StreamData): for random schemas and random appended
optional fields, encode with version k and decode with version k+j (and
the reverse for open schemas) — the shared fields round-trip identically.

## Implementation sketch (Elixir)

- `Validator.to_name_map/2` (decode) and `to_name_map_for_encode/2`
  (encode): replace the equality check with the M < N / M > N rules;
  pass `closed` in (both already have the `Compiled` at hand).
- `Validator.materialize/4`: absent trailing fields go through the same
  default/required handling as absent keyed fields.
- `Binary.Encoder`: optional trailing-absent truncation behind an option
  (`compact: true`), default off to keep encodes stable byte-for-byte.
- `TypeExpr.matches?/3`: the reference fix (section 3).
- New `Dextrin.Schema.Compat` + `mix dextrin.compat` (section 4).
- Docs: DXN.md §2.1, §4.7, new §4.8; README "Components"; the tutorial's
  schema chapter gets an "Evolving a schema" section; CHANGELOG.

## Other implementations

`node-dextrin` and `php-dextrin` implement the same DXN.md, so the rule
is only real once all three read M ≠ N the same way. Order: land the
spec text and the Elixir implementation with a shared cross-language
fixture set (the golden `.dxnb` files above), then port to Node and PHP
against those same files.

## Consumers (ASCO workspace) once this exists

- `asco_rabbitmq_event`: its `User` already follows rule 1 (`id?`
  appended); wire `mix dextrin.compat` into its CI against the previous
  schema; drop the "a three-field User does not validate" caveat from the
  schema comment, ARCHITECTURE and CHANGELOG.
- `asco_rabbitmq_event` (own fix, independent of this design): its
  writer sends `source` as a string while the schema declares
  `:keyword`; one of them must change before DXN events are produced.
- `asco_rabbitmq_dxn`: validate against the schema on encode and decode
  (today the schema is never used at runtime).

## Open questions

- **Preserve unknown trailing fields?** Keeping items N+1..M lets an old
  reader that re-encodes (e.g. a forwarding relay) pass a newer message on
  losslessly, as Protobuf does with unknown fields. It needs a place in
  the decoded value (a hidden `__unknown__`-style slot) and a rule for
  keyed text output. Worth it, or out of scope for a first version?
- **Type widening:** is any `type_expr` change safe (e.g. `:integer` →
  `:number`, or a named type to `:any`)? Simplest answer: none, until a
  real case needs one.
- **Required fields after optional ones:** the rule only ever appends
  optional fields, so a required field never follows an optional one in a
  schema that started valid. Should the compiler reject a *new* schema
  that has a required field after an optional one, since such a schema
  can never have been reached by allowed evolution?
- **`closed: true` and evolution:** a closed schema can still gain
  appended optional fields (rule 1), but an *older* closed reader then
  rejects newer documents (M > N). Document that "closed" means "no
  forward compatibility", or forbid appending to closed schemas?
- **Text form of a positional literal** (`%Name[ ... ]`): same M ≠ N rules
  as `.dxnb`? Proposed yes, since both forms "parse equal" (DXN.md §1.3).
