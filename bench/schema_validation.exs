# How long decoding and a schema check take, stage by stage, on a schema
# set more complex than any one would meet in practice
# (bench/schemas/universe.dxns).
#
#     mix run bench/schema_validation.exs              # for 10 minutes
#     mix run bench/schema_validation.exs 60           # for 60 seconds
#     mix run bench/schema_validation.exs 60 7         # another seed
#
# In a loop until the time is up: generate a data set
# (bench/support/universe_data.exs: one Universe as DXN text, about 30% of
# them with exactly one error of 44 kinds), then time it, stage by stage:
#
# - lex:    the text into tokens (`Dextrin.Text.Grammar.tokenize/2`);
# - parse:  the tokens into a parse (`parse/2`, less the lexing);
# - build:  the parse into Dextrin's values (`Dextrin.decode/2`, less the
#           parse);
# - decode: text to values, the three together;
# - check:  `Dextrin.Schema.check/3` against Universe;
# - total:  decode and check.
#
# Each stage is the decoder run up to that stage, so a stage's time is a
# difference of two runs, and a short one can come out slightly below
# zero. Generating is not timed. The first 200 data sets warm up, untimed.
# The Node and PHP benchmarks read the very same data sets from
# bench/generate_universes.exs, so the three can be compared.
#
# Every verdict is compared with what the generator meant; a wrong one is
# counted as a mismatch and the run exits 1, so the times are the times of
# correct answers. The report gives each stage's count, total, mean,
# standard deviation, minimum, median, p90, p99, p99.9 and maximum; the
# check and the total for the good and the bad data sets; and the check by
# kind of error. Six data sets are written to tmp/bench/schema-validation/
# as formatted DXN: for the good ones and the bad ones, the fastest, the
# slowest and the one closest to the mean total as the run went.

Code.require_file("support/universe_data.exs", __DIR__)

defmodule SchemaValidation do
  @moduledoc false

  alias Dextrin.Schema
  alias Dextrin.Text.Grammar

  @schemas Path.join(__DIR__, "schemas/universe.dxns")
  @samples "tmp/bench/schema-validation"
  @warm_up 200

  def run(seconds, seed) do
    {:ok, doc} = Dextrin.decode(File.read!(@schemas))
    {:ok, registry} = Schema.compile(doc)
    context = Dextrin.Registry.from_options([])
    UniverseData.seed(seed)

    measure = fn text ->
      {lex, _} = :timer.tc(fn -> Grammar.tokenize(text, context) end, :nanosecond)
      {parse, _} = :timer.tc(fn -> Grammar.parse(text, context) end, :nanosecond)
      {decode, {:ok, value}} = :timer.tc(fn -> Dextrin.decode(text) end, :nanosecond)
      {check, verdict} = :timer.tc(fn -> Schema.check(value, registry, "Universe") end, :nanosecond)

      {verdict == :ok,
       %{lex: lex, parse: parse - lex, build: decode - parse, decode: decode, check: check, total: decode + check}}
    end

    for _ <- 1..@warm_up, do: measure.(elem(UniverseData.data_set(), 0))

    IO.puts("Timing data sets against Universe for #{seconds} s (seed #{seed}, after #{@warm_up} untimed)...")
    deadline = System.monotonic_time(:millisecond) + seconds * 1000
    acc = loop(measure, deadline, Report.new())
    Report.print(acc, [:lex, :parse, :build, :decode, :check, :total], seconds)
    Report.mismatches(acc.wrong)
    Samples.write(acc.samples, @samples, seed)
  end

  defp loop(measure, deadline, acc) do
    if System.monotonic_time(:millisecond) >= deadline do
      acc
    else
      {text, error} = UniverseData.data_set()
      {ok?, times} = measure.(text)
      loop(measure, deadline, Report.add(acc, error, ok?, times, text))
    end
  end
end

defmodule Samples do
  @moduledoc false
  # The fastest, the slowest and the one closest to the running mean total,
  # of the good data sets and of the bad ones, each with its text.

  def new, do: %{good: nil, bad: nil}

  def see(samples, label, ns, data) do
    Map.update!(samples, label, fn
      nil ->
        %{n: 1, sum: ns, fastest: {ns, data}, slowest: {ns, data}, average: {ns, data}}

      s ->
        n = s.n + 1
        sum = s.sum + ns
        mean = sum / n
        {avg_ns, _} = s.average

        %{
          s
          | n: n,
            sum: sum,
            fastest: if(ns < elem(s.fastest, 0), do: {ns, data}, else: s.fastest),
            slowest: if(ns > elem(s.slowest, 0), do: {ns, data}, else: s.slowest),
            average: if(abs(ns - mean) < abs(avg_ns - mean), do: {ns, data}, else: s.average)
        }
    end)
  end

  def write(samples, dir, seed) do
    File.mkdir_p!(dir)

    for {label, s} <- samples, s != nil, which <- [:fastest, :average, :slowest] do
      {ns, {i, error, text}} = Map.fetch!(s, which)
      {:ok, value} = Dextrin.decode(text)
      {:ok, pretty} = Dextrin.encode(value, pretty: true)
      what = if error, do: "error #{error}", else: "no error"
      head = "# Data set ##{i} (seed #{seed}), #{what}: decoded and checked in #{Report.us(ns)} µs.\n"
      File.write!(Path.join(dir, "#{which}-#{label}.dxn"), head <> pretty <> "\n")
    end

    IO.puts("\nSix data sets written to #{dir}/: the fastest, the slowest and the one")
    IO.puts("closest to the mean, of the good ones and of the bad ones.")
  end
