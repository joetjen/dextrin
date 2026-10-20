defmodule Dextrin.Text.OneSpellingTest do
  @moduledoc """
  One way to write a value (Jan, 2026-10-20; DXN.md §1.2): dates, times
  and regexes are tags with a string, sigils are gone, timestamp and
  datetime are one type, and times carry nanoseconds -- in text and in
  `.dxnb`, where 0.2's microsecond tags are still read as they were meant.
  """

  use ExUnit.Case, async: true

  defp category({:error, %Dextrin.Error{category: category}}), do: category
  defp category(other), do: other

  defp round_trip(text) do
    {:ok, value} = Dextrin.decode(text)
    {:ok, bytes} = Dextrin.encode_binary(value)
    {:ok, back} = Dextrin.decode_binary(bytes)
    Dextrin.Canonical.print(back)
  end

  describe "sigils are gone" do
    test "every one is refused" do
      for old <- ["~D[2026-10-20]", "~T[12:00:00]", "~U[2026-10-20 12:00:00Z]", "~r/a/i"] do
        assert category(Dextrin.decode(old)) == "syntax", old
      end
    end
  end

  describe "dates and times" do
    test "read and write as ISO 8601 strings under their tag" do
      for text <- [
            ~s|@date "2026-10-20"|,
            ~s|@time "14:30:00.5"|,
            ~s|@datetime "2026-10-20T14:30:00Z"|,
            ~s|@datetime "2026-10-20T16:30:00+02:00"|,
            ~s|@local-datetime "2026-10-20T14:30:00"|,
            ~s|@duration "P1DT2.5S"|
          ] do
        {:ok, value} = Dextrin.decode(text)
        assert Dextrin.Canonical.print(value) == {:ok, text}
      end
    end

    test "a UTC datetime is written Z, whichever way it was given" do
      {:ok, value} = Dextrin.decode(~s|@datetime "2026-10-20T14:30:00+00:00"|)
      assert Dextrin.Canonical.print(value) == {:ok, ~s|@datetime "2026-10-20T14:30:00Z"|}
    end

    test "an unknown offset, -00:00, is refused; a local date-time has none" do
      assert category(Dextrin.decode(~s|@datetime "2026-10-20T14:30:00-00:00"|)) == "syntax"
      assert category(Dextrin.decode(~s|@datetime "2026-10-20T14:30:00"|)) == "syntax"
      assert category(Dextrin.decode(~s|@local-datetime "2026-10-20T14:30:00Z"|)) == "syntax"
    end

    test "nine fraction digits survive text and binary" do
      for text <- [
            ~s|@time "14:30:00.123456789"|,
            ~s|@datetime "2026-10-20T14:30:00.000000001+05:30"|,
            ~s|@local-datetime "1969-12-31T23:59:59.999999999"|,
            ~s|@duration "PT0.000000001S"|
          ] do
        assert round_trip(text) == {:ok, text}, text
      end
    end

    test "a value finer than a microsecond is a Dextrin.Nanos, a coarser one the native type" do
      assert {:ok, %Time{}} = Dextrin.decode(~s|@time "14:30:00.123456"|)

      assert {:ok, %Dextrin.Nanos{nanosecond: 789}} =
               Dextrin.decode(~s|@time "14:30:00.123456789"|)

      assert {:ok, %NaiveDateTime{}} = Dextrin.decode(~s|@local-datetime "2026-10-20T14:30:00"|)
    end
  end

  describe "regex" do
    test "flags in a header, or inline in the pattern; two different values" do
      assert round_trip(~s|@regex(im) "^\\\\d+$"|) == {:ok, ~s|@regex(im) "^\\\\d+$"|}
      assert round_trip(~s|@regex "(?im)^\\\\d+$"|) == {:ok, ~s|@regex "(?im)^\\\\d+$"|}
      {:ok, header} = Dextrin.decode(~s|@regex(i) "a"|)
      {:ok, inline} = Dextrin.decode(~s|@regex "(?i)a"|)
      assert Regex.match?(header, "A") and Regex.match?(inline, "A")
    end

    test "the flags are written in their canonical order" do
      {:ok, value} = Dextrin.decode(~s|@regex(mi) "a"|)
      assert Dextrin.Canonical.print(value) == {:ok, ~s|@regex(im) "a"|}
    end

    test "a header on any other tag, a flag given twice, or an unknown flag is refused" do
      assert category(Dextrin.decode(~s|@uuid(i) "x"|)) == "syntax"
      assert category(Dextrin.decode(~s|@regex(ii) "a"|)) == "syntax"
      assert category(Dextrin.decode(~s|@regex(q) "a"|)) == "syntax"
    end
  end

  describe "0.2's binary" do
    # A tag never changes its meaning (DXN.md §2.3): 0.2 wrote a time as
    # microseconds under 210, a UTC timestamp under 1.
    test "a microsecond time and a tag-1 timestamp read as what they meant" do
      # 210(43_200_000_000): 12:00:00 in microseconds.
      time = <<"DX", 1, 0xD8, 210, 0x1B, 43_200_000_000::64>>
      assert {:ok, ~T[12:00:00.000000]} = Dextrin.decode_binary(time)

      # 1(1_000_000): one second past the epoch, in microseconds.
      utc = <<"DX", 1, 0xC1, 0x1A, 1_000_000::32>>
      assert {:ok, ~U[1970-01-01 00:00:01.000000Z]} = Dextrin.decode_binary(utc)
    end
  end
end
