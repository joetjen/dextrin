defmodule Dextrin.Codegen.Elixir do
  @moduledoc """
  Elixir code from DXNS (T684, design/codegen-elixir.md).

  For each `%schema` of a tree of `.dxns` files (`Dextrin.Schema.Tree`) it
  writes two files:

    * `order.ex`, **the user's**: written once, never rewritten. It
      `use`s the generated module, which gives it the struct and every
      function; hand-written upgrade callbacks and anything else of the
      user's own go here.
    * `order.gen.ex`, **the generator's**: rewritten on every run. It
      holds a function per version that reads and checks the fields
      (`read_v1/1`), an upgrade step between each version and the next
      (`upgrade_v1/1`), and `read/1`, which dispatches on the version a
      struct was written with. Every check is code of its own: no schema
      is read when it runs.

  What is written by hand survives regenerating, in two places: the
  user's file, which is never touched, and the generated file's regions --
  `# dextrin:keep NAME` ... `# dextrin:end NAME` -- whose lines are put
  back in the slot of the same name. A region whose slot is gone is kept
  at the end of the file as `orphaned_NAME`, and `check/2` fails until it
  is dealt with. Both files start with `# dextrin:schema NAME`, by which
  a schema's files are found again: their module name and paths are kept
  as the user's file writes them.
  """

  alias Dextrin.Schema.{Compiled, Field, Tree}

  @schema_tag "# dextrin:schema "

  @typedoc "What `write/2` and `check/2` take."
  @type opts :: [prefix: String.t(), out: Path.t()]

  @doc """
  Generates the files for the schemas under `roots` into `opts[:out]`:
  the generated files rewritten, the user's files written once.
  Answers `{:ok, paths written}` or `{:error, problems}`.
  """
  @spec write([Path.t()], opts()) :: {:ok, [Path.t()]} | {:error, [String.t()]}
  def write(roots, opts) do
    with {:ok, files} <- files(roots, opts) do
      written =
        for {path, content, kind} <- files, kind == :generated or not File.exists?(path) do
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, content)
          path
        end

      {:ok, Enum.sort(written)}
    end
  end

  @doc """
  Whether the generated files under `opts[:out]` are what `write/2` would
  write now, with no orphaned region in them: `:ok`, or `{:error,
  problems}`, each naming a file. For CI.
  """
  @spec check([Path.t()], opts()) :: :ok | {:error, [String.t()]}
  def check(roots, opts) do
    with {:ok, files} <- files(roots, opts) do
      problems =
        for {path, content, :generated} <- files,
            problem <- stale(path, content) ++ orphans(path, content),
            do: problem

      if problems == [], do: :ok, else: {:error, problems}
    end
  end

  defp stale(path, content) do
    case File.read(path) do
      {:ok, ^content} -> []
      {:ok, _other} -> ["#{path} is out of date with its schema"]
      {:error, _} -> ["#{path} is missing"]
    end
  end

  defp orphans(path, content) do
    for [name] <- Regex.scan(~r/# dextrin:keep (orphaned_\S+)/, content, capture: :all_but_first),
        do: "#{path} holds the orphaned region #{name}: move its code or delete it"
  end

  # Every file, `{path, content, :generated | :user}`.
  defp files(roots, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    out = Keyword.fetch!(opts, :out)

    case Tree.load(roots) do
      {:ok, registry, _summary} ->
        known = known(out)
        names = registry.structs |> Map.keys() |> Enum.sort()
        modules = Map.new(names, &{&1, module_for(&1, prefix, known)})

        decoder =
          {Path.join(out, "decoder.gen.ex"), decoder_file(prefix, names, modules), :generated}

        {:ok,
         [decoder] ++
           Enum.flat_map(names, fn name ->
             paths = paths_for(name, out, known)
             versions = registry.structs[name] |> Map.values() |> Enum.sort_by(& &1.version)
             generated = generated(name, versions, modules, registry)
             old = if File.exists?(paths.gen), do: File.read!(paths.gen), else: nil

             [
               {paths.gen, merge_regions(generated, old), :generated},
               {paths.user, user_file(name, modules[name]), :user}
             ]
           end)}

      {:error, problems} ->
        {:error, Enum.map(problems, &"#{&1.file}:#{&1.line}: #{&1.message}")}
    end
  end

  # ---- names and paths, kept --------------------------------------------------

  # The files under `out` that say which schema they are: by schema, the
  # user's file and its module, and the generated file.
  defp known(out) do
    Path.join(out, "**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce(%{}, fn path, acc ->
      text = File.read!(path)

      case Regex.run(~r/^# dextrin:schema (\S+)$/m, text, capture: :all_but_first) do
        [schema] ->
          entry = Map.get(acc, schema, %{})
          kind = if String.ends_with?(path, ".gen.ex"), do: :gen, else: :user

          entry =
            if kind == :user do
              [module] = Regex.run(~r/^defmodule (\S+) do$/m, text, capture: :all_but_first)
              Map.merge(entry, %{user: path, module: module})
            else
              Map.put(entry, :gen, path)
            end

          Map.put(acc, schema, entry)

        nil ->
          acc
      end
    end)
  end

  defp module_for(name, prefix, known) do
    case known[name] do
      %{module: module} ->
        module

      _ ->
        {namespace, local} = split(name)

        Enum.join(
          [prefix | Enum.map(namespace, &Macro.camelize/1)] ++ [Macro.camelize(local)],
          "."
        )
    end
  end

  defp paths_for(name, out, known) do
    case known[name] do
      %{user: user} ->
        %{
          user: user,
          gen: Map.get(known[name], :gen, String.replace_suffix(user, ".ex", ".gen.ex"))
        }

      _ ->
        {namespace, local} = split(name)
        base = Path.join([out | namespace] ++ [Macro.underscore(local)])
        %{user: base <> ".ex", gen: base <> ".gen.ex"}
    end
  end

  defp split(name) do
    case String.split(name, "/", parts: 2) do
      [namespace, local] -> {String.split(namespace, "."), local}
      [local] -> {[], local}
    end
  end

  # ---- the decoder ---------------------------------------------------------------

  # `Prefix.Decoder`: DXN text decoded, every struct of a known schema read
  # with its generated functions -- no registry, so no schema at run time.
  defp decoder_file(prefix, names, modules) do
    """
    # Generated by mix dextrin.gen.elixir.
    # Regenerating rewrites it: do not edit it.
    defmodule #{prefix}.Decoder do
      @moduledoc \"\"\"
      DXN decoded into the generated structs: every struct of a schema this
      prefix was generated from is read by its module's `read/1`, wherever
      it stands.
      \"\"\"

      @modules %{#{Enum.map_join(names, ", ", &"#{inspect(&1)} => #{modules[&1]}")}}

      @doc "The module generated for each schema, by schema name."
      def modules, do: @modules

      @doc "`text` decoded, its structs read into the generated modules: `{:ok, value}` or why not."
      def decode(text, opts \\\\ []) do
        with {:ok, value} <- Dextrin.decode(text, opts), do: read(value)
      end

      @doc "A decoded value with its structs read into the generated modules."
      def read(%Dextrin.Struct{name: name} = struct) do
        case Map.fetch(@modules, name) do
          {:ok, module} -> module.read(struct)
          :error -> {:ok, struct}
        end
      end

      def read(list) when is_list(list) do
        Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
          case read(item) do
            {:ok, item} -> {:cont, {:ok, [item | acc]}}
            error -> {:halt, error}
          end
        end)
        |> then(fn {:ok, items} -> {:ok, Enum.reverse(items)}; error -> error end)
      end

      def read(map) when is_map(map) and not is_struct(map) do
        Enum.reduce_while(map, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
          case read(v) do
            {:ok, v} -> {:cont, {:ok, Map.put(acc, k, v)}}
            error -> {:halt, error}
          end
        end)
      end

      def read(other), do: {:ok, other}
    end
    """
    |> format!()
  end

  # ---- the user's file ---------------------------------------------------------

  defp user_file(name, module) do
    """
    #{@schema_tag}#{name}
    defmodule #{module} do
      @moduledoc \"\"\"
      The schema #{name}. Its struct and functions come from
      #{module}.Gen, which `mix dextrin.gen.elixir` rewrites; this file
      is yours and is never rewritten.
      \"\"\"

      use #{module}.Gen
    end
    """
  end

  # ---- the generated file -------------------------------------------------------

  defp generated(name, versions, modules, registry) do
    module = modules[name]
    latest = List.last(versions)
    state = %{fns: [], seen: %{}, next: 1, modules: modules, registry: registry, attrs: []}

    {version_code, state} =
      Enum.map_reduce(versions, state, fn compiled, state -> version_code(compiled, state) end)

    upgrades = upgrades(versions)

    """
    # Generated by mix dextrin.gen.elixir from the DXNS schema #{name}.
    # Regenerating rewrites it: do not edit it outside the dextrin:keep regions.
    #{@schema_tag}#{name}
    defmodule #{module}.Gen do
      @moduledoc false

      # dextrin:keep top
      # dextrin:end top

      alias Dextrin.Codegen.Runtime
      alias Dextrin.Schema.TypeExpr

      @owner #{module}
      @latest #{latest.version}

    #{Enum.map_join(callbacks(upgrades), "", &"  @callback #{&1}(map()) :: map()\n")}
      @doc false
      defmacro __using__(_opts) do
        quote do
          #{if callbacks(upgrades) != [], do: "@behaviour #{module}.Gen", else: ""}
          defstruct #{inspect(Enum.map(latest.fields, &String.to_atom(&1.name)))}
          @type t :: %__MODULE__{}

          @doc "The DXNS schema this struct is."
          def __dextrin_schema__, do: #{inspect(name)}

          @doc "A decoded `%#{name}{}` of any known version, read into this struct."
          def read(value), do: #{module}.Gen.read(value)

          @doc "Whether this struct is a valid #{name}."
          def validate(value), do: #{module}.Gen.validate(value)

          @doc "This struct as DXN, at the latest version."
          def to_dxn(value), do: #{module}.Gen.to_dxn(value)
        end
      end

    #{Enum.map_join(Enum.reverse(state.attrs), "", &"  #{&1}\n")}
      @doc "A decoded struct of any known version, read and upgraded to the latest."
      def read(%Dextrin.Struct{name: #{inspect(name)}, version: version, fields: fields}) do
        case version || @latest do
    #{Enum.map_join(versions, "", fn c -> "      #{c.version} -> with {:ok, f} <- Runtime.named(fields, #{inspect(Compiled.field_names(c))}), do: read_v#{c.version}(f)\n" end)}      v when v > @latest -> with {:ok, f} <- Runtime.named(fields, #{inspect(Compiled.field_names(latest))}), do: read_v#{latest.version}(f)
          v -> {:error, "#{name} version \#{v} is not known"}
        end
      end

      def read(%{__struct__: @owner} = value), do: {:ok, value}
      def read(other), do: {:error, "expected a #{name}, got " <> Runtime.show(other)}

      @doc "Whether `value`, this struct, is a valid #{name} at the latest version."
      def validate(%{__struct__: @owner} = value) do
        fields = value |> Map.from_struct() |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
        with {:ok, _} <- conform_v#{latest.version}(fields), do: :ok
      end

      @doc "This struct as a `Dextrin.Struct` at the latest version."
      def to_dxn(%{__struct__: @owner} = value) do
        pairs =
          for name <- #{inspect(Compiled.field_names(latest))},
              v = Map.fetch!(value, String.to_atom(name)),
              not is_nil(v),
              do: {name, Runtime.to_dxn(v)}

        Dextrin.Struct.keyed(#{inspect(name)}, pairs, @latest)
      end

    #{Enum.join(version_code, "\n")}
    #{upgrade_code(name, versions, upgrades)}
    #{Enum.join(Enum.reverse(state.fns), "\n")}
      # dextrin:keep bottom
      # dextrin:end bottom
    end
    """
    |> drop_unused_alias()
    |> format!()
  end

  # The TypeExpr alias only where a check calls it.
  defp drop_unused_alias(source) do
    if String.contains?(source, "TypeExpr."),
      do: source,
      else: String.replace(source, "  alias Dextrin.Schema.TypeExpr\n", "")
  end

  defp format!(source),
    do: source |> Code.format_string!() |> IO.iodata_to_binary() |> Kernel.<>("\n")

  # One version's functions: read (check, fill defaults, upgrade to the
  # latest) and conform (check and fill defaults). A deprecated version's
  # are marked (G10).
  defp version_code(%Compiled{version: v, fields: fields, annotations: notes}, state) do
    {checks, state} =
      Enum.map_reduce(fields, state, fn field, state ->
        {fun, state} = type_fun(field.type, state)
        {String.trim_trailing(field_check(field, fun)), state}
      end)

    deprecated =
      case Dextrin.Schema.Deprecations.reason(notes) do
        {:deprecated, why} -> "@deprecated #{inspect(why || "version #{v} is deprecated")}\n"
        :none -> ""
      end

    code = """
      @doc "Fields written with version #{v}: checked, defaults filled, upgraded to the latest."
      #{deprecated}def read_v#{v}(fields) do
        with {:ok, fields} <- conform_v#{v}(fields) do
          fields = upgrade_from(#{v}, fields)
          {:ok, struct(@owner, Map.new(fields, fn {k, val} -> {String.to_atom(k), val} end))}
        end
      end

      @doc "Fields as version #{v} says them: checked, defaults filled."
      #{deprecated}def conform_v#{v}(fields) do
        Enum.reduce_while(
          [#{Enum.join(checks, ", ")}],
          {:ok, %{}},
          fn check, {:ok, acc} ->
            case check.(fields) do
              {:ok, nil} -> {:cont, {:ok, acc}}
              {:ok, {name, value}} -> {:cont, {:ok, Map.put(acc, name, value)}}
              {:error, why} -> {:halt, {:error, why}}
            end
          end
        )
      end
    """

    {code, state}
  end

  # A field's check: `{:ok, {name, value}}`, `{:ok, nil}` when absent and
  # optional, or why not.
  defp field_check(%Field{name: name, required: required, default: default}, fun) do
    absent =
      cond do
        default != :none ->
          "{:ok, {#{inspect(name)}, Runtime.value!(#{inspect(dxn_text(Field.filled(default)))})}}"

        required ->
          "{:error, \"missing required field #{name}\"}"

        true ->
          "{:ok, nil}"
      end

    """
    fn fields ->
      case Map.fetch(fields, #{inspect(name)}) do
        {:ok, value} ->
          case #{fun}(value) do
            {:ok, value} -> {:ok, {#{inspect(name)}, value}}
            {:error, why} -> {:error, "field #{name}: " <> why}
          end
        :error -> #{absent}
      end
    end
    """
  end

  defp dxn_text(value) do
    {:ok, text} = Dextrin.encode(value)
    text
  end

  # ---- upgrades -----------------------------------------------------------------

  # Between each version and the next: what moves, what is dropped, and
  # whether a hand-written step is needed (a changed type, a field made
  # required, a required field with no default added).
  defp upgrades(versions) do
    versions
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from, to] ->
      before = Map.new(from.fields, &{&1.name, &1})

      steps =
        Enum.map(to.fields, fn field ->
          old = Map.get(before, renamed_from(field) || field.name)

          # A field whose type changed, or that became required, is
          # carried into the hand-written step, under its new name.
          cond do
            old == nil and (not field.required or field.default != :none) -> {:added, field.name}
            old == nil -> {:hand, field.name}
            meaning(old.type) != meaning(field.type) -> {:hand, old.name, field.name}
            field.required and not old.required -> {:hand, old.name, field.name}
            old.name != field.name -> {:move, old.name, field.name}
            true -> {:keep, field.name}
          end
        end)

      kept =
        for(step <- steps, do: step)
        |> Enum.flat_map(fn
          {:move, old, _new} -> [old]
          {:hand, old, _new} -> [old]
          {:keep, name} -> [name]
          _ -> []
        end)

      %{
        from: from.version,
        to: to.version,
        steps: steps,
        dropped: Enum.reject(Compiled.field_names(from), &(&1 in kept)),
        hand: Enum.any?(steps, &(elem(&1, 0) == :hand))
      }
    end)
  end

  defp moved({kind, old, new}) when kind in [:move, :hand] and old != new,
    do: "fields = move(fields, #{inspect(old)}, #{inspect(new)})\n"

  defp moved(_step), do: nil

  defp callbacks(upgrades), do: for(%{hand: true, from: v} <- upgrades, do: "upgrade_v#{v}")

  defp renamed_from(%Field{type: {:doc, _, notes}}) do
    case notes do
      %{"meta" => %{"typespec.renamed-from" => old}} -> old
      _ -> nil
    end
  end

  defp renamed_from(_field), do: nil

  defp meaning({:doc, type, _}), do: meaning(type)

  defp meaning(type) when is_tuple(type),
    do: type |> Tuple.to_list() |> Enum.map(&meaning/1) |> List.to_tuple()

  defp meaning(list) when is_list(list), do: Enum.map(list, &meaning/1)
  defp meaning(%Field{} = f), do: %{f | type: meaning(f.type), description: nil}
  defp meaning(other), do: other

  defp upgrade_code(_name, versions, upgrades) do
    steps =
      Enum.map_join(upgrades, "\n", fn %{from: from, to: to} = up ->
        moves =
          for(step <- up.steps, moved = moved(step), moved != nil, do: moved) ++
            for(old <- up.dropped, do: "fields = Map.delete(fields, #{inspect(old)})\n")

        tail = if up.hand, do: "@owner.upgrade_v#{from}(fields)", else: "fields"
        hand = for(step <- up.steps, elem(step, 0) == :hand, do: elem(step, tuple_size(step) - 1))

        """
          @doc "Fields of version #{from} as version #{to} has them.#{if hand != [], do: " #{Enum.join(hand, ", ")}: by hand, upgrade_v#{from}/1 in the user's module, or this region.", else: ""}"
          def upgrade_v#{from}(fields) do
            #{Enum.join(moves, "")}
            # dextrin:keep upgrade_v#{from}
            # dextrin:end upgrade_v#{from}
            #{tail}
          end
        """
      end)

    clauses =
      Enum.map_join(upgrades, "", fn %{from: from} ->
        "  defp upgrade_from(#{from}, fields), do: upgrade_from(#{from + 1}, upgrade_v#{from}(fields))\n"
      end)

    _ = versions

    move =
      if String.contains?(steps, "move(fields"),
        do: """
          defp move(fields, from, to) do
            case Map.pop(fields, from) do
              {nil, fields} -> fields
              {value, fields} -> Map.put(fields, to, value)
            end
          end
        """,
        else: ""

    """
    #{steps}
    #{clauses}  defp upgrade_from(_latest, fields), do: fields

    #{move}
    """
  end

  # ---- types --------------------------------------------------------------------

  # The name of a function `(value -> {:ok, value} | {:error, why})` for
  # `type`, written once per distinct type.
  defp type_fun(type, state) do
    case Map.fetch(state.seen, type) do
      {:ok, name} ->
        {name, state}

      :error ->
        name = "t#{state.next}"
        state = %{state | next: state.next + 1, seen: Map.put(state.seen, type, name)}
        {body, state} = type_body(type, state)
        {name, %{state | fns: ["  defp #{name}(v) do\n#{body}\n  end\n" | state.fns]}}
    end
  end

  defp ok, do: "{:ok, v}"
  defp err(what), do: "{:error, \"expected #{what}, got \" <> Runtime.show(v)}"

  defp type_body(:any, state), do: {ok(), state}
  defp type_body(:never, state), do: {"{:error, \"no value is allowed here\"}", state}

  defp type_body({:primitive, name}, state) do
    guard =
      %{
        "integer" => "is_integer(v)",
        "string" => "is_binary(v)",
        "boolean" => "is_boolean(v)",
        "nil" => "is_nil(v)",
        "list" => "is_list(v)",
        "map" => "is_map(v) and not is_struct(v)"
      }[name] || "TypeExpr.primitive?(#{inspect(name)}, v)"

    {"if #{guard}, do: #{ok()}, else: #{err(name)}", state}
  end

  defp type_body({:doc, type, _notes}, state) do
    {fun, state} = type_fun(type, state)
    {"#{fun}(v)", state}
  end

  defp type_body({:nilable, type}, state) do
    {fun, state} = type_fun(type, state)
    {"if is_nil(v), do: #{ok()}, else: #{fun}(v)", state}
  end

  defp type_body({:refine, base, constraints}, state) do
    unsupported =
      Map.keys(constraints) -- (Map.keys(constraints) -- ~w(contains content encodes encodes-seq))

    if unsupported != [],
      do: raise(ArgumentError, "refine keys not generated yet: #{Enum.join(unsupported, ", ")}")

    {fun, state} = type_fun(base, state)
    attr = "@c#{state.next}"

    state = %{
      state
      | next: state.next + 1,
        attrs: ["#{attr} Runtime.constraints!(#{inspect(dxn_text(constraints))})" | state.attrs]
    }

    body = """
    with {:ok, v} <- #{fun}(v) do
      if TypeExpr.constraints?(v, #{attr}, #{inspect(primitive_of(base))}),
        do: #{ok()},
        else: {:error, Runtime.show(v) <> " does not meet " <> Runtime.show(#{attr})}
    end
    """

    {body, state}
  end

  defp type_body({:enum, literals}, state) do
    attr = "@e#{state.next}"

    state = %{
      state
      | next: state.next + 1,
        attrs: ["#{attr} Runtime.value!(#{inspect(dxn_text(literals))})" | state.attrs]
    }

    {"if TypeExpr.enum_member?(#{attr}, v), do: #{ok()}, else: {:error, \"expected one of \" <> Runtime.show(#{attr}) <> \", got \" <> Runtime.show(v)}",
     state}
  end

  defp type_body({:list_of, type}, state) do
    {fun, state} = type_fun(type, state)

    body = """
    if is_list(v) do
      v
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {item, i}, {:ok, acc} ->
        case #{fun}(item) do
          {:ok, item} -> {:cont, {:ok, [item | acc]}}
          {:error, why} -> {:halt, {:error, "[\#{i}]: " <> why}}
        end
      end)
      |> then(fn {:ok, items} -> {:ok, Enum.reverse(items)}; error -> error end)
    else
      #{err("a list")}
    end
    """

    {body, state}
  end

  defp type_body({:map_of, key, value}, state) do
    {kfun, state} = type_fun(key, state)
    {vfun, state} = type_fun(value, state)

    body = """
    if is_map(v) and not is_struct(v) do
      Enum.reduce_while(v, {:ok, %{}}, fn {k, val}, {:ok, acc} ->
        with {:ok, k} <- #{kfun}(k), {:ok, val} <- #{vfun}(val) do
          {:cont, {:ok, Map.put(acc, k, val)}}
        else
          {:error, why} -> {:halt, {:error, Runtime.show(k) <> ": " <> why}}
        end
      end)
    else
      #{err("a map")}
    end
    """

    {body, state}
  end

  defp type_body({kind, types}, state) when kind in [:any_of, :one_of, :all_of] do
    {funs, state} = Enum.map_reduce(types, state, &type_fun/2)

    body =
      case kind do
        :any_of ->
          "Enum.find_value(#{list(funs)}, #{err("one of its variants")}, fn f -> case f.(v) do {:ok, _} = ok -> ok; _ -> nil end end)"

        :one_of ->
          """
          case Enum.filter(#{list(funs)}, &match?({:ok, _}, &1.(v))) do
            [f] -> f.(v)
            [] -> #{err("one of its variants")}
            _ -> {:error, "more than one variant takes " <> Runtime.show(v)}
          end
          """

        :all_of ->
          "Enum.reduce_while(#{list(funs)}, {:ok, v}, fn f, {:ok, v} -> case f.(v) do {:ok, _} = ok -> {:cont, ok}; error -> {:halt, error} end end)"
      end

    {body, state}
  end

  defp type_body({:not, type}, state) do
    {fun, state} = type_fun(type, state)

    {"case #{fun}(v) do {:ok, _} -> {:error, Runtime.show(v) <> \" is what is excluded\"}; _ -> #{ok()} end",
     state}
  end

  defp type_body({:if, test, then, otherwise}, state) do
    {tf, state} = type_fun(test, state)
    {thf, state} = type_fun(then, state)
    {ef, state} = type_fun(otherwise, state)
    {"case #{tf}(v) do {:ok, _} -> #{thf}(v); _ -> #{ef}(v) end", state}
  end

  defp type_body({:reference, name}, state) do
    module = Map.fetch!(state.modules, name)

    {"case v do %Dextrin.Struct{name: #{inspect(name)}} -> #{module}.Gen.read(v); %{__struct__: #{module}} -> #{module}.Gen.validate(v) |> then(fn :ok -> {:ok, v}; e -> e end); _ -> #{err(name)} end",
     state}
  end

  defp type_body({:shape, _name, fields, extras}, state) do
    {checks, state} =
      Enum.map_reduce(fields, state, fn field, state ->
        {fun, state} = type_fun(field.type, state)
        {String.trim_trailing(shape_check(field, fun)), state}
      end)

    {extra_check, state} = extras_check(extras, Enum.map(fields, & &1.name), state)

    body = """
    if is_map(v) and not is_struct(v) do
      with {:ok, v} <- Enum.reduce_while([#{Enum.join(checks, ", ")}], {:ok, v}, fn check, {:ok, acc} ->
             case check.(acc) do
               {:ok, acc} -> {:cont, {:ok, acc}}
               error -> {:halt, error}
             end
           end) do
        #{extra_check}
      end
    else
      #{err("a map")}
    end
    """

    {body, state}
  end

  defp type_body({:named, name}, state) do
    type = Map.fetch!(state.registry.type_aliases, name)
    fun = "n_" <> String.replace(name, ~r/[^A-Za-z0-9_]/, "_")

    if Map.has_key?(state.seen, {:named, name}) do
      {"#{fun}(v)", state}
    else
      state = %{state | seen: Map.put(state.seen, {:named, name}, fun)}
      {inner, state} = type_fun(type, state)
      {"#{fun}(v)", %{state | fns: ["  defp #{fun}(v), do: #{inner}(v)\n" | state.fns]}}
    end
  end

  defp type_body(type, _state),
    do: raise(ArgumentError, "a type the generator does not write yet: #{inspect(type)}")

  defp list(funs), do: "[" <> Enum.map_join(funs, ", ", &"&#{&1}/1") <> "]"

  # A shape's field: put back under its key, a default filled in.
  defp shape_check(%Field{name: name, required: required, default: default}, fun) do
    absent =
      cond do
        default != :none ->
          "{:ok, Map.put(map, %Dextrin.Keyword{name: #{inspect(name)}}, Runtime.value!(#{inspect(dxn_text(Field.filled(default)))}))}"

        required ->
          "{:error, \"missing required field #{name}\"}"

        true ->
          "{:ok, map}"
      end

    """
    fn map ->
      case Runtime.field(map, #{inspect(name)}) do
        {:ok, key, value} ->
          case #{fun}(value) do
            {:ok, value} -> {:ok, Map.put(map, key, value)}
            {:error, why} -> {:error, "#{name}: " <> why}
          end
        :none -> #{absent}
      end
    end
    """
  end

  defp extras_check(%{entries: [], closed: false}, _names, state), do: {"{:ok, v}", state}

  defp extras_check(%{entries: [], closed: true}, names, state) do
    {"case Runtime.undeclared(v, #{inspect(names)}) do [] -> {:ok, v}; [{k, _} | _] -> {:error, Runtime.show(k) <> \" is no field, and the shape is closed\"} end",
     state}
  end

  defp extras_check(_extras, _names, _state),
    do: raise(ArgumentError, "typed extras (* K => V) are not generated yet")

  defp primitive_of({:primitive, _} = p), do: p
  defp primitive_of({:refine, base, _}), do: primitive_of(base)
  defp primitive_of({:doc, base, _}), do: primitive_of(base)
  defp primitive_of(_), do: :any

  # ---- regions ------------------------------------------------------------------

  @region ~r/^([ \t]*)# dextrin:keep (\S+)\n(.*?)^[ \t]*# dextrin:end \2\n/ms

  # `generated` with the regions of `old` put back by name; one whose slot
  # is gone kept at the end of the module as an orphan.
  defp merge_regions(generated, nil), do: generated

  defp merge_regions(generated, old) do
    kept =
      for [_, _indent, name, body] <- Regex.scan(@region, old),
          body != "",
          into: %{},
          do: {name, body}

    slots =
      for [_, _indent, name, _] <- Regex.scan(@region, generated), into: MapSet.new(), do: name

    filled =
      Regex.replace(@region, generated, fn whole, indent, name, _body ->
        case Map.fetch(kept, name) do
          {:ok, body} ->
            "#{indent}# dextrin:keep #{name}\n#{body}#{indent}# dextrin:end #{name}\n"

          :error ->
            whole
        end
      end)

    orphans =
      for {name, body} <- Enum.sort(kept), not MapSet.member?(slots, name) do
        orphan = if String.starts_with?(name, "orphaned_"), do: name, else: "orphaned_" <> name

        "  # dextrin:keep #{orphan}\n  # Was in the region #{String.replace_prefix(name, "orphaned_", "")}, whose place is gone: move it, or delete it.\n#{body}  # dextrin:end #{orphan}\n"
      end

    if orphans == [] do
      filled
    else
      String.replace(filled, ~r/\nend\n\z/, "\n\n" <> Enum.join(orphans, "\n") <> "end\n")
    end
  end
end
