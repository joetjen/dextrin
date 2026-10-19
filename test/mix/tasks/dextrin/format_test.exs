defmodule Mix.Tasks.Dextrin.FormatTest do
  @moduledoc "`mix dextrin.format` — reformats a `.dxn` file, pretty or condensed."

  use ExUnit.Case, async: true

  alias Mix.Tasks.Dextrin.Format

  import ExUnit.CaptureIO

  @tag :tmp_dir
  test "defaults to --mode pretty, printed to stdout", %{tmp_dir: dir} do
    path = Path.join(dir, "data.dxn")
    File.write!(path, "%{x: 1, y: 2}")

    output = capture_io(fn -> Format.run([path]) end)

    # The document laid out, its entries in the order the file wrote
    # them. Not the value re-encoded: a map's key order is the runtime's,
    # and OTP 26 and 27 write this one `y` first.
    assert output == "%{\n  x: 1\n  y: 2\n}\n"
    # File itself is untouched without --in-place.
    assert File.read!(path) == "%{x: 1, y: 2}"
  end

  @tag :tmp_dir
  test "--mode condense prints single-line output", %{tmp_dir: dir} do
    path = Path.join(dir, "data.dxn")
    File.write!(path, "%{\n  x: 1\n}")

    output = capture_io(fn -> Format.run([path, "--mode", "condense"]) end)

    assert output == "%{x:1}\n"
  end

  @tag :tmp_dir
  test "--mode pretty keeps every comment beside its entry", %{tmp_dir: dir} do
    path = Path.join(dir, "in.dxn")
    File.write!(path, "# the config\n%{name: \"acme\", # the name\n deps: [\"a\"]}\n")

    output = capture_io(fn -> Format.run([path]) end)

    assert output ==
             "# the config\n%{\n  name: \"acme\"  # the name\n  deps: [\n    \"a\"\n  ]\n}\n"
  end

  @tag :tmp_dir
  test "--mode condense drops comments: a comment ends its line, and condensed is one", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "in.dxn")
    File.write!(path, "%{name: \"acme\"} # the name\n")

    output = capture_io(fn -> Format.run([path, "--mode", "condense"]) end)
    assert output == ~s|%{name:"acme"}\n|
  end

  @tag :tmp_dir
  test "--in-place rewrites the file instead of printing to stdout", %{tmp_dir: dir} do
    path = Path.join(dir, "data.dxn")
    File.write!(path, "%{x: 1}")

    output = capture_io(fn -> Format.run([path, "--mode", "condense", "--in-place"]) end)

    assert output == ""
    assert File.read!(path) == "%{x:1}\n"
  end

  @tag :tmp_dir
  test "an unrecognized --mode raises a clear error", %{tmp_dir: dir} do
    path = Path.join(dir, "data.dxn")
    File.write!(path, "%{x: 1}")

    assert_raise Mix.Error, ~r/unrecognized --mode "loud"/, fn ->
      Format.run([path, "--mode", "loud"])
    end
  end

  test "no path argument raises a usage error" do
    assert_raise Mix.Error, ~r/usage: mix dextrin.format PATH/, fn -> Format.run([]) end
  end

  @tag :tmp_dir
  test "malformed .dxn content raises a formatted Dextrin.Error", %{tmp_dir: dir} do
    path = Path.join(dir, "bad.dxn")
    File.write!(path, "%{x: }")

    assert_raise Mix.Error, fn -> Format.run([path]) end
  end
end
