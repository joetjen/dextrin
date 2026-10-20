defmodule Dextrin.Schema.AnnotationsTest do
  @moduledoc """
  `{:doc T %{...}}`, the superset's group 8 (design/schema-superset.md,
  Jan, 2026-10-20): a title, a description, examples, read-only,
  write-only, deprecated and free `meta` on any type, a whole schema
  included, and docs for single enum values. Annotations say things
  about a type; they never change what it takes.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Schema

  @schemas """
  %{
    Order: {:doc %schema(2){
      id: :integer
      email: {:doc :string %{description: "Where receipts go", meta: %{"acme.pii" => true}}}
      legacy?: {:doc :string %{deprecated: "use email"}}
    } %{title: "An order", description: "One checkout", deprecated: false}}

    Color: {:doc {:enum :red :green :old-blue} %{
      description: "A color"
      values: %{:old-blue => %{deprecated: true, description: "Use :blue"}}
    }}

    Port: {:doc {:refine :integer %{min: 1, max: 65535}} %{examples: [80 443], read-only: true}}

    Page: {:doc {:generic [t] %shape{items: {:list-of t}}} %{description: "A page of anything"}}
  }
  """

  defp registry do
    {:ok, doc} = Dextrin.decode(@schemas)
    {:ok, registry} = Schema.compile(doc)
    registry
  end

  defp compile_error(text) do
    {:ok, doc} = Dextrin.decode(text)
    {:error, %Dextrin.Error{category: "schema/compile", message: message}} = Schema.compile(doc)
    message
  end

  test "an annotated type takes what the type takes, nothing more and nothing less" do
    r = registry()
    assert Schema.check(80, r, "Port") == :ok
    assert {:error, _} = Schema.check(0, r, "Port")
    assert {:ok, _} = Dextrin.decode(~s|%Order(2){id: 1, email: "a@b"}|, registry: r)
    assert {:error, _} = Dextrin.decode(~s|%Order(2){id: 1, email: 5}|, registry: r)
    assert {:ok, _} = Dextrin.decode(~s|%Order(2){id: 1, email: "a@b", legacy: "x"}|, registry: r)
  end

  test "a schema's, a named type's and a generic's annotations are readable by name" do
    r = registry()

    assert {:ok, %{"title" => "An order", "description" => "One checkout", "deprecated" => false}} =
             Schema.annotations(r, "Order")

    assert {:ok, %{"examples" => [80, 443], "read-only" => true}} = Schema.annotations(r, "Port")
    assert {:ok, %{"description" => "A page of anything"}} = Schema.annotations(r, "Page")
    assert {:ok, %{}} = Schema.annotations(registry_with("%{Plain: :integer}"), "Plain")
    assert :error = Schema.annotations(r, "Nothing")
  end

  test "an enum value's own annotations sit under values" do
    {:ok, %{"values" => values}} = Schema.annotations(registry(), "Color")
    assert [{%Dextrin.Keyword{name: "old-blue"}, %{"deprecated" => true}}] = Map.to_list(values)
  end

  test "a field's annotations stay on its type, and its meta is kept as written" do
    {:ok, compiled, _} = Dextrin.Registry.fetch_struct_schema(registry(), "Order", 2)
    email = Enum.find(compiled.fields, &(&1.name == "email"))
    assert {:doc, {:primitive, "string"}, %{"meta" => %{"acme.pii" => true}}} = email.type
  end

  test "the keys are a closed set, each of its kind" do
    for {text, key} <- [
          {"%{T: {:doc :integer %{summary: \"x\"}}}", "summary"},
          {"%{T: {:doc :integer %{description: 5}}}", "description"},
          {"%{T: {:doc :integer %{examples: 5}}}", "examples"},
          {"%{T: {:doc :integer %{read-only: \"yes\"}}}", "read-only"},
          {"%{T: {:doc :integer %{deprecated: 5}}}", "deprecated"},
          {"%{T: {:doc :integer %{meta: [1]}}}", "meta"},
          {"%{T: {:doc :integer %{values: %{1 => %{}}}}}", "values"},
          {"%{T: {:doc {:enum :a} %{values: %{:b => %{}}}}}", ":b"},
          {"%{T: {:doc {:enum :a} %{values: %{:a => %{values: %{}}}}}}", "values"},
          {"%{T: {:doc :integer}}", "doc"}
        ] do
      assert compile_error(text) =~ key, text
    end
  end

  test "a doc is no guard: it checks the same value" do
    assert compile_error("%{A: {:doc A %{description: \"loops\"}}}") =~ "A"
  end

  defp registry_with(text) do
    {:ok, doc} = Dextrin.decode(text)
    {:ok, registry} = Schema.compile(doc)
    registry
  end
end
