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

  - `"format"` reads `"text"` as a `Dextrin.Document` and answers it laid
    out, comments kept (`Dextrin.Document.format/2`), as `"text"`;
  - `"edit"` reads `"text"` as a document, makes its `"edits"` in order,
    and answers the document rendered, as `"text"`. An edit is
    `{"op": "replace" | "delete" | "insert" | "update", ...}` with
    `"path"`, `"value"` and `"where"` written as DXN text, read by this
    implementation's own decoder; `"update"` may say `"on_ambiguity"`. A
    refused edit answers `document/not-found`, `document/exists`,
    `document/ambiguous` or `document/not-a-collection`.

  A case may carry `"schemas"`, `.dxns` sources compiled in order into
  the registry it runs with, and `"strict": true`, which decodes
  strictly (`DXN.md` §4.7).

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
    answered =
      case loaded(Map.get(case, "schemas", [])) do
        {:ok, registry} ->
          outcome(case, registry: registry, strict: Map.get(case, "strict", false))

        {:error, error} ->
          failed(error)
      end

    Map.put(answered, "id", id)
  end

  # A case's schemas, compiled in order into one registry.
  defp loaded(sources) do
    Enum.reduce_while(sources, {:ok, Dextrin.Registry.new()}, fn source, {:ok, registry} ->
      with {:ok, doc} <- Dextrin.decode(source),
           {:ok, registry} <- Dextrin.Schema.compile(doc, registry) do
        {:cont, {:ok, registry}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp outcome(%{"operation" => "decode", "text" => text}, opts) do
    with {:ok, value} <- Dextrin.decode(text, opts),
         {:ok, canonical} <- Dextrin.Canonical.print(value) do
      %{"canonical" => canonical}
    else
      {:error, error} -> failed(error)
    end
  end

  defp outcome(%{"operation" => "decode-binary", "binary" => base64}, opts) do
    with {:ok, bytes} <- Base.decode64(base64),
         {:ok, value} <- Dextrin.decode_binary(bytes, opts),
         {:ok, canonical} <- Dextrin.Canonical.print(value) do
      %{"canonical" => canonical}
    else
      :error -> %{"error" => "binary"}
      {:error, error} -> failed(error)
    end
  end

  defp outcome(%{"operation" => "encode", "text" => text}, opts) do
    with {:ok, value} <- Dextrin.decode(text, opts),
         {:ok, bytes} <- Dextrin.encode_binary(value, registry: opts[:registry]) do
      %{"binary" => Base.encode64(bytes)}
    else
      {:error, error} -> failed(error)
    end
  end

  defp outcome(%{"operation" => "format", "text" => text}, opts) do
    case Dextrin.Document.parse(text, opts) do
      {:ok, doc} -> %{"text" => Dextrin.Document.format(doc)}
      {:error, error} -> failed(error)
    end
  end

  defp outcome(%{"operation" => "edit", "text" => text, "edits" => edits}, opts) do
    with {:ok, doc} <- Dextrin.Document.parse(text, opts),
         {:ok, doc} <- edited(doc, edits, opts) do
      %{"text" => Dextrin.Document.render(doc)}
    else
      {:error, error} -> failed(error)
    end
  end

  defp outcome(%{"operation" => operation}, _opts),
    do: %{"error" => "unsupported operation #{inspect(operation)}"}

  defp edited(doc, edits, opts) do
    Enum.reduce_while(edits, {:ok, doc}, fn edit, {:ok, doc} ->
      case edit_once(doc, edit, opts) do
        {:ok, doc} -> {:cont, {:ok, doc}}
        {:ok, doc, _changes} -> {:cont, {:ok, doc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp edit_once(doc, %{"op" => "replace", "path" => path, "value" => value}, opts) do
    with {:ok, path} <- Dextrin.decode(path, opts),
         {:ok, value} <- Dextrin.decode(value, opts),
         do: Dextrin.Document.replace(doc, path, value)
  end

  defp edit_once(doc, %{"op" => "delete", "path" => path}, opts) do
    with {:ok, path} <- Dextrin.decode(path, opts), do: Dextrin.Document.delete(doc, path)
  end

  defp edit_once(
         doc,
         %{"op" => "insert", "path" => path, "where" => where, "value" => value},
         opts
       ) do
    with {:ok, path} <- Dextrin.decode(path, opts),
         {:ok, where} <- Dextrin.decode(where, opts),
         {:ok, value} <- Dextrin.decode(value, opts),
         do: Dextrin.Document.insert(doc, path, where, value)
  end

  defp edit_once(doc, %{"op" => "update", "value" => value} = edit, opts) do
    with {:ok, mode} <- ambiguity(Map.get(edit, "on_ambiguity", "safe")),
         {:ok, value} <- Dextrin.decode(value, opts),
         do: Dextrin.Document.update(doc, value, on_ambiguity: mode)
  end

  defp ambiguity("safe"), do: {:ok, :safe}
  defp ambiguity("guess"), do: {:ok, :guess}
  defp ambiguity("error"), do: {:ok, :error}

  defp ambiguity(other),
    do: {:error, Dextrin.Error.action("unknown on_ambiguity #{inspect(other)}")}

  defp failed({reason, _path})
       when reason in [:not_found, :exists, :ambiguous, :not_a_collection],
       do: %{"error" => "document/" <> String.replace(Atom.to_string(reason), "_", "-")}

  defp failed([error | _]), do: failed(error)
  defp failed(%Dextrin.Error{category: nil}), do: %{"error" => "uncategorised"}
  defp failed(%Dextrin.Error{category: category}), do: %{"error" => category}
end
