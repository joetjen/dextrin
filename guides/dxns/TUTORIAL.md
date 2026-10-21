# DXNS Tutorial

DXNS is how DXN describes data: what a document holds, which values are
allowed, how a record changes over time. A schema is itself a DXN
document, a `.dxns` file, so there is no second syntax to learn. This
tutorial starts with one small schema and grows it, step by step, until
it has used nearly every form there is.

It shows schemas and data only. How your language loads a schema and
checks a value against it is in your library's own tutorial; every
implementation does the same thing with the same schema:

| Implementation | Load a schema, then check |
|---|---|
| Elixir | `Dextrin.Schema.compile/2`, then `Dextrin.decode(text, registry: r)` or `Dextrin.Schema.check/3` |
| Node | `Schema.compile(decode(text), new Registry())`, then `decode(text, { registry })` or `Schema.check` |
| PHP | `Schema::compile(Dextrin::decode($text), new Registry())`, then `Dextrin::decode($text, $registry)` or `Schema::check` |

A data block below begins with `# good: Name` or `# bad: Name`: the
value is, or is not, a `Name` under the schema just before it.

## 1. A first schema

A `.dxns` document is a map from names to definitions. The simplest
definition is a **struct schema**: the fields of a record, each with its
type.

```dxns
%{
  User: %schema{
    name: :string
    age: :integer
  }
}
```

A value of it is a struct literal, the record's name before its fields:

```dxn
# good: User
%User{name: "Ada", age: 36}
```

A missing field, or a field of the wrong type, is refused:

```dxn
# bad: User
%User{name: "Ada", age: "thirty-six"}
```

A field the schema does not declare is kept, as an *extra* field, so a
newer writer's fields pass through an older reader. Ask for a *strict*
decode when you want them refused instead, a config file with a typo in
it, say.

## 2. Optional fields and defaults

A `?` after a field's name makes it optional; `%field{}` gives a field a
default, and a description:

```dxns
%{
  User: %schema{
    name: :string
    nickname?: :string
    role: %field{type: {:enum :admin :staff :guest}, default: :guest, description: "What the user may do"}
  }
}
```

```dxn
# good: User
%User{name: "Ada"}
```

`role` is `:guest` once decoded, and `nickname` is absent. When a field
must be present but may be `nil`, write `{:nilable T}` instead.

## 3. Types

Every DXN type has a name in a schema: `:integer`, `:float`, `:decimal`,
`:string`, `:date`, `:datetime`, `:uuid`, `:bytes` and the rest. The
collections take the type of their elements:

```dxns
%{
  Order: %schema{
    id: :uuid
    placed: :datetime
    lines: {:list-of Line}
    tags: {:set-of :keyword}
    totals: {:map-of :keyword :decimal}
  }

  Line: %schema{sku: :string, qty: :integer}
}
```

`Line` is used before it is defined: a document's definitions see each
other in any order.

```dxn
# good: Order
%Order{
  id: @uuid "6f9c1a8e-3b2d-4e5f-9a7b-1c2d3e4f5a6b"
  placed: @datetime "2026-10-21T09:30:00Z"
  lines: [%Line{sku: "TEE-00042", qty: 2}]
  tags: @{:gift}
  totals: %{net: 39.90M, vat: 7.58M}
}
```

## 4. Refining a type

`{:refine T %{...}}` takes a type and narrows it: a range, a length, a
pattern, a format.

```dxns
%{
  Product: %schema{
    sku: {:refine :string %{pattern: @regex "^[A-Z]{3}-[0-9]{5}$"}}
    price: {:refine :decimal %{min: 0M, max-exponent: 0, min-exponent: -2}}
    stock: {:refine :integer %{min: 0}}
    contact: {:refine :string %{format: :email}}
    photos: {:refine {:list-of :uri} %{max-count: 8}}
  }
}
```

```dxn
# good: Product
%Product{sku: "TEE-00042", price: 19.99M, stock: 5, contact: "shop@example.com", photos: []}
```

