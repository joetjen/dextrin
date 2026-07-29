defmodule Dextrin.Text.ActionsErrorTest do
  @moduledoc """
  Error paths in `Dextrin.Text.Actions` reachable through the real
  grammar — a sigil/tag's *body* text is captured freely at the lexer
  level (`(!"]" .)*` and similar), so validating it (ISO 8601 parsing,
  regex compilation, base64, UUID format) is entirely this module's
  own job, not the grammar's. Each of these is a real "syntactically
  valid DXN, semantically invalid content" case, distinct from a parse
  error.
  """

  use ExUnit.Case, async: true

  defp error_message(text) do
    assert {:error, %Dextrin.Error{message: message}} = Dextrin.decode(text)
    message
  end

  test "an invalid date sigil body is a clear error" do
    assert error_message("~D[not-a-date]") =~ "invalid date"
  end

  test "an invalid time sigil body is a clear error" do
    assert error_message("~T[25:99:99]") =~ "invalid time"
  end

  test "an invalid instant sigil body is a clear error" do
    assert error_message("~U[garbage]") =~ "invalid instant"
  end

  test "a regex with invalid PCRE syntax fails to compile" do
    assert error_message("~r/(/") =~ "invalid regex"
  end

  test "an invalid uuid is a clear error" do
    assert error_message(~s(@uuid "not-a-uuid")) =~ "invalid uuid"
  end

  test "invalid base64 in @bytes is a clear error" do
    assert error_message(~s(@bytes "not valid base64!!!")) =~ "invalid base64"
  end

  test "an invalid @datetime body is a clear error" do
    assert error_message(~s(@datetime "garbage")) =~ "invalid datetime"
  end

  test "an invalid @duration body is a clear error" do
    assert error_message(~s(@duration "not-a-duration")) =~ "invalid duration"
  end

  test "@ordered applied to anything other than a map literal is a clear error" do
    assert error_message("@ordered [1, 2, 3]") =~ "@ordered requires a map literal argument"
  end

  test "a struct field key that's neither an identifier nor a string is a clear error" do
    # struct_keyed reuses the same map_entry rule as a plain map, which
    # also allows the arrow form -- %Point{1 => 2} is syntactically
    # valid, but 1 isn't a usable field name.
    assert error_message("%Point{1 => 2}") =~
             "struct field name must be an identifier or string"
  end

  test "a bare symbol is also an accepted struct field name, via the arrow form" do
    assert {:ok, %Dextrin.Struct{name: "Point", fields: {:keyed, [{"sym", 2}]}}} =
             Dextrin.decode("%Point{sym => 2}")
  end

  test "a @datetime body with no offset (neither Z nor +HH:MM) is a clear error" do
    assert error_message(~s(@datetime "2024-01-01T10:00:00")) =~ "invalid datetime"
  end

  test "a registered custom tag decoder that returns {:error, reason} surfaces that reason" do
    registry =
      Dextrin.Registry.put_tag(Dextrin.Registry.new(), "my-app/money", fn _ ->
        {:error, "not a valid money value"}
      end)

    assert {:error, %Dextrin.Error{message: message}} =
             Dextrin.decode("@my-app/money 100", registry: registry)

    assert message =~ "not a valid money value"
  end

  test "with no registry in context (nil), an unrecognized tag still falls back to Dextrin.CustomTag" do
    assert {:ok, %Dextrin.CustomTag{name: "my-app/money", value: 100}} =
             Dextrin.Text.Grammar.run("@my-app/money 100")
  end

  test "with no registry in context (nil), a struct literal still decodes to an opaque Dextrin.Struct" do
    assert {:ok, %Dextrin.Struct{name: "Point", fields: {:keyed, [{"x", 1}]}}} =
             Dextrin.Text.Grammar.run("%Point{x: 1}")
  end
end
