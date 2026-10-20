defmodule Dextrin.Binary.V013Test do
  @moduledoc """
  `.dxnb` written by Dextrin 0.1.3 still reads (the migration notes of
  0.2.0). The fixtures were written by 0.1.3 itself:
  `test/fixtures/v0.1.3/generate.exs`.
  """

  use ExUnit.Case, async: true

  alias Dextrin.{Registry, Schema, Struct}

  @fixtures Path.expand("../fixtures/v0.1.3", __DIR__)

  # The 0.1.3 `user.dxns`, as 0.2.0 writes it: the body lists the
  # fields in the order `fields: @ordered %{...}` gave them.
  @v1 "%{User: %schema{name: :string, email?: :string, role: %field{type: :keyword, default: :member}}}"
  @v2 "%{User: %schema(2){name: :string, email?: :string, role: :keyword, nick?: :string}}"

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp loaded(sources) do
    Enum.reduce(sources, Registry.new(), fn source, registry ->
      {:ok, doc} = Dextrin.decode(source)
      {:ok, registry} = Schema.compile(doc, registry)
      registry
    end)
  end

  # Two compiled regexes never compare equal, whatever they were
  # compiled from; their source and options do.
  defp comparable({:ok, %{} = map}), do: {:ok, Map.new(map, fn {k, v} -> {k, comparable(v)} end)}
  defp comparable(%Regex{} = regex), do: {Regex.source(regex), Regex.opts(regex)}
  defp comparable(value), do: value

  test "every value 0.1.3 wrote reads back as its text decodes" do
    assert comparable(Dextrin.decode_binary(fixture("values.dxnb"))) ==
             comparable(Dextrin.decode(fixture("values.respelled.dxn")))
  end

  test "a struct 0.1.3 wrote has no version, and reads as version 1 of the same schema" do
    assert Dextrin.decode_binary(fixture("user_full.dxnb"), registry: loaded([@v1])) ==
             {:ok,
              Struct.keyed(
                "User",
                [
                  {"name", "Ann"},
                  {"email", "ann@example.com"},
                  {"role", Dextrin.Keyword.new("admin")}
                ],
                1
              )}
  end

  test "written again, it carries its version" do
    registry = loaded([@v1])
    {:ok, user} = Dextrin.decode_binary(fixture("user_full.dxnb"), registry: registry)
    {:ok, bytes} = Dextrin.encode_binary(user, registry: registry)

    assert bytes =~ "User(1)"
  end

  test "once a version 2 is loaded, a struct without a version is read as version 2" do
    result = Dextrin.decode_binary(fixture("user_full.dxnb"), registry: loaded([@v1, @v2]))

    assert {:error, %Dextrin.Error{category: "schema/field-count"}} = result
  end
end
