# The sizes behind the README's "Why use Dextrin?" table.
#
#     mix run bench/format_sizes.exs
#
# Encodes the same four payloads as DXN text, .dxnb, JSON, BSON,
# MessagePack, CBOR and Protocol Buffers, and prints each size raw and
# gzipped. Deterministic: the
# payloads are built from fixed seeds, so the numbers only change when an
# encoder does.
#
# The formats without a type for a value get their closest equivalent,
# the one an application would really write: JSON a decimal, a date, a
# UUID or bytes as a string (base64 for bytes); BSON and MessagePack a
# UUID and bytes as native binary, a timestamp as BSON's own date
# (milliseconds) or MessagePack's timestamp extension, a decimal as a
# string; CBOR a decimal as its decimal fraction (tag 4), a timestamp as
# epoch seconds (tag 1), a UUID under tag 37; Protocol Buffers -- whose
# schema, not the data, carries the names -- a timestamp as the standard
# Timestamp message and a decimal as a string, with field numbers in key
# order and proto3's rule that a field holding its default is left out.
# BSON, MessagePack, CBOR and Protocol Buffers are encoded by the minimal
# encoders below, written from their specifications (bsonspec.org,
# msgpack/spec.md, RFC 8949, protobuf.dev/programming-guides/encoding) and
# covering only the types these payloads use.

