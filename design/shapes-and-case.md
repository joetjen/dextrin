# Shapes and `{:case}`

Status: decided by Jan on 2026-10-20, implementation starting in the
Elixir reference; Node, PHP and the Praxis port follow it. Target:
Dextrin 0.3.0. The format version stays 1.0.

## Why

A RabbitMQ envelope -- `%Envelope{type: ..., payload: ...}` -- carries
a payload whose shape depends on its `type`. Today a `.dxns` document
can say "payload is a map" or "payload is one of these structs", but
not "payload is a plain map with these keys, and which keys depends on
`type`". Payloads are maps, not structs, so every consumer in every
language reads them without knowing Dextrin's struct names.

## `%shape{...}`

```
OrderPlaced: %shape{
  order_id: :uuid
  currency: %field{type: :string, default: "EUR"}
  gift?: :boolean
}
```

- **A named, unversioned map type.** The body is a `%schema` body:
  fields in order, `name?:` for optional, `%field{type:, default:,
  description:}`. `%shape(N){...}` and a positional `%shape[...]` are
  compile errors. Shapes have no version; evolving one compatibly is
  the schema author's job, not Dextrin's (Jan).
- **It is a named type** (§4.5): a top-level entry, referenced by a
  bare symbol wherever a `type_expr` goes. It matches a **plain map**
  only, never a struct, and no struct matches it.
- **Keys behave as in `%schema`** (Jan): a declared field is matched by
  name -- `name:`, `"name" =>` and `:"name" =>` all count; giving it
  twice is a refusal. Every other key is an extra, kept; a strict
  decode (`strict: true`) refuses extras, as it does on a struct.
- **Defaults are filled** (Jan, option 1): a map a shape checks while
  decoding comes out with each missing field's default filled in, as a
  struct's does. The inserted key is a keyword (`currency:`), an atom
  when the decode is trusted. Encoding writes what it is given; it does
  not fill.
- **A failure inside a shape is the enclosing field's**
  `schema/type-mismatch`: a shape is a type, and a type either matches
  or not. The checking functions below name the reason in the message.

## `{:case field %{value => type, ...}}`

```
payload: {:case type %{
  "acme.shop.order.placed"    => OrderPlaced
  "acme.shop.order.cancelled" => OrderCancelled
  :else                       => :any
}}
```

- **A type chosen by a sibling field's value.** `field` is a symbol
  naming a field of the enclosing `%schema` or `%shape`; the sibling's
  value is compared with each key as `{:enum ...}` compares, and the
  first equal key's type is the type. `:else` is the type when none is
  equal, or when the sibling is absent; with no `:else`, that is a
  refusal.
- **Anywhere in a field's type** (Jan): inside `{:nilable ...}`,
  `{:list-of ...}`, `{:any-of ...}` and so on, always reading the
  sibling of the nearest enclosing schema or shape. Outside any field
  -- a named type's own top, `{:case}` not reached through a field --
  there is no sibling, so only `:else` applies.
- A `field` naming no declared field of the enclosing schema or shape
  is a compile error where it can be told (directly in a schema's or
  shape's field).

## Named types see their siblings

DXNS.md §5 leaves a reference from one named type to another in the
same document implementation-defined. Shapes need it (`OrderCancelled`
names `CancelReason` beside it), so it becomes normative: **every
named type in a document may refer to every other**, resolved after all
of them are read, so the order of a map's entries never matters. A
named type may refer to itself, directly or through others, when every
cycle passes a guard -- a field, or a collection's elements (Jan,
2026-10-20, DXNS.md §5); there the reference stays by name and is
looked up when it is checked. An unguarded cycle is a compile error.

## Checking without decoding

Two public functions in every implementation, for a value a program
already holds -- against any named definition, a `%schema`, a
`%shape` or a named type:

- `check(value, registry, name)`: whether it matches. Never changes
  the value. `:ok`, or the error saying why.
- `conform(value, registry, name)`: the same check, answering the value
  with every shape's defaults filled in, as a decode would.

(Jan, 2026-10-20: "there should be functions available that perform
just the check".) `validate/3` stays as it is, for a struct.

## How it is built (Elixir)

`Dextrin.Schema.TypeExpr.conform/3` takes a type, a value and a context
-- the registry, the enclosing fields for `{:case}`, `strict` and
`trusted` -- and answers `{:ok, value}` or `:error`. `matches?/3` is
`conform/3` answered as a boolean, so there is one check, not two. The
validator conforms each field's value, so a struct's shape-typed fields
come out filled.

## Suite

`cases/shapes.pxn`: decode cases for every rule above (a shape-typed
field taking and refusing maps, defaults filled, extras kept and
strictly refused, keys by any spelling and twice, struct refused,
`{:case}` choosing, `:else`, absent sibling, nested case, sibling named
types, recursion refused).
