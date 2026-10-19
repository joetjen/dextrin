defmodule Dextrin.Document do
  @moduledoc """
  A `.dxn` document with everything it holds: its value, and every
  comment, blank line and comma around it (`design/comment-retention.md`).

  `Dextrin.decode/2` keeps only the value, which is right for data and
  wrong for a file people annotate: decoding, changing one entry and
  encoding again deletes every comment. A document keeps the
  **full-fidelity syntax tree** instead -- every token, trivia included
  (`Ichor.Syntax`) -- with the value as a projection of it:

      {:ok, doc} = Dextrin.Document.parse(source)
      Dextrin.Document.to_value(doc)   # what Dextrin.decode/2 returns
      Dextrin.Document.render(doc)     # source, byte for byte

  **One grammar, parsed one way.** The tree comes from the same
  `priv/grammar/dxn.aether` as `decode/2`, through the lossless entry
  point Ichor generates beside the fast one, and the same actions
  build the value -- so a document parses exactly when `decode/2`
  would, and refuses with the same errors.

  **An untouched node renders its own bytes.** Preservation is a
  property of rendering, not something a printer has to get right.

  ## Edits

  `replace/3`, `delete/2` and `insert/4` name what they change by a
  **path** from the document's value: a map's key as it decodes
  (`:deps`, `"x"`), a struct's field name (`"y"`), a list's, tuple's or
  set's index. Each splices the source text at the edited node and
  parses the result again, so every byte it does not touch is rendered
  as it was, and the edited document is checked by the same parser as
  any other.

  **A comment belongs to an entry** (`design/comment-retention.md`,
  "Trivia ownership"), by lines alone: a block starting on an entry's
  own line is that entry's *trailing* block, however many lines it runs
  to; every other block of comment lines is *above* the next entry, and
  a blank line separates blocks. So a deleted entry takes its trailing
  block and the blocks above it, and nobody else's; a replaced value
  keeps every comment around it, even one it has made stale; an
  inserted entry goes above the comments of the entry it lands before,
  so they stay with that entry.

  ## Updating to a new value

  `update/3` is a convenience over the edits, for a caller who has only
  the new value: it compares it with the document's, leaves what is
  equal alone -- `1.50` stays `1.50` when the new value is `1.5` -- and
  answers the edits it made as a changeset. Lists are compared with
  `List.myers_difference/2`. **A deleted item followed by an inserted
  one is ambiguous**: a replace keeps the deleted item's comments, a
  delete and an insert drop them. `on_ambiguity:` decides -- `:safe`
  (the default) takes it as a replace where the deleted item owns no
  comment, and refuses where it does; `:guess` always takes it as a
  replace; `:error` refuses every such pair.
  """

  alias Dextrin.Registry
  alias Dextrin.Schema.Validated

  alias Ichor.Syntax.{Node, Token}

  @enforce_keys [:tree, :value]
  defstruct [:tree, :value, opts: []]

  @typedoc """
  A parsed document: its syntax tree, the value it holds, and the
  options it was parsed with, which every edit parses again with.
  """
  @type t :: %__MODULE__{tree: Node.t(), value: term(), opts: keyword()}

  @typedoc "Where a value sits in a document: one key, field name or index per level."
  @type path :: [term()]

  @typedoc "An edit `update/3` made, in the order it made them."
  @type change ::
          {:replace, {path(), term()}}
          | {:delete, path()}
          | {:insert, {path(), integer() | term(), term()}}

  @typedoc "Why an edit was refused."
  @type refusal ::
          {:not_found, path()}
          | {:ambiguous, path()}
          | {:exists, path()}
          | {:not_a_collection, path()}
          | Dextrin.Error.t()
          | [Dextrin.Error.t()]

  @doc """
  Parses `source`, keeping everything in it. `opts` are
  `Dextrin.decode/2`'s -- `:registry`, `:trusted`, `:strict` -- and mean
  the same; so do the errors.
  """
  @spec parse(String.t(), keyword()) ::
          {:ok, t()} | {:error, Dextrin.Error.t() | [Dextrin.Error.t()]}
  def parse(source, opts \\ []) when is_binary(source) do
    case Dextrin.Text.Grammar.run_lossless(source, Registry.from_options(opts)) do
      {:ok, value, tree} ->
        {:ok, %__MODULE__{tree: tree, value: Validated.strip(value), opts: opts}}

      {:error, errors} ->
        {:error, Dextrin.Error.from_parse(errors)}
    end
  end

  @doc "The value `doc` holds: what `Dextrin.decode/2` gives for its source."
  @spec to_value(t()) :: term()
  def to_value(%__MODULE__{value: value}), do: value

  @doc "`doc` as `.dxn` text: its source, byte for byte, when nothing was edited."
  @spec render(t()) :: String.t()
  def render(%__MODULE__{tree: tree}), do: Ichor.Syntax.text(tree)

  # ---- edits ------------------------------------------------------------------

  @doc """
  `doc` with the value at `path` replaced by `value`, written as
  `Dextrin.encode/2` writes it -- laid out over lines at the indentation
  it replaces when it needs more than one. Every comment around it stays.
  """
  @spec replace(t(), path(), term()) :: {:ok, t()} | {:error, refusal()}
  def replace(%__MODULE__{} = doc, path, value) do
    with {:ok, found} <- located(doc, path),
         {:ok, text} <- written(doc, value, indentation(render(doc), found.value.offset)) do
      body = body_node(found.value)
      spliced(doc, body.offset, body.offset + body.size, text)
    end
  end

  @doc """
  `doc` without the entry at `path` -- a map's key and value, a list's
  item -- and without the comments that belong to it: the blocks above
  it and the block trailing it.
  """
  @spec delete(t(), path()) :: {:ok, t()} | {:error, refusal()}
  def delete(%__MODULE__{} = doc, [_ | _] = path) do
    with {:ok, found} <- located(doc, path) do
      source = render(doc)
      layout = layout(doc.tree)
      {from, to} = owned_span(source, layout, found.entry, found.siblings)
      spliced(doc, from, to, "")
    end
  end

  @doc """
  `doc` with `value` added to the collection at `path`: before the item
  at `index` in a list, tuple or set (`-1` for the end), or under the new
  `key` in a map or a struct, after its last entry. It is laid out like
  the entries beside it. A key already there is refused; that is
  `replace/3`'s.
  """
  @spec insert(t(), path(), integer() | term(), term()) :: {:ok, t()} | {:error, refusal()}
  def insert(%__MODULE__{} = doc, path, where, value) do
    with {:ok, collection} <- collection_at(doc, path),
         :ok <- absent_key(doc, collection, path, where),
         {:ok, text} <- entry_text(doc, collection, where, value) do
      source = render(doc)
      inserted(doc, source, layout(doc.tree), collection, where, text)
    end
  end

  @doc """
  `doc` holding `value`, by the fewest edits that make it, and those
  edits. See "Updating to a new value" above for `on_ambiguity:`.
  """
  @spec update(t(), term(), keyword()) :: {:ok, t(), [change()]} | {:error, refusal()}
  def update(%__MODULE__{} = doc, value, opts \\ []) do
    mode = Keyword.get(opts, :on_ambiguity, :safe)

    with {:ok, changes} <- changes(doc, [], to_value(doc), value, mode),
         {:ok, updated} <- applied(doc, changes) do
      {:ok, updated, changes}
    end
  end

  defp applied(doc, changes) do
    Enum.reduce_while(changes, {:ok, doc}, fn change, {:ok, doc} ->
      case apply_change(doc, change) do
        {:ok, doc} -> {:cont, {:ok, doc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp apply_change(doc, {:replace, {path, value}}), do: replace(doc, path, value)
  defp apply_change(doc, {:delete, path}), do: delete(doc, path)
  defp apply_change(doc, {:insert, {path, where, value}}), do: insert(doc, path, where, value)

  # The edits that turn `old`, at `path`, into `new`. Paths are where the
  # edit applies once every edit before it has been made.
  defp changes(_doc, _path, same, same, _mode), do: {:ok, []}

  defp changes(doc, path, %{} = old, %{} = new, mode)
       when not is_struct(old) and not is_struct(new),
       do: keyed_changes(doc, path, old, new, mode)

  defp changes(
         doc,
         path,
         %Dextrin.Struct{name: name, version: version, fields: {:keyed, old}},
         %Dextrin.Struct{name: name, version: version, fields: {:keyed, new}},
         mode
       ),
       do: keyed_changes(doc, path, Map.new(old), Map.new(new), mode)

  defp changes(doc, path, old, new, mode) when is_list(old) and is_list(new),
    do: listed_changes(doc, path, List.myers_difference(old, new), 0, 0, [], mode)

  defp changes(_doc, path, _old, new, _mode), do: {:ok, [replace: {path, new}]}

  # A map's or a keyed struct's entries: the keys gone are deleted, the
  # keys kept are compared, the keys new are inserted after the last.
  defp keyed_changes(doc, path, old, new, mode) do
    gone = for key <- Map.keys(old), not Map.has_key?(new, key), do: {:delete, path ++ [key]}
    added = for {key, value} <- new, not Map.has_key?(old, key), do: {:insert, {path, key, value}}

    kept =
      Enum.reduce_while(old, {:ok, []}, fn {key, value}, {:ok, acc} ->
        case Map.fetch(new, key) do
          {:ok, ^value} -> {:cont, {:ok, acc}}
          {:ok, other} -> nested(changes(doc, path ++ [key], value, other, mode), acc)
          :error -> {:cont, {:ok, acc}}
        end
      end)

    with {:ok, kept} <- kept, do: {:ok, gone ++ kept ++ added}
  end

  defp nested({:ok, changes}, acc), do: {:cont, {:ok, acc ++ changes}}
  defp nested({:error, _} = error, _acc), do: {:halt, error}

  # A list's edit script, item by item: `at` is where the next edit
  # applies, `was` where the item it looks at sat in the document as
  # parsed -- which is where its comments are.
  defp listed_changes(_doc, _path, [], _at, _was, acc, _mode), do: {:ok, acc}

  defp listed_changes(doc, path, [{:eq, same} | rest], at, was, acc, mode),
    do: listed_changes(doc, path, rest, at + length(same), was + length(same), acc, mode)

  defp listed_changes(
         doc,
         path,
         [{:del, [old | gone]}, {:ins, [new | come]} | rest],
         at,
         was,
         acc,
         mode
       ) do
    with :ok <- unambiguous(doc, path ++ [was], mode),
         {:ok, inner} <- changes(doc, path ++ [at], old, new, mode) do
      rest = Enum.reject([{:del, gone}, {:ins, come} | rest], &match?({_, []}, &1))
      listed_changes(doc, path, rest, at + 1, was + 1, acc ++ inner, mode)
    end
  end

  defp listed_changes(doc, path, [{:del, gone} | rest], at, was, acc, mode),
    do:
      listed_changes(
        doc,
        path,
        rest,
        at,
        was + length(gone),
        acc ++ List.duplicate({:delete, path ++ [at]}, length(gone)),
        mode
      )

  defp listed_changes(doc, path, [{:ins, come} | rest], at, was, acc, mode) do
    inserts =
      come |> Enum.with_index(at) |> Enum.map(fn {value, i} -> {:insert, {path, i, value}} end)

    listed_changes(doc, path, rest, at + length(come), was, acc ++ inserts, mode)
  end

  # Whether a deleted item followed by an inserted one may be read as a
  # replace of the item at `path`, as the document was parsed.
  defp unambiguous(_doc, _path, :guess), do: :ok
  defp unambiguous(_doc, path, :error), do: {:error, {:ambiguous, path}}

  defp unambiguous(doc, path, :safe) do
    if owns_comment?(doc, path), do: {:error, {:ambiguous, path}}, else: :ok
  end

  defp owns_comment?(doc, path) do
    {:ok, found} = located(doc, path)
    source = render(doc)
    comments = layout(doc.tree)
    {from, to} = owned_span(source, comments, found.entry, found.siblings)
    Enum.any?(comments, fn {c, _} -> c >= from and c < to end)
  end

  # ---- finding a path -----------------------------------------------------------

  # What a path leads to: the `value` node it names, the node standing
  # for the whole entry (a map's `map_entry`, a list's `value`), and the
  # entries beside it in its collection.
  defp located(%__MODULE__{tree: tree} = doc, path) do
    walk(doc, root_value(tree), %{value: root_value(tree), entry: nil, siblings: []}, path, [])
  end

  defp walk(_doc, _value, found, [], _seen), do: {:ok, found}

  defp walk(doc, value, _found, [step | rest], seen) do
    here = seen ++ [step]

    case step_into(doc, collection_node(value), step) do
      {:ok, next} -> walk(doc, next.value, next, rest, here)
      :error -> {:error, {:not_found, here}}
    end
  end

  # One step into a collection: the entry `step` names.
  defp step_into(doc, %Node{rule: rule} = node, step) when rule in [:map_lit, :struct_keyed] do
    entries = entries(node)

    case Enum.find(entries, &(key_of(doc, &1, rule) == {:ok, step})) do
      nil -> :error
      entry -> {:ok, %{value: entry_value(entry), entry: entry, siblings: entries}}
    end
  end

  defp step_into(doc, %Node{rule: :struct_positional} = node, step) when not is_integer(step) do
    step_into(doc, %{node | rule: :struct_keyed}, step)
  end

  defp step_into(_doc, %Node{rule: rule} = node, index)
       when rule in [:list, :tuple, :set_lit, :struct_positional] and is_integer(index) do
    items = items(node)

    case Enum.at(items, index) do
      nil -> :error
      item -> {:ok, %{value: item, entry: item, siblings: items}}
    end
  end

  defp step_into(_doc, _node, _step), do: :error

  defp collection_at(doc, path) do
    with {:ok, found} <- located(doc, path) do
      case collection_node(found.value) do
        %Node{rule: rule} = node
        when rule in [:map_lit, :struct_keyed, :struct_positional, :list, :tuple, :set_lit] ->
          {:ok, node}

        _ ->
          {:error, {:not_a_collection, path}}
      end
    end
  end

  defp absent_key(doc, %Node{rule: rule} = node, path, key)
       when rule in [:map_lit, :struct_keyed] do
    if Enum.any?(entries(node), &(key_of(doc, &1, rule) == {:ok, key})),
      do: {:error, {:exists, path ++ [key]}},
      else: :ok
  end

  defp absent_key(_doc, _node, _path, _where), do: :ok

  # The document's own value, under its header and trivia.
  defp root_value(%Node{children: children}),
    do: Enum.find(children, &match?(%Node{rule: :value}, &1))

  # The collection or scalar a `value` node holds, past its discards; a
  # struct's keyed or positional body.
  defp collection_node(%Node{} = value) do
    case body_node(value) do
      %Node{children: [%Node{rule: :struct_lit, children: children}]} ->
        Enum.find(
          children,
          &match?(%Node{rule: rule} when rule in [:struct_keyed, :struct_positional], &1)
        )

      %Node{children: [inner]} ->
        inner

      other ->
        other
    end
  end

  defp body_node(%Node{children: children}),
    do: Enum.find(children, &match?(%Node{rule: :value_body}, &1))

  defp entries(%Node{children: children}),
    do: Enum.filter(children, &match?(%Node{rule: :map_entry}, &1))

  defp items(%Node{children: children}),
    do: Enum.filter(children, &match?(%Node{rule: :value}, &1))

  defp entry_value(%Node{children: children}),
    do: children |> Enum.filter(&match?(%Node{rule: :value}, &1)) |> List.last()

  # A map entry's key as it decodes: a shorthand `name:` is the keyword
  # `:name` in a map and the field name `"name"` in a struct; an arrow
  # entry's key is its value.
  defp key_of(doc, %Node{children: [%Token{name: :MAP_KEY, text: text} | _]}, rule) do
    name = String.trim_trailing(text, ":")
    if rule == :struct_keyed, do: {:ok, name}, else: Dextrin.decode(":" <> name, doc.opts)
  end

  defp key_of(doc, %Node{children: [%Node{rule: :value} = key | _]}, _rule),
    do: Dextrin.decode(Ichor.Syntax.text(key), doc.opts)

  # ---- comments and lines -------------------------------------------------------

  # Every comment in the document, as `{from, to}` byte offsets -- the
  # `#` to the end of its line, newline excluded -- found in the trivia
  # tokens, where a `#` can only begin one.
  defp layout(tree) do
    for %Token{trivia: true, text: text, offset: offset} <- Ichor.Syntax.tokens(tree),
        [{at, length}] <- Regex.scan(~r/#[^\n]*/, text, return: :index),
        do: {offset + at, offset + at + length}
  end

  # The bytes an entry owns: the blocks above it and its trailing block,
  # whole lines, when it stands on a line of its own; itself and the
  # separator beside it when it shares its line.
  defp owned_span(source, comments, %Node{offset: from, size: size}, siblings) do
    to = from + size

    if alone_before?(source, from) and alone_after?(source, comments, to) do
      {above_start(source, comments, from), trailing_end(source, comments, to)}
    else
      inline_span(source, from, to, siblings)
    end
  end

  # An entry sharing its line goes with the separator after it, or before
  # it when it is the last.
  defp inline_span(source, from, to, siblings) do
    %Node{offset: last_from, size: last_size} = List.last(siblings)

    if last_from + last_size == to do
      {from - separator_length_before(source, from), to}
    else
      {from, to + separator_length_after(source, to)}
    end
  end

  defp separator_length_after(source, at) do
    rest = binary_part(source, at, byte_size(source) - at)
    [gap] = Regex.run(~r/\A[ \t,]*/, rest)
    byte_size(gap)
  end

  defp separator_length_before(source, at) do
    [gap] = Regex.run(~r/[ \t,]*\z/, binary_part(source, 0, at))
    byte_size(gap)
  end

  # Whether nothing but whitespace and commas precedes `at` on its line.
  defp alone_before?(source, at),
    do:
      binary_part(source, line_start(source, at), at - line_start(source, at)) =~ ~r/\A[ \t,]*\z/

  # Whether nothing but whitespace, commas and a comment follows `at` on
  # its line.
  defp alone_after?(source, comments, at) do
    rest = binary_part(source, at, line_end(source, at) - at)

    case comment_at_or_after(comments, at, line_end(source, at)) do
      nil -> rest =~ ~r/\A[ \t,]*\z/
      {c_from, _c_to} -> binary_part(source, at, c_from - at) =~ ~r/\A[ \t,]*\z/
    end
  end

  defp comment_at_or_after(comments, from, to),
    do: Enum.find(comments, fn {c, _} -> c >= from and c < to end)

  # The end of an entry's trailing block -- the comment on its own line
  # and every comment line straight after it -- or of its own line.
  defp trailing_end(source, comments, at) do
    case comment_at_or_after(comments, at, line_end(source, at)) do
      nil -> after_newline(source, line_end(source, at))
      {_from, to} -> after_newline(source, block_end(source, comments, to))
    end
  end

  # The end of the last comment in an unbroken run of comment lines after
  # `to`.
  defp block_end(source, comments, to) do
    next_line = after_newline(source, to)

    case Enum.find(comments, fn {c, _} -> c >= next_line and own_line_comment?(source, c) end) do
      {c_from, c_to} ->
        if line_start(source, c_from) == next_line,
          do: block_end(source, comments, c_to),
          else: to

      nil ->
        to
    end
  end

  # Where an entry's above blocks start: the comment lines straight
  # above it, blank lines between blocks allowed, up to a line of code --
  # less a topmost block that is the previous entry's trailing block,
  # continuing a comment on that entry's own line with no blank line.
  defp above_start(source, comments, at) do
    own_start = line_start(source, at)

    above =
      comments
      |> Enum.filter(fn {_c, c_to} -> c_to <= own_start end)
      |> Enum.reverse()
      |> Enum.reduce_while({own_start, []}, fn {c_from, c_to}, {cursor, kept} ->
        gap = binary_part(source, c_to, cursor - c_to)

        if own_line_comment?(source, c_from) and gap =~ ~r/\A[ \t,\r\n]*\z/,
          do: {:cont, {line_start(source, c_from), [{c_from, c_to} | kept]}},
          else: {:halt, {cursor, kept}}
      end)
      |> elem(1)

    case drop_continued_trailing(source, comments, blocks(source, above)) do
      [] -> own_start
      [[{first, _} | _] | _] -> line_start(source, first)
    end
  end

  # Comments, top to bottom, as blocks: a blank line ends one.
  defp blocks(_source, []), do: []

  defp blocks(source, [first | rest]) do
    rest
    |> Enum.reduce([[first]], fn {c_from, _} = comment, [[{_, p_to} | _] = block | done] ->
      if blank_between?(source, p_to, c_from),
        do: [[comment] | [Enum.reverse(block) | done]],
        else: [[comment | block] | done]
    end)
    |> then(fn [block | done] -> Enum.reverse([Enum.reverse(block) | done]) end)
  end

  defp blank_between?(source, from, to),
    do: binary_part(source, from, to - from) |> String.split("\n") |> length() > 2

  # A topmost block with no blank line between it and a line that ends in
  # a comment belongs to the entry on that line.
  defp drop_continued_trailing(_source, _comments, []), do: []

  defp drop_continued_trailing(source, comments, [[{first, _} | _] | later] = all) do
    top_line = line_start(source, first)

    if top_line > 0 do
      previous = line_start(source, top_line - 1)

      continued? =
        Enum.any?(comments, fn {c, _} ->
          c >= previous and c < top_line and not own_line_comment?(source, c)
        end)

      if continued?, do: later, else: all
    else
      all
    end
  end

  defp own_line_comment?(source, at), do: alone_before?(source, at)

  defp line_start(source, at) do
    case :binary.matches(binary_part(source, 0, at), "\n") do
      [] -> 0
      matches -> matches |> List.last() |> then(fn {i, _} -> i + 1 end)
    end
  end

  defp line_end(source, at) do
    case :binary.match(source, "\n", scope: {at, byte_size(source) - at}) do
      {i, _} -> i
      :nomatch -> byte_size(source)
    end
  end

  defp after_newline(source, at) when at < byte_size(source), do: at + 1
  defp after_newline(_source, at), do: at

  defp indentation(source, at) do
    start = line_start(source, at)
    [indent] = Regex.run(~r/\A[ \t]*/, binary_part(source, start, byte_size(source) - start))
    indent
  end

  # ---- writing ------------------------------------------------------------------

  # `value` as `.dxn` text, its continuation lines at `indent`.
  defp written(doc, value, indent) do
    with {:ok, text} <-
           Dextrin.encode(value, pretty: true, registry: Registry.from_options(doc.opts)) do
      {:ok, String.replace(text, "\n", "\n" <> indent)}
    end
  end

  # The text of a new entry: a map's `key: value`, written as the pretty
  # printer writes a one-entry map, or a list's item.
  defp entry_text(doc, %Node{rule: rule}, key, value) when rule in [:map_lit, :struct_keyed] do
    key = if rule == :struct_keyed, do: String.to_atom(to_string(key)), else: key

    with {:ok, text} <-
           Dextrin.encode(%{key => value},
             pretty: true,
             registry: Registry.from_options(doc.opts)
           ) do
      lines =
        text
        |> String.split("\n")
        |> Enum.slice(1..-2//1)
        |> Enum.map(&String.replace_prefix(&1, "  ", ""))

      {:ok, Enum.join(lines, "\n")}
    end
  end

  defp entry_text(doc, _node, _index, value), do: written(doc, value, "")

  defp inserted(doc, source, comments, collection, where, text) do
    elements =
      if collection.rule in [:map_lit, :struct_keyed],
        do: entries(collection),
        else: items(collection)

    index =
      if is_integer(where) and where >= 0,
        do: min(where, length(elements)),
        else: length(elements)

    before = Enum.at(elements, index)
    multiline? = multiline?(source, comments, collection, elements)

    cond do
      multiline? and before != nil ->
        at = above_start(source, comments, before.offset)
        indent = indentation(source, before.offset)
        spliced(doc, at, at, indent <> indented(text, indent) <> "\n")

      multiline? and elements != [] ->
        last = List.last(elements)
        at = trailing_end(source, comments, last.offset + last.size)
        indent = indentation(source, last.offset)
        spliced(doc, at, at, indent <> indented(text, indent) <> "\n")

      multiline? ->
        close = closing_offset(collection)
        at = line_start(source, close)
        indent = indentation(source, close) <> "  "
        spliced(doc, at, at, indent <> indented(text, indent) <> "\n")

      before != nil ->
        spliced(doc, before.offset, before.offset, text <> " ")

      elements != [] ->
        last = List.last(elements)
        spliced(doc, last.offset + last.size, last.offset + last.size, " " <> text)

      true ->
        at = closing_offset(collection)
        spliced(doc, at, at, text)
    end
  end

  defp indented(text, indent), do: String.replace(text, "\n", "\n" <> indent)

  # A collection is laid out over lines when its entries stand on lines
  # of their own, or, empty, when it opens and closes on different lines.
  defp multiline?(source, _comments, collection, []),
    do: line_start(source, collection.offset) != line_start(source, closing_offset(collection))

  defp multiline?(source, comments, _collection, [first | _]),
    do:
      alone_before?(source, first.offset) and
        alone_after?(source, comments, first.offset + first.size)

  defp closing_offset(%Node{children: children}) do
    %Token{offset: offset} =
      children |> Enum.filter(&match?(%Token{trivia: false}, &1)) |> List.last()

    offset
  end

  # The document with `from..to` of its text replaced by `text`, parsed
  # again with the options it was parsed with.
  defp spliced(%__MODULE__{opts: opts} = doc, from, to, text) do
    source = render(doc)

    parse(
      binary_part(source, 0, from) <> text <> binary_part(source, to, byte_size(source) - to),
      opts
    )
  end
end
