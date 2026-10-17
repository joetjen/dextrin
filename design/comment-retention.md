# Comment retention

**Status: agreed 2026-10-17, phase C of [`implementation-plan.md`](implementation-plan.md)**, built on a lossless mode in Ichor.

**Original status: design, deliberately not implemented.** Nothing described
here exists in `dextrin` yet, and building it is on hold by choice
rather than by backlog — the maintenance tax under "Open questions" is
real enough to be worth sleeping on before committing to it.

`prax`, the consumer that motivated this, has **dropped DXN for its
project manifest for now** and uses Praxis data (`project.pxn`)
instead. So nothing is waiting on this, and there is no deadline
pushing a decision that deserves to be made slowly.

## The problem

`.dxn`'s lexer discards `#`-comments as trivia before the parser sees
them, so by the time a value exists there is no comment text left to
reprint. `decode |> encode` is lossless for data and total loss for
comments.

That is fine for a wire format and disqualifying for a **configuration
file that a tool edits**. The motivating case is `prax`, whose project
manifest is currently Praxis data (`project.pxn`) rather than DXN for
exactly this reason: `prax deps add` would decode, re-encode, and
silently delete the line explaining why a version is pinned. A manifest
is precisely the file people annotate.

Restoring comments is what would let DXN become the *published* form of
a manifest while the authored form keeps its comments. That remains the
reason to want it; it is not currently a reason to hurry.

## What this is not

- **Not two parsers.** One grammar parsed one way. Two parsers for one
  format always drift, and the failure is a document that parses for
  `decode/1` and not for an edit, which nobody can reproduce.
- **Not comments in `Dextrin.Value.t()`.** That union is shared by
  `.dxn`, `.dxnb` and `.dxns`, and CBOR has no representation for a
  comment. A value type one of three formats cannot express is the
  wrong place for this.
- **Not an option that changes the shape of decoded data.** A flag
  turning `[1, 2]` into a three-element list when a comment sits
  between them makes every `length/1` and every pattern match
  flag-dependent.

## The approach

**A full-fidelity syntax tree, with the value as a projection.**

Every token in the tree, including trivia — comments, whitespace,
newlines. Every node keeps its source span. `decode/1` becomes a
projection over that tree rather than the primary thing.

```elixir
{:ok, doc} = Dextrin.Document.parse(source)
value      = Dextrin.Document.to_value(doc)   # what decode/1 returns today
```

Rendering has one rule: **an untouched node emits its original bytes;
a touched node is re-rendered.** Preservation is then a property of
the algorithm rather than something a printer has to get right, and a
rendering bug can only damage what was actually edited.

This is Roslyn's full-fidelity tree and rust-analyzer's `rowan`. It is
the only shape where "preserve everything" is the default and change
is the exception, rather than a goal approached asymptotically.

### One parser, two paths

`decode/1` does not want a tree. It parses fully and strips trivia
before projecting to a value — the same grammar, the same code path,
one extra step.

Not building trivia at all is a legitimate optimisation for that path,
but **start with parse-then-strip**: it is identical to the full parse
by construction, and the allocation only matters if DXN is used for
interchange at volume. Measure before adding a mode.

The **updater** cannot take that shortcut. To diff new values against
old it needs both the tree and the values, so it parses fully and
projects. There is no second read: `to_value/1` over the tree already
in hand is the same projection `decode/1` performs.

### Edits are explicit; the diff is a convenience over them

```elixir
doc = Dextrin.Document.insert(doc, [:deps], -1, "new-thing")
doc = Dextrin.Document.delete(doc, [:deps, 1])
doc = Dextrin.Document.replace(doc, [:version], "2.0.0")
```

**Diffing discards information the caller already had.** `["a", "b"]`
becoming `["a", "c"]` is ambiguous between "replace `b` with `c`" and
"delete `b`, insert `c`", and those differ in what happens to `b`'s
comment. A tool adding a dependency *knows* it is inserting; handing a
value to a differ and asking it to reconstruct that is throwing away
certainty and paying LCS to approximate it back.

So explicit edits are the real API, and the value-diff form is a
wrapper over them for callers who only have the new values:

```elixir
{:ok, doc, changeset} = Dextrin.Document.update(doc, new_value)
#=> changeset: [delete: [:deps, 1], insert: {[:deps], 1, "new-thing"}]
```