defmodule FormatSizes do
  @moduledoc false

  # ---- payloads -------------------------------------------------------------

  def payloads do
    :rand.seed(:exsss, {2026, 10, 19})

    [
      {"config file", config()},
      {"API response, 100 records", records(100)},
      {"time series, 1,000 points", series(1_000)},
      {"record with a 4 KiB blob", blob(4_096)}
    ]
  end

  defp config do
    %{
      name: "acme-billing",
      version: "2.4.1",
      port: 4_000,
      debug: false,
      timeout_ms: 15_000,
      ratio: 0.75,
      hosts: ["eu-1.acme.example", "eu-2.acme.example", "us-1.acme.example"],
      database: %{url: "postgres://db.acme.example/billing", pool: 10, ssl: true},
      features: %{invoices: true, refunds: true, exports: false}
    }
  end

  defp records(count) do
    for i <- 1..count do
      %{
        id: Dextrin.Uuid.new(:rand.bytes(16)),
        name: "User #{i}",
        email: "user#{i}@example.com",
        created_at: DateTime.add(~U[2026-01-01 00:00:00Z], i * 3_600, :second),
        balance: Decimal.new("#{:rand.uniform(100_000)}.#{:rand.uniform(89) + 10}"),
        active: rem(i, 3) != 0,
        tags: Enum.take(["admin", "staff", "beta", "billing"], rem(i, 4) + 1)
      }
    end
  end

  defp series(count) do
    for i <- 1..count do
      %{at: DateTime.add(~U[2026-10-19 00:00:00Z], i * 60, :second), value: :rand.uniform() * 100}
    end
  end

  defp blob(size) do
    %{name: "avatar.png", type: "image/png", data: Dextrin.Bytes.new(:rand.bytes(size))}
  end

  # ---- encoders ---------------------------------------------------------------

  def encodings(value) do
    [
      {"DXN text", dxn(value, [])},
      {"DXN text, pretty", dxn(value, pretty: true)},
      {".dxnb", dxnb(value, [])},
      {".dxnb, shared", dxnb(value, share: true)},
      {"JSON", JSON.encode!(for_json(value))},
      {"JSON, pretty", pretty_json(for_json(value))},
      {"BSON", bson(%{"v" => value})},
      {"MessagePack", msgpack(value)},
      {"CBOR", cbor(value)},
      {"Protocol Buffers", protobuf(value)}
    ]
  end

  defp dxn(value, opts) do
    {:ok, text} = Dextrin.encode(value, opts)
    text
  end

  defp dxnb(value, opts) do
    {:ok, bytes} = Dextrin.encode_binary(value, opts)
    bytes
  end

  # JSON: the closest equivalent of every value it has no type for.
  defp for_json(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp for_json(%Decimal{} = d), do: Decimal.to_string(d)
  defp for_json(%Dextrin.Uuid{} = u), do: Dextrin.Uuid.format(u)
  defp for_json(%Dextrin.Bytes{data: data}), do: Base.encode64(data)

  defp for_json(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), for_json(v)} end)

  defp for_json(list) when is_list(list), do: Enum.map(list, &for_json/1)
  defp for_json(other), do: other

  # Two-space indentation, one entry per line: what a pretty JSON writer
  # produces.
  defp pretty_json(value), do: pretty_json(value, "")

  defp pretty_json(map, indent) when is_map(map) and map_size(map) > 0 do
    inner = indent <> "  "

    entries =
      Enum.map_join(map, ",\n", fn {k, v} ->
        inner <> JSON.encode!(k) <> ": " <> pretty_json(v, inner)
      end)

    "{\n" <> entries <> "\n" <> indent <> "}"
  end

  defp pretty_json(list, indent) when is_list(list) and list != [] do
    inner = indent <> "  "

    "[\n" <>
      Enum.map_join(list, ",\n", &(inner <> pretty_json(&1, inner))) <> "\n" <> indent <> "]"
  end

  defp pretty_json(other, _indent), do: JSON.encode!(other)

  # BSON (bsonspec.org): a document is int32 length, elements, 0x00; an
  # element is a type byte, a cstring name and the value.
  defp bson(map) when is_map(map) do
    elements = Enum.map(map, fn {k, v} -> bson_element(to_string(k), v) end)
    body = IO.iodata_to_binary(elements)
    <<byte_size(body) + 5::little-32, body::binary, 0>>
  end

  defp bson_element(name, value), do: [bson_type(value), name, 0, bson_value(value)]

  defp bson_type(v) when is_float(v), do: 0x01
  defp bson_type(v) when is_binary(v), do: 0x02
  defp bson_type(%Decimal{}), do: 0x02
  defp bson_type(%DateTime{}), do: 0x09
  defp bson_type(%Dextrin.Uuid{}), do: 0x05
  defp bson_type(%Dextrin.Bytes{}), do: 0x05
  defp bson_type(v) when is_map(v), do: 0x03
  defp bson_type(v) when is_list(v), do: 0x04
  defp bson_type(v) when is_boolean(v), do: 0x08
  defp bson_type(v) when is_integer(v) and v in -0x80000000..0x7FFFFFFF, do: 0x10
  defp bson_type(v) when is_integer(v), do: 0x12

  defp bson_value(v) when is_float(v), do: <<v::little-float-64>>
  defp bson_value(v) when is_binary(v), do: [<<byte_size(v) + 1::little-32>>, v, 0]
  defp bson_value(%Decimal{} = d), do: bson_value(Decimal.to_string(d))
  defp bson_value(%DateTime{} = at), do: <<DateTime.to_unix(at, :millisecond)::little-signed-64>>
  defp bson_value(%Dextrin.Uuid{} = u), do: [<<16::little-32, 4>>, u.bytes]
  defp bson_value(%Dextrin.Bytes{data: data}), do: [<<byte_size(data)::little-32, 0>>, data]
  defp bson_value(v) when is_map(v), do: bson(v)

  defp bson_value(v) when is_list(v),
    do: bson(v |> Enum.with_index() |> Map.new(fn {x, i} -> {i, x} end))

  defp bson_value(true), do: <<1>>
  defp bson_value(false), do: <<0>>

  defp bson_value(v) when is_integer(v) and v in -0x80000000..0x7FFFFFFF,
    do: <<v::little-signed-32>>

  defp bson_value(v) when is_integer(v), do: <<v::little-signed-64>>

  # MessagePack (msgpack/spec.md), the smallest form of each value.
  defp msgpack(value), do: IO.iodata_to_binary(mp(value))

  defp mp(nil), do: <<0xC0>>
  defp mp(false), do: <<0xC2>>
  defp mp(true), do: <<0xC3>>
  defp mp(v) when is_integer(v) and v in 0..127, do: <<v>>
  defp mp(v) when is_integer(v) and v in -32..-1, do: <<v::signed-8>>
  defp mp(v) when is_integer(v) and v in 0..0xFFFF, do: <<0xCD, v::16>>
  defp mp(v) when is_integer(v) and v in 0..0xFFFFFFFF, do: <<0xCE, v::32>>
  defp mp(v) when is_integer(v), do: <<0xD3, v::signed-64>>
  defp mp(v) when is_float(v), do: <<0xCB, v::float-64>>
  defp mp(v) when is_atom(v), do: mp(Atom.to_string(v))
  defp mp(v) when is_binary(v) and byte_size(v) < 32, do: [<<0xA0 + byte_size(v)>>, v]
  defp mp(v) when is_binary(v) and byte_size(v) < 256, do: [<<0xD9, byte_size(v)>>, v]
  defp mp(v) when is_binary(v), do: [<<0xDA, byte_size(v)::16>>, v]
  defp mp(%Decimal{} = d), do: mp(Decimal.to_string(d))
  defp mp(%DateTime{} = at), do: [<<0xD6, 0xFF>>, <<DateTime.to_unix(at)::32>>]
  defp mp(%Dextrin.Uuid{} = u), do: [<<0xC4, 16>>, u.bytes]
  defp mp(%Dextrin.Bytes{data: d}) when byte_size(d) < 256, do: [<<0xC4, byte_size(d)>>, d]
  defp mp(%Dextrin.Bytes{data: d}), do: [<<0xC5, byte_size(d)::16>>, d]

  defp mp(list) when is_list(list) and length(list) < 16,
    do: [<<0x90 + length(list)>> | Enum.map(list, &mp/1)]

  defp mp(list) when is_list(list), do: [<<0xDC, length(list)::16>> | Enum.map(list, &mp/1)]

  defp mp(map) when is_map(map) and map_size(map) < 16,
    do: [<<0x80 + map_size(map)>> | Enum.flat_map(map, fn {k, v} -> [mp(k), mp(v)] end)]

  # CBOR (RFC 8949): a major type and its argument in the fewest bytes.
  defp cbor(value), do: IO.iodata_to_binary(cb(value))

  defp head(major, n) when n < 24, do: <<major::3, n::5>>
  defp head(major, n) when n < 0x100, do: <<major::3, 24::5, n>>
  defp head(major, n) when n < 0x10000, do: <<major::3, 25::5, n::16>>
  defp head(major, n) when n < 0x100000000, do: <<major::3, 26::5, n::32>>
  defp head(major, n), do: <<major::3, 27::5, n::64>>

  defp cb(nil), do: <<0xF6>>
  defp cb(false), do: <<0xF4>>
  defp cb(true), do: <<0xF5>>
  defp cb(v) when is_integer(v) and v >= 0, do: head(0, v)
  defp cb(v) when is_integer(v), do: head(1, -1 - v)
  defp cb(v) when is_float(v), do: <<0xFB, v::float-64>>
  defp cb(v) when is_atom(v), do: cb(Atom.to_string(v))
  defp cb(v) when is_binary(v), do: [head(3, byte_size(v)), v]
  defp cb(%Dextrin.Bytes{data: d}), do: [head(2, byte_size(d)), d]
  defp cb(%Dextrin.Uuid{} = u), do: [head(6, 37), head(2, 16), u.bytes]
  defp cb(%DateTime{} = at), do: [head(6, 1), cb(DateTime.to_unix(at))]

  defp cb(%Decimal{sign: sign, coef: coef, exp: exp}),
    do: [head(6, 4), head(4, 2), cb(exp), cb(sign * coef)]

  defp cb(list) when is_list(list), do: [head(4, length(list)) | Enum.map(list, &cb/1)]

  defp cb(map) when is_map(map),
    do: [head(5, map_size(map)) | Enum.flat_map(map, fn {k, v} -> [cb(k), cb(v)] end)]

  # Protocol Buffers: a message is fields in number order, a field a
  # varint key (number << 3 | wire type) and its value. A list at the
  # top is a message whose one repeated field holds it.
  defp protobuf(list) when is_list(list), do: IO.iodata_to_binary(pb_field(1, list))
  defp protobuf(map), do: IO.iodata_to_binary(pb_message(map))

  defp pb_message(map) do
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.with_index(1)
    |> Enum.map(fn {{_k, v}, number} -> pb_field(number, v) end)
  end

  # proto3 leaves a field out when it holds its type's default.
  defp pb_field(_n, v) when v in [false, 0, "", []], do: []
  defp pb_field(_n, v) when is_float(v) and v == 0.0, do: []
  defp pb_field(n, v) when is_integer(v), do: [varint(n * 8), varint(v)]
  defp pb_field(n, true), do: [varint(n * 8), 1]
  defp pb_field(n, v) when is_float(v), do: [varint(n * 8 + 1), <<v::little-float-64>>]
  defp pb_field(n, v) when is_binary(v), do: delimited(n, v)
  defp pb_field(n, %Decimal{} = d), do: delimited(n, Decimal.to_string(d))
  defp pb_field(n, %Dextrin.Uuid{} = u), do: delimited(n, u.bytes)
  defp pb_field(n, %Dextrin.Bytes{data: d}), do: delimited(n, d)

  defp pb_field(n, %DateTime{} = at),
    do: delimited(n, IO.iodata_to_binary(pb_field(1, DateTime.to_unix(at))))

  defp pb_field(n, map) when is_map(map), do: delimited(n, IO.iodata_to_binary(pb_message(map)))
  defp pb_field(n, list) when is_list(list), do: Enum.map(list, &pb_field(n, &1))

  defp delimited(n, bytes), do: [varint(n * 8 + 2), varint(byte_size(bytes)), bytes]

  defp varint(v) when v < 0x80, do: <<v>>
  defp varint(v), do: <<1::1, Bitwise.band(v, 0x7F)::7, varint(Bitwise.bsr(v, 7))::binary>>

  # ---- report -------------------------------------------------------------------

  def run do
    for {title, value} <- payloads() do
      IO.puts("\n#{title}")

      for {format, encoded} <- encodings(value) do
        IO.puts(
          String.pad_trailing("  " <> format, 22) <>
            String.pad_leading(Integer.to_string(byte_size(encoded)), 8) <>
            String.pad_leading(Integer.to_string(byte_size(:zlib.gzip(encoded))), 8)
        )
      end
    end
  end
end

FormatSizes.run()
