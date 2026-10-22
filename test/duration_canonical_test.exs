defmodule Dextrin.DurationCanonicalTest do
  @moduledoc """
  A duration's zero fields are left out when it is written, in text and
  in `.dxnb`, and one that is zero throughout is `PT0S` (DXN.md §1.5).
  Reading keeps what was written: only the writer drops a zero field.
  """

  use ExUnit.Case, async: true

  defp rewritten(text) do
    {:ok, value} = Dextrin.decode(text)
    {:ok, out} = Dextrin.encode(value)
    out
  end

  test "a zero field is left out" do
    assert rewritten(~s|@duration "P1DT0H"|) == ~s|@duration "P1D"|
    assert rewritten(~s|@duration "P0Y2M0DT3H0M0S"|) == ~s|@duration "P2MT3H"|
    assert rewritten(~s|@duration "PT0H30M"|) == ~s|@duration "PT30M"|
  end

  test "a duration that is zero throughout is PT0S" do
    for text <- ["P0D", "P0Y0M", "PT0H", "PT0M0S", "PT0.000S"] do
      assert rewritten(~s|@duration "#{text}"|) == ~s|@duration "PT0S"|, text
    end
  end

  test "a negative field is kept" do
    assert rewritten(~s|@duration "P-1DT0H"|) == ~s|@duration "P-1D"|
    assert rewritten(~s|@duration "PT-0.5S"|) == ~s|@duration "PT-0.5S"|
  end

  test "reading keeps a zero field" do
    assert {:ok, %Dextrin.Duration{days: 0, hours: nil}} = Dextrin.decode(~s|@duration "P0D"|)
  end

  test ".dxnb writes only the fields that are not zero" do
    {:ok, with_zero} = Dextrin.decode(~s|@duration "P1DT0H"|)
    {:ok, without} = Dextrin.decode(~s|@duration "P1D"|)
    assert Dextrin.encode_binary(with_zero) == Dextrin.encode_binary(without)

    {:ok, bin} = Dextrin.encode_binary(with_zero)
    assert {:ok, %Dextrin.Duration{days: 1, hours: nil}} = Dextrin.decode_binary(bin)
  end

  test "an all-zero duration in .dxnb has no field, and reads back as PT0S" do
    {:ok, zero} = Dextrin.decode(~s|@duration "P0D"|)
    {:ok, bin} = Dextrin.encode_binary(zero)
    {:ok, back} = Dextrin.decode_binary(bin)
    assert back == %Dextrin.Duration{}
    assert Dextrin.encode(back) == {:ok, ~s|@duration "PT0S"|}
  end

  test "P0D and PT0S are the same value to a uniqueness check" do
    {:ok, schema} = Dextrin.decode("%{T: {:refine {:list-of :duration} %{unique: true}}}")
    {:ok, registry} = Dextrin.Schema.compile(schema)
    {:ok, value} = Dextrin.decode(~s|[@duration "P0D" @duration "PT0S"]|)
    refute Dextrin.Schema.check(value, registry, "T") == :ok
  end
end
