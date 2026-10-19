defmodule Dextrin.MapKeyTest do
  @moduledoc """
  `DXN.md` §1.6: a map key is a `string`, `keyword`, `integer`, `uuid`,
  `date`, `bytes`, `symbol` or `char`, and anything else is refused as
  `key/not-allowed` -- in text, in binary, and when encoding.
  """

  use ExUnit.Case, async: true

  alias Dextrin.MapKey

  defp refused(result) do
    assert {:error, %Dextrin.Error{category: "key/not-allowed"}} = result
  end

  describe "which keys are allowed" do
    test "the eight types are" do
      {:ok, uuid} = Dextrin.Uuid.parse("6f9619ff-8b86-d011-b42d-00c04fc964ff")

      for key <- [
            "a",
            :a,
            %Dextrin.Keyword{name: "a"},
            7,
            123_456_789_012_345_678_901_234_567_890,
            uuid,
            ~D[2026-10-17],
            %Dextrin.Bytes{data: <<0, 1>>},
            %Dextrin.Symbol{name: "s"},
            %Dextrin.Char{codepoint: ?c}
          ] do
        assert MapKey.check(key) == :ok, "#{inspect(key)} should be allowed"
      end
    end

    test "nothing else is" do
      for key <- [
            1.5,
            Decimal.new("1.0"),
            %Dextrin.Rational{numerator: 1, denominator: 2},
            nil,
            true,
            false,
            ~T[10:00:00],
            ~U[2026-10-17 10:00:00Z],
            %Dextrin.Uri{value: "https://a"},
            [1, 2],
            %{a: 1},
            %Dextrin.Tuple{items: [1]},
            MapSet.new([1]),
            %Dextrin.CustomTag{name: "money", value: 1}
          ] do
        refused(MapKey.check(key))
      end
    end
  end

  describe "decoding text" do
    test "an allowed key decodes" do
      assert {:ok, %{"a" => 1}} = Dextrin.decode(~s(%{"a" => 1}))
    end

    test "a float, a nil and a list key are refused" do
      refused(Dextrin.decode("%{1.5 => 1}"))
      refused(Dextrin.decode("%{nil => 1}"))
      refused(Dextrin.decode("%{[1 2] => 1}"))
    end

    test "a NaN key is refused, though the keyword :nan is allowed" do
      refused(Dextrin.decode("%{NaN => 1}"))
      assert {:ok, %{nan: 1}} = Dextrin.decode("%{:nan => 1}")
    end

    test "an ordered map refuses the same keys" do
      refused(Dextrin.decode("@ordered %{1.5 => 1}"))
    end
  end

  describe "decoding binary" do
    test "a float key is refused" do
      refused(Dextrin.decode_binary(Base.decode16!("445801A1FB3FF800000000000001")))
    end

    test "a nil key is refused" do
      refused(Dextrin.decode_binary(Base.decode16!("445801A1F601")))
    end

    test "an integer key decodes" do
      {:ok, bytes} = Dextrin.encode_binary(%{7 => 1})
      assert {:ok, %{7 => 1}} = Dextrin.decode_binary(bytes)
    end
  end

  describe "encoding" do
    test "text refuses a float key" do
      refused(Dextrin.encode(%{1.5 => 1}))
    end

    test "binary refuses a float key" do
      refused(Dextrin.encode_binary(%{1.5 => 1}))
    end

    test "an ordered map refuses one too" do
      refused(Dextrin.encode(%Dextrin.OrderedMap{pairs: [{nil, 1}]}))
    end
  end
end
