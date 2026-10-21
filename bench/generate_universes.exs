# Writes the schema-validation benchmark's data sets to stdout, one per
# line: the error the data set carries (`-` for none), a tab, and the data
# set as DXN text, without end, until the reader stops reading. The Node
# and PHP benchmarks read them, so all three implementations time the very
# same data sets, in the same order as the Elixir benchmark generates them:
#
#     mix run bench/generate_universes.exs 2026 2>/dev/null | node bench/schema-validation.cjs
#
# Argument: SEED (default 2026).

Code.require_file("support/universe_data.exs", __DIR__)

seed =
  case System.argv() do
    [s] -> String.to_integer(s)
    [] -> 2026
  end

UniverseData.seed(seed)

Stream.repeatedly(&UniverseData.data_set/0)
|> Enum.each(fn {text, error} ->
  IO.binwrite([if(error, do: Atom.to_string(error), else: "-"), ?\t, text, ?\n])
end)