The wrapper uses `List.myers_difference/2` — Myers' algorithm, the
same LCS-based diff `git` uses, already in Elixir's standard library.
Its known limitation is that a **move reads as a delete plus an
insert**, so a reordered element loses its comments. That is a
property of diff in general, not of this design.

### Ambiguity is detected, not merely documented

Documentation is the weakest possible mitigation for "this can be
wrong": nobody reads it at the moment it matters, and a developer who
skips the docs will skip a returned changeset too. So the **default
protects them**:

```elixir
on_ambiguity: :safe    # default: guess where nothing can be lost, refuse where trivia is at risk
on_ambiguity: :guess   # always guess; the caller accepts the trade
on_ambiguity: :error   # refuse any ambiguity at all
```

`:safe` works because **the fallible case is much narrower than it
sounds.** A `del`/`ins` pair whose nodes carry no comments produces
byte-identical output whichever reading is taken — there is nothing to
get wrong. The risk exists only where trivia is attached, which the
updater can check directly. So it stays silent for the overwhelming
majority of edits and refuses only when guessing would destroy
something a human wrote.

The returned changeset remains useful for callers that want to report
what happened. **The library never writes to stdout**; what it does is
hand back what it decided.

### Trivia ownership

Nothing is re-placed, so the slot model is not needed for rendering.
It is needed to answer **what goes with a node when that node is
deleted**:

```
# Pinned until upstream fixes #431.      <- its `above` block: deleted with it
"left-pad"  # temporary                  <- its `trailing` block: deleted with it
"right-pad"                              <- untouched
```

Without ownership rules a deletion orphans an entry's explanation onto
the next entry, which is worse than losing it. The rules are the same
three slots, `above` / `between` / `trailing`, and the same block and
precedence rules described under the alternative below — used here as
a definition of belonging rather than of placement.

### A replaced value keeps its comments

`version: "1.0.0" # bumped for the security fix`, with the version
changed to `"2.0.0"`, keeps the comment — **even though it may now be
misleading.**

A comment about an entry usually survives that entry's value changing,
and silently deleting a human's note because a tool touched the line
beside it is the worse failure. Keeping a stale comment is the
developer's to fix, and the explicit edit API is there for anyone who
wants to remove or replace it deliberately.

## Recorded alternative: a comment side-table

Rejected in favour of the tree, but kept because it is cheaper, was
prototyped end to end, and remains the right answer if the full tree
proves too costly to maintain.

### The model

The decoded value is **unchanged**. Comments come back separately, as a
map from position to lines:

```elixir
{:ok, value} = Dextrin.decode(source)
#=> %{name: "acme", deps: ["left-pad", "right-pad"]}

{:ok, value, comments} = Dextrin.decode(source, comments: true)

Dextrin.encode(value, pretty: true, comments: comments)
```

```elixir
@type comments :: %{key => [String.t()]}
@type key :: {target, slot}
@type target :: path | {:terminal, path} | :eof
@type slot :: :above | :between | :trailing
@type path :: [term()]
```

Values are plain lists of comment lines — no wrapper struct, no flags.
Everything a wrapper might have held is layout, and layout belongs to
the printer.

#### Slots

Every comment in a valid document is `above`, `between` or `trailing`
some entry:

```
above:    zero or more blocks   before an entry, on their own lines
between:  one block             after a prefix token, before its value
trailing: one block             starting on the same line as the entry
```

`between` exists because two constructs put a token before their value:
a map key's `:` and a tag's name. Both accept a comment in the gap
today:

```
version:  # here
  "1.0.0"

@my-app/money  # and here
  500
```

#### The virtual terminal

A comment can sit after the last entry of a collection, with nothing to
be `above`:

```
deps: [
  "left-pad"
  # nothing follows this
]
```

Rather than a fourth slot, every collection has a **virtual terminal
entry** that holds only `above`. The document is the outermost
collection and its terminal is `:eof`, so end-of-file stops being a
special case:

```elixir
{{:terminal, [:deps]}, :above} => ["nothing follows this"]
{:eof, :above}                 => ["a comment below everything"]
```

An empty collection is the same case: `[ # nothing yet\n ]` has a
terminal and no entries.

#### Identity, per collection kind

