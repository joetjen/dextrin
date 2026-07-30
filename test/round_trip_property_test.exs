defmodule Dextrin.RoundTripPropertyTest do
  @moduledoc """
  Property-based companion to the manual round-trip audit that found
  `DateTime`/`Duration`/keyed-struct/`Regex` as genuine exceptions:
  for every value `Dextrin.Generators.dxn_value/0` can produce, both
  `encode/2`/`decode/2` and `encode_binary/2`/`decode_binary/2` MUST
  round-trip to a structurally `==` value. A failure here means an
  actual bug, not a known asymmetry — those are excluded from the
  generator itself (see its own moduledoc).

  `trusted: false` throughout, same reason as
  `Dextrin.RoundTripByTypeTest`: `dxn_value/0` builds `keyword`
  -shaped values as `Dextrin.Keyword`, which only the untrusted decode
  path reconstructs — `trusted: true` (the default) would decode that
  same text back as a plain atom instead.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Dextrin.Generators, only: [dxn_value: 0]

  property "encode/2 then decode/2 returns the original value" do
    check all(value <- dxn_value()) do
      assert {:ok, encoded} = Dextrin.encode(value)
      assert {:ok, ^value} = Dextrin.decode(encoded, trusted: false)
    end
  end

  property "encode_binary/2 then decode_binary/2 returns the original value" do
    check all(value <- dxn_value()) do
      assert {:ok, encoded} = Dextrin.encode_binary(value)
      assert {:ok, ^value} = Dextrin.decode_binary(encoded, trusted: false)
    end
  end

  property "share: true never changes the decoded result, only (at most) the byte size" do
    check all(value <- dxn_value()) do
      assert {:ok, unshared} = Dextrin.encode_binary(value, share: false)
      assert {:ok, shared} = Dextrin.encode_binary(value, share: true)
      assert byte_size(shared) <= byte_size(unshared)
      assert {:ok, ^value} = Dextrin.decode_binary(shared, trusted: false)
    end
  end

  property "pretty: true round-trips to the same value as compact encoding" do
    check all(value <- dxn_value()) do
      assert {:ok, compact} = Dextrin.encode(value)
      assert {:ok, pretty} = Dextrin.encode(value, pretty: true)
      assert {:ok, ^value} = Dextrin.decode(compact, trusted: false)
      assert {:ok, ^value} = Dextrin.decode(pretty, trusted: false)
    end
  end
end
