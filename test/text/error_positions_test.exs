defmodule Dextrin.Text.ErrorPositionsTest do
  @moduledoc """
  An error of Dextrin's own found while parsing text -- a map key that
  is not allowed, a value that is not one, a schema violation -- says
  where it is: the line and column of what it is about, from Ichor,
  which places an action's error where its rule or token matched. These
  came back with neither.
  """

  use ExUnit.Case, async: true

  defp position(text, opts \\ []) do
    {:error, %Dextrin.Error{ichor_error: %Ichor.Error{line: line, column: column}} = error} =
      Dextrin.decode(text, opts)

    {error.category, line, column}
  end

  test "a map key that is not allowed is placed at the key" do
    assert position("%{a: 1\n 1.5 => 2}") == {"key/not-allowed", 2, 2}
  end

  test "a uuid that is not one is placed at its tag" do
    assert position(~s|[1 @uuid "nope"]|) == {"syntax", 1, 4}
  end

  test "an impossible date is placed at its sigil" do
    assert position("[\n  ~D[2020-13-45]]") == {"syntax", 2, 3}
  end

  test "a zero denominator is placed at its rational" do
    assert position("%{a: 1/0}") == {"syntax", 1, 6}
  end

  test "a schema violation is placed at its struct" do
    {:ok, doc} = Dextrin.decode("%{U: %schema{a: :string}}")
    {:ok, registry} = Dextrin.Schema.compile(doc)

    assert position(~s|[1\n %U{a: 2}]|, registry: registry) == {"schema/type-mismatch", 2, 2}
  end

  test "and Dextrin.Error.format/1 shows where" do
    {:error, error} = Dextrin.decode("%{a: 1\n 1.5 => 2}")
    assert Dextrin.Error.format(error) =~ "2"
    assert Dextrin.Error.format(error) =~ "^"
  end
end
