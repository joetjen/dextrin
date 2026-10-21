# DXNS Examples

Whole schemas, as one would write them, each followed by data it takes
or refuses (`# good: Name`, `# bad: Name`). The forms are explained in
the [tutorial](TUTORIAL.md), the rules in the [reference](DXNS.md).

## A configuration file

Strict about what it takes, generous with defaults:

```dxns
%{
  Config: %schema{
    service: {:refine :string %{pattern: @regex "^[a-z][a-z0-9-]{1,30}$"}}
    listen: {:refine :string %{format: :host-port}}
    workers: %field{type: {:refine :int32 %{min: 1, max: 64}}, default: 4}
    timeout: %field{type: {:refine :duration %{max: @duration "PT5M"}}, default: @duration "PT30S"}
    log: %field{type: {:enum :debug :info :warn :error}, default: :info}
    database: %shape{
      url: {:refine :string %{format: :uri}}
      pool: %field{type: {:refine :int32 %{min: 1}}, default: 10}
    }
    features?: {:refine {:set-of :keyword} %{max-count: 32}}
  }
}
```

```dxn
# good: Config
%Config{
  service: "orders"
  listen: "0.0.0.0:8080"
  database: %{url: "postgres://db.internal/orders"}
}
```

```dxn
# bad: Config
%Config{service: "Orders", listen: "0.0.0.0:8080", database: %{url: "postgres://db.internal/orders"}}
```

## A schema document with named types

```dxns
%{
  Percentage: {:refine :float %{min: 0.0, max: 100.0}}
  Tag:        {:refine :string %{min-length: 1, max-length: 20}}

  Address: %schema{
    street: :string
    city:   :string
    zip?:   :string
  }

  Customer: %schema{
    name:    :string
    address: Address
    loyalty: Percentage
    tags?:   {:list-of Tag}
  }
}
```

`Percentage` and `Tag` are named types, used like a struct's name.

```dxn
# good: Customer
%Customer{name: "Ada", address: %Address{street: "1 Main St", city: "London"}, loyalty: 42.5}
```

## An API response, paged

A generic page wraps any kind of item:

```dxns
%{
  Page: {:generic [t] %shape{
    items: {:list-of t}
    total: {:refine :int64 %{min: 0}}
    next?: {:refine :string %{format: :uri}}
  }}

  User: %shape{
    id: :uuid
    name: {:refine :string %{min-length: 1, max-length: 100}}
    email: {:refine :string %{format: :email}}
  }

  UserPage: {:of Page User}
}
```

```dxn
# good: UserPage
%{
  items: [%{id: @uuid "6f9c1a8e-3b2d-4e5f-9a7b-1c2d3e4f5a6b", name: "Ada", email: "ada@example.com"}]
  total: 1
}
```

## Events on a bus

Each event's payload is chosen by its type:

```dxns
%{
  Event: %shape{
    type: {:enum "order.placed" "order.cancelled" "customer.registered"}
    at: {:refine :datetime %{offsets: ["Z"]}}
    payload: {:case type %{
      "order.placed" => OrderPlaced
      "order.cancelled" => %shape{order: :uuid, reason: CancelReason}
      :else => :any
    }}
  }

  OrderPlaced: %shape{
    order: :uuid
    lines: {:list-items Line {:repeat Line 0 nil}}
  }

  Line: %shape{sku: :string, qty: {:refine :int32 %{min: 1}}}

  # A known reason, or a short text: exactly one of them.
  CancelReason: {:one-of {:enum :customer_request :out_of_stock}
                         {:refine :string %{max-length: 200}}}
}
```

```dxn
# good: Event
%{
  type: "order.placed"
  at: @datetime "2026-10-21T09:30:00Z"
  payload: %{order: @uuid "6f9c1a8e-3b2d-4e5f-9a7b-1c2d3e4f5a6b", lines: [%{sku: "TEE-00042", qty: 1}]}
}
```

```dxn
# bad: Event
%{
  type: "order.placed"
  at: @datetime "2026-10-21T09:30:00Z"
  payload: %{order: @uuid "6f9c1a8e-3b2d-4e5f-9a7b-1c2d3e4f5a6b", lines: []}
}
```

