defmodule Dextrin.Conformance.WorkedExampleTest do
  @moduledoc """
  `DXN.md` §3's worked example — the one document that exercises every
  type at once, the way a real consumer would.
  """

  use ExUnit.Case, async: true

  @source """
  @dxn "1.0"
  %{
    id:      @uuid "550e8400-e29b-41d4-a716-446655440000"
    name:    "Ada Lovelace"
    active:  true
    score:   19.99M
    tags:    @{:admin :staff}
    meta:    @ordered %{created: ~U[1990-01-01 00:00:00Z]}
    address: %Point[51.05, 13.74]
    result:  {:ok, 200}
    handle:  ~r/^[a-z0-9_]{3,20}$/i
  }
  """

  setup do
    {:ok, value} = Dextrin.decode(@source)
    %{value: value}
  end

  test "decodes to a plain map with keyword keys", %{value: value} do
    assert %{} = value
    assert map_size(value) == 9
  end

  test "id is a Dextrin.Uuid", %{value: value} do
    assert %Dextrin.Uuid{} = fetch(value, "id")
    assert Dextrin.Uuid.format(fetch(value, "id")) == "550e8400-e29b-41d4-a716-446655440000"
  end

  test "name is a plain string", %{value: value} do
    assert fetch(value, "name") == "Ada Lovelace"
  end

  test "active is a boolean", %{value: value} do
    assert fetch(value, "active") == true
  end

  test "score is an exact Decimal", %{value: value} do
    assert %Decimal{} = score = fetch(value, "score")
    assert Decimal.to_string(score, :normal) == "19.99"
  end

  test "tags is a set of keywords", %{value: value} do
    assert %MapSet{} = tags = fetch(value, "tags")

    assert MapSet.equal?(
             tags,
             MapSet.new([Dextrin.Keyword.new("admin"), Dextrin.Keyword.new("staff")])
           )
  end

  test "meta is an ordered map preserving field order", %{value: value} do
    assert %Dextrin.OrderedMap{pairs: [{key, created}]} = fetch(value, "meta")
    assert key == Dextrin.Keyword.new("created")
    assert %DateTime{utc_offset: 0} = created
  end

  test "address is an opaque positional struct (no schema registered)", %{value: value} do
    assert %Dextrin.Struct{name: "Point", fields: {:positional, [51.05, 13.74]}} =
             fetch(value, "address")
  end

  test "result is a tuple", %{value: value} do
    assert %Dextrin.Tuple{items: [ok, 200]} = fetch(value, "result")
    assert ok == Dextrin.Keyword.new("ok")
  end

  test "handle is a compiled Regex", %{value: value} do
    assert %Regex{} = handle = fetch(value, "handle")
    assert Regex.match?(handle, "abc_123")
    refute Regex.match?(handle, "AB")
  end

  test "every field round-trips through .dxnb", %{value: value} do
    assert {:ok, encoded} = Dextrin.encode_binary(value)
    assert {:ok, decoded} = Dextrin.decode_binary(encoded)
    # "handle"'s Regex is compiled independently on each side (once by
    # Dextrin.decode/1, once by decode_binary/1 here) -- Elixir's own
    # `Regex.compile!/2` never produces two structs that are `==` to
    # each other for the same source/opts (a distinct opaque
    # `re_pattern` resource per compile), so it's swapped for a plain,
    # comparable tuple on both sides before the equality check.
    normalize = fn map -> Map.new(map, fn {k, v} -> {k, comparable(v)} end) end
    assert normalize.(decoded) == normalize.(value)
  end

  defp fetch(map, key), do: Map.fetch!(map, Dextrin.Keyword.new(key))

  defp comparable(%Regex{} = r), do: {Regex.source(r), Regex.opts(r)}
  defp comparable(other), do: other
end
