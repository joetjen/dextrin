# DXN Examples

Various examples of `.dxn`/`.dxns` documents, format-level rather than
tied to any particular reader's API. See the [tutorial](TUTORIAL.md)
first if you haven't already, and [dextrin's own examples](../EXAMPLES.md)
for the Elixir-API-level equivalents of several of these.

## Application configuration

```
@dxn "1.1"
%{
  env:   :production
  debug: false

  server: %{
    host:    "0.0.0.0"
    port:    4000
    timeout: ~T[00:00:30]
  }

  database: %{
    url:       @uri "postgres://db.internal:5432/app"
    pool_size: 10
  }

  feature_flags: @{:new-checkout :dark-mode}
}
```

## An API response body

```
%{
  status: :ok
  data: %User{
    id:      @uuid "9b74c989-1e2a-4b17-9b1f-2a6a4a2b6f10"
    email:   "ada@example.com"
    role:    :admin
    created: ~U[2024-01-01 00:00:00Z]
  }
}
```

## An event log entry

```
%{
  event:  :purchase
  at:     ~U[2024-03-15 14:22:07Z]
  user:   @uuid "9b74c989-1e2a-4b17-9b1f-2a6a4a2b6f10"
  amount: 49.99M
  items:  [
    {:sku "ABC-123", :qty 2}
    {:sku "XYZ-789", :qty 1}
  ]
}
```

## Positional vs. keyed structs

```
# Keyed -- field order in the source text doesn't matter
%Point{y: 2, x: 1}

# Positional -- order is everything, and matches the schema's own
# canonical field order (also what .dxnb always uses on the wire)
%Point[1, 2]
```

## Nested structs and cross-references

```
%Order{
  id:       @uuid "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
  customer: %Customer{
    name:    "Grace Hopper"
    address: %Address{
      street: "1 Main St"
      city:   "Springfield"
    }
  }
  total: 199.99M
}
```

## A schema document (`.dxns`)

```
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

Note `Percentage` and `Tag` aren't `%schema{}` entries — they're named
types, reusable named shorthand for a combination of the fixed
type_expr vocabulary, referenced from `Customer`'s own fields exactly
like a struct name (a bare symbol).

## Cross-file schema references

Given `Address.dxns`:

```
%{
  Address: %schema{ street: :string, city: :string }
}
```

`Customer.dxns` can reference it by namespaced name:

```
%{
  Customer: %schema{
      name: :string
      home: Address/Address
    }
}
```

`Address/Address` is a bare (namespaced) symbol — the identifier
grammar already supports `Namespace/Name` directly; a reader's own
file-resolution convention decides what "Address" maps to on disk
(one reasonable default: `Address/Address` -> `<search-path>/Address.dxns`,
entry `Address`).

## A schema, version by version

Each `.dxns` document describes one version of a schema, in its header.
The fields are the body, in order:

```
# user-v1.dxns
%{
  User: %schema{
    name: :string
    email: :string
  }
}

# user-v2.dxns
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
can say which version it was written with:

```
%User(2){name: "Ada", email: "ada@example.com"}
```

## Value sharing in `.dxnb` (binary-only, described in text)

A `.dxnb` encoder that finds the same `Address` value repeated three
times in one document (say, `hq`/`billing`/`shipping` all pointing at
identical data) may write it once and reference it twice instead,
transparently — the decoded result is `==`-equal to what an unshared
encoding of the same document would have produced. This has no `.dxn`
text-syntax representation; it's purely a `.dxnb` size optimization.
See [the reference](DXN.md#25-value-sharing-arbitrary-repeated-values)
for the exact mechanism (CBOR tags 28/29).
