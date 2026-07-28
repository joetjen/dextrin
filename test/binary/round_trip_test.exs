defmodule Dextrin.Binary.RoundTripTest do
  @moduledoc """
  Per-type round-trip: `.dxn` text decodes to the same value that
  `.dxnb` decodes back to after an encode/decode cycle. Edge values
  chosen for the corners each type is actually likely to
  break on, not just a happy-path sample.
  """

  use ExUnit.Case, async: true

  @samples [
    {"nil", "nil"},
    {"true", "true"},
    {"integer 0", "0"},
    {"negative integer", "-1"},
    {"bignum beyond 64 bits", "999999999999999999999999999999"},
    {"negative bignum beyond 64 bits", "-999999999999999999999999999999"},
    {"float", "19.99"},
    {"float -0.0", "-0.0"},
    {"NaN", "NaN"},
    {"Infinity", "Infinity"},
    {"-Infinity", "-Infinity"},
    {"decimal", "19.99M"},
    {"decimal negative", "-5M"},
    {"rational", "22/7"},
    {"rational negative numerator", "-22/7"},
    {"empty string", ~s("")},
    {"string with escapes", ~s("a\\"b\\\\c\\nd")},
    {"char", "?a"},
    {"char space sugar", "?s"},
    {"symbol", "foo-bar?"},
    {"namespaced symbol", "geo/Point"},
    {"keyword", ":admin"},
    {"quoted keyword", ~s(:"has space")},
    {"empty list", "[]"},
    {"empty tuple", "{}"},
    {"empty set", "@{}"},
    {"empty map", "%{}"},
    {"nested collections", "[{:a [1 2]} %{b: @{1 2}}]"},
    {"struct positional", "%Point[1, 2]"},
    {"date", "~D[1990-01-01]"},
    {"time no fraction", "~T[12:00:00]"},
    {"time with fraction", "~T[12:00:00.123456]"},
    {"instant", "~U[1990-01-01 00:00:00Z]"},
    {"regex all flags", "~r/^a.b$/imsuxfr"},
    {"ordered map with nested list", "@ordered %{a: 1, b: [1,2,3]}"},
    {"sorted set", "@sorted-set @{3 1 2}"},
    {"array", "@array[1, 2, 3]"},
    {"uuid", ~s(@uuid "550e8400-e29b-41d4-a716-446655440000")},
    {"uri", ~s(@uri "https://example.com/x?y=1")},
    {"bytes", ~s(@bytes "aGVsbG8=")},
    {"bytes that happen to be valid UTF-8", ~s(@bytes "aGVsbG8=")},
    {"datetime positive offset", ~s(@datetime "1990-01-01T13:00:00+02:00")},
    {"datetime negative offset", ~s(@datetime "1990-01-01T13:00:00-05:30")},
    {"duration all fields", ~s(@duration "P1Y2M3W4DT5H6M7.5S")},
    {"duration years only", ~s(@duration "P1Y")},
    {"custom tag", "@my-app/money 100"}
  ]

  for {label, text} <- @samples do
    test "round-trips: #{label}" do
      text = unquote(text)
      assert {:ok, value} = Dextrin.decode(text)
      assert {:ok, encoded} = Dextrin.encode_binary(value)
      assert {:ok, decoded} = Dextrin.decode_binary(encoded)
      assert decoded == value
    end
  end

  # DXN.md §2.5's general value-sharing (CBOR tags 28/29) is
  # implemented — see test/binary/value_sharing_test.exs,
  # not here, since it needs its own fixtures (repeated compound
  # values) rather than the one-off samples this file uses.
end