The second has no line: an order needs at least one.

## Money, exactly

```dxns
%{
  Money: {:doc %shape{
    amount: {:refine :decimal %{min-exponent: -2, max-exponent: 0, max-precision: 18}}
    currency: {:refine :keyword %{pattern: @regex "^[a-z]{3}$"}}
  } %{description: "An amount in a currency, to the cent", examples: [%{amount: 19.99M, currency: :eur}]}}
}
```

```dxn
# bad: Money
%{amount: 19.995M, currency: :eur}
```

Three decimal places are one too many.

## A tree, and a value like JSON

```dxns
%{
  Category: %shape{
    name: {:refine :string %{min-length: 1}}
    children: %field{type: {:list-of Category}, default: []}
  }

  Json: {:any-of :nil :boolean :number :string {:list-of Json} {:map-of :string Json}}

  Settings: %shape{name: :string, extra: {:map-of :string Json}}
}
```

```dxn
# good: Settings
%{name: "theme", extra: %{"colors" => ["#000" "#fff"], "contrast" => 4.5, "dark" => true}}
```

## An expression language

Three types that refer to each other, each case choosing its arguments:

```dxns
%{
  Expr: %shape{
    op: {:enum :lit :add :neg :if}
    args: {:case op %{
      :lit => {:list-items :number}
      :add => {:list-items Expr Expr {:repeat Expr 0 nil}}
      :neg => {:list-items Expr}
      :if  => {:list-items Cond Expr Expr}
    }}
  }

  Cond: %shape{
    op: {:enum :and :not :lt}
    args: {:case op %{
      :and => {:list-items Cond {:repeat Cond 1 nil}}
      :not => {:list-items Cond}
      :lt  => {:list-items Expr Expr}
    }}
  }
}
```

```dxn
# good: Expr
%{op: :if, args: [
  %{op: :lt, args: [%{op: :lit, args: [1]} %{op: :lit, args: [2]}]}
  %{op: :lit, args: [10]}
  %{op: :add, args: [%{op: :lit, args: [1]} %{op: :lit, args: [2]} %{op: :lit, args: [3]}]}
]}
```

```dxn
# bad: Expr
%{op: :add, args: [%{op: :lit, args: [1]}]}
```

`:add` takes two arguments or more.

## A schema, version by version

Each `.dxns` document describes one version of a schema, in its header.
`user-v1.dxns`:

```dxns
%{
  User: %schema{
    name: :string
    email: :string
  }
}
```

`user-v2.dxns`, a field appended:

```dxns
%{
  User: %schema(2){
    name: :string
    email: :string
    id?: :uuid
  }
}
```

The first has no header, so it is version 1. Load both and a reader
keeps `User` v1 and v2 side by side; loading `user-v2.dxns` a second
time is an error (`schema/duplicate-version`), because two documents
claiming to be `User` v2 is a mistake rather than an update. A struct
says which version it was written with:

```dxn
# good: User
%User(2){name: "Ada", email: "ada@example.com"}
```

## Schemas across files

`acme/common.dxns` holds a namespace's small types, each named
`acme.common/...`:

```dxns
%{
  Money: %shape{amount: :decimal, currency: :keyword}
  Code: {:refine :string %{pattern: @regex "^[A-Z]{3}$"}}
}
```

`acme/shop/Order.dxns` holds `acme.shop/Order`, and refers to them by
their full names:

```text
%{
  Order: %schema{
    total: acme.common/Money
    country: acme.common/Code
  }
}
```

A reader finds a name's file by the same rules (DXNS.md §6), and a
tree's check -- `mix dextrin.check acme/` -- reports a name that resolves
to nothing.

## Everything at once

`bench/schemas/universe.dxns`, the schema the schema-validation
benchmark checks against, uses nearly every form there is in one
document -- mutual recursion, nested generics, cases inside cases, a
`.dxnb` document inside a base64 string -- and is more complex than any
real schema is likely to be.
