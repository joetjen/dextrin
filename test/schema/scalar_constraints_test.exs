defmodule Dextrin.Schema.ScalarConstraintsTest do
  @moduledoc """
  Scalar refine keys, the superset's group 5 (design/schema-superset.md,
  Jan, 2026-10-20): lengths and patterns on more types, a decimal's
  precision and exponent, single precision, allowed bits, and ranges on
  dates, times and durations. A constraint on a value it does not apply
  to refuses it, never raises.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Schema

  defp compiled(type) do
    {:ok, doc} = Dextrin.decode("%{T: #{type}}")
    Schema.compile(doc)
  end

  # Whether the value written `text` is a `type`.
  defp takes?(type, text) do
    {:ok, registry} = compiled(type)
    {:ok, value} = Dextrin.decode(text)
    Schema.check(value, registry, "T") == :ok
  end

  describe "a constraint on a value it does not apply to" do
    test "refuses the value" do
      refute takes?("{:refine :any %{min-length: 1}}", "5")
      refute takes?("{:refine :any %{min: 1}}", ~s|"x"|)
      refute takes?("{:refine :any %{pattern: @regex \"a\"}}", "5")
      refute takes?("{:refine :any %{min-count: 1}}", "5")
      refute takes?("{:refine :any %{min-precision: 1}}", "1.5")
    end
  end

  describe "compiling" do
    defp compile_error(type) do
      {:error, %Dextrin.Error{category: "schema/compile", message: message}} = compiled(type)
      message
    end

    test "a key, a unique-by or a resolution that is no name is refused, never raised" do
      assert compile_error("{:refine :string %{1 => 2}}") =~ "key is a name"
      assert compile_error("{:refine {:list-of :any} %{unique-by: 5}}") =~ "unique-by"
      assert compile_error("{:refine :time %{resolution: :fortnight}}") =~ ":millisecond"
    end
  end

  describe "lengths" do
    test "a keyword's or a symbol's is its name's, in codepoints" do
      assert takes?("{:refine :keyword %{max-length: 3}}", ":abc")
      refute takes?("{:refine :keyword %{max-length: 3}}", ":abcd")
      assert takes?("{:refine :symbol %{min-length: 2}}", "ab")
    end

    test "a byte string's is in bytes, a bit run's under :bits in bits" do
      assert takes?("{:refine :bytes %{min-length: 2, max-length: 2}}", ~s|@bytes "AQI="|)
      refute takes?("{:refine :bytes %{max-length: 1}}", ~s|@bytes "AQI="|)
      assert takes?("{:refine :bits %{min-length: 12}}", ~s|@bytes "AQI="|)
      refute takes?("{:refine :bits %{min-length: 17}}", ~s|@bytes "AQI="|)
    end

    test "min-bytes and max-bytes count a string in UTF-8" do
      assert takes?("{:refine :string %{max-length: 1, max-bytes: 2}}", ~s|"é"|)
      refute takes?("{:refine :string %{max-bytes: 1}}", ~s|"é"|)
      assert takes?("{:refine :string %{min-bytes: 2}}", ~s|"é"|)
    end
  end

  describe "pattern" do
    test "matches a keyword's or a symbol's name" do
      assert takes?(~s|{:refine :keyword %{pattern: @regex "^[a-z]+$"}}|, ":abc")
      refute takes?(~s|{:refine :symbol %{pattern: @regex "^[a-z]+$"}}|, "Abc")
    end

    test "matches bytes one character per byte" do
      assert takes?(~s|{:refine :bytes %{pattern: @regex "^\\\\x01\\\\xff$"}}|, ~s|@bytes "Af8="|)
      refute takes?(~s|{:refine :bytes %{pattern: @regex "^\\\\x01$"}}|, ~s|@bytes "Af8="|)
    end
  end

  describe "a decimal's precision and exponent" do
    test "precision counts the coefficient's digits, as written" do
      assert takes?("{:refine :decimal %{max-precision: 3}}", "1.50M")
      refute takes?("{:refine :decimal %{max-precision: 2}}", "1.50M")
      assert takes?("{:refine :decimal %{min-precision: 3}}", "1.50M")
      assert takes?("{:refine :decimal %{min-precision: 1, max-precision: 1}}", "0M")
    end

    test "the exponent is the power of ten the coefficient is scaled by" do
      assert takes?("{:refine :decimal %{min-exponent: -2, max-exponent: -2}}", "1.50M")
      refute takes?("{:refine :decimal %{min-exponent: -1}}", "1.50M")
    end
  end

  describe "float32" do
    test "the float holds in single precision exactly" do
      assert takes?("{:refine :float %{float32: true}}", "1.5")
      refute takes?("{:refine :float %{float32: true}}", "0.1")
      refute takes?("{:refine :float %{float32: true}}", "1.0e300")
      assert takes?("{:refine :float %{float32: true}}", "Infinity")
      assert takes?("{:refine :float %{float32: false}}", "0.1")
    end
  end

  describe "bits" do
    test "an unsigned integer sets only the bits given" do
      rwx = "{:refine :integer %{bits: [0 1 2]}}"
      assert takes?(rwx, "5")
      assert takes?(rwx, "0")
      refute takes?(rwx, "8")
      refute takes?(rwx, "-1")
    end

    test "a byte string numbers its bits from the first byte's lowest" do
      flags = "{:refine :bytes %{bits: [0 9]}}"
      assert takes?(flags, ~s|@bytes "AQI="|)
      refute takes?(flags, ~s|@bytes "Ag=="|)
      assert takes?(flags, ~s|@bytes ""|)
    end
  end

  describe "ranges on dates, times and durations" do
    test "min and max compare values of the same kind" do
      type = ~s|{:refine :date %{min: @date "2026-01-01", exclusive-max: @date "2027-01-01"}}|
      assert takes?(type, ~s|@date "2026-10-20"|)
      refute takes?(type, ~s|@date "2027-01-01"|)
      refute takes?(type, ~s|@date "2025-12-31"|)
    end

    test "datetimes compare as instants, whatever their offsets" do
      type = ~s|{:refine :datetime %{max: @datetime "2026-10-20T12:00:00Z"}}|
      assert takes?(type, ~s|@datetime "2026-10-20T13:00:00+01:00"|)
      refute takes?(type, ~s|@datetime "2026-10-20T12:00:01Z"|)
    end

    test "a time, a local date-time and a duration compare too" do
      assert takes?(~s|{:refine :time %{min: @time "09:00:00"}}|, ~s|@time "09:30:00"|)

      assert takes?(
               ~s|{:refine :local-datetime %{max: @local-datetime "2026-10-20T00:00:00"}}|,
               ~s|@local-datetime "2026-10-19T23:59:59.999999999"|
             )

      assert takes?(~s|{:refine :duration %{max: @duration "PT1H"}}|, ~s|@duration "PT59M"|)
      refute takes?(~s|{:refine :duration %{max: @duration "PT1H"}}|, ~s|@duration "P1D"|)
    end

    test "a duration with years or months, or values of two kinds, compare with nothing" do
      refute takes?(~s|{:refine :duration %{max: @duration "P400D"}}|, ~s|@duration "P1Y"|)
      refute takes?(~s|{:refine :any %{min: @date "2026-01-01"}}|, ~s|@time "12:00:00"|)
      refute takes?(~s|{:refine :any %{min: @date "2026-01-01"}}|, "5")
    end

    test "before-now, after-now and within compare a datetime with the time of the check" do
      assert takes?(
               "{:refine :datetime %{before-now: true}}",
               ~s|@datetime "2000-01-01T00:00:00Z"|
             )

      refute takes?(
               "{:refine :datetime %{after-now: true}}",
               ~s|@datetime "2000-01-01T00:00:00Z"|
             )

      assert takes?(
               "{:refine :datetime %{after-now: true}}",
               ~s|@datetime "2999-01-01T00:00:00Z"|
             )

      refute takes?(
               ~s|{:refine :datetime %{within: @duration "PT1H"}}|,
               ~s|@datetime "2000-01-01T00:00:00Z"|
             )

      {:ok, registry} = compiled(~s|{:refine :datetime %{within: @duration "PT1H"}}|)
      assert Schema.check(DateTime.utc_now(), registry, "T") == :ok
    end

    test "resolution: no part of the value is finer than the unit given" do
      assert takes?("{:refine :time %{resolution: :second}}", ~s|@time "12:00:00"|)
      refute takes?("{:refine :time %{resolution: :second}}", ~s|@time "12:00:00.5"|)

      assert takes?(
               "{:refine :datetime %{resolution: :millisecond}}",
               ~s|@datetime "2026-10-20T12:00:00.123Z"|
             )

      refute takes?(
               "{:refine :datetime %{resolution: :millisecond}}",
               ~s|@datetime "2026-10-20T12:00:00.1234Z"|
             )

      assert takes?("{:refine :duration %{resolution: :second}}", ~s|@duration "PT2S"|)
      refute takes?("{:refine :duration %{resolution: :second}}", ~s|@duration "PT2.5S"|)
    end
  end
end