A path names a position, and each kind of collection has its own
natural identity:

| kind | keyed by | survives |
|---|---|---|
| map | key name — `[:deps]` | reordering |
| array | index — `[:deps, 0]` | nothing before it changing |
| set | element value — `[:tags, {:element, :admin}]` | reordering |

A set has no order, so an index would be meaningless; keying by value
is both possible and correct, since a set cannot hold two equal
elements.

Because a map entry's comments are keyed by name, **comment retention
does not require key-order preservation**. See "Ordering is a separate
problem" below.

**For maps, the terminal must not be foldable into the path.** `%{end:
1}` is legal DXN, so `[:deps, :end]` would be ambiguous between an
entry called `:end` and the position after the last entry. Hence
`{:terminal, path}` as a distinct target rather than a path suffix.

### The rules

1. **A block is a maximal run of consecutive comment lines** with no
   blank line between them. Blocks are captured whole; a block is never
   split across slots.
2. **`trailing` beats `above`.** If a block's first line begins on the
   same line as an entry, the entire block is that entry's `trailing`,
   however many lines it runs to.
3. Otherwise the block is `above` the next entry, or the terminal's
   `above` if no entry follows.

So:

```
a: 1 # comment1
     # comment2
     # comment3
b: 2, # comment4
```

```elixir
{[:a], :trailing} => ["comment1", "comment2", "comment3"]
{[:b], :trailing} => ["comment4"]
```

Rule 2 is decidable from position alone, which is the point. It has one
consequence worth documenting for users rather than hiding:

```
a: 1 # about a
# about b
b: 2
```

Both lines become `a`'s trailing, because no blank line separates them.
**The escape is a blank line**, which is what authors already use to
separate logical groups:

```
a: 1 # about a

# about b
b: 2
```

An indentation-based rule would read both cases the way a human does,
and is rejected deliberately: it would make comment ownership depend on
whitespace in a format that otherwise does not care, break under tabs
and under differing alignment styles, and let reformatting change which
entry a comment belongs to.

Rule 2 must be stated in terms of **lines**, not adjacent tokens.
Both of these are accepted by the grammar, and the comment follows the
comma in each:

```
a: 1, # same line as a  →  a's trailing
b: 2

a: 1,
   # own line           →  b's above
b: 2
```

## Positions that cannot occur

Applies to both designs. Worth recording, because they are cases that
would otherwise need inventing — the tree needs them for ownership,
the alternative for placement. Each was checked against the current
parser:

| position | grammar |
|---|---|
| between a key and its `:` — `%{a # c\n : 1}` | **rejected** |
| between two top-level values — `1 # c\n 2` | **rejected**, a document is one value |
| a document of only comments | **rejected**, a document must have a value |
| inside a rational — `22 # c\n /7` | **rejected**, one token |
| inside a string | not a comment |

### What a printer owns, in that alternative

Everything not in the table:

- indentation, and alignment of trailing comments
- blank lines — including grouping blank lines that have **no comment
  next to them at all**, which no comment map can preserve by
  construction
- where a `between` comment is placed relative to its value
- line wrapping

Two constraints a printer has to respect, both found by building a
prototype rather than by reasoning:

- **A comment ends its line**, so a slot whose comment is followed by
  more content on the same line must break the line and re-indent what
  follows. `version:  # c` cannot be followed by `"1.0.0"` on that line.
- **Continuation lines of a `trailing` block must align under the first
  `#`.** Left at the entry's own indentation they read as comments
  about whatever comes next, visually contradicting the rule that put
  them there.

## Ordering is a separate problem

A decoded map is a plain Elixir map, which has no source order. Measured:

```
%{zebra: 1, apple: 2, mango: 3}        → [:zebra, :apple, :mango]
%{apple: 2, mango: 3, zebra: 1}        → [:zebra, :apple, :mango]   (same)
%{zzz_new_a: 1, version: 2, error: 3}  → [:error, :version, :zzz_new_a]
40 keys                                → hash order
```

Key order is **atom-table creation order** below 32 keys and hash order
above it. It is deterministic for a given set of atoms in a given VM,
and it is neither source order nor alphabetical.

This does **not** affect comments, which are keyed by name. It affects
diff noise: a tool rewriting a document emits keys in an order nobody
wrote, and the order can differ between invocations that loaded
different code.

