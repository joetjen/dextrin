defmodule Dextrin.Schema.CountTest do
  @moduledoc """
  `min-count` and `max-count` on maps, shapes and structs (T674, Jan,
  2026-11-17): JSON Schema's minProperties and maxProperties, counting
  the entries present.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Schema

  defp registry(text) do
    {:ok, doc} = Dextrin.decode(text)
    {:ok, registry} = Schema.compile(doc)
    registry
  end

  defp takes?(registry, name, text) do
    {:ok, value} = Dextrin.decode(text)
    Schema.check(value, registry, name) == :ok
  end

  test "a map counts its entries" do
    r = registry("%{M: {:refine {:map-of :string :integer} %{min-count: 1 max-count: 2}}}")
    refute takes?(r, "M", "%{}")
    assert takes?(r, "M", ~s|%{"a" => 1}|)
    assert takes?(r, "M", ~s|%{"a" => 1 "b" => 2}|)
    refute takes?(r, "M", ~s|%{"a" => 1 "b" => 2 "c" => 3}|)
  end

  test "a shape counts the fields present and its extras" do
    r = registry("%{S: {:refine %shape{a?: :integer b?: :integer} %{min-count: 1 max-count: 2}}}")
    refute takes?(r, "S", "%{}")
    assert takes?(r, "S", "%{a: 1}")
    refute takes?(r, "S", ~s|%{a: 1 b: 2 "c" => 3}|)
  end

  test "an ordered map counts as a map does" do
    r = registry("%{M: {:refine :ordered-map %{max-count: 1}}}")
    assert takes?(r, "M", "@ordered %{a: 1}")
    refute takes?(r, "M", "@ordered %{a: 1 b: 2}")
  end

  test "a struct counts its fields present and its extras" do
    r =
      registry("""
      %{
        P: %schema{a?: :integer b?: :integer}
        Holder: %schema{p: {:refine P %{min-count: 1}}}
      }
      """)

    assert {:ok, _} = Dextrin.decode("%Holder{p: %P{a: 1}}", registry: r)
    assert {:error, _} = Dextrin.decode("%Holder{p: %P{}}", registry: r)
  end

  test "contains and unique still apply to collections only" do
    {:ok, doc} = Dextrin.decode("%{M: {:refine :map %{unique: true}}}")
    r = elem(Schema.compile(doc), 1)
    refute takes?(r, "M", ~s|%{"a" => 1}|)
  end
end
