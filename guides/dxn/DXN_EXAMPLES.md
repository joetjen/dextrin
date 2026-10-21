# DXN Examples

Various examples of `.dxn`/`.dxns` documents, format-level rather than
tied to any particular reader's API. See the [tutorial](TUTORIAL.md)
first if you haven't already, and [dextrin's own examples](../EXAMPLES.md)
for the Elixir-API-level equivalents of several of these.

## Application configuration

```
@dxn "1.0"
%{
  env:   :production
  debug: false

  server: %{
    host:    "0.0.0.0"
    port:    4000
    timeout: @time "00:00:30"
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
    created: @datetime "2024-01-01T00:00:00Z"
  }
}
```

## An event log entry

```
%{
  event:  :purchase
  at:     @datetime "2024-03-15T14:22:07Z"
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

## Schemas

Whole schemas, from a configuration file to an expression language, are
in [DXNS_EXAMPLES.md](../dxns/DXNS_EXAMPLES.md).

## Value sharing in `.dxnb` (binary-only, described in text)

A `.dxnb` encoder that finds the same `Address` value repeated three
times in one document (say, `hq`/`billing`/`shipping` all pointing at
identical data) may write it once and reference it twice instead,
transparently — the decoded result is `==`-equal to what an unshared
encoding of the same document would have produced. This has no `.dxn`
text-syntax representation; it's purely a `.dxnb` size optimization.
See [the reference](DXN.md#25-value-sharing-arbitrary-repeated-values)
for the exact mechanism (CBOR tags 28/29).
