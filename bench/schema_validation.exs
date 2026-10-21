# How long a schema check takes, on a schema set that uses most of DXNS.
#
#     mix run bench/schema_validation.exs              # 1,000,000 data sets
#     mix run bench/schema_validation.exs 10000        # fewer
#     mix run bench/schema_validation.exs 10000 7      # another seed
#
# Compiles one schema set -- recursive types (a category tree and a
# JSON-like value), a generic page, shapes with defaults, a case chosen by
# a sibling field, a list's items in order, refine keys (formats, patterns,
# ranges, uniqueness, contains, offsets), sugar, annotations, objectids and
# IP addresses -- then generates COUNT data sets from a fixed seed, about
# 30% of them carrying exactly one error, and checks each with
# `Dextrin.Schema.check/3`. Only the check is timed, one data set at a
# time, in nanoseconds, after 1,000 untimed checks to warm up; generating
# a data set is not timed.
#
# Every verdict is compared with what the generator meant: a data set
# meant to be good that is refused, or one meant to be bad that passes, is
# counted as a mismatch and the run exits 1, so the times are the times of
# correct answers. The report gives, for all data sets, the good ones and
# the bad ones: count, total, mean, standard deviation, minimum, median,
# p90, p99, p99.9 and maximum, then the bad ones by kind of error.

