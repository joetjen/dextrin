defmodule Mix.Tasks.Dextrin.Gen.UnicodeTest do
  @moduledoc """
  `mix dextrin.gen.unicode` — fetches (or, via `--file`, reads) UCD
  data and regenerates `priv/grammar/dxn.aether`'s Unicode ranges.

  Every test here runs against an isolated `tmp_dir`, never the real
  `priv/` tree — `grammar_path/0`/`ucd_data_path/0`/`version_path/0`
  are all `File.cwd!()`-relative, so `File.cd!/2` is what keeps this
  from ever touching (or, on a bug, corrupting) this repo's own
  checked-in grammar. `File.cd!/2` changes the OS process's working
  directory for its duration, so this module is deliberately not
  `async: true`.
  """

  use ExUnit.Case, async: false

  alias Mix.Tasks.Dextrin.Gen.Unicode, as: GenUnicode

  import ExUnit.CaptureIO

  @current_fixture """
  # DerivedCoreProperties-17.0.0.txt
  # Date: 2026-01-01, 00:00:00 GMT

  0041..0045    ; XID_Start # L&   [5] LATIN CAPITAL LETTER A..LATIN CAPITAL LETTER E
  0030..0039    ; XID_Continue # Nd  [10] DIGIT ZERO..DIGIT NINE
  """

  @newer_fixture """
  # DerivedCoreProperties-99.0.0.txt
  # Date: 2099-01-01, 00:00:00 GMT

  0041..004A    ; XID_Start # L&   [10] LATIN CAPITAL LETTER A..LATIN CAPITAL LETTER J
  0030..0039    ; XID_Continue # Nd  [10] DIGIT ZERO..DIGIT NINE
  0041..005A    ; XID_Continue # L&  [26] LATIN CAPITAL LETTER A..LATIN CAPITAL LETTER Z
  """

  # Safe to run against the *real* priv/unicode/VERSION: read-only,
  # never writes, as long as the fixture's version matches what's
  # actually checked in.
  test "reports already up to date when the fixture's version matches priv/unicode/VERSION" do
    real_version =
      File.read!(Path.join([File.cwd!(), "priv", "unicode", "VERSION"])) |> String.trim()

    fixture = String.replace(@current_fixture, "17.0.0", real_version)
    fixture_path = Path.join(System.tmp_dir!(), "dextrin_gen_unicode_current_fixture.txt")
    File.write!(fixture_path, fixture)

    output = capture_io(fn -> GenUnicode.run(["--file", fixture_path]) end)

    assert output =~ "Already up to date (Unicode #{real_version})"
  after
    File.rm(Path.join(System.tmp_dir!(), "dextrin_gen_unicode_current_fixture.txt"))
  end

  @tag :tmp_dir
  test "regenerates the grammar and version files when given a newer fixture", %{tmp_dir: dir} do
    setup_priv_tree!(dir, version: "17.0.0")
    fixture_path = Path.join(dir, "newer.txt")
    File.write!(fixture_path, @newer_fixture)

    output =
      File.cd!(dir, fn ->
        capture_io(fn -> GenUnicode.run(["--file", fixture_path]) end)
      end)

    assert output =~ "Updated Unicode 17.0.0 -> 99.0.0"
    assert output =~ "XID_Start ranges"
    assert File.read!(Path.join(dir, "priv/unicode/VERSION")) == "99.0.0\n"

    grammar = File.read!(Path.join(dir, "priv/grammar/dxn.aether"))
    assert grammar =~ "BEGIN GENERATED UNICODE RANGES"
    assert grammar =~ "IDENTIFIER"
  end

  @tag :tmp_dir
  test "--force regenerates even when the version hasn't changed", %{tmp_dir: dir} do
    setup_priv_tree!(dir, version: "17.0.0")
    fixture_path = Path.join(dir, "same.txt")
    File.write!(fixture_path, @current_fixture)

    output =
      File.cd!(dir, fn ->
        capture_io(fn -> GenUnicode.run(["--file", fixture_path, "--force"]) end)
      end)

    assert output =~ "Updated Unicode 17.0.0 -> 17.0.0"
  end

  @tag :tmp_dir
  test "no prior VERSION file reports \"none\" as the starting version", %{tmp_dir: dir} do
    setup_priv_tree!(dir, version: nil)
    fixture_path = Path.join(dir, "newer.txt")
    File.write!(fixture_path, @newer_fixture)

    output =
      File.cd!(dir, fn ->
        capture_io(fn -> GenUnicode.run(["--file", fixture_path]) end)
      end)

    assert output =~ "Updated Unicode none -> 99.0.0"
  end

  @tag :tmp_dir
  test "a missing grammar file raises a clear error", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "priv/unicode"))
    fixture_path = Path.join(dir, "newer.txt")
    File.write!(fixture_path, @newer_fixture)

    assert_raise Mix.Error, ~r/dxn\.aether does not exist/, fn ->
      File.cd!(dir, fn -> GenUnicode.run(["--file", fixture_path]) end)
    end
  end

  test "a nonexistent --file raises a clear error" do
    assert_raise Mix.Error, ~r/Could not read/, fn ->
      GenUnicode.run(["--file", "/nonexistent/path/to/nowhere.txt"])
    end
  end

  defp setup_priv_tree!(dir, opts) do
    File.mkdir_p!(Path.join(dir, "priv/grammar"))
    File.mkdir_p!(Path.join(dir, "priv/unicode"))
    File.write!(Path.join(dir, "priv/grammar/dxn.aether"), "@grammar \"fixture\"\n@root value\n")

    case Keyword.fetch(opts, :version) do
      {:ok, nil} -> :ok
      {:ok, version} -> File.write!(Path.join(dir, "priv/unicode/VERSION"), version <> "\n")
    end
  end
end
