defmodule Dextrin.Text.Escapes do
  @moduledoc """
  Shared escape-decoding for DXN's `string`/`char`/quoted-`keyword`
  bodies (`DXN.md` §1.1's `escape` production) — one implementation so
  none of the token handlers in `Dextrin.Text.Actions` duplicate it.
  """

  @doc "Decodes a full string/keyword body (text between quotes, quotes already stripped)."
  @spec decode(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def decode(body) when is_binary(body), do: decode(body, [])

  defp decode(<<>>, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp decode(<<"\\", rest::binary>>, acc) do
    case decode_escape(rest) do
      {:ok, char, rest2} -> decode(rest2, [char | acc])
      {:error, _} = err -> err
    end
  end

  defp decode(<<c::utf8, rest::binary>>, acc), do: decode(rest, [<<c::utf8>> | acc])

  @doc "Decodes exactly one escape sequence, the text *after* the leading backslash."
  @spec decode_escape(String.t()) :: {:ok, String.t(), String.t()} | {:error, String.t()}
  def decode_escape(<<"\"", rest::binary>>), do: {:ok, "\"", rest}
  def decode_escape(<<"\\", rest::binary>>), do: {:ok, "\\", rest}
  def decode_escape(<<"n", rest::binary>>), do: {:ok, "\n", rest}
  def decode_escape(<<"t", rest::binary>>), do: {:ok, "\t", rest}
  def decode_escape(<<"r", rest::binary>>), do: {:ok, "\r", rest}
  def decode_escape(<<"0", rest::binary>>), do: {:ok, <<0>>, rest}
  def decode_escape(<<"a", rest::binary>>), do: {:ok, <<7>>, rest}
  def decode_escape(<<"b", rest::binary>>), do: {:ok, <<8>>, rest}
  def decode_escape(<<"f", rest::binary>>), do: {:ok, <<12>>, rest}
  def decode_escape(<<"v", rest::binary>>), do: {:ok, <<11>>, rest}

  def decode_escape(<<"x{", rest::binary>>) do
    case take_hex(rest, []) do
      {hex, <<"}", rest2::binary>>} when hex != [] ->
        codepoint = hex |> IO.iodata_to_binary() |> String.to_integer(16)
        {:ok, <<codepoint::utf8>>, rest2}

      _ ->
        {:error, "invalid \\x{...} escape"}
    end
  end

  def decode_escape(_), do: {:error, "unrecognized escape sequence"}

  defp take_hex(<<c, rest::binary>>, acc) when c in ?0..?9 or c in ?a..?f or c in ?A..?F do
    take_hex(rest, [<<c>> | acc])
  end

  defp take_hex(rest, acc), do: {Enum.reverse(acc), rest}
end
