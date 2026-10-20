defmodule Dextrin.ObjectIdIpTest do
  @moduledoc """
  `@objectid` and `@ip`, built in like `@uuid` (Jan, 2026-10-20; DXN.md
  §1.2): readable in text, their raw bytes in `.dxnb`, the smallest form
  that keeps them.
  """

  use ExUnit.Case, async: true

  doctest Dextrin.ObjectId
  doctest Dextrin.Ip

  defp category({:error, %Dextrin.Error{category: category}}), do: category
  defp category(other), do: other

  defp canonical(text) do
    {:ok, value} = Dextrin.decode(text)
    {:ok, printed} = Dextrin.Canonical.print(value)
    printed
  end

  defp binary(text) do
    {:ok, value} = Dextrin.decode(text)
    {:ok, <<"DX", 1, item::binary>>} = Dextrin.encode_binary(value)
    item
  end

  describe "@objectid" do
    test "is 24 hex digits, either case read, lowercase written" do
      assert canonical(~s|@objectid "507F1F77BCF86CD799439011"|) ==
               ~s|@objectid "507f1f77bcf86cd799439011"|
    end

    test "is 12 raw bytes in .dxnb, under tag 221" do
      # 0xD8 0xDD: tag 221; 0x4C: a 12-byte byte string.
      assert <<0xD8, 221, 0x4C, raw::binary-size(12)>> =
               binary(~s|@objectid "507f1f77bcf86cd799439011"|)

      assert Base.encode16(raw, case: :lower) == "507f1f77bcf86cd799439011"

      assert {:ok, %Dextrin.ObjectId{}} =
               Dextrin.decode_binary(<<"DX", 1, 0xD8, 221, 0x4C, raw::binary>>)
    end

    test "anything but 24 hex digits is refused" do
      for bad <- ["507f1f77bcf86cd79943901", "507f1f77bcf86cd79943901g", ""] do
        assert category(Dextrin.decode(~s|@objectid "#{bad}"|)) == "syntax", bad
      end
    end

    test "may be a map key" do
      assert {:ok, _} = Dextrin.decode(~s|%{@objectid "507f1f77bcf86cd799439011" => 1}|)
    end
  end

  describe "@ip" do
    test "an address or a prefix, IPv4 or IPv6, in their canonical text" do
      assert canonical(~s|@ip "192.0.2.1"|) == ~s|@ip "192.0.2.1"|
      assert canonical(~s|@ip "10.0.0.0/8"|) == ~s|@ip "10.0.0.0/8"|
      assert canonical(~s|@ip "2001:DB8:0:0:0:0:0:1"|) == ~s|@ip "2001:db8::1"|
      assert canonical(~s|@ip "2001:db8::/32"|) == ~s|@ip "2001:db8::/32"|
    end

    test "is raw bytes in .dxnb, RFC 9164: an address whole, a prefix trimmed" do
      # 0xD8 0x34: tag 52; 0x44: a 4-byte byte string.
      assert binary(~s|@ip "192.0.2.1"|) == <<0xD8, 52, 0x44, 192, 0, 2, 1>>
      # [8, h'0a']: the length, then the bytes without trailing zeros.
      assert binary(~s|@ip "10.0.0.0/8"|) == <<0xD8, 52, 0x82, 8, 0x41, 10>>
      # 0xD8 0x36: tag 54.
      assert <<0xD8, 54, 0x50, _::binary-size(16)>> = binary(~s|@ip "2001:db8::1"|)

      for text <- [
            ~s|@ip "192.0.2.1"|,
            ~s|@ip "10.0.0.0/8"|,
            ~s|@ip "2001:db8::/32"|,
            ~s|@ip "::/0"|
          ] do
        {:ok, value} = Dextrin.decode(text)
        {:ok, bytes} = Dextrin.encode_binary(value)
        assert Dextrin.decode_binary(bytes) == {:ok, value}, text
      end
    end

    test "a prefix with host bits set, a zone, or a shorthand address is refused" do
      for bad <- ["10.0.0.1/8", "10.0.0.0/33", "fe80::1%eth0", "10.1", "nope"] do
        assert category(Dextrin.decode(~s|@ip "#{bad}"|)) == "syntax", bad
      end
    end
  end

  describe "in schemas" do
    defp registry(type) do
      {:ok, doc} = Dextrin.decode("%{T: %schema{v: #{type}}}")
      {:ok, registry} = Dextrin.Schema.compile(doc)
      registry
    end

    defp takes?(registry, value),
      do: match?({:ok, _}, Dextrin.decode("%T{v: #{value}}", registry: registry))

    test ":objectid and :ip, and an ip's version and prefix" do
      assert takes?(registry(":objectid"), ~s|@objectid "507f1f77bcf86cd799439011"|)
      refute takes?(registry(":objectid"), ~s|"507f1f77bcf86cd799439011"|)

      v6 = registry("{:refine :ip %{version: 6, prefix: false}}")
      assert takes?(v6, ~s|@ip "2001:db8::1"|)
      refute takes?(v6, ~s|@ip "192.0.2.1"|)
      refute takes?(v6, ~s|@ip "2001:db8::/32"|)
    end
  end
end
