defmodule Mix.Tasks.Dextrin.EncodeTest do
  @moduledoc "`mix dextrin.encode` — `.dxn` text to `.dxnb` binary."

  use ExUnit.Case, async: true

  alias Mix.Tasks.Dextrin.Encode

  import ExUnit.CaptureIO

  @tag :tmp_dir
  test "writes binary bytes to stdout by default", %{tmp_dir: dir} do
    source = "%{x: 1}"
    path = Path.join(dir, "data.dxn")
    File.write!(path, source)

    # latin1 -- .dxnb bytes aren't valid UTF-8 in general; capture_io's
    # default (unicode) encoding would transcode/corrupt them.
    output = capture_io([encoding: :latin1], fn -> Encode.run([path]) end)

    {:ok, value} = Dextrin.decode(source)
    {:ok, expected} = Dextrin.encode_binary(value)
    assert output == expected
  end

  @tag :tmp_dir
  test "--out writes to a file instead of stdout", %{tmp_dir: dir} do
    in_path = Path.join(dir, "data.dxn")
    out_path = Path.join(dir, "data.dxnb")
    File.write!(in_path, "[1 2 3]")

    capture_io(fn -> Encode.run([in_path, "--out", out_path]) end)

    {:ok, expected} = Dextrin.encode_binary([1, 2, 3])
    assert File.read!(out_path) == expected
  end

  @tag :tmp_dir
  test "--share opts into value-sharing, producing smaller output for repeated values", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "data.dxn")
    shared_map = ~s(%{a: 1, b: 2, c: 3, d: 4, e: 5})
    File.write!(path, "[#{shared_map} #{shared_map} #{shared_map} #{shared_map}]")

    shared = capture_io([encoding: :latin1], fn -> Encode.run([path, "--share"]) end)
    unshared = capture_io([encoding: :latin1], fn -> Encode.run([path]) end)

    assert byte_size(shared) < byte_size(unshared)
  end

  test "no path argument raises a usage error" do
    assert_raise Mix.Error, ~r/usage: mix dextrin.encode PATH/, fn -> Encode.run([]) end
  end

  @tag :tmp_dir
  test "malformed .dxn content raises a formatted Dextrin.Error", %{tmp_dir: dir} do
    path = Path.join(dir, "bad.dxn")
    File.write!(path, "%{x: }")

    assert_raise Mix.Error, fn -> Encode.run([path]) end
  end
end