end

defmodule Report do
  @moduledoc false

  @head ["", "count", "total ms", "mean µs", "stddev µs", "min µs", "median µs", "p90 µs", "p99 µs", "p99.9 µs", "max µs"]

  def new, do: %{n: 0, stages: %{}, good: %{check: [], total: []}, bad: %{check: [], total: []}, kinds: %{}, wrong: [], samples: Samples.new()}

  def add(acc, error, ok?, times, text) do
    n = acc.n + 1
    label = if error, do: :bad, else: :good
    stages = Enum.reduce(times, acc.stages, fn {stage, ns}, st -> Map.update(st, stage, [ns], &[ns | &1]) end)
    side = Map.fetch!(acc, label)
    side = %{check: [times.check | side.check], total: [times.total | side.total]}
    kinds = if error, do: Map.update(acc.kinds, error, [times.check], &[times.check | &1]), else: acc.kinds
    wrong = if ok? == (error == nil), do: acc.wrong, else: [{n, error, ok?} | acc.wrong]

    acc
    |> Map.merge(%{n: n, stages: stages, kinds: kinds, wrong: wrong})
    |> Map.put(label, side)
    |> Map.put(:samples, Samples.see(acc.samples, label, times.total, {n, error, text}))
  end

  def print(acc, stages, seconds) do
    IO.puts("\n#{fmt_int(acc.n)} data sets in #{seconds} s: #{fmt_int(div(acc.n, max(seconds, 1)))} a second, generating included.\n")
    IO.puts("Each stage, all data sets:\n")
    IO.puts(row(@head))
    for stage <- stages, do: IO.puts(row(stats(Atom.to_string(stage), Map.get(acc.stages, stage, []))))
    IO.puts("\nThe check and the total, good and bad:\n")
    IO.puts(row(@head))

    for {label, side} <- [{"good", acc.good}, {"bad", acc.bad}], {what, times} <- [{"check", side.check}, {"total", side.total}],
        do: IO.puts(row(stats("#{what}, #{label}", times)))

    IO.puts("\nThe check of the bad ones, by error:\n")
    IO.puts(row(@head))
    for {kind, times} <- Enum.sort(acc.kinds), do: IO.puts(row(stats(Atom.to_string(kind), times)))
  end

  def mismatches([]), do: IO.puts("\nEvery verdict matched what the data set was meant to be.")

  def mismatches(wrong) do
    IO.puts("\n#{length(wrong)} verdicts did not match what the data set was meant to be; the first ones:")

    for {i, error, ok?} <- wrong |> Enum.reverse() |> Enum.take(10),
        do: IO.puts("  ##{i}: meant #{error || "good"}, got #{if ok?, do: "ok", else: "refused"}")

    System.halt(1)
  end

  defp stats(name, []), do: [name, "0" | List.duplicate("-", 9)]

  defp stats(name, times) do
    sorted = times |> Enum.sort() |> List.to_tuple()
    n = tuple_size(sorted)
    total = Enum.sum(times)
    mean = total / n
    var = Enum.reduce(times, 0.0, fn t, a -> a + (t - mean) * (t - mean) end) / n
    at = fn q -> elem(sorted, min(n - 1, trunc(q * n))) end

    [name, fmt_int(n), us(total / 1000), us(mean), us(:math.sqrt(var)), us(elem(sorted, 0)),
     us(at.(0.5)), us(at.(0.9)), us(at.(0.99)), us(at.(0.999)), us(elem(sorted, n - 1))]
  end

  # Nanoseconds as microseconds, one decimal; a total given in µs comes out in ms.
  def us(ns), do: :erlang.float_to_binary(ns / 1000, decimals: 1)

  defp row([first | rest]), do: String.pad_trailing(first, 22) <> Enum.map_join(rest, "", &String.pad_leading(&1, 11))

  def fmt_int(n),
    do: n |> Integer.to_string() |> String.reverse() |> String.replace(~r/(\d{3})(?=\d)/, "\\1,") |> String.reverse()
end

{seconds, seed} =
  case System.argv() do
    [s, seed] -> {String.to_integer(s), String.to_integer(seed)}
    [s] -> {String.to_integer(s), 2026}
    [] -> {600, 2026}
  end

SchemaValidation.run(seconds, seed)
