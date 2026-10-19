defmodule Mix.Tasks.Dextrin.CompatTest do
  @moduledoc "`mix dextrin.compat OLD NEW` — the version discipline check, for CI."

  use ExUnit.Case, async: true

  alias Mix.Tasks.Dextrin.Compat

  import ExUnit.CaptureIO

  defp write(dir, name, files) do
    path = Path.join(dir, name)
    File.mkdir_p!(path)
    for {file, source} <- files, do: File.write!(Path.join(path, file), source)
    path
  end

  @tag :tmp_dir
  test "passes, listing what the materializer has to upgrade", %{tmp_dir: dir} do
    old = write(dir, "old", %{"user.dxns" => "%{User: %schema{name: :string}}"})

    new =
      write(dir, "new", %{
        "user.dxns" => "%{User: %schema{name: :string}}",
        "user-2.dxns" => "%{User: %schema(2){name: :string, email?: :string}}"
      })

    output = capture_io(fn -> Compat.run([old, new]) end)

    assert output =~ "OK: no version discipline problems"
    assert output =~ "User 1 -> 2: added email"
  end

  @tag :tmp_dir
  test "fails on a version whose content changed without a new version", %{tmp_dir: dir} do
    old = write(dir, "old", %{"user.dxns" => "%{User: %schema{name: :string}}"})
    new = write(dir, "new", %{"user.dxns" => "%{User: %schema{name: :integer}}"})

    assert_raise Mix.Error, ~r/User version 1 changed without a new version/, fn ->
      capture_io(fn -> Compat.run([old, new]) end)
    end
  end

  @tag :tmp_dir
  test "takes a single file as well as a directory", %{tmp_dir: dir} do
    old = Path.join(dir, "old.dxns")
    File.write!(old, "%{User: %schema(2){name: :string}}")
    new = Path.join(dir, "new.dxns")
    File.write!(new, "%{User: %schema{name: :string}}")

    assert_raise Mix.Error, ~r/User went down from version 2 to 1/, fn ->
      capture_io(fn -> Compat.run([old, new]) end)
    end
  end
end