```dxn
# bad: Product
%Product{sku: "tee-42", price: 19.99M, stock: 5, contact: "shop@example.com", photos: []}
```

A misspelt key, `min-lenght:`, is a compile error rather than a type
that refuses everything; so is an argument of the wrong kind.

## 5. Named types

Any entry that is not a `%schema` is a **named type**: a name for a
type, used wherever a type goes.

```dxns
%{
  Sku: {:refine :string %{pattern: @regex "^[A-Z]{3}-[0-9]{5}$"}}
  Money: %shape{amount: {:refine :decimal %{min: 0M}}, currency: {:enum :eur :usd :gbp}}

  Line: %schema{sku: Sku, price: Money}
}
```

`Money` is a **shape**: a plain map with these fields, rather than a
record with a name of its own. A shape fills its defaults like a schema,
but has no version and travels as a map:

```dxn
# good: Line
%Line{sku: "TEE-00042", price: %{amount: 19.99M, currency: :eur}}
```

## 6. Choosing a type by a field

`{:case field %{...}}` lets one field's value choose another field's
type. A payment's details depend on how it is paid:

```dxns
%{
  Payment: %shape{
    method: {:enum "card" "iban"}
    details: {:case method %{
      "card" => %shape{number: {:refine :string %{pattern: @regex "^[0-9]{16}$"}}}
      "iban" => %shape{iban: {:refine :string %{min-length: 15, max-length: 34}}}
    }}
  }
}
```

```dxn
# good: Payment
%{method: "iban", details: %{iban: "DE89370400440532013000"}}
```

```dxn
# bad: Payment
%{method: "card", details: %{iban: "DE89370400440532013000"}}
```

Add `:else => T` for the values the case does not list; without one,
they are refused.

## 7. Either, or, both, neither

| Form | A value must be |
|---|---|
| `{:enum a b c}` | one of these literals |
| `{:const v}` | exactly `v` |
| `{:one-of A B}` | exactly one of `A` and `B` |
| `{:any-of A B}` | at least one of them |
| `{:all-of A B}` | both |
| `{:not T}` | anything but a `T` |
| `{:if I T E}` | a `T` when it is an `I`, an `E` otherwise |

```dxns
%{
  # A contact: an email address or a phone number, never both.
  Contact: {:one-of %shape{email: {:refine :string %{format: :email}}}
                    %shape{phone: {:refine :string %{pattern: @regex "^\\+[0-9]{8,15}$"}}}}

  # A discount: a whole percentage, or an amount.
  Discount: {:if :integer {:refine :integer %{min: 0, max: 100}} {:refine :decimal %{min: 0M}}}
}
```

```dxn
# good: Contact
%{phone: "+4930123456"}
```

```dxn
# bad: Contact
%{email: "ada@example.com", phone: "+4930123456"}
```

## 8. A list, item by item

`{:list-of T}` says every element is a `T`. `{:list-items ...}` says what
each position holds, the way a command line or a CSV row is laid out:

```dxns
%{
  # A command, then its arguments.
  Command: {:list-items :keyword {:repeat :string 0 nil}}

  # Name and value pairs, at least one.
  Pairs: {:list-items {:repeat {:group :string :integer} 1 nil}}
}
```

```dxn
# good: Command
[:copy "a.txt" "b.txt"]
```

```dxn
# good: Pairs
["width" 640 "height" 480]
```

A list must be taken whole: an item no part of `list-items` takes is
refused.

## 9. Types that refer to themselves

A type may refer to itself, as long as something lies between: a field,
or a collection's elements.

```dxns
%{
  Category: %shape{
    name: :string
    children: %field{type: {:list-of Category}, default: []}
  }

  # JSON's own value type, in DXNS.
  Json: {:any-of :nil :boolean :number :string {:list-of Json} {:map-of :string Json}}
}
```

```dxn
# good: Category
%{name: "Clothing", children: [%{name: "Shirts"} %{name: "Socks", children: []}]}
```

