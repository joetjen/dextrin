defmodule Mix.Tasks.Dextrin.ValidateTest do
  @moduledoc "`mix dextrin.validate` — validates `.dxn`/`.dxnb`, optionally against a schema."

  use ExUnit.Case, async: true

  alias Mix.Tasks.Dextrin.Validate

  import ExUnit.CaptureIO

  @tag :tmp_dir
  test "valid .dxn text, no schema", %{tmp_dir: dir} do
    path = Path.join(dir, "data.dxn")
    File.write!(path, "%{x: 1}")

    output = capture_io(fn -> Validate.run([path]) end)

    assert output == "OK: #{path} is valid .dxn\n"
  end

  @tag :tmp_dir
  test "valid .dxnb binary, format sniffed from the extension", %{tmp_dir: dir} do
    path = Path.join(dir, "data.dxnb")
    {:ok, bytes} = Dextrin.encode_binary(%{"x" => 1})
    File.write!(path, bytes)

    output = capture_io(fn -> Validate.run([path]) end)

    assert output == "OK: #{path} is valid .dxnb\n"
  end

  @tag :tmp_dir
  test "--format overrides extension-based sniffing", %{tmp_dir: dir} do
    path = Path.join(dir, "data.txt")
    {:ok, bytes} = Dextrin.encode_binary(%{"x" => 1})
    File.write!(path, bytes)

    output = capture_io(fn -> Validate.run([path, "--format", "binary"]) end)

    assert output == "OK: #{path} is valid .dxnb\n"
  end

  # A *nameless* value (a plain map, not `%Point{...}`) is the real use
  # case for --schema/--as: decode/2 already auto-validates any named
  # struct unconditionally, so re-checking one after a successful
  # decode would be redundant (and a violating one would already have
  # made decode itself raise, never reaching this check at all). What
  # --schema/--as actually adds is confirming a nameless top-level
  # value against a schema decode has no name to key its own automatic
  # check off of.
  @tag :tmp_dir
  test "--schema/--as reports success when a nameless value satisfies the schema", %{
    tmp_dir: dir
  } do
    data_path = Path.join(dir, "point.dxn")
    schema_path = Path.join(dir, "point.dxns")
    File.write!(data_path, "%{x: 1, y: 2}")

    File.write!(
      schema_path,
      "%{ Point: %schema{ fields: @ordered %{ x: :integer, y: :integer } } }"
    )

    output =
      capture_io(fn -> Validate.run([data_path, "--schema", schema_path, "--as", "Point"]) end)

    assert output == "OK: #{data_path} is valid .dxn and satisfies schema Point\n"
  end

  @tag :tmp_dir
  test "--schema/--as raises when a nameless value violates the schema", %{tmp_dir: dir} do
    data_path = Path.join(dir, "point.dxn")
    schema_path = Path.join(dir, "point.dxns")
    File.write!(data_path, "%{x: 1}")

    File.write!(
      schema_path,
      "%{ Point: %schema{ fields: @ordered %{ x: :integer, y: :integer } } }"
    )

    assert_raise Mix.Error, ~r/does not satisfy schema Point.*missing required field/, fn ->
      Validate.run([data_path, "--schema", schema_path, "--as", "Point"])
    end
  end

  @tag :tmp_dir
  test "--schema/--as still succeeds for an already-decoded named struct (auto-validated by decode itself)",
       %{tmp_dir: dir} do
    data_path = Path.join(dir, "point.dxn")
    schema_path = Path.join(dir, "point.dxns")
    File.write!(data_path, "%Point{x: 1, y: 2}")

    File.write!(
      schema_path,
      "%{ Point: %schema{ fields: @ordered %{ x: :integer, y: :integer } } }"
    )

    output =
      capture_io(fn -> Validate.run([data_path, "--schema", schema_path, "--as", "Point"]) end)

    assert output == "OK: #{data_path} is valid .dxn and satisfies schema Point\n"
  end

  @tag :tmp_dir
  test "a named struct that violates its schema is caught by decode itself, before --as ever runs",
       %{tmp_dir: dir} do
    data_path = Path.join(dir, "point.dxn")
    schema_path = Path.join(dir, "point.dxns")
    File.write!(data_path, "%Point{x: 1}")

    File.write!(
      schema_path,
      "%{ Point: %schema{ fields: @ordered %{ x: :integer, y: :integer } } }"
    )

    assert_raise Mix.Error, ~r/^#{Regex.escape(data_path)}: .*missing required field/, fn ->
      Validate.run([data_path, "--schema", schema_path, "--as", "Point"])
    end
  end

  @tag :tmp_dir
  test "an uncompilable --schema file raises a clear error", %{tmp_dir: dir} do
    data_path = Path.join(dir, "point.dxn")
    schema_path = Path.join(dir, "bad.dxns")
    File.write!(data_path, "%Point{x: 1}")
    File.write!(schema_path, "%{ Point: :not-a-schema-form-with-unknown-type }")

    assert_raise Mix.Error, ~r/failed to compile schema/, fn ->
      Validate.run([data_path, "--schema", schema_path, "--as", "Point"])
    end
  end

  @tag :tmp_dir
  test "malformed content raises an error prefixed with the file path", %{tmp_dir: dir} do
    path = Path.join(dir, "bad.dxn")
    File.write!(path, "%{x: }")

    assert_raise Mix.Error, ~r/^#{Regex.escape(path)}: /, fn -> Validate.run([path]) end
  end

  test "no path argument raises a usage error" do
    assert_raise Mix.Error, ~r/usage: mix dextrin.validate PATH/, fn -> Validate.run([]) end
  end
end
