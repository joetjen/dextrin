# Examples

Worked examples across a range of use cases. See the
[tutorial](TUTORIAL.md) first if you haven't already, and the
[DXN examples](dxn/DXN_EXAMPLES.md) for format-level (not
Elixir-API-level) examples.

## A config file

```
# config.dxn
@dxn "1.0"
%{
  env:      :production
  debug:    false
  db: %{
    host:     "db.internal"
    port:     5432
    pool:     10
    timeout:  ~T[00:00:30]
  }
  features: @{:billing :notifications}
}
```

```elixir
{:ok, config} = File.read!("config.dxn") |> Dextrin.decode()
config["db"]["host"]
#=> "db.internal"
MapSet.member?(config["features"], %Dextrin.Keyword{name: "billing"})
#=> true
```

## An API payload with an explicit schema

```elixir
schema_source = """
%{
  User: %schema{
    closed: true
    fields: @ordered %{
      id:       :uuid
      email:    NonEmptyString
      role:     {:enum :admin :member :guest}
      created:  :timestamp
      note?:    :string
    }
  }
}
"""

{:ok, doc} = Dextrin.decode(schema_source)
{:ok, registry} = Dextrin.Schema.compile(doc, Dextrin.Schema.Std.registry())

payload = """
%User{
  id:      @uuid "550e8400-e29b-41d4-a716-446655440000"
  email:   "ada@example.com"
  role:    :admin
  created: ~U[2024-01-01 00:00:00Z]
}
"""

{:ok, user} = Dextrin.decode(payload, registry: registry)
#=> {:ok, %{"id" => %Dextrin.Uuid{...}, "email" => "ada@example.com", "role" => %Dextrin.Keyword{name: "admin"}, ...}}

# A response body accidentally including a legacy field is rejected loudly, not silently dropped:
Dextrin.decode(~s(%User{id: @uuid "...", email: "a@b.co", role: :admin, created: ~U[2024-01-01 00:00:00Z], legacy_id: 1}), registry: registry)
#=> {:error, %Dextrin.Error{message: "struct \"User\" violates its schema: unknown field \"legacy_id\" (schema is closed)", ...}}
```

## An event log, streamed to `.dxnb` for storage

```elixir
events = [
  %{type: :login, user_id: 1, at: ~U[2024-01-01 08:00:00Z]},
  %{type: :purchase, user_id: 1, amount: Decimal.new("19.99"), at: ~U[2024-01-01 08:05:00Z]}
]

encoded = Enum.map(events, fn event ->
  {:ok, bytes} = Dextrin.encode_binary(event)
  bytes
end)

# ... write each to a file/stream, one .dxnb value per line/frame ...

decoded = Enum.map(encoded, fn bytes ->
  {:ok, event} = Dextrin.decode_binary(bytes)
  event
end)
```

`.dxnb` is a good fit here specifically because `timestamp` uses tag
1's *integer* microsecond form (never the lossy float form) and
`decimal` maps directly to CBOR tag 4 — money and event timestamps
round-trip exactly, unlike JSON-over-the-wire where both would need
an app-level convention.

## Money: `struct` + `refine`, combined

```elixir
schema_source = """
%{
  Money: %schema{
    fields: @ordered %{
      amount:   :decimal
      currency: {:enum :usd :eur :gbp}
    }
  }
}
"""

{:ok, doc} = Dextrin.decode(schema_source)
{:ok, registry} = Dextrin.Schema.compile(doc)

registry =
  Dextrin.Registry.put_struct_materializer(registry, "Money", fn %{amount: a, currency: c} ->
    {:ok, %{amount: a, currency: c.name}}
  end)

Dextrin.decode(~s(%Money{amount: 19.99M, currency: :usd}), registry: registry)
#=> {:ok, %{amount: #Decimal<19.99>, currency: "usd"}}
```

## Cross-field validation with `refine-fn`

A `type_expr` can only describe shape, not "field A implies field B" —
`refine-fn:` names a predicate resolved from a `predicates` map passed
to `compile/3`:

```elixir
schema_source = """
%{
  DateRange: %schema{
    refine-fn: date-range/valid
    fields: @ordered %{ starts: :date, ends: :date }
  }
}
"""

predicates = %{
  "date-range/valid" => fn %{starts: s, ends: e} ->
    if Date.compare(s, e) != :gt, do: :ok, else: {:error, "starts must not be after ends"}
  end
}

{:ok, doc} = Dextrin.decode(schema_source)
{:ok, registry} = Dextrin.Schema.compile(doc, Dextrin.Registry.new(), predicates)

Dextrin.decode(~s(%DateRange{starts: ~D[2024-06-01], ends: ~D[2024-01-01]}), registry: registry)
#=> {:error, %Dextrin.Error{message: "struct \"DateRange\" violates its schema: starts must not be after ends", ...}}
```

## Cross-file schemas with `Dextrin.Schema.FileResolver`

Given `schemas/Address.dxns` and `schemas/Person.dxns` on disk, where
`Person.dxns` references `Address/Address` (a namespaced reference):

```elixir
resolver = Dextrin.Schema.FileResolver.for_paths(["schemas"])
registry = Dextrin.Registry.put_resolver(Dextrin.Registry.new(), resolver)

Dextrin.decode(~s(%Person{name: "Ada", home: %Address{street: "1 Main St"}}), registry: registry)
```

Each referenced schema file is loaded and compiled lazily, on first
encounter with its name, and memoized for the rest of that decode.

## Generating a schema scaffold from an existing struct

```sh
mix dextrin.gen.schema MyApp.Point --out point.dxns --name Point
```

```
%{
  Point: %schema{
    fields: @ordered %{
      x?: :integer
      y?: :integer
    }
  }
}
```

A starting point to review and tighten by hand — every generated field
is optional (a default value alone can't tell you whether a field is
actually required), and unrecognized default shapes fall back to
`:any` rather than a guess.

## Round-tripping a value with repeated structure, compactly

```elixir
shared_address = %{"street" => "1 Main St", "city" => "Springfield"}
company = %{"hq" => shared_address, "billing" => shared_address, "shipping" => shared_address}

{:ok, compact} = Dextrin.encode_binary(company, share: true)
{:ok, ^company} = Dextrin.decode_binary(compact)
```

The three copies of `shared_address` are written once and referenced
twice — transparently: the decoded result is an ordinary, independent
value, `==`-equal to what an unshared encoding would have produced.
