defmodule Dextrin.Conformance do
  @moduledoc """
  This implementation's answers to the Dextrin Conformance Suite.

  The suite runs every DXN implementation against the same cases,
  reaching each one through its `conformance` command
  (`mix dextrin.conformance` here) with a JSON request, and reading a
  JSON answer back:

      %{"cases" => [%{"id" => "scalars: an integer", "operation" => "decode", "text" => "42"}]}
      #=> %{"results" => [%{"id" => "scalars: an integer", "canonical" => "42"}]}

  - `"decode"` reads `"text"` and answers its canonical form
    (`Dextrin.Canonical`, `DXN.md` §1.5);
  - `"decode-binary"` reads `"binary"`, a base64 `.dxnb` document, and
    answers its canonical form;
  - `"encode"` reads `"text"` and answers the exact `.dxnb` bytes, as
    base64.

  Any of them may answer `"error"` instead: the error's category
  (`DXN.md` §5), never its message. An error with no category yet is
  answered as `"uncategorised"`, which no case expects, so it shows up
  as a disagreement rather than passing by accident.

  **JSON, not DXN**, on purpose: the suite must never read what an
  implementation said through any implementation's DXN.
  """

  @doc "The answer to `request`, one result per case, in order."
  @spec answer(map()) :: map()
  def answer(%{"cases" => cases}) when is_list(cases) do
    %{"results" => Enum.map(cases, &result/1)}
  end

  defp result(%{"id" => id} = case) do
    Map.put(outcome(case), "id", id)
  end

  defp outcome(%{"operation" => "decode", "text" => text}) do
    with {:ok, value} <- Dextrin.decode(text),
         {:ok, canonical} <- Dextrin.Canonical.print(value) do
      %{"canonical" => canonical}
    else
      {:error, error} -> failed(error)
    end
  end

  defp outcome(%{"operation" => "decode-binary", "binary" => base64}) do
    with {:ok, bytes} <- Base.decode64(base64),
         {:ok, value} <- Dextrin.decode_binary(bytes),
         {:ok, canonical} <- Dextrin.Canonical.print(value) do
      %{"canonical" => canonical}
    else
      :error -> %{"error" => "binary"}
      {:error, error} -> failed(error)
    end
  end

  defp outcome(%{"operation" => "encode", "text" => text}) do
    with {:ok, value} <- Dextrin.decode(text),
         {:ok, bytes} <- Dextrin.encode_binary(value) do
      %{"binary" => Base.encode64(bytes)}
    else
      {:error, error} -> failed(error)
    end
  end

  defp outcome(%{"operation" => operation}),
    do: %{"error" => "unsupported operation #{inspect(operation)}"}

  defp failed([error | _]), do: failed(error)
  defp failed(%Dextrin.Error{category: nil}), do: %{"error" => "uncategorised"}
  defp failed(%Dextrin.Error{category: category}), do: %{"error" => category}
end
