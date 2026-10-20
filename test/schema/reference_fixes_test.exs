defmodule Dextrin.Schema.ReferenceFixesTest do
  @moduledoc """
  What the PHP port's cross-check found in the reference (2026-10-20):
  NaN and the infinities as bounds, `$` before a final newline, a crash
  in `host-port`, hostname lengths in graphemes, an unknown type in
  `inspect`'s words -- and a trusted decode reading six keywords as the
  values whose atoms they share.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Schema

  defp compiled(type) do
    {:ok, doc} = Dextrin.decode("%{T: #{type}}")
    Schema.compile(doc)
  end

  defp takes?(type, value) do
    {:ok, registry} = compiled(type)
    Schema.check(value, registry, "T") == :ok
  end

  test "NaN and the infinities are numbers in a schema, bounds like any other" do
    assert {:ok, _} = compiled("{:refine :float %{max: Infinity}}")
    assert takes?("{:refine :float %{min: -Infinity}}", 1.0)
    refute takes?("{:refine :float %{min: NaN}}", 1.0)
    assert takes?("{:enum NaN}", :nan)
  end

  test "a grammar's end is the string's end: a final newline is refused" do
    # A json-pointer's tokens may hold a newline, so it is no example.
    for format <- ~w(hostname semver mac uri email uri-template host-port) do
      good =
        %{
          "hostname" => "example.com",
          "semver" => "1.2.3",
          "mac" => "00:1a:2b:3c:4d:5e",
          "uri" => "https://example.com",
          "email" => "a@example.com",
          "uri-template" => "/{id}",
          "host-port" => "a:80"
        }[format]

      assert takes?("{:refine :string %{format: :#{format}}}", good), format
      refute takes?("{:refine :string %{format: :#{format}}}", good <> "\n"), format
    end
  end

  test "dates and times read no final newline either" do
    for {format, text} <- [
          {"date", "2026-10-20"},
          {"time", "12:00:00"},
          {"datetime", "2026-10-20T12:00:00Z"},
          {"local-datetime", "2026-10-20T12:00:00"},
          {"duration", "P1D"}
        ] do
      refute takes?("{:refine :string %{format: :#{format}}}", text <> "\n"), format
      assert {:error, _} = Dextrin.decode(~s|@#{format} "#{text}\\n"|), format
    end
  end

  test "an offset and a media type in a schema end where the string does" do
    assert {:error, _} = compiled(~s|{:refine :datetime %{offsets: ["Z\\n"]}}|)
    assert {:error, _} = compiled(~s|{:refine :string %{media-type: "a/b\\n"}}|)
  end

  test "a hostname's 253 are codepoints" do
    label = String.duplicate("é", 31)
    name = Enum.join(List.duplicate(label, 4), ".") <> ".ab"
    assert String.length(name) <= 253 and length(String.to_charlist(name)) > 253
    refute takes?("{:refine :string %{format: :idn-hostname}}", name)
  end

  test "an unknown type is written in DXN in its message" do
    {:error, %Dextrin.Error{message: message}} = compiled("{:list-of :nope}")
    assert message =~ ":nope"
    refute message =~ "Dextrin.Keyword"
  end

  describe "a trusted decode" do
    defp trusted(text), do: Dextrin.decode(text, trusted: true)

    test "keeps a keyword named like NaN, an infinity, nil, true or false a keyword" do
      for name <- ~w(nan positive_infinity negative_infinity nil true false) do
        assert {:ok, %Dextrin.Keyword{name: ^name}} = trusted(":#{name}"), name
        {:ok, value} = trusted(":#{name}")
        {:ok, bytes} = Dextrin.encode_binary(value)
        assert {:ok, %Dextrin.Keyword{name: ^name}} = Dextrin.decode_binary(bytes, trusted: true)
      end
    end

    test "still reads every other keyword as its atom, and NaN, nil and true as themselves" do
      assert {:ok, :ok} = trusted(":ok")
      assert {:ok, :nan} = trusted("NaN")
      assert {:ok, nil} = trusted("nil")
      assert {:ok, true} = trusted("true")
    end
  end
end
