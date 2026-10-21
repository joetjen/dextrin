defmodule Dextrin.Format do
  @moduledoc """
  The three forms' names on the wire and on disk, and a cheap test of
  whether a body is worth decoding as one -- DXN.md §6, so every
  implementation answers the same.

  A form is `:text` (`.dxn`), `:binary` (`.dxnb`) or `:schema` (`.dxns`).

  `identifies?/2` is a prefix test, not a parse: `true` means "worth
  attempting", never "valid". Its text rule mainly tells DXN from JSON in
  a body that comes without a type, so it accepts only what JSON cannot
  start with: after whitespace, comments and an optional header, a `%` --
  a map, a struct or a schema document. A list or a scalar is DXN too,
  but it overlaps with JSON, and stays unrecognised on purpose (Jan,
  2026-10-20).
  """

  @typedoc "One of DXN's three forms."
  @type form :: :text | :binary | :schema

  @media_types %{
    text: "application/vnd.dxn",
    binary: "application/vnd.dxnb",
    schema: "application/vnd.dxns"
  }

  @doc """
  The media type of `form`.

      iex> Dextrin.Format.media_type(:binary)
      "application/vnd.dxnb"
  """
  @spec media_type(form()) :: String.t()
  def media_type(form) when is_map_key(@media_types, form), do: Map.fetch!(@media_types, form)

  @doc """
  The file extension of `form`, with its dot.

      iex> Dextrin.Format.extension(:schema)
      ".dxns"
  """
  @spec extension(form()) :: String.t()
  def extension(:text), do: ".dxn"
  def extension(:binary), do: ".dxnb"
  def extension(:schema), do: ".dxns"

  @doc """
  The form `media_type` names: one of the three, or text for any type with
  a structured `+dxn` suffix (`application/vnd.acme.event+dxn`). There is
  no `+dxnb` suffix. Media types compare without regard to case; the
  caller strips any parameters (`; charset=...`) first.

      iex> Dextrin.Format.form("application/vnd.acme.event+dxn")
      {:ok, :text}

      iex> Dextrin.Format.form("application/json")
      :error
  """
  @spec form(String.t()) :: {:ok, form()} | :error
  def form(media_type) when is_binary(media_type) do
    type = String.downcase(media_type)

    case Enum.find(@media_types, fn {_form, known} -> known == type end) do
      {form, _known} -> {:ok, form}
      nil -> if suffixed?(type), do: {:ok, :text}, else: :error
    end
  end

  # `type/subtype+dxn`, with something before the suffix.
  defp suffixed?(type), do: Regex.match?(~r{\A[^/\s;]+/[^/\s;+]+[^/\s;]*\+dxn\z}, type)

  @doc """
  Whether `body` is worth decoding as `form`.

  Binary: the envelope's magic, `DX`, and a version byte (DXN.md §2.1).
  Text and schemas: after whitespace (commas included), `#` comments and
  an optional `@dxn "..."` header, the first character is `%`.

      iex> Dextrin.Format.identifies?("# config\\n%{a: 1}", :text)
      true

      iex> Dextrin.Format.identifies?("[1 2]", :text)
      false
  """
  @spec identifies?(binary(), form()) :: boolean()
  def identifies?(<<"DX", _version, _rest::binary>>, :binary), do: true
  def identifies?(_body, :binary), do: false

  def identifies?(body, form) when form in [:text, :schema] and is_binary(body) do
    match?("%" <> _, body |> skip_trivia() |> skip_header() |> skip_trivia())
  end

  # `body` without its leading whitespace and comments.
  defp skip_trivia(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r, ?,], do: skip_trivia(rest)

  defp skip_trivia("#" <> rest) do
    case String.split(rest, "\n", parts: 2) do
      [_comment, after_it] -> skip_trivia(after_it)
      [_comment] -> ""
    end
  end

  defp skip_trivia(body), do: body

  # `body` without a leading header, `@dxn "..."`.
  defp skip_header(body) do
    case Regex.run(~r/\A@dxn[ \t\n\r,]*"[^"\n]*"/, body) do
      [header] -> binary_part(body, byte_size(header), byte_size(body) - byte_size(header))
      nil -> body
    end
  end
end
