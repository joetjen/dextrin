defmodule Dextrin.Schema.CompatTest do
  @moduledoc """
  B8 of `design/implementation-plan.md`: the version discipline check. A
  schema whose content changed needs a new version, a version never goes
  down, and the latest version lists which older ones its materializer
  has to upgrade, with what changed.
  """

  use ExUnit.Case, async: true

  alias Dextrin.{Registry, Schema}
  alias Dextrin.Schema.Compat

  defp loaded(sources) do
    Enum.reduce(sources, Registry.new(), fn source, registry ->
      {:ok, doc} = Dextrin.decode(source)
      {:ok, registry} = Schema.compile(doc, registry)
      registry
    end)
  end

  @v1 "%{User: %schema{name: :string}}"
  @v2 "%{User: %schema(2){name: :string, email?: :string}}"

  test "the same schemas pass with nothing to report" do
    assert Compat.check(loaded([@v1, @v2]), loaded([@v1, @v2])) ==
             %{
               problems: [],
               upgrades: [
                 %{schema: "User", from: 1, to: 2, added: ["email"], removed: [], changed: []}
               ]
             }
  end

  test "a new version passes" do
    assert %{problems: []} = Compat.check(loaded([@v1]), loaded([@v1, @v2]))
  end

  test "a version whose content changed without a new version is a problem" do
    changed = "%{User: %schema{name: :string, nick?: :string}}"

    assert %{problems: [%{schema: "User", version: 1, problem: :changed_without_new_version}]} =
             Compat.check(loaded([@v1]), loaded([changed]))
  end

  test "a changed type, requiredness or default is a change; a description is not" do
    base = "%{User: %schema{name: :string}}"

    for changed <- [
          "%{User: %schema{name: :integer}}",
          "%{User: %schema{name?: :string}}",
          ~s(%{User: %schema{name: %field{type: :string, default: "x"}}})
        ] do
      assert %{problems: [_]} = Compat.check(loaded([base]), loaded([changed]))
    end

    described = ~s(%{User: %schema{name: %field{type: :string, description: "the name"}}})
    assert %{problems: []} = Compat.check(loaded([base]), loaded([described]))
  end

  test "a version that went down is a problem" do
    assert %{problems: [%{schema: "User", problem: :version_went_down, from: 2, to: 1}]} =
             Compat.check(loaded([@v1, @v2]), loaded([@v1]))
  end

  test "the upgrade checklist says what changed since each older version" do
    v3 = "%{User: %schema(3){name: :integer, email?: :string, id: :uuid}}"

    assert %{upgrades: upgrades} = Compat.check(loaded([@v1, @v2]), loaded([@v1, @v2, v3]))

    assert %{
             schema: "User",
             from: 1,
             to: 3,
             added: ["email", "id"],
             removed: [],
             changed: ["name"]
           } in upgrades

    assert %{schema: "User", from: 2, to: 3, added: ["id"], removed: [], changed: ["name"]} in upgrades
  end

  test "a new schema is not a problem" do
    assert %{problems: []} =
             Compat.check(loaded([@v1]), loaded([@v1, "%{Other: %schema{x: :integer}}"]))
  end

  describe "named types with versions (Way B, DXNS.md §5c)" do
    @c1 "%{Color: {:enum :red :green}}"
    @c2 "%{Color: %type(2)[{:enum :red :green :blue}]}"

    test "a new version passes; a version whose definition changed is a problem" do
      assert %{problems: []} = Compat.check(loaded([@c1]), loaded([@c1, @c2]))

      assert %{problems: [%{type: "Color", version: 1, problem: :changed_without_new_version}]} =
               Compat.check(loaded([@c1]), loaded(["%{Color: {:enum :red}}"]))
    end

    test "a version that went down is a problem" do
      assert %{problems: [%{type: "Color", problem: :version_went_down, from: 2, to: 1}]} =
               Compat.check(loaded([@c1, @c2]), loaded([@c1]))
    end
  end

  test "annotations are no change: deprecating a version that shipped passes" do
    deprecated =
      ~s(%{User: {:doc %schema{name: {:doc :string %{deprecated: "use full_name"}}} %{deprecated: true}}})

    assert %{problems: []} = Compat.check(loaded([@v1]), loaded([deprecated]))

    color = ~s(%{Color: {:doc {:enum :red :green} %{deprecated: true}}})

    assert %{problems: []} =
             Compat.check(loaded(["%{Color: {:enum :red :green}}"]), loaded([color]))
  end

  test "closing a version, or typing its extras otherwise, is a change" do
    base = "%{User: %schema{name: :string}}"

    for changed <- [
          "%{User: %schema{name: :string - *}}",
          "%{User: %schema{name: :string * :string => :integer}}"
        ] do
      assert %{problems: [%{problem: :changed_without_new_version}]} =
               Compat.check(loaded([base]), loaded([changed])),
             changed
    end
  end
end