defmodule SchemaValidation do
  @moduledoc false

  alias Dextrin.{Ip, ObjectId, Schema, Uuid}

  @schemas ~S"""
  %{
    Money: %shape{
      amount: {:refine :decimal %{min: 0M, max-exponent: 0, min-exponent: -2}}
      currency: {:doc {:enum "EUR" "USD" "GBP"} %{description: "ISO 4217"}}
    }

    # A tree of categories, each holding more: recursion through a list.
    Category: %shape{
      name: {:refine :string %{min-length: 1, max-length: 40}}
      children: %field{type: {:list-of Category}, default: []}
    }

    # A JSON-like value: recursion through lists and maps.
    Json: {:any-of :nil :boolean :int64 :float {:refine :string %{max-bytes: 256}}
                   {:list-of Json} {:map-of :string Json}}

    Line: %shape{
      sku: {:refine :string %{pattern: @regex "^[A-Z]{3}-[0-9]{5}$"}}
      qty: {:refine :int32 %{min: 1, max: 999}}
      price: Money
      note?: {:refine :string %{max-length: 200}}
    }

    Customer: %shape{
      id: :objectid
      name: {:refine :string %{min-length: 1}}
      email: {:refine :string %{format: :email}}
      vip: %field{type: :boolean, default: false}
    }

    CardDetails: %shape{
      number: {:refine :string %{pattern: @regex "^[0-9]{16}$"}}
      expires: :date
    }
    IbanDetails: %shape{iban: {:refine :string %{min-length: 15, max-length: 34}}}
    VoucherDetails: %shape{code: {:refine :string %{min-length: 8}}}

    Payment: %shape{
      method: {:enum "card" "iban" "voucher"}
      details: {:case method %{
        "card" => CardDetails
        "iban" => IbanDetails
        :else  => VoucherDetails
      }}
    }

    Order: %shape{
      id: :uuid
      customer: Customer
      placed: {:refine :datetime %{offsets: ["Z"]}}
      lines: {:list-items Line {:repeat Line 0 nil}}
      tags?: {:refine {:list-of :string} %{unique: true, max-count: 8}}
      total: Money
      payment: Payment
      category: Category
      meta?: {:map-of :string Json}
      origin?: {:refine :ip %{prefix: false}}
      discount?: {:if :integer {:refine :integer %{min: 0, max: 100}} {:refine :decimal %{min: 0M}}}
      flags: {:refine {:list-of :integer} %{contains: {:const 0}, max-count: 6}}
    }

    Page: {:generic [t] %shape{
      items: {:list-of t}
      next?: {:refine :string %{format: :uri}}
    }}

    Envelope: {:doc %shape{
      kind: {:enum "order" "feed"}
      body: {:case kind %{"order" => Order, "feed" => {:of Page Order}}}
    } %{title: "A message on the bus"}}
  }
  """

  # The errors a bad data set carries, one each; a path names where.
  @errors [
    :currency,
    :negative_amount,
    :amount_exponent,
    :bad_sku,
    :zero_qty,
    :no_lines,
    :bad_email,
    :card_number,
    :case_mismatch,
    :deep_category_name,
    :json_tuple,
    :duplicate_tag,
    :offset,
    :ip_prefix,
    :discount_range,
    :flags_without_zero
  ]

  def run(count, seed) do
    {:ok, doc} = Dextrin.decode(@schemas)
    {:ok, registry} = Schema.compile(doc)
    :rand.seed(:exsss, {seed, 10, 21})

    # Untimed first: the first checks pay once for compiling the format
    # grammars and warming the code, which no later check pays again.
    for _ <- 1..1_000, do: Schema.check(elem(data_set(), 0), registry, "Envelope")

    IO.puts("Checking #{fmt_int(count)} data sets against Envelope (seed #{seed}, after 1,000 untimed)...")
    started = System.monotonic_time(:millisecond)

    {times_good, times_bad, by_kind, mismatches} =
      Enum.reduce(1..count, {[], [], %{}, []}, fn i, {good, bad, kinds, wrong} ->
        {value, error} = data_set()
        t0 = System.monotonic_time(:nanosecond)
        verdict = Schema.check(value, registry, "Envelope")
        ns = System.monotonic_time(:nanosecond) - t0
        ok? = verdict == :ok

        wrong =
          if ok? == (error == nil),
            do: wrong,
            else: [{i, error, verdict} | wrong]

        case error do
          nil -> {[ns | good], bad, kinds, wrong}
          kind -> {good, [ns | bad], Map.update(kinds, kind, [ns], &[ns | &1]), wrong}
        end
      end)

    elapsed = System.monotonic_time(:millisecond) - started
    report(times_good, times_bad, by_kind, elapsed)
    mismatches(mismatches)
  end

  # ---- data -----------------------------------------------------------------

  # A data set, and the error it was given (nil for none): about 30% bad.
  defp data_set do
    kind = if :rand.uniform(10) <= 7, do: nil, else: Enum.random(@errors)
    {envelope(kind), kind}
  end

  defp envelope(error) do
    if :rand.uniform(5) == 1 do
      orders = for _ <- 1..:rand.uniform(3), do: order(nil)
      orders = if error, do: List.replace_at(orders, 0, order(error)), else: orders
      page = %{items: orders}
      page = if :rand.uniform(2) == 1, do: Map.put(page, :next, "https://example.com/feed?page=2"), else: page
      %{kind: "feed", body: page}
    else
      %{kind: "order", body: order(error)}
    end
  end

  defp order(error) do
    lines = for _ <- 1..:rand.uniform(5), do: line()

    order = %{
      id: Uuid.new(:crypto.strong_rand_bytes(16)),
      customer: customer(),
      placed: DateTime.utc_now() |> DateTime.add(-:rand.uniform(100_000_000), :second),
      lines: lines,
      total: money(),
      payment: payment(),
      category: category(0),
      flags: Enum.shuffle([0 | for(_ <- 1..:rand.uniform(4), do: :rand.uniform(9))])
    }

    order
    |> maybe(:tags, fn -> Enum.uniq(for _ <- 1..:rand.uniform(5), do: Enum.random(~w(gift rush fragile bulk eco promo))) end)
    |> maybe(:meta, fn -> %{"source" => json(0), "trace" => json(0)} end)
    |> maybe(:origin, fn -> {:ok, ip} = Ip.parse("192.0.2.#{:rand.uniform(254)}"); ip end)
    |> maybe(:discount, fn -> if :rand.uniform(2) == 1, do: :rand.uniform(100), else: Decimal.new("2.50") end)
    |> corrupt(error)
  end

  defp maybe(map, key, fun), do: if(:rand.uniform(2) == 1, do: Map.put(map, key, fun.()), else: map)

  defp line do
    sku = Enum.map_join(1..3, fn _ -> <<?A + :rand.uniform(26) - 1>> end) <> "-" <> digits(5)
    line = %{sku: sku, qty: :rand.uniform(20), price: money()}
    if :rand.uniform(4) == 1, do: Map.put(line, :note, "leave at the door"), else: line
  end

  defp money do
    cents = :rand.uniform(100_000)
    %{amount: Decimal.new(1, cents, -2), currency: Enum.random(["EUR", "USD", "GBP"])}
  end

  defp customer do
    hex = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    {:ok, id} = ObjectId.parse(hex)
    c = %{id: id, name: "Customer #{:rand.uniform(9999)}", email: "c#{:rand.uniform(9999)}@example.com"}
    if :rand.uniform(3) == 1, do: Map.put(c, :vip, true), else: c
  end

  defp payment do
    case :rand.uniform(3) do
      1 -> %{method: "card", details: %{number: digits(16), expires: Date.add(~D[2027-01-01], :rand.uniform(1000))}}
      2 -> %{method: "iban", details: %{iban: "DE89370400440532013000"}}
      3 -> %{method: "voucher", details: %{code: "SAVE" <> digits(6)}}
    end
  end

  # A tree up to four levels deep.
  defp category(depth) do
    children = if depth < 3, do: for(_ <- 1..Enum.random(0..3)//1, do: category(depth + 1)), else: []
    c = %{name: "Category #{depth}.#{:rand.uniform(99)}"}
    if children == [] and :rand.uniform(2) == 1, do: c, else: Map.put(c, :children, children)
  end

  # A JSON-like value up to three levels deep.
  defp json(depth) do
    case if(depth >= 3, do: :rand.uniform(5), else: :rand.uniform(7)) do
      1 -> nil
      2 -> :rand.uniform(2) == 1
      3 -> :rand.uniform(1_000_000)
      4 -> :rand.uniform() * 100
      5 -> "value #{:rand.uniform(999)}"
      6 -> for _ <- 1..:rand.uniform(3), do: json(depth + 1)
      7 -> Map.new(1..:rand.uniform(3), fn i -> {"k#{i}", json(depth + 1)} end)
    end
  end

  defp digits(n), do: Enum.map_join(1..n, fn _ -> Integer.to_string(:rand.uniform(10) - 1) end)

  # ---- errors -------------------------------------------------------------

  defp corrupt(order, nil), do: order
  defp corrupt(order, :currency), do: put_in(order, [:total, :currency], "JPY")
  defp corrupt(order, :negative_amount), do: put_in(order, [:total, :amount], Decimal.new("-1.00"))
  defp corrupt(order, :amount_exponent), do: put_in(order, [:total, :amount], Decimal.new("1.005"))
  defp corrupt(order, :bad_sku), do: update_in(order, [:lines], &List.replace_at(&1, -1, %{hd(&1) | sku: "abc-12345"}))
  defp corrupt(order, :zero_qty), do: update_in(order, [:lines], &List.replace_at(&1, 0, %{hd(&1) | qty: 0}))
  defp corrupt(order, :no_lines), do: %{order | lines: []}
  defp corrupt(order, :bad_email), do: put_in(order, [:customer, :email], "not an email")
  defp corrupt(order, :card_number), do: %{order | payment: %{method: "card", details: %{number: "1234", expires: ~D[2027-01-01]}}}
  defp corrupt(order, :case_mismatch), do: %{order | payment: %{method: "iban", details: %{code: "SAVE123456"}}}
  defp corrupt(order, :deep_category_name), do: %{order | category: deepen(order.category, String.duplicate("x", 41))}
  defp corrupt(order, :json_tuple), do: Map.put(order, :meta, %{"bad" => [1, %{"k" => {:not, :json}}]})
  defp corrupt(order, :duplicate_tag), do: Map.put(order, :tags, ["gift", "rush", "gift"])
  defp corrupt(order, :offset), do: %{order | placed: elem(Dextrin.decode(~s|@datetime "2026-10-21T13:00:00+01:00"|), 1)}
  defp corrupt(order, :ip_prefix), do: Map.put(order, :origin, elem(Ip.parse("10.0.0.0/8"), 1))
  defp corrupt(order, :discount_range), do: Map.put(order, :discount, 150)
  defp corrupt(order, :flags_without_zero), do: %{order | flags: [1, 2, 3]}

  # The deepest first category, renamed.
  defp deepen(%{children: [child | rest]} = c, name), do: %{c | children: [deepen(child, name) | rest]}
  defp deepen(c, name), do: %{c | name: name}

  # ---- report -------------------------------------------------------------

  defp report(good, bad, by_kind, elapsed) do
    all = good ++ bad
    IO.puts("\nWall clock, generating and checking: #{fmt_int(elapsed)} ms")
    IO.puts("Checks per second: #{fmt_int(div(length(all) * 1_000_000_000, max(Enum.sum(all), 1)))}\n")

    IO.puts(row(["", "count", "total ms", "mean µs", "stddev µs", "min µs", "median µs", "p90 µs", "p99 µs", "p99.9 µs", "max µs"]))
    for {name, times} <- [{"all", all}, {"good", good}, {"bad", bad}], do: IO.puts(row(stats(name, times)))

    IO.puts("\nThe bad ones, by error:\n")
    IO.puts(row(["", "count", "total ms", "mean µs", "stddev µs", "min µs", "median µs", "p90 µs", "p99 µs", "p99.9 µs", "max µs"]))

    for {kind, times} <- Enum.sort(by_kind), do: IO.puts(row(stats(Atom.to_string(kind), times)))
  end

  defp stats(name, []), do: [name, "0" | List.duplicate("-", 9)]

  defp stats(name, times) do
    sorted = Enum.sort(times)
    n = length(sorted)
    total = Enum.sum(sorted)
    mean = total / n
    var = Enum.reduce(sorted, 0.0, fn t, acc -> acc + (t - mean) * (t - mean) end) / n
    at = fn q -> Enum.at(sorted, min(n - 1, trunc(q * n))) end

    [name, fmt_int(n), us(total / 1000), us(mean), us(:math.sqrt(var)), us(hd(sorted)),
     us(at.(0.5)), us(at.(0.9)), us(at.(0.99)), us(at.(0.999)), us(List.last(sorted))]
  end

  # Nanoseconds as microseconds, one decimal; a total as milliseconds.
  defp us(ns), do: :erlang.float_to_binary(ns / 1000, decimals: 1)

  defp row(cells) do
    [first | rest] = cells
    String.pad_trailing(first, 22) <> Enum.map_join(rest, "", &String.pad_leading(&1, 11))
  end

  defp fmt_int(n), do: n |> Integer.to_string() |> String.reverse() |> String.replace(~r/(\d{3})(?=\d)/, "\\1,") |> String.reverse()

  defp mismatches([]), do: IO.puts("\nEvery verdict matched what the data set was meant to be.")

  defp mismatches(wrong) do
    IO.puts("\n#{length(wrong)} verdicts did not match what the data set was meant to be; the first ones:")
    for {i, error, verdict} <- wrong |> Enum.reverse() |> Enum.take(10), do: IO.puts("  ##{i}: meant #{inspect(error || :good)}, got #{inspect(verdict, limit: 5)}")
    System.halt(1)
  end
end

{count, seed} =
  case System.argv() do
    [c, s] -> {String.to_integer(c), String.to_integer(s)}
    [c] -> {String.to_integer(c), 2026}
    [] -> {1_000_000, 2026}
  end

SchemaValidation.run(count, seed)
