defmodule Dextrin.Schema.ContentTest do
  @moduledoc """
  Encoded content, the superset's group 5 (design/schema-superset.md,
  Jan, 2026-10-20): `encoding:`, `media-type:` and `content:` on strings
  (JSON Schema's contentEncoding, contentMediaType and contentSchema),
  `encodes:` and `encodes-seq:` on bytes (CDDL's `.cbor` and `.cborseq`).
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

  defp compile_error(type) do
    {:error, %Dextrin.Error{category: "schema/compile", message: message}} = compiled(type)
    message
  end

  defp dxnb(text) do
    {:ok, value} = Dextrin.decode(text)
    {:ok, bytes} = Dextrin.encode_binary(value)
    bytes
  end

  describe "encoding" do
    test "the string is valid in that RFC 4648 encoding" do
      assert takes?("{:refine :string %{encoding: :base64}}", "aGk=")
      refute takes?("{:refine :string %{encoding: :base64}}", "aGk")
      refute takes?("{:refine :string %{encoding: :base64}}", "a-k=")
      assert takes?("{:refine :string %{encoding: :base64url}}", "a-_9")
      assert takes?("{:refine :string %{encoding: :base64url}}", "aGk")
      assert takes?("{:refine :string %{encoding: :base32}}", "NBUQ====")
      refute takes?("{:refine :string %{encoding: :base32}}", "nbuq====")
      assert takes?("{:refine :string %{encoding: :base16}}", "6869")
      assert takes?("{:refine :string %{encoding: :base16}}", "6A6b")
      refute takes?("{:refine :string %{encoding: :base16}}", "686")
    end

    test "an unknown encoding is a compile error" do
      assert compile_error("{:refine :string %{encoding: :rot13}}") =~ "encoding"
    end
  end

  describe "media-type" do
    test "says what the string holds, and checks nothing else" do
      assert takes?(~s|{:refine :string %{media-type: "image/png"}}|, "anything")
      refute takes?(~s|{:refine :string %{media-type: "image/png"}}|, 5)
    end

    test "is a type/subtype name" do
      assert compile_error(~s|{:refine :string %{media-type: "png"}}|) =~ "media-type"
    end
  end

  describe "content" do
    test "the string is a DXN document whose value is a T" do
      type = "{:refine :string %{content: {:list-of :integer}}}"
      assert takes?(type, "[1 2 3]")
      refute takes?(type, ~s|["a"]|)
      refute takes?(type, "[1 2")
    end

    test "with an encoding, the decoded bytes are the document: .dxnb under application/dxnb" do
      type =
        ~s|{:refine :string %{encoding: :base64, media-type: "application/dxnb", content: :integer}}|

      assert takes?(type, Base.encode64(dxnb("42")))
      refute takes?(type, Base.encode64(dxnb(~s|"x"|)))

      text = ~s|{:refine :string %{encoding: :base16, content: :integer}}|
      assert takes?(text, Base.encode16("42"))
    end

    test "any other media type has no reader, and is a compile error" do
      assert compile_error(~s|{:refine :string %{media-type: "application/json", content: :any}}|) =~
               "content"
    end
  end

  describe "encodes" do
    test "the bytes are a .dxnb document whose value is a T" do
      assert takes?(
               "{:refine :bytes %{encodes: {:list-of :integer}}}",
               Dextrin.Bytes.new(dxnb("[1 2]"))
             )

      refute takes?("{:refine :bytes %{encodes: :string}}", Dextrin.Bytes.new(dxnb("[1 2]")))
      refute takes?("{:refine :bytes %{encodes: :any}}", Dextrin.Bytes.new("not dxnb"))
    end

    test "encodes-seq: documents back to back, each a T, none at all too" do
      seq = Dextrin.Bytes.new(dxnb("1") <> dxnb("2") <> dxnb("3"))
      assert takes?("{:refine :bytes %{encodes-seq: :integer}}", seq)
      refute takes?("{:refine :bytes %{encodes-seq: :string}}", seq)
      assert takes?("{:refine :bytes %{encodes-seq: :integer}}", Dextrin.Bytes.new(""))

      refute takes?(
               "{:refine :bytes %{encodes-seq: :integer}}",
               Dextrin.Bytes.new(dxnb("1") <> "DX")
             )
    end

    test "a check inside a decode leaves the decode's own state alone" do
      {:ok, doc} =
        Dextrin.decode(
          "%{Box: %schema{payload: {:refine :bytes %{encodes: :string}}, again: :string}}"
        )

      {:ok, registry} = Schema.compile(doc)
      inner = Base.encode64(dxnb(~s|"shared"|))

      text = ~s|[%Box{payload: @bytes "#{inner}", again: "shared"} "shared"]|
      assert {:ok, [_, "shared"]} = Dextrin.decode(text, registry: registry)

      {:ok, value} = Dextrin.decode(text, registry: registry)
      {:ok, bytes} = Dextrin.encode_binary(value, registry: registry)
      assert {:ok, [_, "shared"]} = Dextrin.decode_binary(bytes, registry: registry)
    end
  end
end
