defmodule Dextrin.Schema.DeprecationTest do
  @moduledoc """
  G10 of design/typespec.md (T673, Jan, 2026-11-17): "mark Schemas in
  Dextrin as deprecated, and generate a warning when they are used",
  and "we need to be able to deprecate a specific version of a schema,
  not only the whole schema".

  `deprecated:` (DXNS.md §1b) on a version's own entry deprecates that
  version only. A warning fires when a schema compiles against what is
  deprecated, and when data goes through it; `deprecations:` says how
  often, or makes it an error (`schema/deprecated`), and
  `on_deprecated:` receives each warning in place of the log.
  """

  use ExUnit.Case, async: true

  alias Dextrin.{Registry, Schema}

  doctest Dextrin.Schema, only: [annotations: 3]

  @pet_v1 ~s|%{Pet: {:doc %schema(1){name: :string, colour: :string} %{deprecated: "use Pet(2)"}}}|
  @pet_v2 "%{Pet: %schema(2){name: :string, color: :string}}"

  defp loaded(sources, registry \\ Registry.new()) do
    Enum.reduce(sources, registry, fn source, registry ->
      {:ok, doc} = Dextrin.decode(source)
      {:ok, registry} = Schema.compile(doc, registry)
      registry
    end)
  end

  defp upgraded(registry) do
    Registry.put_struct_materializer(registry, "Pet", fn
      _name, 1, fields -> {:ok, %{"name" => fields["name"], "color" => fields["colour"]}}
      _name, _version, fields -> {:ok, fields}
    end)
  end

  # Decodes `text`, every warning sent to this process.
  defp decode(text, registry, opts \\ []) do
    me = self()

    Dextrin.decode(
      text,
      [registry: registry, on_deprecated: &send(me, {:deprecated, &1})] ++ opts
    )
  end

  defp warnings do
    receive do
      {:deprecated, warning} -> [warning | warnings()]
    after
      0 -> []
    end
  end

  describe "one version of a schema" do
    test "data written with it warns, naming the version and the reason" do
      r = upgraded(loaded([@pet_v1, @pet_v2]))
      assert {:ok, _} = decode(~s|%Pet(1){name: "a", colour: "red"}|, r)

      assert [%{name: "Pet", version: 1, message: "use Pet(2)", category: "schema/deprecated"}] =
               warnings()
    end

    test "the other versions, and data with no version, do not" do
      r = upgraded(loaded([@pet_v1, @pet_v2]))
      assert {:ok, _} = decode(~s|%Pet(2){name: "a", color: "red"}|, r)
      assert {:ok, _} = decode(~s|%Pet{name: "a", color: "red"}|, r)
      assert warnings() == []
    end

    test "a reader upgrading it to the latest still warns, once" do
      r = upgraded(loaded([@pet_v1, @pet_v2]))

      assert {:ok, [_, _]} =
               decode(~s|[%Pet(1){name: "a", colour: "red"} %Pet(1){name: "b", colour: "g"}]|, r)

      assert [%{version: 1}] = warnings()
      assert {:ok, _} = decode(~s|%Pet(1){name: "c", colour: "red"}|, r)
      assert warnings() == []
    end

    test "every use warns under deprecations: :every, none under :off" do
      r = upgraded(loaded([@pet_v1, @pet_v2]))
      text = ~s|[%Pet(1){name: "a", colour: "red"} %Pet(1){name: "b", colour: "g"}]|
      assert {:ok, _} = decode(text, r, deprecations: :every)
      assert length(warnings()) == 2
      assert {:ok, _} = decode(text, r, deprecations: :off)
      assert warnings() == []
    end

    test "is an error under deprecations: :error" do
      r = upgraded(loaded([@pet_v1, @pet_v2]))

      assert {:error, %Dextrin.Error{category: "schema/deprecated"}} =
               decode(~s|%Pet(1){name: "a", colour: "red"}|, r, deprecations: :error)
    end

    test "a base naming that version warns when the schema compiles; any other does not" do
      r = loaded([@pet_v1, @pet_v2])

      pinned = loaded(["%{Show: %schema includes Pet(1) {judge: :string}}"], r)
      assert [%{name: "Pet", version: 1, at: "Show"}] = Registry.warnings(pinned)

      for text <- [
            "%{Show: %schema includes Pet(2) {judge: :string}}",
            "%{Show: %schema includes Pet {judge: :string}}",
            "%{Owner: %schema{pet: Pet}}"
          ] do
        assert Registry.warnings(loaded([text], r)) == [], text
      end
    end

    test "its annotations are read by its version" do
      r = loaded([@pet_v1, @pet_v2])
      assert {:ok, %{"deprecated" => "use Pet(2)"}} = Schema.annotations(r, "Pet", 1)
      assert {:ok, annotations} = Schema.annotations(r, "Pet", 2)
      refute Map.has_key?(annotations, "deprecated")
    end
  end

  describe "a whole schema" do
    @old """
    %{
      Old: {:doc %schema{x: :integer} %{deprecated: true}}
      Holder: %schema{old: Old}
    }
    """

    test "warns where another schema names it, and stays silent in what is deprecated itself" do
      r = loaded([@old])
      assert [%{name: "Old", at: "Holder"}] = Registry.warnings(r)

      quiet =
        loaded([
          "%{Old: {:doc %schema{x: :integer} %{deprecated: true}}, Older: {:doc %schema{o: Old} %{deprecated: true}}}"
        ])

      assert Registry.warnings(quiet) == []
    end

    test "data of it warns, whatever its version" do
      assert {:ok, _} = decode("%Holder{old: %Old{x: 1}}", loaded([@old]))
      assert [%{name: "Old", message: nil}] = warnings()
    end
  end

  describe "a named type" do
    test "warns where a schema names it, and when data goes through it" do
      r =
        loaded([
          ~s|%{Colour: {:doc {:enum :red :green} %{deprecated: "use Color"}}, Car: %schema{paint: Colour}}|
        ])

      assert [%{name: "Colour", version: nil, message: "use Color", at: "Car"}] =
               Registry.warnings(r)

      assert {:ok, _} = decode("%Car{paint: :red}", r)
      assert [%{message: "use Color"}] = warnings()
    end
  end

  describe "a field, an enum value and a variant" do
    @parts """
    %{
      User: %schema{
        email: :string
        legacy?: {:doc :string %{deprecated: "use email"}}
        color?: {:doc {:enum :red :old-blue} %{values: %{:old-blue => %{deprecated: "use :blue"}}}}
        id?: {:any-of :integer {:doc :string %{deprecated: "ids are integers now"}}}
      }
    }
    """

    test "warn only when the value goes through them" do
      r = loaded([@parts])
      assert {:ok, _} = decode(~s|%User{email: "a", color: :red, id: 1}|, r)
      assert warnings() == []

      assert {:ok, _} = decode(~s|%User{email: "a", legacy: "x", color: :old-blue, id: "7"}|, r)

      assert ["ids are integers now", "use :blue", "use email"] =
               warnings() |> Enum.map(& &1.message) |> Enum.sort()
    end
  end

  test "an encode warns as a decode does" do
    r = loaded([@old])
    me = self()

    {:ok, value} =
      Dextrin.decode("%Holder{old: %Old{x: 1}}", registry: loaded([@old]), deprecations: :off)

    assert {:ok, _} =
             Dextrin.encode(value, registry: r, on_deprecated: &send(me, {:deprecated, &1}))

    assert [%{name: "Old"}] = warnings()
  end

  test "without on_deprecated, a warning is logged" do
    r = loaded([@old])

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} = Dextrin.decode("%Holder{old: %Old{x: 1}}", registry: r)
      end)

    assert log =~ "Old"
    assert log =~ "deprecated"
  end

  test "a type named only in * K => V warns too" do
    r =
      loaded([
        "%{Old: {:doc :string %{deprecated: true}}, H: %schema{n: :integer, * :string => Old}}"
      ])

    assert [%{name: "Old", at: "H"}] = Registry.warnings(r)
  end

  test "encoding warns of the struct's own version only, not the base it passes as" do
    r = loaded([@pet_v1, @pet_v2, "%{Show: %schema extends Pet(1) {judge: :string}}"])
    show = Dextrin.Struct.keyed("Show", [{"name", "a"}, {"colour", "red"}, {"judge", "j"}])
    me = self()

    assert {:ok, _} =
             Dextrin.encode(show, registry: r, on_deprecated: &send(me, {:deprecated, &1}))

    assert warnings() == []
  end

  test "an encode under deprecations: :error refuses a deprecated struct" do
    r = loaded([@old])

    {:ok, value} =
      Dextrin.decode("%Holder{old: %Old{x: 1}}", registry: r, deprecations: :off)

    assert {:error, %Dextrin.Error{category: "schema/deprecated"}} =
             Dextrin.encode(value, registry: r, deprecations: :error)
  end

  test "compile warnings come in the order of the entries' names" do
    r =
      loaded([
        "%{Old: {:doc :string %{deprecated: true}}, Zed: %schema{o: Old}, Abe: %schema{o: Old}}"
      ])

    assert ["Abe", "Zed"] = Enum.map(Registry.warnings(r), & &1.at)
  end
end
