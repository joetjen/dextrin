defmodule Dextrin.Schema.Docs do
  @moduledoc """
  HTML documentation for a directory of `.dxns` schema documents: a small
  static site -- an index of the namespaces, and a page for each, every
  schema, shape and named type on it anchored, every reference a link,
  every version of a schema shown (Jan, 2026-10-20).

  It reads the documents' **source**, not their compiled schemas, so it
  documents what a person wrote -- comments, the order of fields, a
  type as it was spelled -- and needs no schema to compile.

  ## Names

  A definition's name comes from where its file lies under the root, by
  the conventions of DXN.md §4.6:

  - `acme/shop/Customer-v2.dxns`, `acme/shop/Order/v1.dxns` and
    `acme.shop.Product.dxns` each hold one definition, the entry named
    like the file: `acme.shop/Customer`, `acme.shop/Order`,
    `acme.shop/Product`. Every other entry in such a file is **internal**
    to that definition: it uses them, and no file name leads to them.
  - `acme.common.dxns`, whose entries are not named like it, is a
    *namespace file*: each entry is `acme.common/<entry>`.
  - `HealthCheck.dxns` holding `HealthCheck` is a name with no
    namespace.

  ## Comments

  A definition's documentation is its comments (see
  `Dextrin.Schema.Docs.Comments`), written in the Markdown subset of
  `Dextrin.Schema.Docs.Markdown`; a code span naming a definition links
  to it. A namespace file's leading comments describe its namespace; any
  other file's describe the version of the definition it holds.
  """

  alias Dextrin.Schema.Docs.{Comments, Html}
  alias Ichor.Syntax.{Node, Token}

  @typedoc "A page of the site: its path under the output directory, and its content."
  @type page :: {Path.t(), iodata()}

  @doc """
  The documentation of every `.dxns` file under `root`, as pages.

  `opts`: `:title`, the site's name (the root directory's name when not
  given).
  """
  @spec site(Path.t(), keyword()) :: {:ok, [page()]} | {:error, String.t()}
  def site(root, opts \\ []) do
    files =
      root
      |> Path.join("**/*.dxns")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.sort()

    with {:ok, read} <- read_all(root, files) do
      title = Keyword.get(opts, :title, Path.basename(Path.expand(root)))
      {:ok, Html.pages(title, model(read))}
    end
  end

  @doc """
  The documentation of every `.dxns` file under `root`, written to `out`:
  the paths it wrote, or why it could not.
  """
  @spec write(Path.t(), Path.t(), keyword()) :: {:ok, [Path.t()]} | {:error, String.t()}
  def write(root, out, opts \\ []) do
    with {:ok, pages} <- site(root, opts) do
      written =
        for {path, content} <- pages do
          target = Path.join(out, path)
          File.mkdir_p!(Path.dirname(target))
          File.write!(target, content)
          target
        end

      {:ok, written}
    end
  end

  # ---- reading ---------------------------------------------------------------

  defp read_all(root, files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case read_file(root, file) do
        {:ok, read} -> {:cont, {:ok, [read | acc]}}
        {:error, why} -> {:halt, {:error, "#{file}: #{why}"}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # One file: where its names come from, what it says about itself, and
  # its entries.
  defp read_file(root, file) do
    with {:ok, source} <- File.read(Path.join(root, file)),
         {:ok, doc} <- parse(source),
         {:ok, map} <- top_map(doc.tree) do
      entries = entries_of(map)
      {stem, version} = stem_of(file)

      {:ok,
       %{
         file: file,
         stem: stem,
         file_version: version,
         leading: Comments.leading(doc.tree.children),
         entries: entries
       }}
    else
      {:error, %{message: message}} -> {:error, message}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp parse(source), do: Dextrin.Document.parse(source)

  defp top_map(%Node{children: children}) do
    with %Node{rule: :value} = value <- Enum.find(children, &match?(%Node{rule: :value}, &1)),
         %Node{rule: :map_lit} = map <- body(value) do
      {:ok, map}
    else
      _ -> {:error, "a .dxns document is a map of names to schemas and types"}
    end
  end

  # The node a `value` holds: a collection, a struct, a tag or a scalar.
  @doc false
  def body(%Node{rule: :value, children: children}) do
    case Enum.find(children, &match?(%Node{rule: :value_body}, &1)) do
      %Node{children: [inner | _]} -> inner
      _ -> nil
    end
  end

  def body(_other), do: nil

  # The entries of a map node, each with its key, its value and its
  # comments.
  defp entries_of(%Node{children: children}) do
    nodes = Enum.filter(children, &match?(%Node{rule: :map_entry}, &1))

    Enum.zip_with(nodes, Comments.attached(children), fn node, comments ->
      %{key: key_of(node), value: value_of(node), doc: doc_text(comments)}
    end)
  end

  defp doc_text(%{above: above, after: after_lines}),
    do: (above ++ after_lines) |> Enum.join("\n") |> String.trim()

  @doc false
  def key_of(%Node{children: children}) do
    case Enum.reject(children, &match?(%Token{trivia: true}, &1)) do
      [%Token{name: :MAP_KEY, text: text} | _] -> String.trim_trailing(text, ":")
      [%Node{} = key | _] -> key |> text() |> String.trim("\"")
    end
  end

  @doc false
  def value_of(%Node{children: children}),
    do: children |> Enum.filter(&match?(%Node{rule: :value}, &1)) |> List.last()

  @doc "The tokens under `node`, written together without trivia."
  @spec text(Node.t() | Token.t()) :: String.t()
  def text(%Token{trivia: true}), do: ""
  def text(%Token{text: text}), do: text
  def text(%Node{children: children}), do: Enum.map_join(children, &text/1)

  # A file's dotted stem and the version its name says: `acme/shop/
  # Customer-v2.dxns` is `["acme", "shop", "Customer"]` at 2,
  # `acme/shop/Order/v1.dxns` `["acme", "shop", "Order"]` at 1, and a file
  # whose name says no version, nil.
  defp stem_of(file) do
    parts = file |> String.replace_suffix(".dxns", "") |> Path.split()
    {dirs, [last]} = Enum.split(parts, -1)

    {name_parts, version} =
      cond do
        dirs != [] and Regex.match?(~r/^v[1-9][0-9]*$/, last) ->
          {dirs, last |> String.trim_leading("v") |> String.to_integer()}

        match = Regex.run(~r/^(.+)-v([1-9][0-9]*)$/, last) ->
          [_, base, n] = match
          {dirs ++ [base], String.to_integer(n)}

        true ->
          {dirs ++ [last], nil}
      end

    {Enum.flat_map(name_parts, &String.split(&1, ".")), version}
  end

  # ---- the model -------------------------------------------------------------

  # Every definition, by name, with its versions merged.
  defp model(files) do
    files
    |> Enum.flat_map(&definitions_of/1)
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {_name, parts} -> merge(parts) end)
    |> Enum.sort_by(& &1.name)
  end

  # The definitions one file holds, each knowing how to resolve a bare
  # name: an entry beside it, or a name of its own.
  #
  # The names are the ones every reader of a tree gives them
  # (`Dextrin.Schema.Layout`, DXN.md §4.6).
  defp definitions_of(%{entries: entries} = file) do
    layout = Dextrin.Schema.Layout.of(file.file, Enum.map(entries, & &1.key))
    names = layout.names
    holder = layout.holder
    own = holder
    owner = holder && Map.fetch!(names, holder)

    for %{key: key, value: written, doc: doc} <- entries do
      name = Map.fetch!(names, key)
      internal_to = if holder && key != own, do: owner
      {value, notes} = undoc(written)
      {kind, version, fields} = classify(value, file.file_version)

      %{
        name: name,
        short: key,
        namespace: if(internal_to, do: namespace_of(owner), else: namespace_of(name)),
        kind: kind,
        internal_to: internal_to,
        doc: doc,
        scope: names,
        namespace_note: if(holder, do: nil, else: file.leading),
        versions: [
          %{
            version: version,
            file: file.file,
            note: if(holder && key == own, do: file.leading, else: nil),
            fields: fields,
            value: value,
            annotations: notes
          }
        ]
      }
    end
  end

  @doc """
  A value node without the `{:doc T %{...}}` around it, and what the doc
  says (DXN.md §4.1b): its annotations by name, each value decoded --
  `%{}` for a value without one.
  """
  @spec undoc(Node.t() | nil) :: {Node.t() | nil, %{optional(String.t()) => term()}}
  def undoc(value) do
    with %Node{rule: :tuple, children: children} <- body(value),
         [head, inner, notes] <- Enum.filter(children, &match?(%Node{rule: :value}, &1)),
         ":doc" <- text(head),
         {:ok, map} when is_map(map) <- Dextrin.decode(source(notes)) do
      {inner, named_notes(map)}
    else
      _ -> {value, %{}}
    end
  end

  # Annotations keyed by name, and so are each enum value's under
  # `values`.
  defp named_notes(map) do
    Map.new(map, fn {key, value} ->
      case annotation_name(key) do
        "values" when is_map(value) ->
          {"values", Map.new(value, fn {lit, n} -> {lit, named_notes(n)} end)}

        name ->
          {name, value}
      end
    end)
  end

  defp annotation_name(%Dextrin.Keyword{name: name}), do: name
  defp annotation_name(name) when is_binary(name), do: name
  defp annotation_name(other), do: inspect(other)

  # A node's tokens as written, trivia included, so it decodes as it reads.
  defp source(%Token{text: text}), do: text
  defp source(%Node{children: children}), do: Enum.map_join(children, &source/1)

  @doc false
  def namespace_of(name) do
    case String.split(name, "/", parts: 2) do
      [namespace, _] -> namespace
      [_] -> ""
    end
  end

  # What an entry is: a schema with its version and fields, a shape with
  # its fields, or a named type.
  defp classify(value, file_version) do
    case body(value) do
      %Node{rule: :struct_lit, children: children} = struct ->
        case struct_name(struct) do
          "schema" -> {:schema, header_version(children) || file_version || 1, fields(struct)}
          "shape" -> {:shape, nil, fields(struct)}
          _other -> {:type, nil, []}
        end

      _ ->
        {:type, nil, []}
    end
  end

  @doc false
  def struct_name(%Node{rule: :struct_lit, children: children}) do
    Enum.find_value(children, fn
      %Token{name: :IDENTIFIER, text: text} -> text
      _ -> nil
    end)
  end

  def struct_name(_other), do: nil

  defp header_version(children) do
    Enum.find_value(children, fn
      %Token{name: :INTEGER, text: text} -> String.to_integer(text)
      _ -> nil
    end)
  end

  # A schema's or shape's fields, in order: name, whether it is
  # optional, its type, default and description, and its comments.
  defp fields(%Node{children: children}) do
    case Enum.find(children, &match?(%Node{rule: :struct_keyed}, &1)) do
      nil ->
        []

      %Node{children: body} = keyed ->
        _ = keyed

        body
        |> Enum.filter(&match?(%Node{rule: :map_entry}, &1))
        |> Enum.zip_with(Comments.attached(body), fn entry, comments ->
          raw = key_of(entry)
          optional? = String.ends_with?(raw, "?")
          field(String.trim_trailing(raw, "?"), optional?, value_of(entry), doc_text(comments))
        end)
        |> Enum.with_index(1)
        |> Enum.map(fn {field, position} -> Map.put(field, :position, position) end)
    end
  end

  defp field(name, optional?, written, doc) do
    {value, notes} = undoc(written)

    base = %{
      name: name,
      optional?: optional?,
      type: value,
      default: nil,
      description: nil,
      doc: doc,
      annotations: notes
    }

    with %Node{rule: :struct_lit} = struct <- body(value),
         "field" <- struct_name(struct),
         %Node{children: body} <-
           Enum.find(struct.children, &match?(%Node{rule: :struct_keyed}, &1)) do
      parts =
        for e <- body, match?(%Node{rule: :map_entry}, e), into: %{}, do: {key_of(e), value_of(e)}

      {type, type_notes} = undoc(Map.get(parts, "type"))

      %{
        base
        | type: type,
          default: Map.get(parts, "default"),
          description: parts |> Map.get("description") |> string_value(),
          annotations: Map.merge(notes, type_notes)
      }
    else
      _ -> base
    end
  end

  defp string_value(nil), do: nil

  defp string_value(node) do
    case Dextrin.decode(text(node)) do
      {:ok, string} when is_binary(string) -> string
      _ -> text(node)
    end
  end

  # One definition from its parts across files: its versions, latest
  # first, and the documentation of the latest.
  defp merge([first | _] = parts) do
    versions = parts |> Enum.flat_map(& &1.versions) |> Enum.sort_by(&(&1.version || 0), :desc)
    latest = Enum.max_by(parts, fn part -> hd(part.versions).version || 0 end)
    %{latest | versions: versions, namespace_note: first.namespace_note}
  end

  # ---- references ------------------------------------------------------------

  @doc """
  The names the type `node` refers to, as `scope` resolves them.
  """
  @spec references(Node.t() | Token.t() | nil, %{String.t() => String.t()}) :: [String.t()]
  def references(nil, _scope), do: []

  def references(%Node{rule: :symbol} = node, scope), do: [resolve(text(node), scope)]

  def references(%Node{children: children}, scope),
    do: Enum.flat_map(children, &references(&1, scope))

  def references(%Token{}, _scope), do: []

  @doc "The name a bare or namespaced `name` stands for, in a file whose entries are `scope`."
  @spec resolve(String.t(), %{String.t() => String.t()}) :: String.t()
  def resolve(name, scope), do: Map.get(scope, name, name)
end
