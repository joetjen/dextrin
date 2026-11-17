defmodule Dextrin.Schema.PinTest do
  @moduledoc """
  G11 and Q4 of design/typespec.md (T673, Jan, 2026-11-17): a field
  pinned to one version of a schema or a named type, written `Pet(1)` --
  text sugar for `{:at Pet 1}` -- and named types with versions of their
  own, `%type(N)[T]` (Way B). Unpinned, a reference means the latest.
  """

  use ExUnit.Case, async: true

  alias Dextrin.{Keyword, Registry, Schema, Symbol, Tuple}

  doctest Dextrin.Tuple

  defp loaded(sources, registry \\ Registry.new()) do
    Enum.reduce(sources, registry, fn source, registry ->
      {:ok, doc} = Dextrin.decode(source)
      {:ok, registry} = Schema.compile(doc, registry)
      registry
    end)
  end

  defp compile_error(sources) do
    [last | first] = Enum.reverse(sources)
    {:ok, doc} = Dextrin.decode(last)

    {:error, %Dextrin.Error{category: category, message: message}} =
      Schema.compile(doc, loaded(Enum.reverse(first)))

    {category, message}
  end

  defp category({:error, %Dextrin.Error{category: category}}), do: category
  defp category(other), do: other

  describe "Name(N) in DXN text" do
    test "reads as {:at Name N}, wherever it stands" do
      at = %Tuple{items: [Keyword.new("at"), Symbol.new("Pet"), 1]}
      assert {:ok, ^at} = Dextrin.decode("Pet(1)")
      assert Dextrin.decode("Pet(1)") == Dextrin.decode("{:at Pet 1}")
      assert {:ok, [^at, 2]} = Dextrin.decode("[Pet(1) 2]")
      assert {:ok, %Tuple{items: [:at, _, 3]}} = Dextrin.decode("acme/Pet(3)", trusted: true)
    end

    test "is written back as Name(N), plain, pretty and canonical" do
      {:ok, value} = Dextrin.decode("%{pet: {:at acme.zoo/Pet 2}, n: 1}")
      assert {:ok, text} = Dextrin.encode(value)
      assert text =~ "acme.zoo/Pet(2)"
      assert {:ok, pretty} = Dextrin.encode(value, pretty: true)
      assert pretty =~ "acme.zoo/Pet(2)"
      assert {:ok, canonical} = Dextrin.Canonical.print(value)
      assert canonical =~ "acme.zoo/Pet(2)"
    end

    test "any other {:at ...} is an ordinary tuple, written as one" do
      for text <- ["{:at Pet 0}", "{:at \"Pet\" 1}", "{:at Pet 1 2}", "{:at Pet}"] do
        {:ok, value} = Dextrin.decode(text)
        assert {:ok, written} = Dextrin.encode(value)
        assert String.starts_with?(written, "{"), text
      end
    end

    test "the version is a positive integer" do
      assert {:error, %Dextrin.Error{message: message}} = Dextrin.decode("Pet(0)")
      assert message =~ "positive"
      assert {:error, _} = Dextrin.decode("Pet(x)")
    end

    test "the lossless formatter keeps it as written" do
      {:ok, doc} = Dextrin.Document.parse("%{pet:   Pet(1)}")
      assert Dextrin.Document.format(doc) =~ "pet: Pet(1)"
    end
  end

  describe "a field pinned to a schema version" do
    @pets [
      "%{Pet: %schema(1){name: :string, colour: :string}}",
      "%{Pet: %schema(2){name: :string, color: :string}}"
    ]

    defp pets(owner) do
      @pets
      |> loaded()
      |> Registry.put_struct_materializer("Pet", fn
        _name, 1, fields -> {:ok, %{"name" => fields["name"], "color" => fields["colour"]}}
        _name, _version, fields -> {:ok, fields}
      end)
      |> then(&loaded([owner], &1))
    end

    test "takes that version only, and keeps it as written, not upgraded" do
      r = pets("%{Owner: %schema{pet: Pet(1)}}")

      assert {:ok, %Dextrin.Struct{fields: {:keyed, [{"pet", pet}]}}} =
               Dextrin.decode(~s|%Owner{pet: %Pet(1){name: "a", colour: "red"}}|, registry: r)

      assert %Dextrin.Struct{name: "Pet", version: 1, fields: {:keyed, fields}} = pet
      assert {"colour", "red"} in fields

      for text <- [
            ~s|%Owner{pet: %Pet(2){name: "a", color: "red"}}|,
            ~s|%Owner{pet: %Pet{name: "a", color: "red"}}|
          ] do
        assert category(Dextrin.decode(text, registry: r)) == "schema/type-mismatch", text
      end
    end

    test "needs no materializer: the struct is taken as read" do
      r = loaded(@pets ++ ["%{Owner: %schema{pet: Pet(1)}, Keeper: %schema{pet: Pet}}"])

      assert {:ok, _} =
               Dextrin.decode(~s|%Owner{pet: %Pet(1){name: "a", colour: "red"}}|, registry: r)

      assert category(
               Dextrin.decode(~s|%Keeper{pet: %Pet(1){name: "a", colour: "red"}}|, registry: r)
             ) == "schema/no-materializer"

      assert category(Dextrin.decode(~s|[%Pet(1){name: "a", colour: "red"}]|, registry: r)) ==
               "schema/no-materializer"
    end

    test "unpinned, any loaded version is taken and upgraded to the latest" do
      r = pets("%{Owner: %schema{pet: Pet}}")

      assert {:ok, %Dextrin.Struct{fields: {:keyed, [{"pet", %{"color" => "red"}}]}}} =
               Dextrin.decode(~s|%Owner{pet: %Pet(1){name: "a", colour: "red"}}|, registry: r)
    end

    test "is written at that version" do
      r = pets("%{Owner: %schema{pet: Pet(1)}}")
      pet = Dextrin.Struct.keyed("Pet", [{"name", "a"}, {"colour", "red"}], 1)
      owner = Dextrin.Struct.keyed("Owner", [{"pet", pet}])
      assert {:ok, text} = Dextrin.encode(owner, registry: r)
      assert text =~ "%Pet(1){"

      wrong = Dextrin.Struct.keyed("Owner", [{"pet", %{pet | version: 2}}])
      assert {:error, _} = Dextrin.encode(wrong, registry: r)
    end

    test "is written to binary at that version, in its field order" do
      r = pets("%{Owner: %schema{pet: Pet(1)}}")
      pet = Dextrin.Struct.keyed("Pet", [{"colour", "red"}, {"name", "a"}], 1)
      assert {:ok, bytes} = Dextrin.encode_binary(pet, registry: r)

      assert {:ok, %Dextrin.Struct{name: "Pet", version: 1, fields: {:positional, ["a", "red"]}}} =
               Dextrin.decode_binary(bytes)
    end

    test "checked alone, an older version without a materializer is still refused" do
      r = loaded(@pets)
      pet = Dextrin.Struct.keyed("Pet", [{"name", "a"}, {"colour", "red"}], 1)

      assert {:error, %Dextrin.Error{category: "schema/no-materializer"}} =
               Schema.check(pet, r, "Pet")
    end

    test "a pinned variant is named by its pin" do
      assert {:error, %Dextrin.Error{message: message}} =
               Schema.compile(
                 elem(
                   Dextrin.decode("%{U: {:doc {:one-of Pet(1) Pet(2)} %{discriminator: :kind}}}"),
                   1
                 ),
                 loaded(@pets)
               )

      assert message =~ "Pet(1)"
    end

    test "{:at Pet 1} and Pet(1) are the same field" do
      a = pets("%{Owner: %schema{pet: Pet(1)}}")
      b = pets("%{Owner: %schema{pet: {:at Pet 1}}}")

      assert Registry.fetch_struct_schema(a, "Owner") |> elem(1) |> Map.get(:fields) ==
               Registry.fetch_struct_schema(b, "Owner") |> elem(1) |> Map.get(:fields)
    end
  end

  describe "a named type with versions (%type(N))" do
    @colors [
      "%{Color: %type(1)[{:enum :red :green}]}",
      "%{Color: %type(2)[{:enum :red :green :blue}]}"
    ]

    test "a reference means the latest; a pin means that version" do
      r =
        loaded(
          @colors ++
            ["%{Car: %schema{paint: Color}, OldCar: %schema{paint: Color(1)}}"]
        )

      assert {:ok, _} = Dextrin.decode("%Car{paint: :blue}", registry: r)
      assert {:ok, _} = Dextrin.decode("%OldCar{paint: :red}", registry: r)

      assert category(Dextrin.decode("%OldCar{paint: :blue}", registry: r)) ==
               "schema/type-mismatch"
    end

    test "a plain definition is version 1" do
      r = loaded(["%{Color: {:enum :red}}", "%{Color: %type(2)[{:enum :red :blue}]}"])
      assert Schema.check(Dextrin.Keyword.new("blue"), r, "Color") == :ok
      r = loaded(["%{Car: %schema{paint: Color(1)}}"], r)
      assert category(Dextrin.decode("%Car{paint: :blue}", registry: r)) == "schema/type-mismatch"
    end

    test "each version once; the same definition again is no change" do
      assert {"schema/duplicate-version", message} =
               compile_error(@colors ++ ["%{Color: %type(2)[{:enum :red}]}"])

      assert message =~ "Color"
      assert %Registry{} = loaded(@colors ++ ["%{Color: %type(2)[{:enum :red :green :blue}]}"])
    end

    test "a pin to a version not loaded is a compile error" do
      assert {"schema/compile", message} =
               compile_error(@colors ++ ["%{Car: %schema{paint: Color(3)}}"])

      assert message =~ "Color(3)"
    end

    test "%type takes one item, the type, and a version" do
      for text <- [
            "%{C: %type(1)[:string :integer]}",
            "%{C: %type[:string]}",
            "%{C: %type(1){a: 1}}"
          ] do
        assert {:error, %Dextrin.Error{category: "schema/compile"}} =
                 Schema.compile(elem(Dextrin.decode(text), 1), Registry.new()),
               text
      end
    end

    test "one version can be deprecated" do
      r =
        loaded([
          ~s|%{Color: {:doc %type(1)[{:enum :red :green}] %{deprecated: "use Color(2)"}}}|,
          "%{Color: %type(2)[{:enum :red :green :blue}]}",
          "%{Car: %schema{paint: Color}, OldCar: %schema{paint: Color(1)}}"
        ])

      assert [%{name: "Color", version: 1, at: "OldCar"}] = Registry.warnings(r)
    end
  end
end
