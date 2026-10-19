# Writes the `.dxnb` fixtures beside it with Dextrin 0.1.3, for the
# releases after it to read back (`test/binary/v0_1_3_test.exs`). Run
# it in a checkout of `v0.1.3`, never against the current code:
#
#     git worktree add ../dextrin-013 v0.1.3
#     cd ../dextrin-013 && mix deps.get
#     mix run ../dextrin/test/fixtures/v0.1.3/generate.exs OUT_DIR
#
# 0.1.3 refused `nil` in an optional field of a positional struct, so
# there is no fixture of a struct with an absent field.
[out] = System.argv()
File.mkdir_p!(out)

values = ~S"""
%{
  int: 42
  neg: -7
  big: 123456789012345678901234567890
  float: 3.25
  dec: 49.99M
  str: "héllo\n"
  sym: abc
  kw: :ok
  t: true
  f: false
  none: nil
  char: ?a
  bytes: @bytes "AAEC"
  uuid: @uuid "9b74c989-1e2a-4b17-9b1f-2a6a4a2b6f10"
  uri: @uri "https://example.com/a?b=1"
  date: ~D[2024-03-15]
  time: ~T[14:22:07]
  ratio: 3/4
  regex: ~r/a+b/i
  custom: @money {12 :eur}
  utc: ~U[2024-03-15 14:22:07Z]
  list: [1 "two" :three]
  tuple: {1 2}
  set: @{:a :b}
  omap: @ordered %{z: 1 a: 2}
  nested: %{inner: [%{deep: 1}]}
  point: %Point[1 2]
}
"""

{:ok, value} = Dextrin.decode(values)
{:ok, bin} = Dextrin.encode_binary(value)
File.write!(Path.join(out, "values.dxnb"), bin)
File.write!(Path.join(out, "values.dxn"), values)

schema = ~S"""
%{
  User: %schema{
    fields: @ordered %{
      name: :string
      email?: :string
      role: %field{type: :keyword default: :member}
    }
  }
}
"""

{:ok, doc} = Dextrin.decode(schema)
{:ok, registry} = Dextrin.Schema.compile(doc)
opts = [registry: registry]
File.write!(Path.join(out, "user.dxns"), schema)

# 0.1.3 decodes a schema struct to a plain map, so a struct is built
# directly, the way an application hands one to the encoder.
for {name, v} <- [
      full: Dextrin.Struct.positional("User", ["Ann", "ann@example.com", :admin]),
      no_email: Dextrin.Struct.positional("User", ["Bob", nil, :member])
    ] do
  case Dextrin.encode_binary(v, opts) do
    {:ok, bin} ->
      File.write!(Path.join(out, "user_#{name}.dxnb"), bin)
      IO.puts("user_#{name}: #{inspect(v)} -> #{Base.encode16(bin)}")

    {:error, e} ->
      IO.puts("user_#{name}: refused #{e.message}")
  end
end

IO.puts("values: #{byte_size(bin)} bytes")
