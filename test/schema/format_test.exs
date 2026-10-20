defmodule Dextrin.Schema.FormatTest do
  @moduledoc """
  `format:`, the superset's group 5 (design/schema-superset.md, Jan,
  2026-10-20): a string in one of a closed set of formats. Each is
  checked the same way in every implementation: by the reader DXN has
  for the tagged value, or by the grammar DXN.md §4.2a gives.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Schema

  defp compiled(type) do
    {:ok, doc} = Dextrin.decode("%{T: #{type}}")
    Schema.compile(doc)
  end

  defp registry(format) do
    {:ok, registry} = compiled("{:refine :string %{format: :#{format}}}")
    registry
  end

  # That `format` takes every string of `good` and refuses every one of `bad`.
  defp check(format, good, bad) do
    r = registry(format)

    for text <- good,
        do: assert(Schema.check(text, r, "T") == :ok, "#{format} should take #{inspect(text)}")

    for text <- bad,
        do: refute(Schema.check(text, r, "T") == :ok, "#{format} should refuse #{inspect(text)}")
  end

  test "dates and times, as DXN reads their tags" do
    check(:date, ["2026-10-20"], ["2026-13-01", "2026-10-20T00:00:00Z", ""])
    check(:time, ["14:30:00", "14:30:00.123456789"], ["24:00:00", "14:30"])

    check(:datetime, ["2026-10-20T14:30:00Z", "2026-10-20T14:30:00+02:00"], [
      "2026-10-20T14:30:00",
      "2026-10-20 14:30:00Z"
    ])

    check(:"local-datetime", ["2026-10-20T14:30:00"], ["2026-10-20T14:30:00Z"])
    check(:duration, ["P1D", "PT2.5S"], ["P", "1D"])
  end

  test "@uuid itself reads only 8-4-4-4-12 hex digits" do
    for bad <- ["123e4567e89b12d3a456426614174000", "123e4567-e89b12d3-a456-4266-14174000"] do
      assert {:error, %Dextrin.Error{category: "syntax"}} = Dextrin.decode(~s|@uuid "#{bad}"|)
    end
  end

  test "uuid, ipv4 and ipv6, as DXN reads @uuid and @ip" do
    check(:uuid, ["123e4567-e89b-12d3-a456-426614174000"], ["123e4567e89b12d3a456426614174000"])
    check(:ipv4, ["192.0.2.1"], ["2001:db8::1", "10.0.0.0/8", "1.2.3"])

    check(:ipv6, ["2001:db8::1", "::ffff:192.0.2.1"], [
      "192.0.2.1",
      "2001:db8::/32",
      "fe80::1%eth0"
    ])
  end

  test "hostname: RFC 1123 labels, 253 characters at most" do
    check(:hostname, ["example.com", "a", "xn--bcher-kva.example", "a-b.c"], [
      "-a.com",
      "a-.com",
      "a..com",
      "example.com.",
      "ex_ample.com",
      "bücher.example",
      String.duplicate("a", 64) <> ".com",
      Enum.join(List.duplicate(String.duplicate("a", 63), 4), ".")
    ])
  end

  test "idn-hostname: labels of letters, digits, marks and hyphens in any script" do
    check(:"idn-hostname", ["bücher.example", "例え.テスト", "example.com"], [
      "-bücher.example",
      "bü cher.example",
      "a..b"
    ])
  end

  test "email: a dot-atom or quoted local part, at a hostname or an address literal" do
    check(
      :email,
      [
        "joe@example.com",
        "first.last+tag@example.com",
        ~s|"joe smith"@example.com|,
        "joe@[192.0.2.1]",
        "joe@[IPv6:2001:db8::1]"
      ],
      [
        "joe",
        "joe@",
        "@example.com",
        ".joe@example.com",
        "jo..e@example.com",
        "joe@example..com",
        "jöe@example.com",
        "joe@[2001:db8::1]",
        String.duplicate("a", 65) <> "@example.com"
      ]
    )
  end

  test "idn-email: an email that may hold characters of any script" do
    check(:"idn-email", ["jöe@bücher.example", "joe@example.com"], ["jöe", "jöe@-bücher.example"])
  end

  test "uri and uri-reference: RFC 3986" do
    check(
      :uri,
      [
        "https://example.com/a/b?q=1#f",
        "mailto:joe@example.com",
        "urn:isbn:0451450523",
        "http://[2001:db8::1]:8080/",
        "http://user:pw@host/%20x"
      ],
      [
        "/relative/path",
        "//example.com",
        "http://exa mple.com",
        "http://[nope]/",
        "1http://x",
        "http://x/%zz"
      ]
    )

    check(:"uri-reference", ["/relative/path", "?q", "#f", "", "../a", "https://example.com"], [
      "a:b c",
      "http://exa mple.com",
      "%zz"
    ])
  end

  test "iri and iri-reference: a uri that may hold characters of any script" do
    check(:iri, ["https://bücher.example/straße"], ["/straße", "https://bü cher.example"])
    check(:"iri-reference", ["/straße", "https://bücher.example"], ["a b"])
  end

  test "uri-template: RFC 6570" do
    check(
      :"uri-template",
      ["https://example.com/{id}", "/s{?q,lang}", "{+path:6}/x", "{list*}", "plain"],
      [
        "{",
        "{}",
        "{a b}",
        "x}",
        "{?}",
        "{a:0}"
      ]
    )
  end

  test "json-pointer and relative-json-pointer: RFC 6901 and its draft" do
    check(:"json-pointer", ["", "/a/b", "/a~0b/c~1d", "/"], ["a", "/a~2", "/~"])
    check(:"relative-json-pointer", ["0", "1/a", "2#", "0/"], ["", "/a", "01", "-1", "1#/a"])
  end

  test "semver: Semantic Versioning 2.0.0" do
    check(:semver, ["1.2.3", "0.0.0", "1.0.0-alpha.1", "1.0.0+build.5", "1.0.0-rc.1+sha.abc"], [
      "1.2",
      "01.2.3",
      "1.2.3-",
      "1.2.3-01",
      "v1.2.3"
    ])
  end

  test "mac: six or eight pairs of hex digits, one separator throughout" do
    check(:mac, ["00:1a:2B:3c:4d:5e", "00-1a-2b-3c-4d-5e", "00:1a:2b:3c:4d:5e:6f:70"], [
      "00:1a:2b-3c:4d:5e",
      "001a2b3c4d5e",
      "00:1a:2b:3c:4d",
      "00:1a:2b:3c:4d:5e:6f"
    ])
  end

  test "host-port: a hostname, an IPv4 address or a bracketed IPv6 one, and a port" do
    check(:"host-port", ["example.com:443", "192.0.2.1:0", "[2001:db8::1]:65535"], [
      "example.com",
      "example.com:65536",
      "example.com:08",
      "2001:db8::1:80",
      ":80"
    ])
  end

  test "a format refuses a value that is no string" do
    {:ok, value} = Dextrin.decode(~s|@uuid "123e4567-e89b-12d3-a456-426614174000"|)
    refute Schema.check(value, registry(:uuid), "T") == :ok
  end

  test "an unknown format is refused when the schema compiles" do
    {:error, %Dextrin.Error{category: "schema/compile", message: message}} =
      compiled("{:refine :string %{format: :regex}}")

    assert message =~ "format"
  end
end
