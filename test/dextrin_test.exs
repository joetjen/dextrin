defmodule DextrinTest do
  use ExUnit.Case, async: true

  describe "decode/2 and encode/2 (.dxn text)" do
    test "decodes every scalar type" do
      assert {:ok, nil} = Dextrin.decode("nil")
      assert {:ok, true} = Dextrin.decode("true")
      assert {:ok, false} = Dextrin.decode("false")
      assert {:ok, 42} = Dextrin.decode("42")
      assert {:ok, -42} = Dextrin.decode("-42")
      assert {:ok, 19.99} = Dextrin.decode("19.99")
      assert {:ok, :nan} = Dextrin.decode("NaN")
      assert {:ok, :positive_infinity} = Dextrin.decode("Infinity")
      assert {:ok, :negative_infinity} = Dextrin.decode("-Infinity")
      assert {:ok, %Decimal{}} = Dextrin.decode("19.99M")
      assert {:ok, %Dextrin.Rational{numerator: 22, denominator: 7}} = Dextrin.decode("22/7")
      assert {:ok, "hi"} = Dextrin.decode(~s("hi"))
      assert {:ok, %Dextrin.Char{codepoint: 97}} = Dextrin.decode("?a")
      assert {:ok, %Dextrin.Char{codepoint: 32}} = Dextrin.decode("?s")
      assert {:ok, %Dextrin.Symbol{name: "foo-bar?"}} = Dextrin.decode("foo-bar?")
      assert {:ok, %Dextrin.Keyword{name: "admin"}} = Dextrin.decode(":admin", trusted: false)
      assert {:ok, :admin} = Dextrin.decode(":admin")
    end

    test "decodes every collection type" do
      assert {:ok, [1, 2, 3]} = Dextrin.decode("[1 2 3]")
      assert {:ok, %Dextrin.Tuple{items: [1, 2]}} = Dextrin.decode("{1 2}")
      assert {:ok, %{}} = Dextrin.decode("%{}")
      assert {:ok, %Dextrin.OrderedMap{}} = Dextrin.decode("@ordered %{a: 1}")
      assert {:ok, %MapSet{}} = Dextrin.decode("@{1 2 3}")
      assert {:ok, %Dextrin.SortedSet{items: [1, 2, 3]}} = Dextrin.decode("@sorted-set @{3 1 2}")
      assert {:ok, %Dextrin.Array{items: {1, 2, 3}}} = Dextrin.decode("@array[1, 2, 3]")
    end

    test "decodes struct forms as opaque without a schema" do
      assert {:ok, %Dextrin.Struct{name: "Point", fields: {:keyed, [x: 1, y: 2]}}} =
               Dextrin.decode("%Point{x: 1, y: 2}")

      assert {:ok, %Dextrin.Struct{name: "Point", fields: {:positional, [1, 2]}}} =
               Dextrin.decode("%Point[1, 2]")
    end

    test "an opaque struct's keyed field names follow the same trusted rule as an ordinary map key" do
      assert {:ok, %Dextrin.Struct{fields: {:keyed, [x: 1]}}} =
               Dextrin.decode("%Point{x: 1}")

      assert {:ok, %Dextrin.Struct{fields: {:keyed, [{%Dextrin.Keyword{name: "x"}, 1}]}}} =
               Dextrin.decode("%Point{x: 1}", trusted: false)

      assert {:ok, %Dextrin.Struct{fields: {:keyed, [{"x", 1}]}}} =
               Dextrin.decode(~s(%Point{"x" => 1}), trusted: false)
    end

    test "decodes temporal and extended types" do
      assert {:ok, ~D[1990-01-01]} = Dextrin.decode("~D[1990-01-01]")
      # Precision normalized to 6 always — .dxnb is always
      # integer-microsecond granularity, so a value
      # decoded from text must match that shape regardless of how many
      # fractional digits the source happened to write.
      assert {:ok, ~T[12:00:00.000000]} = Dextrin.decode("~T[12:00:00]")
      assert {:ok, %DateTime{utc_offset: 0}} = Dextrin.decode("~U[1990-01-01 00:00:00Z]")

      assert {:ok, %DateTime{utc_offset: 7200}} =
               Dextrin.decode(~s(@datetime "1990-01-01T13:00:00+02:00"))

      assert {:ok, %Dextrin.Duration{years: 1}} = Dextrin.decode(~s(@duration "P1Y"))

      assert {:ok, %Dextrin.Uuid{}} =
               Dextrin.decode(~s(@uuid "550e8400-e29b-41d4-a716-446655440000"))

      assert {:ok, %Dextrin.Uri{value: "https://example.com"}} =
               Dextrin.decode(~s(@uri "https://example.com"))

      assert {:ok, %Dextrin.Bytes{data: "hello"}} = Dextrin.decode(~s(@bytes "aGVsbG8="))
      assert {:ok, %Regex{}} = Dextrin.decode("~r/a+/i")
    end

    test "custom tags fall back to Dextrin.CustomTag with no registered decoder" do
      assert {:ok, %Dextrin.CustomTag{name: "my-app/money", value: 100}} =
               Dextrin.decode("@my-app/money 100")
    end

    test "discard produces nothing" do
      assert {:ok, 2} = Dextrin.decode("@_ 1 2")
    end

    test "comments are insignificant" do
      assert {:ok, 1} = Dextrin.decode("1 # trailing comment\n")
    end

    test "returns a Dextrin.Error, not a raw Ichor.Error, on invalid syntax" do
      assert {:error, %Dextrin.Error{}} = Dextrin.decode("not valid ]")
    end

    test "encode/2 round-trips through decode/2" do
      for text <- ["42", "%{x: 1, y: 2}", "[1, 2, 3]", ~s("hello")] do
        {:ok, value} = Dextrin.decode(text)
        {:ok, printed} = Dextrin.encode(value)
        {:ok, reparsed} = Dextrin.decode(printed)
        assert value == reparsed
      end
    end

    test "encode/2 defaults to compact, single-line output" do
      assert {:ok, "[1 2 3]"} = Dextrin.encode([1, 2, 3])
    end

    test "encode/2 with pretty: true produces multi-line, indented output" do
      assert {:ok, "[\n  1\n  2\n  3\n]"} = Dextrin.encode([1, 2, 3], pretty: true)
    end

    test "encode/2 with pretty: true and indent: controls spaces per level" do
      assert {:ok, "[\n    1\n    2\n]"} = Dextrin.encode([1, 2], pretty: true, indent: 4)
    end

    test "pretty: true still round-trips to an equal value through decode/2" do
      value = %{
        Dextrin.Keyword.new("a") => [1, 2],
        Dextrin.Keyword.new("b") => %{Dextrin.Keyword.new("c") => 3}
      }

      assert {:ok, pretty} = Dextrin.encode(value, pretty: true, indent: 3)
      assert {:ok, ^value} = Dextrin.decode(pretty, trusted: false)
    end

    test "pretty: and indent: don't change validation -- schema violations still fail either way" do
      {:ok, doc} =
        Dextrin.decode("%{ Point: %schema{ fields: @ordered %{ x: :integer, y: :integer } } }")

      {:ok, registry} = Dextrin.Schema.compile(doc)
      bad = Dextrin.Struct.keyed("Point", [{"x", 1}])

      assert {:error, %Dextrin.Error{}} = Dextrin.encode(bad, registry: registry)
      assert {:error, %Dextrin.Error{}} = Dextrin.encode(bad, registry: registry, pretty: true)
    end

    test "indent: without pretty: true has no effect (still compact)" do
      assert {:ok, "[1 2 3]"} = Dextrin.encode([1, 2, 3], indent: 4)
    end
  end

  describe "decode_binary/2 and encode_binary/2 (.dxnb binary)" do
    test "round-trips a decoded .dxn value through .dxnb" do
      {:ok, value} = Dextrin.decode(~s(%{a: 1, b: [1, 2, 3], c: "hi"}))
      assert {:ok, encoded} = Dextrin.encode_binary(value)
      assert {:ok, ^value} = Dextrin.decode_binary(encoded)
    end

    test "envelope starts with magic \"DX\" and version 1" do
      {:ok, encoded} = Dextrin.encode_binary(42)
      assert <<"DX", 1, _rest::binary>> = encoded
    end

    test "rejects a missing/invalid envelope" do
      assert {:error, %Dextrin.Error{}} = Dextrin.decode_binary(<<0, 0, 0>>)
    end

    test "rejects trailing bytes after the top-level value" do
      {:ok, encoded} = Dextrin.encode_binary(42)
      assert {:error, %Dextrin.Error{}} = Dextrin.decode_binary(encoded <> <<0>>)
    end
  end
end
