defmodule Dextrin.Schema.Tree do
  @moduledoc """
  A tree of `.dxns` files read as one (Jan, 2026-10-20): every entry
  named from where its file lies (DXNS.md §6, `Dextrin.Schema.Layout`),
  the files compiled in the order their references need -- so a
  reference to another file's named type resolves whatever order the
  files sort in -- and every problem reported with its file and line:

  - a file that is not DXN, or not a map of names to definitions;
  - a definition that does not compile;
  - a versioned file holding another version, and one version of a name
    held by two files;
  - files that need each other (a cycle across files is not resolved
    yet);
  - **a name that resolves to nothing** -- a typo such as
    `acme.comon/Money` -- unless its namespace is declared `extern:`,
    supplied by another tree or a provider.

  `mix dextrin.check` is this, for CI.
  """

  alias Dextrin.Registry
  alias Dextrin.Schema.{Compiled, Layout}
  alias Dextrin.{Keyword, Struct, Symbol, Tuple}

  @typedoc "One problem: the file (relative to its root), the line, and what is wrong."
  @type problem :: %{file: String.t(), line: pos_integer(), message: String.t()}

  @typedoc "What a tree that is in order holds."
  @type summary :: %{files: non_neg_integer(), definitions: non_neg_integer()}

  @doc """
  Every `.dxns` file under `roots` (files or directories, searched
  recursively), compiled into one registry over `opts[:registry]`:
  `{:ok, registry, summary}`, or `{:error, problems}` with every problem
  found, in file and line order. `extern:` lists namespaces whose names
  are known to be supplied elsewhere.
  """
  @spec load([Path.t()], keyword()) :: {:ok, Registry.t(), summary()} | {:error, [problem()]}
  def load(roots, opts \\ []) do
    base = Elixir.Keyword.get(opts, :registry, Registry.new())
    extern = Elixir.Keyword.get(opts, :extern, [])

    {files, problems} = roots |> Enum.flat_map(&files_under/1) |> Enum.map(&read/1) |> split()
    {files, layout_problems} = layout(files)
    index = index(files)
    twice = twice(index)
    {ordered, cycle_problems} = ordered(files, index)
    {registry, compile_problems} = compiled(ordered, base)
    unknown = unknown(ordered, registry, index, extern)

    case problems ++ layout_problems ++ twice ++ cycle_problems ++ compile_problems ++ unknown do
      [] ->
        {:ok, registry,
         %{files: length(files), definitions: Enum.sum(Enum.map(files, &length(&1.keys)))}}

      found ->
        {:error, Enum.sort_by(found, &{&1.file, &1.line})}
    end
  end

  @doc """
  The named types `roots` define, compiled as `load/2` compiles them but
  past any problem -- what a file of the tree needs from the others when
  it is compiled on its own (`Dextrin.Schema.FileResolver`). Struct
  schemas are left out: each is loaded where it is asked for.
  """
  @spec named_types([Path.t()]) :: %{String.t() => term()}
  def named_types(roots) do
    {files, _problems} = roots |> Enum.flat_map(&files_under/1) |> Enum.map(&read/1) |> split()
    {ordered, _cycles} = ordered(files, index(files))
    {registry, _problems} = compiled(ordered, Registry.new())
    registry.type_aliases
  end

  # ---- reading -------------------------------------------------------------------

  defp files_under(root) do
    if File.dir?(root) do
      root
      |> Path.join("**/*.dxns")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&{root, Path.relative_to(&1, root)})
    else
      [{Path.dirname(root), Path.basename(root)}]
    end
  end

  defp read({root, relative}) do
    source = File.read!(Path.join(root, relative))

    case Dextrin.decode(source) do
      {:ok, doc} when is_map(doc) and not is_struct(doc) ->
        keys = Enum.map(Map.keys(doc), &key_name/1)
        layout = Layout.of(relative, keys)
        {:ok, %{file: relative, source: source, doc: doc, keys: keys, layout: layout}}

      {:ok, _other} ->
        {:error, problem(relative, 1, "a .dxns document is a map of names to definitions")}

      {:error, %Dextrin.Error{} = error} ->
        {:error, problem(relative, error_position(source, error), Dextrin.Error.format(error))}
    end
  end

  defp split(results) do
    {for({:ok, file} <- results, do: file), for({:error, problem} <- results, do: problem)}
  end

  defp key_name(%Keyword{name: name}), do: name
  defp key_name(%Symbol{name: name}), do: name
  defp key_name(name) when is_atom(name), do: Atom.to_string(name)
  defp key_name(name) when is_binary(name), do: name

  # ---- layout ------------------------------------------------------------------

  # A versioned file holds its entry as the version its name says.
  defp layout(files) do
    Enum.reduce(files, {[], []}, fn file, {ok, problems} ->
      case version_problem(file) do
        nil -> {ok ++ [file], problems}
        problem -> {ok ++ [file], problems ++ [problem]}
      end
    end)
  end

  defp version_problem(%{layout: %{holder: holder, version: version}} = file)
       when is_binary(holder) and is_integer(version) do
    case held(file, holder) do
      %Struct{name: "schema"} = schema ->
        if version_of(schema) == version,
          do: nil,
          else:
            problem(
              file.file,
              entry_line(file, holder),
              "holds #{holder} as version #{version_of(schema)}, but its name says version #{version} (DXNS.md §6)"
            )

      _other ->
        problem(
          file.file,
          entry_line(file, holder),
          "a versioned file holds a %schema(N), not #{holder}'s kind"
        )
    end
  end

  defp version_problem(_file), do: nil

  defp held(file, key),
    do: Enum.find_value(file.doc, fn {k, v} -> if key_name(k) == key, do: v end)

  # ---- names across files ------------------------------------------------------

  # Every full name the tree defines, with the files and versions that
  # define it.
  defp index(files) do
    for file <- files, {key, name} <- file.layout.names, reduce: %{} do
      acc ->
        Map.update(
          acc,
          name,
          [{file.file, version_of(held(file, key))}],
          &(&1 ++ [{file.file, version_of(held(file, key))}])
        )
    end
  end

  # One version of a name in two files (§4.6): found once, or refused
  # naming both. A named type is one version.
  defp twice(index) do
    for {name, holders} <- index,
        {version, files} <- Enum.group_by(holders, &elem(&1, 1), &elem(&1, 0)),
        length(files) > 1 do
      [first | _] = files = Enum.sort(files)
      what = if version == :type, do: name, else: "#{name} version #{version}"

      problem(
        first,
        1,
        "#{what} is in two files, #{Enum.join(files, " and ")}; it is found once (DXNS.md §6)"
      )
    end
  end

  defp version_of(%Struct{name: "schema", version: version}), do: version || 1
  defp version_of(_named_type), do: :type

  # The files in an order that compiles each after every file it refers
  # to; files that need each other are a problem, and are left out.
  defp ordered(files, index) do
    by_file = Map.new(files, &{&1.file, &1})
    needs = Map.new(files, fn file -> {file.file, needs(file, index)} end)
    {order, left} = topological(Enum.map(files, & &1.file), needs, [])

    case left do
      [] ->
        {Enum.map(order, &Map.fetch!(by_file, &1)), []}

      cycle ->
        message =
          "these files need each other, which is not resolved yet: #{Enum.join(Enum.sort(cycle), ", ")}"

        {Enum.map(order, &Map.fetch!(by_file, &1)), [problem(Enum.min(cycle), 1, message)]}
    end
  end

  defp topological([], _needs, order), do: {Enum.reverse(order), []}

  defp topological(pending, needs, order) do
    case Enum.split_with(pending, fn file -> Enum.all?(needs[file], &(&1 in order)) end) do
      {[], left} -> {Enum.reverse(order), left}
      {ready, left} -> topological(left, needs, Enum.reverse(ready) ++ order)
    end
  end

  # The other files `file` refers to.
  defp needs(file, index) do
    file.doc
    |> Map.values()
    |> Enum.flat_map(&symbols/1)
    |> Enum.map(&Map.get(file.layout.names, &1, &1))
    |> Enum.flat_map(&Map.get(index, &1, []))
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == file.file))
  end

  defp symbols(%Symbol{name: name}), do: [name]
  defp symbols(%Tuple{items: items}), do: Enum.flat_map(items, &symbols/1)

  defp symbols(%Struct{fields: {:keyed, pairs}}),
    do: Enum.flat_map(pairs, fn {_k, v} -> symbols(v) end)

  defp symbols(%Struct{fields: {:positional, items}}), do: Enum.flat_map(items, &symbols/1)
  defp symbols(list) when is_list(list), do: Enum.flat_map(list, &symbols/1)

  defp symbols(map) when is_map(map) and not is_struct(map),
    do: Enum.flat_map(Map.values(map), &symbols/1)

  defp symbols(_other), do: []

  # ---- compiling -----------------------------------------------------------------

  defp compiled(files, base) do
    Enum.reduce(files, {base, []}, fn file, {registry, problems} ->
      case Dextrin.Schema.compile(file.doc, registry, file.layout.names) do
        {:ok, registry} ->
          {registry, problems}

        # Reported up front, naming both files (`twice/1`).
        {:error, %Dextrin.Error{category: "schema/duplicate-version"}} ->
          {registry, problems}

        {:error, %Dextrin.Error{} = error} ->
          {registry,
           problems ++ [problem(file.file, error_line(file, error.message), error.message)]}
      end
    end)
  end

  # The line of the entry a compile error names.
  defp error_line(file, message) do
    with [_, name] <- Regex.run(~r/^(?:schema|named type) "([^"]+)"/, message),
         {key, _} <- Enum.find(file.layout.names, fn {_key, full} -> full == name end) do
      entry_line(file, key)
    else
      _ -> 1
    end
  end

  # ---- names that resolve to nothing --------------------------------------------

  defp unknown(files, registry, index, extern) do
    for file <- files,
        {_key, name} <- file.layout.names,
        reference <- references_of(registry, name) |> Enum.uniq(),
        not Map.has_key?(registry.structs, reference),
        not Map.has_key?(index, reference),
        not extern?(reference, extern) do
      problem(
        file.file,
        mention_line(file, reference),
        "#{reference} names nothing in this tree (declare its namespace extern if it is defined elsewhere)"
      )
    end
    |> Enum.uniq()
  end

  defp references_of(registry, name) do
    case {Map.fetch(registry.type_aliases, name), Map.fetch(registry.structs, name)} do
      {{:ok, type}, _} -> type_references(type)
      {_, {:ok, versions}} -> Enum.flat_map(Map.values(versions), &compiled_references/1)
      _ -> []
    end
  end

  defp compiled_references(%Compiled{fields: fields}),
    do: Enum.flat_map(fields, &type_references(&1.type))

  defp compiled_references(_other), do: []

  defp type_references({:reference, name}), do: [name]

  defp type_references({:shape, _name, fields}),
    do: Enum.flat_map(fields, &type_references(&1.type))

  defp type_references({:case, _f, branches, otherwise}),
    do: Enum.flat_map([otherwise | Enum.map(branches, &elem(&1, 1))], &type_references/1)

  defp type_references({:generic, _params, body}), do: type_references(body)
  defp type_references({:apply, _name, args}), do: Enum.flat_map(args, &type_references/1)

  # A refine's base, and the types its `contains`, `content`, `encodes`
  # and `encodes-seq` hold.
  defp type_references({:refine, type, constraints}) do
    held = for {key, t} <- constraints, key in ~w(contains content encodes encodes-seq), do: t
    Enum.flat_map([type | held], &type_references/1)
  end

  defp type_references({:tagged, _name, type}), do: type_references(type)
  defp type_references({:doc, type, _notes}), do: type_references(type)

  defp type_references({:if, test, then, otherwise}),
    do: Enum.flat_map([test, then, otherwise], &type_references/1)

  defp type_references({:list_items, particles}), do: Enum.flat_map(particles, &type_references/1)
  defp type_references({:one, type}), do: type_references(type)

  defp type_references({:repeat, group, _least, _most}),
    do: Enum.flat_map(group, &type_references/1)

  defp type_references({form, types}) when is_list(types) and form != :enum,
    do: Enum.flat_map(types, &type_references/1)

  defp type_references({_form, type}) when is_tuple(type) or is_atom(type),
    do: type_references(type)

  defp type_references({_form, key, value}), do: type_references(key) ++ type_references(value)
  defp type_references(_leaf), do: []

  defp extern?(name, extern) do
    namespace =
      name
      |> String.split("/", parts: 2)
      |> then(fn parts -> if length(parts) == 2, do: hd(parts) end)

    namespace != nil and
      Enum.any?(extern, &(namespace == &1 or String.starts_with?(namespace, &1 <> ".")))
  end

  # ---- lines ---------------------------------------------------------------------

  defp problem(file, line, message), do: %{file: file, line: line, message: message}

  defp line_at(source, offset) when is_integer(offset) and offset >= 0 do
    source |> binary_part(0, min(offset, byte_size(source))) |> String.split("\n") |> length()
  end

  defp line_at(_source, _offset), do: 1

  # Where a decode error is: its byte offset, else the line its parser
  # gives.
  defp error_position(source, %Dextrin.Error{byte_offset: offset}) when is_integer(offset),
    do: line_at(source, offset)

  defp error_position(_source, %Dextrin.Error{ichor_error: %{line: line}}) when is_integer(line),
    do: line

  defp error_position(_source, _error), do: 1

  # The line an entry's key stands on.
  defp entry_line(file, key) do
    pattern = ~r/^\s*(?:"#{Regex.escape(key)}"\s*=>|:?#{Regex.escape(key)}\??\s*:)/m
    first_line(file.source, pattern)
  end

  # The first line that mentions `name`, as a written reference.
  defp mention_line(file, name) do
    short = name |> String.split("/") |> List.last()
    candidates = [name, short]

    Enum.find_value(
      candidates,
      1,
      &first_line_or_nil(file.source, ~r/(?<![\w.\/])#{Regex.escape(&1)}(?![\w.])/)
    )
  end

  defp first_line(source, pattern), do: first_line_or_nil(source, pattern) || 1

  defp first_line_or_nil(source, pattern) do
    case Regex.run(pattern, source, return: :index) do
      [{offset, _} | _] -> line_at(source, offset)
      nil -> nil
    end
  end
end
