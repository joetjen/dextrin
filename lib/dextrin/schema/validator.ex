defmodule Dextrin.Schema.Validator do
  @moduledoc """
  Checks a value's fields against a `Dextrin.Schema.Compiled` schema
  (required/closed/forbidden/refine) — shared by decode (`materialize/4`,
  which also produces a materialized result) and encode-time validation
  (`validate_for_encode/3`/`validate_tree_for_encode/2`, which never
  transforms `value`). Both directions reuse the exact same
  `resolve_fields/3`/`TypeExpr.matches?/3` field-checking — encode's
  own values are wrapped in the same internal `Dextrin.Schema.
  Validated` marker decode already uses, via `wrap_and_check/2`, so
  there's one type-checking implementation, not two that could drift.

  Enforcement is decode-time and fail-fast, with no lenient escape
  hatch to get the materialized value anyway — a violation is always
  an error, on the same channel an ordinary syntax error already uses.
  """

  alias Dextrin.Schema.{Compiled, Field, TypeExpr, Validated}
  alias Dextrin.{Array, CustomTag, OrderedMap, Registry, SortedSet, Struct}
  alias Ichor.Toolkit.Result

  @type fields :: {:keyed, [{String.t(), term()}]} | {:positional, [term()]}

  @doc """
  Validates and materializes `fields` against `compiled`, using
  `materializer` if given. On success, the result is wrapped in a
  `Validated` (name: `compiled.name`) — internal bookkeeping so an
  *outer* schema's `{:reference, name}` field can verify this value's
  origin even after materialization; callers that aren't another
  schema check (the true top of decoding) must call `Validated.strip/1`
  on the final result.
  """
  @spec materialize(
          Compiled.t(),
          fields(),
          Dextrin.Registry.struct_materializer() | nil,
          Registry.t()
        ) ::
          {:ok, Validated.t()} | {:error, String.t()}
  def materialize(%Compiled{} = compiled, fields, materializer, registry) do
    with {:ok, given} <- to_name_map(compiled, fields),
         :ok <- check_forbidden(compiled, given),
         :ok <- check_closed(compiled, given),
         {:ok, resolved} <- resolve_fields(compiled, given, registry),
         :ok <- run_refine_fn(compiled, resolved),
         {:ok, result} <- materialize_result(resolved, materializer) do
      {:ok, %Validated{name: compiled.name, value: result}}
    end
  end

  # `pairs`' keys arrive as whatever shape `Dextrin.Struct.keyed/2`'s
  # own field-name rule produced (atom, `Dextrin.Keyword.t()`,
  # `Dextrin.Symbol.t()`, or `String.t()` — see its moduledoc) rather
  # than always `String.t()`; `stringify_key/1` (already used for the
  # encode-side mirror below) collapses that to the one representation
  # `field.name` lookups below compare against.
  defp to_name_map(_compiled, {:keyed, pairs}), do: {:ok, Map.new(pairs, &stringify_key/1)}

  defp to_name_map(%Compiled{fields: schema_fields}, {:positional, items}) do
    names = Enum.map(schema_fields, & &1.name)

    if length(names) == length(items) do
      {:ok, Map.new(Enum.zip(names, items))}
    else
      {:error, "expected #{length(names)} positional field(s), got #{length(items)}"}
    end
  end

  defp check_forbidden(%Compiled{forbidden: forbidden}, given) do
    case Enum.find(forbidden, &Map.has_key?(given, &1)) do
      nil -> :ok
      name -> {:error, "field #{inspect(name)} is forbidden"}
    end
  end

  defp check_closed(%Compiled{closed: false}, _given), do: :ok

  defp check_closed(%Compiled{closed: true, fields: fields}, given) do
    allowed = MapSet.new(fields, & &1.name)

    case Enum.find(Map.keys(given), &(not MapSet.member?(allowed, &1))) do
      nil -> :ok
      extra -> {:error, "unknown field #{inspect(extra)} (schema is closed)"}
    end
  end

  defp resolve_fields(%Compiled{fields: fields}, given, registry) do
    Result.reduce_ok(fields, %{}, fn %Field{} = field, acc ->
      case resolve_field(field, given, registry) do
        {:ok, value} -> {:ok, Map.put(acc, String.to_atom(field.name), value)}
        {:error, _} = err -> err
      end
    end)
  end

  defp resolve_field(
         %Field{name: name, required: required, default: default, type: type},
         given,
         registry
       ) do
    case Map.fetch(given, name) do
      {:ok, value} -> check_type(name, value, type, registry)
      :error when default != :none -> {:ok, default}
      :error when required -> {:error, "missing required field #{inspect(name)}"}
      :error -> {:ok, nil}
    end
  end

  defp check_type(name, value, type, registry) do
    if TypeExpr.matches?(type, value, registry) do
      # Stripped here, not deferred to the top: `value` is about to be
      # handed to *this* struct's own materializer (decode) or stored
      # as a checked field value (encode) — neither should ever see an
      # internal `Validated` wrapper once it's done its one job.
      {:ok, Validated.strip(value)}
    else
      {:error, "field #{inspect(name)} does not match its declared type"}
    end
  end

  defp run_refine_fn(%Compiled{refine_fn: nil}, _resolved), do: :ok
  defp run_refine_fn(%Compiled{refine_fn: fun}, resolved), do: fun.(resolved)

  # `resolved` is already atom-keyed (`resolve_fields/3` builds it via
  # `String.to_atom(field.name)` — safe since field names come from the
  # compiled schema, a fixed vocabulary, never the untrusted payload
  # being validated). With no materializer registered, that's the
  # result as-is: a schema-backed struct's default materialization
  # gets real atom keys the same way a plain trusted map would,
  # matching what `struct_materializer`'s own type signature already
  # expects as *input* — no reason for "no materializer" to hand back a
  # different key shape than a materializer itself receives.
  defp materialize_result(resolved, nil), do: {:ok, resolved}

  defp materialize_result(resolved, materializer), do: materializer.(resolved)

  # ---- encode-time validation -------------------------------------------------
  #
  # The mirror image of `materialize/4`, for data on its way *out*:
  # `value` here is ordinary Elixir data you're about to encode — a
  # `Dextrin.Struct` (the one shape that round-trips to `%Name{...}`
  # wire syntax), a plain map (atom or string keys), or a real
  # application struct — and nothing gets materialized or transformed,
  # only ever answers `:ok | {:error, reason}`.
  #
  # The one real difference from decode: decode's nested structs
  # arrive *already* `Validated`-wrapped, bottom-up, as a natural
  # consequence of how decoding recurses. Encode has no such built-in
  # recursion to piggyback on, so `wrap_and_check/2` does it
  # explicitly — walking `value`, wrapping every recognized struct
  # (by its own name, or by `Registry.fetch_schema_name_for_module/2`
  # for a registered application struct) the same way, *before*
  # `resolve_fields/3` ever sees it. That's what lets `check_compiled/3`
  # reuse `resolve_fields/3`/`TypeExpr.matches?/3` completely unchanged
  # from decode's — including full recursive validation of whatever a
  # `{:reference, name}` field points at, not just its type identity.

  @doc """
  Checks `value` — ordinary Elixir data you're about to encode —
  against `compiled`. Never materializes; `value` itself is never
  transformed.
  """
  @spec validate_for_encode(Compiled.t(), term(), Registry.t()) :: :ok | {:error, String.t()}
  def validate_for_encode(%Compiled{} = compiled, value, registry),
    do: check_compiled(compiled, value, registry)

  @doc """
  Walks `value` looking for every `Dextrin.Struct` or registered
  application struct anywhere in the tree and checks each one against
  its own schema, if the registry has one — regardless of what any
  enclosing field's declared type is, and recursing fully into
  whatever it finds (not just confirming type identity).
  `Dextrin.encode/2`/`encode_binary/2` call this automatically (opt
  out with `validate: false`).
  """
  @spec validate_tree_for_encode(term(), Registry.t()) :: :ok | {:error, String.t()}
  def validate_tree_for_encode(value, registry) do
    case wrap_and_check(value, registry) do
      {:ok, _wrapped} -> :ok
      {:error, _} = err -> err
    end
  end

  defp check_compiled(compiled, value, registry) do
    with {:ok, given} <- to_name_map_for_encode(compiled, value),
         {:ok, given} <- wrap_given(given, registry),
         :ok <- check_forbidden(compiled, given),
         :ok <- check_closed(compiled, given),
         {:ok, resolved} <- resolve_fields(compiled, given, registry),
         :ok <- run_refine_fn(compiled, resolved) do
      :ok
    end
  end

  defp to_name_map_for_encode(_compiled, %Struct{fields: {:keyed, pairs}}),
    do: {:ok, Map.new(pairs, &stringify_key/1)}

  defp to_name_map_for_encode(%Compiled{fields: schema_fields}, %Struct{
         fields: {:positional, items}
       }) do
    names = Enum.map(schema_fields, & &1.name)

    if length(names) == length(items) do
      {:ok, Map.new(Enum.zip(names, items))}
    else
      {:error, "expected #{length(names)} positional field(s), got #{length(items)}"}
    end
  end

  defp to_name_map_for_encode(_compiled, value) when is_struct(value) do
    {:ok, value |> Map.from_struct() |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)}
  end

  defp to_name_map_for_encode(_compiled, %{} = value) when not is_struct(value) do
    {:ok, Map.new(value, &stringify_key/1)}
  end

  defp to_name_map_for_encode(_compiled, other) do
    {:error, "expected a map or struct to validate against a schema, got #{inspect(other)}"}
  end

  # Shared by both directions: a decode-side `Dextrin.Struct.fields`
  # keyed pair and an encode-side plain map both key their
  # shorthand/symbol entries with `Dextrin.Keyword.t()`/
  # `Dextrin.Symbol.t()` or a bare atom, never one canonical
  # representation up front (see `Dextrin.Struct`'s own moduledoc) --
  # this is what lets `resolve_field/3`'s `field.name`-keyed lookup
  # below treat all of those the same, regardless of which literal
  # form the source actually used.
  defp stringify_key({%Dextrin.Keyword{name: name}, v}), do: {name, v}
  defp stringify_key({%Dextrin.Symbol{name: name}, v}), do: {name, v}
  defp stringify_key({k, v}) when is_atom(k), do: {Atom.to_string(k), v}
  defp stringify_key({k, v}) when is_binary(k), do: {k, v}
  defp stringify_key({k, v}), do: {k, v}

  # `wrap_and_check/2` is the recursive core: for any value that's a
  # named struct with a registered schema, check it (`check_compiled/3`)
  # and wrap the result in `Validated`; otherwise recurse into whatever
  # container it is, reconstructing it from the (possibly wrapped)
  # results so a wrapped grandchild survives all the way up to
  # whichever ancestor's field type actually needs to see it.

  defp wrap_and_check(value, registry) do
    case schema_name_for(value, registry) do
      {:ok, name, compiled} ->
        case check_compiled(compiled, value, registry) do
          :ok -> {:ok, %Validated{name: name, value: value}}
          {:error, reason} -> {:error, "struct #{inspect(name)} violates its schema: #{reason}"}
        end

      :unknown ->
        wrap_children(value, registry)
    end
  end

  defp schema_name_for(%Struct{name: name}, registry) do
    case Registry.fetch_struct_schema(registry, name) do
      {:ok, compiled, _registry} -> {:ok, name, compiled}
      {:unknown, _registry} -> :unknown
    end
  end

  defp schema_name_for(value, registry) when is_struct(value) do
    with {:ok, name} <- Registry.fetch_schema_name_for_module(registry, value.__struct__),
         {:ok, compiled, _registry} <- Registry.fetch_struct_schema(registry, name) do
      {:ok, name, compiled}
    else
      _ -> :unknown
    end
  end

  defp schema_name_for(_value, _registry), do: :unknown

  defp wrap_given(given, registry) do
    Result.reduce_ok(given, %{}, fn {k, v}, acc ->
      case wrap_and_check(v, registry) do
        {:ok, wrapped} -> {:ok, Map.put(acc, k, wrapped)}
        {:error, _} = err -> err
      end
    end)
  end

  defp wrap_children(list, registry) when is_list(list), do: wrap_all(list, registry)

  defp wrap_children(%Dextrin.Tuple{items: items} = t, registry) do
    with {:ok, wrapped} <- wrap_all(items, registry), do: {:ok, %{t | items: wrapped}}
  end

  defp wrap_children(%Array{items: items} = a, registry) do
    with {:ok, wrapped} <- items |> Tuple.to_list() |> wrap_all(registry) do
      {:ok, %{a | items: List.to_tuple(wrapped)}}
    end
  end

  defp wrap_children(%OrderedMap{pairs: pairs} = om, registry) do
    with {:ok, wrapped} <- wrap_pairs(pairs, registry), do: {:ok, %{om | pairs: wrapped}}
  end

  defp wrap_children(%MapSet{} = set, registry) do
    with {:ok, wrapped} <- set |> MapSet.to_list() |> wrap_all(registry),
         do: {:ok, MapSet.new(wrapped)}
  end

  defp wrap_children(%SortedSet{items: items} = ss, registry) do
    with {:ok, wrapped} <- wrap_all(items, registry), do: {:ok, %{ss | items: wrapped}}
  end

  defp wrap_children(%Struct{fields: {:keyed, pairs}} = s, registry) do
    with {:ok, wrapped} <- wrap_pairs(pairs, registry),
         do: {:ok, %{s | fields: {:keyed, wrapped}}}
  end

  defp wrap_children(%Struct{fields: {:positional, items}} = s, registry) do
    with {:ok, wrapped} <- wrap_all(items, registry),
         do: {:ok, %{s | fields: {:positional, wrapped}}}
  end

  defp wrap_children(%CustomTag{value: value} = c, registry) do
    with {:ok, wrapped} <- wrap_and_check(value, registry), do: {:ok, %{c | value: wrapped}}
  end

  defp wrap_children(%{} = map, registry) when not is_struct(map) do
    with {:ok, wrapped} <- wrap_pairs(Map.to_list(map), registry), do: {:ok, Map.new(wrapped)}
  end

  defp wrap_children(value, registry) when is_struct(value) do
    # An application struct with no schema of its own — still worth
    # reaching into, in case something deeper does have one.
    with {:ok, wrapped} <- value |> Map.from_struct() |> Map.to_list() |> wrap_pairs(registry) do
      {:ok, struct(value.__struct__, wrapped)}
    end
  end

  defp wrap_children(other, _registry), do: {:ok, other}

  defp wrap_all(values, registry) do
    Result.reduce_ok(values, [], fn v, acc ->
      case wrap_and_check(v, registry) do
        {:ok, wrapped} -> {:ok, [wrapped | acc]}
        {:error, _} = err -> err
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp wrap_pairs(pairs, registry) do
    Result.reduce_ok(pairs, [], fn {k, v}, acc ->
      case wrap_and_check(v, registry) do
        {:ok, wrapped} -> {:ok, [{k, wrapped} | acc]}
        {:error, _} = err -> err
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end
end
