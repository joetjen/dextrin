defmodule Dextrin.Text.GrammarTest do
  @moduledoc """
  Direct unit tests for `Dextrin.Text.Grammar`'s own delegate
  functions — `tokenize/1,2`, `parse/1,2`, `run_sequence/2` are only
  ever exercised indirectly elsewhere (`run/2` is what `Dextrin.decode/2`
  calls; `tokenize/1` is used internally by `Dextrin.Text.Printer`).
  """

  use ExUnit.Case, async: true

  alias Dextrin.Text.Grammar

  describe "tokenize/1,2" do
    test "tokenizes a simple identifier into one IDENTIFIER token" do
      assert {:ok, [%{name: :IDENTIFIER, text: "foo"}]} = Grammar.tokenize("foo")
    end

    test "tokenizes a full value into more than one token" do
      assert {:ok, tokens} = Grammar.tokenize("%{x: 1}")
      assert length(tokens) > 1
    end
  end

  describe "parse/1,2" do
    test "parses without evaluating -- a bare recognizer" do
      assert {:ok, _pos, _raw_captures} = Grammar.parse("%{x: 1}")
    end

    test "fails on malformed input, with no Ichor.Actions involved" do
      assert {:error, %Ichor.Error{}} = Grammar.parse("%{x: }")
    end
  end

  describe "run/1,2" do
    test "matches and evaluates through Dextrin.Text.Actions" do
      assert {:ok, %{%Dextrin.Keyword{name: "x"} => 1}} = Grammar.run("%{x: 1}")
    end

    test "threads a registry through as context" do
      {:ok, doc} = Dextrin.decode("%{ Point: %schema{ fields: @ordered %{ x: :integer } } }")
      {:ok, registry} = Dextrin.Schema.compile(doc)

      # Grammar.run/2 is the raw grammar-level entry point -- unlike
      # Dextrin.decode/2, it doesn't strip the internal
      # Dextrin.Schema.Validated provenance wrapper materialize/4
      # produces; that's Dextrin.decode/2's own job.
      assert {:ok, %Dextrin.Schema.Validated{name: "Point", value: %{"x" => 1}}} =
               Grammar.run("%Point{x: 1}", registry)
    end
  end

  describe "run_sequence/2" do
    test "evaluates multiple top-level forms in sequence, threading context between them" do
      assert {:ok, [1, 2, 3], _final_context} = Grammar.run_sequence("1 2 3", nil)
    end

    test "an empty input sequence yields an empty list" do
      assert {:ok, [], nil} = Grammar.run_sequence("", nil)
    end
  end
end
