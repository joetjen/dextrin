defmodule Dextrin.Convert.JsonSchemaTest do
  @moduledoc """
  The JSON Schema converter's own choices (T674, design/json-schema.md):
  what the official suite does not decide -- names, shapes or structs,
  logical types, MongoDB's bsonType, what is kept in meta, and what is
  reported.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Convert.JsonSchema
  alias Mix.Tasks.Dextrin.FromJsonSchema

  import ExUnit.CaptureIO

  defp dxns(json, opts \\ []) do
    {:ok, %{document: doc, inexact: inexact}} = JsonSchema.to_dxns({"schema.json", json}, opts)
    {:ok, text} = Dextrin.encode(doc, pretty: true)
    {text, doc, inexact}
  end

  defp registry(doc) do
    {:ok, registry} = Dextrin.Schema.compile(doc)
    registry
  end

  defp takes?(registry, name, json) do
    {:ok, value} = JsonSchema.decode_json(json)
    Dextrin.Schema.check(JsonSchema.json_value(value), registry, name) == :ok
  end

  test "an object is a shape, its fields in order, those not required optional" do
    {text, _, []} =
      dxns(
        ~s|{"title": "Order", "type": "object", "required": ["id"], "properties": {"id": {"type": "integer"}, "note": {"type": "string"}}}|
      )

    assert text =~ ~s|Order: {:doc %shape{id: :integer note?: :string} %{title: "Order"}}|
  end

  test "$defs are named entries, and a $ref is the name" do
    {text, doc, []} =
      dxns(
        ~s|{"$defs": {"Money": {"type": "number", "minimum": 0}}, "type": "object", "properties": {"price": {"$ref": "#/$defs/Money"}}}|
      )

    assert text =~ "Money: {:refine :number %{min: 0}}"
    assert text =~ "price?: Money"
    assert takes?(registry(doc), "Root", ~s|{"price": 2}|)
    refute takes?(registry(doc), "Root", ~s|{"price": -1}|)
  end

  test "--structs writes a named object as a %schema" do
    {text, _, []} =
      dxns(
        ~s|{"$defs": {"Pet": {"type": "object", "properties": {"name": {"type": "string"}}}}, "$ref": "#/$defs/Pet"}|,
        structs: true
      )

    assert text =~ "Pet: %schema{name?: :string}"
  end

  test "a date-time string is a datetime where formats are checked, a string with meta where not" do
    schema = ~s|{"type": "string", "format": "date-time"}|

    {text, _, _} =
      dxns(
        ~s|{"$schema": "http://json-schema.org/draft-07/schema#", "type": "string", "format": "date-time"}|
      )

    assert text =~ "Root: :datetime"

    {text, _, _} = dxns(schema)
    assert text =~ ":string"
    assert text =~ ~s|"json-schema.format" => "date-time"|

    {text, _, _} = dxns(schema, assert_formats: true)
    assert text =~ "Root: :datetime"
  end

  test "an unknown format is kept in meta and checks nothing" do
    {text, doc, []} = dxns(~s|{"type": "string", "format": "postal-code"}|, assert_formats: true)
    assert text =~ ~s|"json-schema.format" => "postal-code"|
    assert takes?(registry(doc), "Root", ~s|"anything"|)
  end

  test "patternProperties and additionalProperties: false are * K => V entries and - *" do
    {text, doc, []} =
      dxns(
        ~s|{"type": "object", "properties": {"id": {"type": "integer"}}, "patternProperties": {"^x-": {"type": "string"}}, "additionalProperties": false}|
      )

    assert text =~ "- *"
    assert text =~ "* {:refine :string %{pattern:"
    r = registry(doc)
    assert takes?(r, "Root", ~s|{"id": 1, "x-a": "s"}|)
    refute takes?(r, "Root", ~s|{"id": 1, "x-a": 2}|)
    refute takes?(r, "Root", ~s|{"id": 1, "y": 2}|)
  end

  test "a required property that is no identifier is still required" do
    {_, doc, []} = dxns(~s|{"type": "object", "required": ["a b"]}|)
    r = registry(doc)
    assert takes?(r, "Root", ~s|{"a b": 1}|)
    refute takes?(r, "Root", ~s|{"a": 1}|)
  end

  describe "MongoDB" do
    test "bsonType maps to DXN's own types" do
      {text, _, []} =
        dxns(
          ~s|{"bsonType": "object", "required": ["_id"], "properties": {"_id": {"bsonType": "objectId"}, "at": {"bsonType": "date"}, "n": {"bsonType": "long"}, "price": {"bsonType": "decimal"}}}|
        )

      assert text =~ "_id: :objectid"
      assert text =~ "at?: {:refine :timestamp %{resolution: :millisecond}}"
      assert text =~ "n?: :int64"
      assert text =~ "price?: {:refine :decimal %{max-precision: 34}}"
    end

    test "a BSON type with no DXN value is :any, and reported" do
      {_, _, [%{why: why}]} = dxns(~s|{"bsonType": "javascript"}|)
      assert why =~ "javascript"
    end
  end

  test "a $ref to a document not given is an error; nothing is fetched" do
    assert {:error, why} =
             JsonSchema.to_dxns({"a.json", ~s|{"$ref": "https://example.com/b.json"}|})

    assert why =~ "names no schema among those given"
  end

  test "a $ref to another file given resolves" do
    sources = [
      {"a.json", ~s|{"type": "object", "properties": {"b": {"$ref": "b.json"}}}|},
      {"b.json", ~s|{"title": "B", "type": "integer"}|}
    ]

    assert {:ok, %{document: doc}} = JsonSchema.to_dxns(sources)
    assert takes?(registry(doc), "Root", ~s|{"b": 1}|)
    refute takes?(registry(doc), "Root", ~s|{"b": "x"}|)
  end

  test "something not a schema is refused" do
    assert {:error, why} = JsonSchema.to_dxns({"a.json", "12"})
    assert why =~ "object or a boolean"
  end

  test "an ECMA-262 pattern reads as JSON Schema means it" do
    {_, doc, []} = dxns(~s|{"type": "string", "pattern": "^\\\\d+$"}|)
    r = registry(doc)
    assert takes?(r, "Root", ~s|"123"|)
    refute takes?(r, "Root", ~s|"123\\n"|)
    refute takes?(r, "Root", ~s|"١٢٣"|)
  end

  test "a pattern reads code points, as ECMA-262's u flag does" do
    {_, doc, []} = dxns(~s|{"type": "string", "pattern": "^.$"}|)
    assert takes?(registry(doc), "Root", ~s|"é"|)
    {_, doc, []} = dxns(~s|{"type": "string", "pattern": "^\\u0100$"}|)
    assert takes?(registry(doc), "Root", ~s|"Ā"|)
  end

  test "a keyword set to null reads as one left out" do
    {_, doc, []} = dxns(~s|{"type": "number", "minimum": null}|)
    assert takes?(registry(doc), "Root", "-5")
  end

  describe "mix dextrin.from_json_schema" do
    @tag :tmp_dir
    test "writes the DXNS, and reports what is not exact", %{tmp_dir: dir} do
      schema = Path.join(dir, "s.json")
      out = Path.join(dir, "s.dxns")
      File.write!(schema, ~s|{"title": "Thing", "bsonType": "javascript"}|)

      err =
        capture_io(:stderr, fn ->
          capture_io(fn -> FromJsonSchema.run([schema, "--out", out]) end)
        end)

      assert err =~ "inexact: #: bsonType javascript"
      assert File.read!(out) =~ ~s|Thing: {:doc :any %{title: "Thing"}}|
    end

    @tag :tmp_dir
    test "--strict fails on anything not exact", %{tmp_dir: dir} do
      schema = Path.join(dir, "s.json")
      File.write!(schema, ~s|{"bsonType": "javascript"}|)

      assert_raise Mix.Error, ~r/not exact/, fn ->
        capture_io(:stderr, fn -> FromJsonSchema.run([schema, "--strict"]) end)
      end
    end
  end
end