```dxn
# good: Json
%{"a" => [1 2.5 nil], "b" => %{"c" => true}}
```

`Loop: {:nilable Loop}` describes no value at all and is a compile
error: `nilable`, `any-of`, `one-of`, `all-of`, `not`, `refine`, `if`,
`doc` and `case` look at the same value again.

## 10. Generic types

`{:generic [t ...] body}` is a type with parameters; `{:of Name T}` fills
them in.

```dxns
%{
  Page: {:generic [t] %shape{items: {:list-of t}, next?: {:refine :string %{format: :uri}}}}
  Pair: {:generic [a b] {:tuple-of a b}}

  Users: {:of Page %shape{name: :string}}
  Scores: {:list-of {:of Pair :string :integer}}
}
```

```dxn
# good: Users
%{items: [%{name: "Ada"} %{name: "Grace"}], next: "https://example.com/users?page=2"}
```

```dxn
# good: Scores
[{"Ada" 98} {"Grace" 99}]
```

A struct schema cannot be generic: a struct travels under one name.

## 11. Tags of your own

A custom tag, `@acme.money {19.99M :eur}`, is checked with
`{:tagged name T}`, the type of what it wraps:

```dxns
%{
  Price: {:tagged acme.money {:tuple-of :decimal :keyword}}
}
```

```dxn
# good: Price
@acme.money {19.99M :eur}
```

## 12. Saying what a type is for

`{:doc T %{...}}` annotates a type, and changes nothing it takes: a
title, a description, examples, whether it is read-only, write-only or
deprecated, and free `meta`. Around an enum, `values:` documents each
value:

```dxns
%{
  Status: {:doc {:enum :active :paused :legacy} %{
    description: "Where an account stands"
    values: %{:legacy => %{deprecated: "use :paused"}}
  }}

  Account: {:doc %schema{
    email: {:doc {:refine :string %{format: :email}} %{meta: %{"acme.pii" => true}}}
    status: Status
  } %{title: "An account"}}
}
```

Each library can read the annotations back, and its documentation
generator shows them.

## 13. Documents inside documents

A string can hold a whole DXN document, encoded, and a byte string a
`.dxnb` one; `content` and `encodes` check what is inside:

```dxns
%{
  Envelope: %shape{
    type: :string
    # base64 of a .dxnb Order
    payload: {:refine :string %{encoding: :base64, media-type: "application/dxnb", content: Order}}
  }

  Order: %shape{id: :integer}
}
```

## 14. Versions

A struct schema has a version, `%schema(2){...}`, 1 when it has none.
Load several versions of `User` side by side, and data says which one it
was written with: `%User(2){...}`. A writer always writes the latest it
has.

```dxns
%{
  User: %schema(2){
    name: :string
    email: :string
    id?: :uuid
  }
}
```

To change a schema that several services share:

1. **Append fields** at the end, and nothing else, and deploy in any
   order: an older reader matches what it knows and keeps the rest.
2. For anything else, deploy the **readers first**, each with a
   materializer that upgrades the older version, then the writers.
3. Run the compatibility check in CI: a released version that changed is
   an error.

The README's "Changing a schema across services" tells the whole story,
and [DXNS.md §8](DXNS.md) the rules.

## 15. Many files

Schemas of any size are split into files, and a file's path names what
it holds: `acme/shop/Order.dxns` holds `acme.shop/Order`, and
`acme.common.dxns` is a namespace file whose entries are
`acme.common/Money`, `acme.common/Code` and so on. A reference to
another file names the entry: `acme.common/Money`.

A whole tree of schema files is checked from the command line -- every
file reads, every name resolves, no version is held twice -- with
`mix dextrin.check` in Elixir and `dextrin check` in Node and PHP, the
directory as its argument.

## Where to go next

- The [cheatsheet](DXNS_CHEATSHEET.md): every form and key on one page.
- The [examples](DXNS_EXAMPLES.md): whole schemas, as one would write
  them.
- The [reference](DXNS.md): every rule, exactly.
