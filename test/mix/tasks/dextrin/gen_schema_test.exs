defmodule Mix.Tasks.Dextrin.Gen.SchemaTest do
  @moduledoc "`mix dextrin.gen.schema` — scaffolds a `.dxns` document from a compiled struct module."

  use ExUnit.Case, async: true

  alias Mix.Tasks.Dextrin.Gen.Schema

  import ExUnit.CaptureIO

  test "prints a scaffold to stdout by default, every field optional" do
    output = capture_io(fn -> Schema.run(["Dextrin.Test.Support.Money"]) end)

    {:ok, doc} = Dextrin.decode(output)
    {:ok, registry} = Dextrin.Schema.compile(doc)
    assert {:ok, _compiled, _registry} = Dextrin.Registry.fetch_struct_schema(registry, "Money")

    assert output =~ "amount?:"
    assert output =~ "currency?:"
  end

  @tag :tmp_dir
  test "--out writes to a file instead of stdout", %{tmp_dir: dir} do
    path = Path.join(dir, "money.dxns")

    capture_io(fn -> Schema.run(["Dextrin.Test.Support.Money", "--out", path]) end)

    assert {:ok, _doc} = Dextrin.decode(File.read!(path))
  end

  test "--name overrides the schema's own name" do
    output = capture_io(fn -> Schema.run(["Dextrin.Test.Support.Money", "--name", "Cash"]) end)

    assert output =~ "Cash: %schema{"
  end

  test "guesses a DXN type per field from its struct default's own runtime type" do
    output = capture_io(fn -> Schema.run(["Dextrin.Test.Support.GenSchemaFixture"]) end)

    assert output =~ "nil_field?: :any"
    assert output =~ "bool_field?: :boolean"
    assert output =~ "int_field?: :integer"
    assert output =~ "float_field?: :float"
    assert output =~ "string_field?: :string"
    assert output =~ "list_field?: {:list-of :any}"
    assert output =~ "map_field?: {:map-of :any :any}"
    assert output =~ "other_field?: :any"

    {:ok, doc} = Dextrin.decode(output)
    assert {:ok, _registry} = Dextrin.Schema.compile(doc)
  end

  test "a module that isn't a struct raises a clear error" do
    assert_raise Mix.Error, ~r/is not a struct module/, fn ->
      Schema.run(["Enum"])
    end
  end

  test "no module argument raises a usage error" do
    assert_raise Mix.Error, ~r/usage: mix dextrin.gen.schema Module/, fn -> Schema.run([]) end
  end
end