DXN already answers this — `@ordered %{...}` decodes to
`Dextrin.OrderedMap` and keeps source order — so it is a decision for
whoever writes a document, not a reason to complicate this design.

## Open questions

- **The maintenance tax.** A second representation must be kept in step
  with the first forever: every new literal or tag form has to be added
  to the value path *and* the tree, and the two must agree. This is not
  effort paid once, and it is the reason most formats never get an
  editor-grade parser. It is the strongest argument against this
  design and does not go away by working harder.
- **Where an inserted node's style comes from.** Indent width, comma
  convention, one-entry-per-line — inferred by sampling the document,
  with the pretty printer's defaults as the fallback for an empty or
  ambiguous one.
- **Equal but differently written.** `1.0` and `1.00` are the same
  decimal; a map across three lines is the same map as on one. The
  differ must compare *values* and leave text alone when they are
  equal, or a no-op update reformats the file — the exact failure this
  is meant to prevent.
- **`.dxns` schemas** are DXN documents, so they get this for free —
  worth confirming nothing in schema compilation assumes comments are
  absent.

## Worked example, from the prototyped alternative

Source:

```
# A leading comment, above everything.
# Two lines of it.

%{
  # Above an entry.
  name: "acme"        # Trailing, same line.

  version:            # Between the key and its value.
    "1.0.0"

  # Above a nested collection.
  deps: [
    # Above the first element.
    "left-pad"        # Trailing an element.
    # Between elements.
    "right-pad"
    # After the last element, inside the array.
  ]

  tags: @{
    :admin            # Trailing inside a set.
    :staff
  }

  # A comment before a key that is never followed by an entry.
}

# A trailing comment, below everything.
```

Value — exactly what `decode/1` returns today:

```elixir
%{
  name: "acme",
  version: "1.0.0",
  deps: ["left-pad", "right-pad"],
  tags: MapSet.new([:admin, :staff])
}
```

Comments:

```elixir
%{
  {[], :above}                             => ["A leading comment, above everything.",
                                               "Two lines of it."],
  {[:name], :above}                        => ["Above an entry."],
  {[:name], :trailing}                     => ["Trailing, same line."],
  {[:version], :between}                   => ["Between the key and its value."],
  {[:deps], :above}                        => ["Above a nested collection."],
  {[:deps, 0], :above}                     => ["Above the first element."],
  {[:deps, 0], :trailing}                  => ["Trailing an element.",
                                               "Between elements."],
  {{:terminal, [:deps]}, :above}           => ["After the last element, inside the array."],
  {[:tags, {:element, :admin}], :trailing} => ["Trailing inside a set."],
  {{:terminal, []}, :above}                => ["A comment before a key that is never followed by an entry."],
  {:eof, :above}                           => ["A trailing comment, below everything."]
}
```

Note rule 2 at work: `"Between elements."` joins the block above it and
becomes part of `[:deps, 0]`'s trailing, rather than `[:deps, 1]`'s
`above`.

A prototype printer taking only these two inputs produced:

```
# A leading comment, above everything.
# Two lines of it.
%{
  # Above an entry.
  name: "acme"  # Trailing, same line.
  version:   # Between the key and its value.
    "1.0.0"
  # Above a nested collection.
  deps: [
    # Above the first element.
    "left-pad"  # Trailing an element.
      # Between elements.
    "right-pad"
    # After the last element, inside the array.
  ]
  tags: @{
    :admin  # Trailing inside a set.
    :staff
  }
  # A comment before a key that is never followed by an entry.
}
# A trailing comment, below everything.
```

which parses with the current `Dextrin.decode/1` and yields a value
identical to the original.

## Properties worth testing

The tree makes the strongest contract available, so it is the one to
assert:

```
render(parse(s)) == s                              # untouched, byte for byte
to_value(parse(s)) == decode(s)                    # the projection agrees
to_value(apply(parse(s), edits)) == expected       # edits mean what they say
```

The first is the whole point: an unedited document renders identically,
which no reformatting design can promise.

For the recorded alternative, byte-identity is not the contract, so the
properties are weaker and generative instead:

```
decode(encode(decode(s))) == decode(s)             # data survives
comments(encode(v, comments: c)) == c              # comments survive
```
