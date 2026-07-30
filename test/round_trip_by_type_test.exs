defmodule Dextrin.RoundTripByTypeTest do
  @moduledoc """
  One property per DXN type (as opposed to `Dextrin.RoundTripPropertyTest`'s
  arbitrarily nested mix): each asserts `encode/2`/`decode/2` and
  `encode_binary/2`/`decode_binary/2` return the exact original value
  for *that type specifically*. Splitting them out this way means a
  failure names the exact type at fault instead of an arbitrarily deep,
  possibly-shrunk nested structure — and makes it obvious which types
  are and aren't covered at a glance.

  Types intentionally absent, each for a reason already documented on
  `Dextrin.Generators`: `DateTime`, `Dextrin.Duration`, a keyed
  unregistered `Dextrin.Struct`, `Regex`, a positive-exponent
  `Decimal`, and a zero-coefficient negative `Decimal`.

  `trusted: false` throughout — these generators build `keyword`
  -shaped values as `Dextrin.Keyword` explicitly (matching decode's
  behavior before `trusted:` existed at all), so this suite is now the
  *untrusted*-decode coverage specifically (`Dextrin.Registry`'s
  `trusted: true` default would decode `keyword`/map-key text back as
  a plain atom instead, not the `Dextrin.Keyword` these generators
  construct). See the "bare atom" describe block below for coverage
  of the *default*, trusted behavior.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Dextrin.Generators

  defp assert_round_trips(value) do
    assert {:ok, encoded} = Dextrin.encode(value)
    assert {:ok, ^value} = Dextrin.decode(encoded, trusted: false)

    assert {:ok, bytes} = Dextrin.encode_binary(value)
    assert {:ok, ^value} = Dextrin.decode_binary(bytes, trusted: false)
  end

  property "integer" do
    check all(value <- integer()) do
      assert_round_trips(value)
    end
  end

  property "float" do
    check all(value <- float()) do
      assert_round_trips(value)
    end
  end

  property "string" do
    check all(value <- string(:utf8, max_length: 30)) do
      assert_round_trips(value)
    end
  end

  property "boolean" do
    check all(value <- boolean()) do
      assert_round_trips(value)
    end
  end

  test "nil" do
    assert_round_trips(nil)
  end

  property "decimal" do
    check all(value <- Generators.decimal()) do
      assert_round_trips(value)
    end
  end

  property "rational" do
    check all(value <- Generators.rational()) do
      assert_round_trips(value)
    end
  end

  property "char" do
    check all(value <- Generators.char()) do
      assert_round_trips(value)
    end
  end

  property "bytes" do
    check all(value <- Generators.bytes()) do
      assert_round_trips(value)
    end
  end

  property "symbol" do
    check all(value <- Generators.symbol()) do
      assert_round_trips(value)
    end
  end

  property "keyword" do
    check all(value <- Generators.keyword()) do
      assert_round_trips(value)
    end
  end

  property "uuid" do
    check all(value <- Generators.uuid()) do
      assert_round_trips(value)
    end
  end

  property "uri" do
    check all(value <- Generators.uri()) do
      assert_round_trips(value)
    end
  end

  property "date" do
    check all(value <- Generators.date()) do
      assert_round_trips(value)
    end
  end

  property "custom tag" do
    check all(value <- Generators.custom_tag()) do
      assert_round_trips(value)
    end
  end

  property "list" do
    check all(value <- list_of(Generators.scalar(), max_length: 6)) do
      assert_round_trips(value)
    end
  end

  property "tuple" do
    check all(value <- Generators.dextrin_tuple()) do
      assert_round_trips(value)
    end
  end

  property "array" do
    check all(value <- Generators.dextrin_array()) do
      assert_round_trips(value)
    end
  end

  property "set" do
    check all(value <- Generators.set()) do
      assert_round_trips(value)
    end
  end

  property "sorted-set" do
    check all(value <- Generators.sorted_set()) do
      assert_round_trips(value)
    end
  end

  property "plain map (keyword-shorthand keys)" do
    check all(value <- Generators.plain_map()) do
      assert_round_trips(value)
    end
  end

  property "ordered-map" do
    check all(value <- Generators.ordered_map()) do
      assert_round_trips(value)
    end
  end

  property "positional struct" do
    check all(value <- Generators.positional_struct()) do
      assert_round_trips(value)
    end
  end

  describe "bare atom (DXN.md §1.3: keyword's Elixir type is \"Elixir atom\")" do
    # `trusted: true` is the default (`Dextrin.Registry.put_trusted/2`),
    # so this one *does* use `assert_round_trips/1`'s untrusted opt
    # explicitly reversed — a bare atom round-trips to the exact same
    # atom by default, a genuine, symmetric round trip unlike every
    # other property above.
    property "round-trips to the exact same atom by default (trusted)" do
      check all(value <- Generators.atom()) do
        assert {:ok, encoded} = Dextrin.encode(value)
        assert {:ok, ^value} = Dextrin.decode(encoded)

        assert {:ok, bytes} = Dextrin.encode_binary(value)
        assert {:ok, ^value} = Dextrin.decode_binary(bytes)
      end
    end

    # `trusted: false` falls back to `Dextrin.Keyword` on the way
    # back, same as any other keyword-shaped text — encode never
    # needed to know which way the caller will eventually decode.
    property "decodes back as the equivalent Dextrin.Keyword when explicitly untrusted" do
      check all(value <- Generators.atom()) do
        expected = Dextrin.Keyword.new(Atom.to_string(value))

        assert {:ok, encoded} = Dextrin.encode(value)
        assert {:ok, ^expected} = Dextrin.decode(encoded, trusted: false)

        assert {:ok, bytes} = Dextrin.encode_binary(value)
        assert {:ok, ^expected} = Dextrin.decode_binary(bytes, trusted: false)
      end
    end
  end
end
