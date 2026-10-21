# The schema example

One set of `.dxns` schemas for a made-up shop, Acme, that uses every
kind of definition DXN has, and its generated HTML documentation. The
same files live in `example/` in every Dextrin implementation (Elixir,
Node, PHP, Praxis), and each one's docs task must turn them into the
same `doc/`.

- `schemas/` -- the schemas, laid out by the file conventions of
  DXN.md §4.6: a namespace file (`acme.common.dxns`, `acme.events.dxns`),
  versioned files (`acme/shop/Customer-v1.dxns`, `-v2`), a directory per
  name (`acme/shop/Order/v1.dxns`), a flat file
  (`acme.shop.Product.dxns`), and a name with no namespace
  (`HealthCheck.dxns`).
- `doc/` -- what `mix dextrin.docs example/schemas --out example/doc
  --title "Acme schemas"` writes. Open `doc/index.html` in a browser.

`acme.events.dxns` uses `%shape{...}` and `{:case ...}`;
`acme.shop.Product.dxns` and `HealthCheck.dxns` carry annotations,
`{:doc T %{...}}` (DXN.md §4.1b), which the documentation shows beside
the definitions they annotate.
