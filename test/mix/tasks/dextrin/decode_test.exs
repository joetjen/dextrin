defmodule Mix.Tasks.Dextrin.DecodeTest do
  @moduledoc "`mix dextrin.decode` — `.dxnb` binary to `.dxn` text, pretty-printed."

  use ExUnit.Case, async: true

  alias Mix.Tasks.Dextrin.Decode

  import ExUnit.CaptureIO

  @tag :tmp_dir
  test "prints pretty-printed text to stdout by default", %{tmp_dir: dir} do
    {:ok, bytes} = Dextrin.encode_binary(%{"x" => 1})
    path = Path.join(dir, "data.dxnb")
    File.write!(path, bytes)

    output = capture_io(fn -> Decode.run([path]) end)

    assert output == Dextrin.Text.Formatter.pretty(%{"x" => 1}) <> "\n"
  end

  @tag :tmp_dir
  test "--out writes to a file instead of stdout", %{tmp_dir: dir} do
    {:ok, bytes} = Dextrin.encode_binary([1, 2, 3])
    in_path = Path.join(dir, "data.dxnb")
    out_path = Path.join(dir, "data.dxn")
    File.write!(in_path, bytes)

    capture_io(fn -> Decode.run([in_path, "--out", out_path]) end)

    assert File.read!(out_path) == Dextrin.Text.Formatter.pretty([1, 2, 3])
  end

  test "no path argument raises a usage error" do
    assert_raise Mix.Error, ~r/usage: mix dextrin.decode PATH/, fn -> Decode.run([]) end
  end

  @tag :tmp_dir
  test "malformed .dxnb content raises a formatted Dextrin.Error", %{tmp_dir: dir} do
    path = Path.join(dir, "bad.dxnb")
    File.write!(path, "not a real dxnb file")

    assert_raise Mix.Error, fn -> Decode.run([path]) end
  end
end
