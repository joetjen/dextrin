defmodule Mix.Tasks.Dextrin.CheckTest do
  @moduledoc """
  `mix dextrin.check` -- a tree of `.dxns` checked; what compiling finds
  deprecated is printed as a warning (G10 of design/typespec.md), and
  fails the check under `--warnings-as-errors`.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Dextrin.Check

  import ExUnit.CaptureIO

  @deprecated_use """
  %{
    Old: {:doc %schema{x: :integer} %{deprecated: "use New"}}
    Holder: %schema{old: Old}
  }
  """

  defp tree(dir, source) do
    File.write!(Path.join(dir, "acme.dxns"), source)
    dir
  end

  @tag :tmp_dir
  test "a tree with nothing deprecated in use passes quietly", %{tmp_dir: dir} do
    output = capture_io(fn -> Check.run([tree(dir, "%{A: %schema{x: :integer}}")]) end)
    assert output =~ "OK: 1 files"
    refute output =~ "warning"
  end

  @tag :tmp_dir
  test "a use of something deprecated is a warning, and the check passes", %{tmp_dir: dir} do
    output = capture_io(fn -> Check.run([tree(dir, @deprecated_use)]) end)
    assert output =~ "warning: acme/Holder uses acme/Old(1), which is deprecated: use New"
    assert output =~ "OK: 1 files"
  end

  @tag :tmp_dir
  test "--warnings-as-errors fails the check on one", %{tmp_dir: dir} do
    root = tree(dir, @deprecated_use)

    assert_raise Mix.Error, ~r/1 warning/, fn ->
      capture_io(fn -> Check.run([root, "--warnings-as-errors"]) end)
    end
  end
end
