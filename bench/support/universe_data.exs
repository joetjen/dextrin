# The data sets of the schema-validation benchmark: one Universe
# (bench/schemas/universe.dxns) each, written as one line of DXN text, about
# 30% of them carrying exactly one error. Every value comes from the seed
# set with `seed/1`, so the same seed gives the same data sets, in every
# implementation that reads them (bench/generate_universes.exs writes them
# out for the Node and PHP benchmarks).

defmodule UniverseData do
  @moduledoc false

  # Its own `node` and `binding`, the schema's names, not Kernel's.
  import Kernel, except: [node: 1, binding: 1]

  # The errors a bad data set carries, one each.
  @errors ~w(id_pattern duplicate_party_id party_name_too_long person_born_late
             language_pattern org_parent_registry contact_both postal_de
             address_lines geo_range edge_duplicate_id node_key_pattern
             vertex_weight vertex_tags edge_weight ledger_offset
             ledger_resolution ledger_one_leg ledger_checksum money_exponent
             currency_pattern event_payload_case patch_empty op_pointer
             program_literal_args cond_and_one binding_symbol settings_ttl
             settings_semver settings_hosts settings_mode settings_retry
             settings_flags matrix_nan tree_either_both pair_quantity_zero
             lookup_node refs_no_uuid labels_duplicate labels_empty
             attachment_party attachment_base64 raw_entry deep_money)a

  @doc "Every kind of error a bad data set may carry."
  def errors, do: @errors

  @doc "Seeds the generator."
  def seed(seed), do: :rand.seed(:exsss, {seed, 10, 21})

  @doc "A data set: its DXN text, on one line, and its error (nil for none)."
  def data_set do
    error = if u(10) <= 7, do: nil, else: Enum.random(@errors)
    {universe(error), error}
  end

  # ---- small helpers ----------------------------------------------------------

  defp u(n), do: :rand.uniform(n)
  defp pick(list), do: Enum.at(list, u(length(list)) - 1)
  defp digits(n), do: Enum.map_join(1..n, fn _ -> Integer.to_string(u(10) - 1) end)
  defp hex(n), do: Base.encode16(:rand.bytes(div(n + 1, 2)), case: :lower) |> binary_part(0, n)
  defp s(text), do: inspect(text)
  defp list(items), do: "[" <> Enum.join(items, " ") <> "]"
  defp times(n, fun), do: if(n <= 0, do: [], else: for(_ <- 1..n, do: fun.()))

  defp shape(fields) do
    "%{" <> Enum.map_join(fields, ", ", fn {k, v} -> "#{k}: #{v}" end) <> "}"
  end

  defp float(x), do: :erlang.float_to_binary(x * 1.0, decimals: 3)

  # Fields as a keyword list: put, replace, drop.
  defp put(fields, key, value), do: List.keystore(fields, key, 0, {key, value})

  # ---- identities and amounts ---------------------------------------------------

  defp id do
    case u(3) do
      1 -> ~s|@uuid "#{hex(8)}-#{hex(4)}-#{hex(4)}-#{hex(4)}-#{hex(12)}"|
      2 -> ~s|@objectid "#{hex(24)}"|
      3 -> s(<<?a + u(26) - 1, ?a + u(26) - 1>> <> "-" <> digits(6))
    end
  end

  defp uuid_id, do: ~s|@uuid "#{hex(8)}-#{hex(4)}-#{hex(4)}-#{hex(4)}-#{hex(12)}"|

  defp money(amount \\ nil, currency \\ nil) do
    amount = amount || "#{u(99_999)}.#{String.pad_leading(Integer.to_string(u(100) - 1), 2, "0")}M"
    shape(amount: amount, currency: currency || pick(~w(:eur :usd :gbp :jpy :chf)))
  end

  defp quantity do
    case u(3) do
      1 -> Integer.to_string(u(500))
      2 -> "#{u(9)}/#{u(9) + 1}"
      3 -> "#{u(99)}.#{digits(3)}M"
    end
  end

  # ---- the expression language --------------------------------------------------

  defp symbol, do: pick(~w(total rate x y n_items acc tmp_1 alpha beta k))

  defp literal(error \\ nil) do
    case if(error, do: 6, else: u(6)) do
      1 -> Integer.to_string(u(1_000_000) - 500_000)
      2 -> float(:rand.uniform() * 1000)
      3 -> s("lit #{u(99)}")
      4 -> pick(~w(true false))
      5 -> "nil"
      6 -> if(error, do: money("1.00001M"), else: money())
    end
  end

  defp expr(depth, error \\ nil)

  defp expr(depth, error) when depth >= 3, do: leaf(error)

  defp expr(depth, error) do
    case if(error, do: 1, else: u(8)) do
      1 -> shape(op: ":add", args: list([expr(depth + 1, error), expr(depth + 1) | times(u(2) - 1, fn -> expr(depth + 1) end)]))
      2 -> shape(op: ":mul", args: list([expr(depth + 1), expr(depth + 1)]))
      3 -> shape(op: ":neg", args: list([expr(depth + 1)]))
      4 -> shape(op: ":if", args: list([condition(depth + 1), expr(depth + 1), expr(depth + 1)]))
      5 -> shape(op: ":let", args: list(times(u(2), fn -> binding(depth + 1) end) ++ [expr(depth + 1)]))
      6 -> shape(op: ":var", args: list([symbol()]))
      7 -> shape(op: ":call", args: list([symbol() | times(u(3) - 1, fn -> expr(depth + 1) end)]))
      8 -> leaf(nil)
    end
  end

  # A literal expression; with an error deep in the tree: a literal that
  # holds a money amount of too many places.
  defp leaf(nil), do: shape(op: ":lit", args: list([literal()]))
  defp leaf(:deep_money), do: shape(op: ":lit", args: list([literal(:deep_money)]))
  defp leaf(:program_literal_args), do: shape(op: ":lit", args: list([literal(), literal()]))

  defp condition(depth, error \\ nil)

  defp condition(_depth, :cond_and_one), do: shape(op: ":and", args: list([cmp(2)]))
  defp condition(depth, _) when depth >= 3, do: cmp(depth)

  defp condition(depth, _) do
    case u(4) do
      1 -> shape(op: ":and", args: list([condition(depth + 1), condition(depth + 1)]))
      2 -> shape(op: ":or", args: list([condition(depth + 1), condition(depth + 1), condition(depth + 1)]))
      3 -> shape(op: ":not", args: list([condition(depth + 1)]))
      4 -> cmp(depth)
    end
  end

  defp cmp(depth), do: shape(op: ":cmp", args: list([pick(~w(:lt :le :eq :ge :gt)), expr(depth + 1), expr(depth + 1)]))

  defp binding(depth, error \\ nil) do
    name = if error == :binding_symbol, do: "Total", else: symbol()
    "{#{name} #{expr(depth + 1)}}"
  end

  # ---- a JSON-like node, and a graph ------------------------------------------------

  defp scalar do
    case u(5) do
      1 -> "nil"
      2 -> pick(~w(true false))
      3 -> Integer.to_string(u(100_000))
      4 -> float(:rand.uniform() * 50)
      5 -> s("s#{u(999)}")
    end
  end

  defp node(depth) do
    case if(depth >= 2, do: 1, else: u(6)) do
      1 -> scalar()
      2 -> list(times(u(3), fn -> node(depth + 1) end))
      3 -> "%{" <> Enum.map_join(1..u(3), ", ", fn i -> ~s|"key#{i}" => #{node(depth + 1)}| end) <> "}"
      4 -> "@{" <> Enum.join(Enum.uniq(times(u(3), fn -> Integer.to_string(u(50)) end)), " ") <> "}"
      5 -> "{" <> Enum.join(times(u(3), fn -> node(depth + 1) end), " ") <> "}"
      6 -> "@acme.ref " <> id()
    end
  end

  defp tree_of_strings(depth) do
    children = if depth >= 2, do: [], else: times(u(3) - 1, fn -> tree_of_strings(depth + 1) end)
    shape(value: s("t#{u(99)}"), children: list(children))
  end

  defp vertex(error) do
    tags = Enum.uniq(times(u(4), fn -> pick(~w(:a :b :c :d :e :f :g :h)) end))
    tags = if error == :vertex_tags, do: ~w(:a :b :c :d :e :f), else: tags
    weight = if error == :vertex_weight, do: "-1.0", else: float(:rand.uniform() * 10)
    fields = [label: s("v#{u(99)}"), weight: weight, tags: "@{" <> Enum.join(tags, " ") <> "}"]
    if u(3) == 1, do: put(fields, :meta, tree_of_strings(0)), else: fields
  end

  defp graph(error) do
    keys = Enum.uniq(times(u(4) + 1, fn -> "n#{u(9999)}" end))
    keys = if error == :node_key_pattern, do: ["N1" | keys], else: keys

    nodes =
      keys
      |> Enum.with_index()
      |> Enum.map_join(", ", fn {k, i} ->
        "#{s(k)} => #{shape(vertex(if(i == 0, do: error)))}"
      end)

    edges =
      for i <- 1..u(5) do
        weight =
          cond do
            error == :edge_weight and i == 1 -> [weight: "-0.5M"]
            u(3) == 1 -> [weight: Integer.to_string(u(100))]
            u(3) == 1 -> [weight: "#{u(9)}.5M"]
            true -> []
          end

        shape([id: Integer.to_string(i), from: s(pick(keys)), to: s(pick(keys)), kind: pick(~w(:directed :undirected))] ++ weight)
      end

    edges = if error == :edge_duplicate_id, do: edges ++ [hd(edges)], else: edges
    shape(nodes: "%{" <> nodes <> "}", edges: list(edges))
  end

  # ---- parties ---------------------------------------------------------------------

  defp contact(error) do
    case if(error == :contact_both, do: 4, else: u(3)) do
      1 -> shape(email: s("p#{u(9999)}@example.com"))
      2 -> shape(phone: s("+49" <> digits(10)))
      3 -> shape(web: s("https://example.com/p/#{u(999)}"))
      4 -> shape(email: s("p@example.com"), phone: s("+4912345678"))
    end
  end

  defp address(error) do
    country = if error == :postal_de, do: "DE", else: pick(~w(DE US JP GB FR))

    postal =
      case country do
        _ when error == :postal_de -> s("1234")
        "DE" -> s(digits(5))
        "US" -> s(if(u(2) == 1, do: digits(5), else: digits(5) <> "-" <> digits(4)))
        "JP" -> s(digits(3) <> "-" <> digits(4))
        _ -> s("SW1A #{u(9)}AA")
      end

    lines = if error == :address_lines, do: 5, else: u(3)
    fields = [country: s(country), postal: postal, lines: list(times(lines, fn -> s("#{u(99)} Main St") end))]

    cond do
      error == :geo_range -> put(fields, :geo, "{91.0 10.0}")
      u(2) == 1 -> put(fields, :geo, "{#{float(:rand.uniform() * 170 - 85)} #{float(:rand.uniform() * 350 - 175)}}")
      true -> fields
    end
    |> shape()
  end

  defp org(depth, error) do
    registry = if error == :org_parent_registry and depth == 2, do: s("bad_host!"), else: s("org#{u(99)}.example.com")
    fields = [registry: registry, employees: Integer.to_string(u(5000))]

    if depth < 2 and (error == :org_parent_registry or u(2) == 1),
      do: shape(put(fields, :parent, org(depth + 1, error))),
      else: shape(fields)
  end

  defp party(n, error \\ nil) do
    kind = cond do
      error in [:person_born_late, :language_pattern] -> ":person"
      error == :org_parent_registry -> ":org"
      true -> pick(~w(:person :org))
    end

    details =
      case kind do
        ":person" ->
          born = if error == :person_born_late, do: "2011-01-01", else: "#{1900 + u(110)}-0#{u(9)}-1#{u(9) - 1}"
          langs = Enum.uniq(times(u(3), fn -> pick(~w(:de :en :fr :ja :es)) end)) |> Enum.sort()
          langs = if error == :language_pattern, do: [":deu"], else: langs
          shape(born: ~s|@date "#{born}"|, languages: "@sorted-set @{" <> Enum.join(langs, " ") <> "}")

        ":org" ->
          org(0, error)
      end

    name = if error == :party_name_too_long, do: s(String.duplicate("n", 121)), else: s("Party #{n}")

    shape(
      id: s("pa-" <> String.pad_leading(Integer.to_string(n), 6, "0")),
      name: name,
      kind: kind,
      details: details,
      contacts: list([contact(error) | times(u(2) - 1, fn -> contact(nil) end)]),
      addresses: list(if(error in [:postal_de, :address_lines, :geo_range], do: [address(error)], else: times(u(3) - 1, fn -> address(nil) end)))
    )
  end

  # ---- the ledger ---------------------------------------------------------------------

  defp leg(error) do
    amount = if error == :money_exponent, do: money("1.00001M"), else: if(error == :currency_pattern, do: money(nil, ":euro"), else: money())
    "{#{id()} #{pick(~w(:debit :credit))} #{amount}}"
  end

  defp entry(error) do
    offset = if error == :ledger_offset, do: "+03:00", else: pick(~w(Z +01:00 +02:00))
    fraction = if error == :ledger_resolution, do: ".123456", else: "." <> digits(3)
    day = String.pad_leading(Integer.to_string(u(28)), 2, "0")
    at = ~s|@datetime "2026-10-#{day}T1#{u(9) - 1}:#{u(5)}#{u(9) - 1}:0#{u(9) - 1}#{fraction}#{offset}"|
    legs = if error == :ledger_one_leg, do: [leg(nil)], else: [leg(error), leg(nil) | times(u(3) - 1, fn -> leg(nil) end)]
    checksum = Base.encode64(:rand.bytes(if(error == :ledger_checksum, do: 31, else: 32)))
    fields = [at: at, amount: money(), legs: list(legs), checksum: ~s|@bytes "#{checksum}"|]

    fields
    |> then(&if(u(3) == 1, do: put(&1, :memo, s("memo #{u(99)}")), else: &1))
    |> then(&if(u(3) == 1, do: put(&1, :note, s("note #{u(99)}")), else: &1))
    |> shape()
  end

  # ---- events ----------------------------------------------------------------------------

  defp op(error) do
    pointer = if error == :op_pointer, do: s("a/b"), else: s("/" <> pick(~w(name kind contacts addresses)) <> "/#{u(3) - 1}")
    "{#{pick(~w(:add :remove :replace))} #{pointer} #{scalar()}}"
  end

  defp event(error) do
    type = cond do
      error in [:event_payload_case] -> "created"
      error in [:patch_empty, :op_pointer] -> "updated"
      true -> pick(~w(created updated deleted merged))
    end

    payload =
      case type do
        _ when error == :event_payload_case -> list([op(nil)])
        "created" -> shape(version: Integer.to_string(u(9)), data: party(900_000 + u(99_999)))
        "updated" -> if(error == :patch_empty, do: "[]", else: list([op(error) | times(u(3) - 1, fn -> op(nil) end)]))
        "deleted" -> shape(id: id())
        "merged" -> list(times(u(4) + 1, fn -> id() end))
      end

    shape(type: s(type), at: ~s|@datetime "2026-10-0#{u(9)}T12:00:00Z"|, payload: payload)
  end

  # ---- settings ---------------------------------------------------------------------------

  defp settings(error) do
    flags = if error == :settings_flags, do: ~s|@bytes "#{Base.encode64(:rand.bytes(9))}"|, else: ~s|@bits {"oA==" 3}|
    hosts = ["db#{u(9)}.example.com:5432", "[2001:db8::#{u(9)}]:443"]
    hosts = if error == :settings_hosts, do: hosts ++ [hd(hosts)], else: hosts
    matrix = if error == :matrix_nan, do: "@array[@array[1.0 NaN]]", else: "@array[@array[#{float(:rand.uniform())} 2.0] @array[3.0]]"

    shape(
      flags: flags,
      limits: "@ordered %{max: #{u(100)}, min: 0.5, ratio: 1/3}",
      matrix: matrix,
      schedule: list([~s|{@time "09:00:00" @time "17:30:00.250"}|]),
      ttl: ~s|@duration "#{if(error == :settings_ttl, do: "P31D", else: "P#{u(29)}DT#{u(23)}H")}"|,
      version: s(if(error == :settings_semver, do: "1.2", else: "#{u(9)}.#{u(20)}.#{u(99)}")),
      hosts: list(Enum.map(hosts, &s/1)),
      net: list([~s|@ip "10.0.0.0/8"|, ~s|@ip "2001:db8::#{u(99)}"|]),
      retry: if(error == :settings_retry, do: "4", else: "3"),
      mode: s(if(error == :settings_mode, do: "loose", else: pick(~w(strict lax off))))
    )
  end

  # ---- the universe ---------------------------------------------------------------------

  defp either_tree(depth, error) do
    value =
      cond do
        error == :tree_either_both and depth == 2 -> shape(left: s("a"), right: "1")
        u(2) == 1 -> shape(left: s("leaf #{u(99)}"))
        true -> shape(right: Integer.to_string(u(1000)))
      end

    children =
      if depth >= 2, do: [], else: [either_tree(depth + 1, error) | times(u(2) - 1, fn -> either_tree(depth + 1, nil) end)]

    shape(value: value, children: list(children))
  end

  defp universe(error) do
    parties = for n <- 1..u(3), do: party(n, if(n == 1, do: error))
    parties = if error == :duplicate_party_id, do: parties ++ [party(1)], else: parties

    party_text = party(990_000 + u(9_999), if(error == :attachment_party, do: :party_name_too_long))
    {:ok, party_value} = Dextrin.decode(party_text)
    {:ok, party_bytes} = Dextrin.encode_binary(party_value)

    attachment =
      cond do
        error == :attachment_base64 -> s("not base64!")
        error == :attachment_party or u(2) == 1 -> s(Base.encode64(party_bytes))
        true -> nil
      end

    raw =
      if error == :raw_entry or u(3) == 1 do
        bytes =
          for i <- 1..u(2) do
            {:ok, v} = Dextrin.decode(entry(if(error == :raw_entry and i == 1, do: :ledger_offset)))
            {:ok, b} = Dextrin.encode_binary(v)
            b
          end

        ~s|@bytes "#{Base.encode64(IO.iodata_to_binary(bytes))}"|
      end

    ledger_error = if error in ~w(ledger_offset ledger_resolution ledger_one_leg ledger_checksum money_exponent currency_pattern)a, do: error
    event_error = if error in ~w(event_payload_case patch_empty op_pointer)a, do: error
    program_error = if error in ~w(program_literal_args deep_money)a, do: error
    labels = Enum.uniq(times(u(3), fn -> s("label #{u(20)}") end))

    labels =
      cond do
        error == :labels_duplicate -> labels ++ [hd(labels)]
        error == :labels_empty -> []
        true -> labels
      end

    refs = [~s|@acme.ref #{uuid_id()}| | times(u(3) - 1, fn -> "@acme.ref " <> id() end)]
    refs = if error == :refs_no_uuid, do: [~s|@acme.ref "ab-123456"|], else: refs

    lookup =
      Enum.map_join(Enum.uniq(times(u(3), &symbol/0)), ", ", fn k -> "#{k} => #{node(0)}" end)

    lookup = if error == :lookup_node, do: lookup <> ", zz => @{[1 2]}", else: lookup

    fields = [
      id: if(error == :id_pattern, do: s("AB-12"), else: id()),
      parties: list(parties),
      graph: graph(if(error in ~w(edge_duplicate_id node_key_pattern vertex_weight vertex_tags edge_weight)a, do: error)),
      ledger: list([entry(ledger_error) | times(u(3) - 1, fn -> entry(nil) end)]),
      events: list(if(event_error, do: [event(event_error)], else: times(u(3) - 1, fn -> event(nil) end))),
      program: expr(0, program_error),
      rules: list(if(error == :cond_and_one, do: [condition(0, :cond_and_one)], else: times(u(3) - 1, fn -> condition(1) end))),
      settings: settings(error),
      tree: either_tree(0, error),
      pairs: list(for _ <- 1..u(3), do: "{#{id()} {#{pick(~w(:kg :pcs :m))} #{if(error == :pair_quantity_zero, do: "0", else: quantity())}}}"),
      lookup: "%{" <> lookup <> "}",
      refs: list(refs),
      labels: list(labels)
    ]

    fields = if error == :binding_symbol, do: put(fields, :program, shape(op: ":let", args: list([binding(1, :binding_symbol), expr(1)]))), else: fields
    fields = if attachment, do: put(fields, :attachment, attachment), else: fields
    fields = if raw, do: put(fields, :raw, raw), else: fields
    shape(fields)
  end
end
