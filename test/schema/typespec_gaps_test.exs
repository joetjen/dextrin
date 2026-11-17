defmodule Dextrin.Schema.TypeSpecGapsTest do
  @moduledoc """
  What DXNS lacked to say every TypeSpec type exactly (design/typespec.md,
  T673, Jan, 2026-11-17: "build all gaps"):

  - G2: generic parameters with a bound and a default;
  - G3: the `discriminator` annotation;
  - G5: the annotation keys `secret`, `key`, `visibility` and `messages`;
  - G6: a base that is a named type standing for a schema or a shape;
  - G7: the format `http-date`;
  - G8: a field computed when it is filled (`computed: :now`);
  - G9: the sized sugar `:int8`, `:int16`, `:uint8` and `:uint16`.

  G4 is a sentence in DXNS.md, with nothing to test. G1, typed extras
  and closed bodies, is in rest_test.exs until its syntax is decided.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Schema

  defp compiled(text, registry \\ Dextrin.Registry.new()) do
    with {:ok, doc} <- Dextrin.decode(text), do: Schema.compile(doc, registry)
  end

  defp registry(text) do
    {:ok, registry} = compiled(text)
    registry
  end

  defp compile_error(text) do
    {:error, %Dextrin.Error{category: "schema/compile", message: message}} = compiled(text)
    message
  end

  defp category({:error, %Dextrin.Error{category: category}}), do: category
  defp category(other), do: other

  defp takes?(registry, name, text) do
    {:ok, value} = Dextrin.decode(text)
    Schema.check(value, registry, name) == :ok
  end

  describe "G2: generic parameters" do
    @generics """
    %{
      Page: {:generic [t {size :integer :integer}] %shape{items: {:list-of t}, size?: size}}
      Named: {:generic [{t :string}] %shape{name: t}}
      Short: {:refine :string %{max-length: 3}}
      Person: %schema{name: :string}
      Admin: %schema extends Person {role: :string}
      Holder: {:generic [{p Person}] %shape{who: p}}
    }
    """

    test "a parameter with a default may be left out of a use" do
      r = registry(@generics <> "")
      {:ok, r} = compiled("%{Orders: {:of Page :string}}", r)
      assert takes?(r, "Orders", ~s|%{items: ["a"], size: 1}|)
      refute takes?(r, "Orders", ~s|%{items: ["a"], size: "1"}|)
    end

    test "every parameter without a default must be given" do
      {:ok, r} = compiled(@generics)
      assert category(compiled("%{X: {:of Page}}", r)) == "schema/compile"
    end

    test "a parameter without a default after one with a default is a compile error" do
      assert compile_error("%{G: {:generic [{a :any :integer} b] {:tuple-of a b}}}") =~ "default"
    end

    test "an argument passes its parameter's bound when it is or narrows the bound" do
      {:ok, r} = compiled(@generics)

      for arg <- [
            ":string",
            "Short",
            "{:refine :string %{min-length: 1}}",
            ~s|{:const "a"}|,
            ~s|{:enum "a" "b"}|
          ] do
        assert {:ok, _} = compiled("%{X: {:of Named #{arg}}}", r), arg
      end

      assert {:ok, _} = compiled("%{X: {:of Holder Admin}}", r)
    end

    test "an argument outside the bound is a compile error" do
      {:ok, r} = compiled(@generics)

      for arg <- [":integer", ~s|{:enum "a" 1}|, "{:any-of :string :integer}"] do
        assert category(compiled("%{X: {:of Named #{arg}}}", r)) == "schema/compile", arg
      end

      assert category(compiled("%{X: {:of Holder Person2}, Person2: %schema{name: :string}}", r)) ==
               "schema/compile"
    end

    test "a default must pass its own bound" do
      assert compile_error("%{G: {:generic [{t :string :integer}] t}}") =~ "bound"
    end

    test "a parameter passes on to a bounded generic when its own bound is within" do
      {:ok, r} = compiled(@generics)
      assert {:ok, _} = compiled("%{Outer: {:generic [{u :string}] {:of Named u}}}", r)
      assert category(compiled("%{Outer: {:generic [u] {:of Named u}}}", r)) == "schema/compile"

      assert category(compiled("%{Outer: {:generic [{u :integer}] {:of Named u}}}", r)) ==
               "schema/compile"
    end

    test "an argument or a bound may be a type of the same document" do
      {:ok, r} = compiled(@generics)

      assert {:ok, _} =
               compiled("%{Tiny: {:refine :string %{max-length: 1}}, X: {:of Named Tiny}}", r)

      assert {:ok, _} = compiled("%{Str: :string, G: {:generic [{t Str}] t}, X: {:of G :string}}")

      assert category(compiled("%{Str: :string, G: {:generic [{t Str}] t}, X: {:of G :integer}}")) ==
               "schema/compile"
    end

    test "a use as a base has its defaults filled" do
      r =
        registry("""
        %{
          Page: {:generic [t {size :integer :integer}] %shape{items: {:list-of t}, size?: size}}
          P: {:of Page :string}
          S: %schema includes P {}
        }
        """)

      assert {:ok, _} = Dextrin.decode(~s|%S{items: ["a"], size: 1}|, registry: r)

      assert category(Dextrin.decode(~s|%S{items: ["a"], size: "1"}|, registry: r)) ==
               "schema/type-mismatch"
    end

    test "a refusal through a use of a generic says why" do
      {:ok, r} = compiled(@generics)
      {:ok, r} = compiled("%{Orders: {:of Page :string}}", r)
      {:ok, value} = Dextrin.decode(~s|%{items: [1]}|)
      {:error, %Dextrin.Error{message: message}} = Schema.check(value, r, "Orders")
      assert message =~ "items"
    end

    test "a parameter is a symbol, {name bound} or {name bound default}" do
      assert category(compiled("%{G: {:generic [{t}] t}}")) == "schema/compile"
      assert category(compiled("%{G: {:generic [{t :any :any :any}] t}}")) == "schema/compile"
      assert category(compiled("%{G: {:generic [1] :any}}")) == "schema/compile"
    end
  end

  describe "G3: discriminator" do
    @pets """
    %{
      Cat: %shape{kind: {:const "cat"}, meows: :boolean}
      Dog: %shape{kind: {:const "dog"}, barks: :boolean}
      Pet: {:doc {:one-of Cat Dog} %{discriminator: :kind}}
    }
    """

    test "changes nothing a value is checked against" do
      r = registry(@pets)
      assert takes?(r, "Pet", ~s|%{kind: "cat", meows: true}|)
      refute takes?(r, "Pet", ~s|%{kind: "cat", barks: true}|)
      refute takes?(r, "Pet", ~s|%{kind: "cow"}|)
    end

    test "is read back as an annotation" do
      assert {:ok, %{"discriminator" => "kind"}} = Schema.annotations(registry(@pets), "Pet")
    end

    test "a refusal names the field and the variant it chose" do
      r = registry(@pets)
      {:ok, value} = Dextrin.decode(~s|%{kind: "cow"}|)
      {:error, %Dextrin.Error{message: unknown}} = Schema.check(value, r, "Pet")
      assert unknown =~ "kind"
      assert unknown =~ "cow"

      {:ok, value} = Dextrin.decode(~s|%{kind: "cat", meows: 1}|)
      {:error, %Dextrin.Error{message: wrong}} = Schema.check(value, r, "Pet")
      assert wrong =~ "meows"
      refute wrong =~ "barks"
    end

    test "every variant has the field, written in a field's type too" do
      assert compile_error("""
             %{
               Cat: %shape{kind: {:const "cat"}}
               Bird: %shape{wings: :integer}
               Home: %shape{pet: {:doc {:one-of Cat Bird} %{discriminator: :kind}}}
             }
             """) =~ "kind"

      assert compile_error("""
             %{
               Cat: %shape{kind: {:const "cat"}}
               Bird: %shape{wings: :integer}
               Home: %schema{pet: {:doc {:one-of Cat Bird} %{discriminator: :kind}}}
             }
             """) =~ "kind"
    end

    test "stands only on an any-of or a one-of whose every variant has the field" do
      assert compile_error("%{T: {:doc :string %{discriminator: :kind}}}") =~ "discriminator"

      assert compile_error("""
             %{
               Cat: %shape{kind: {:const "cat"}}
               Bird: %shape{wings: :integer}
               Pet: {:doc {:any-of Cat Bird} %{discriminator: :kind}}
             }
             """) =~ "kind"

      assert compile_error(
               "%{Cat: %shape{kind: :string}, P: {:doc {:one-of Cat} %{discriminator: 1}}}"
             ) =~ "discriminator"
    end
  end

  describe "G5: annotation keys" do
    test "secret, key, visibility and messages are read back" do
      r =
        registry("""
        %{
          User: %schema{
            id: {:doc :uuid %{key: true, visibility: [:read]}}
            password: {:doc :string %{secret: true, visibility: [:create :update]}}
            handle: {:doc :string %{key: "login"}}
          }
          Code: {:doc {:refine :string %{pattern: @regex "^[a-z]+$"}} %{messages: %{pattern: "lower case only"}}}
        }
        """)

      assert {:ok, %{"messages" => %{"pattern" => "lower case only"}}} =
               Schema.annotations(r, "Code")
    end

    test "a message replaces the refusal's own words" do
      r =
        registry(
          ~s|%{Code: {:doc {:refine :string %{pattern: @regex "^[a-z]+$"}} %{messages: %{pattern: "lower case only"}}}}|
        )

      {:error, %Dextrin.Error{message: message}} = Schema.check("ABC", r, "Code")
      assert message =~ "lower case only"
    end

    test "each key takes its kind of value" do
      assert compile_error("%{T: {:doc :string %{secret: 1}}}") =~ "secret"
      assert compile_error("%{T: {:doc :string %{key: 1}}}") =~ "key"
      assert compile_error("%{T: {:doc :string %{visibility: [:sometimes]}}}") =~ "visibility"
      assert compile_error("%{T: {:doc :string %{visibility: :read}}}") =~ "visibility"

      assert compile_error("%{T: {:doc :string %{messages: %{min-lenght: \"x\"}}}}") =~
               "min-lenght"

      assert compile_error("%{T: {:doc :string %{messages: %{pattern: 1}}}}") =~ "messages"
    end

    test "visibility and read-only together are a compile error" do
      assert compile_error("%{T: {:doc :string %{read-only: true, visibility: [:read]}}}") =~
               "read-only"
    end

    test "an empty visibility is a field no stage sees" do
      assert {:ok, _} = compiled("%{T: {:doc :string %{visibility: []}}}")
    end
  end

  describe "G6: a named type as a base" do
    @named """
    %{
      Page: {:generic [t] %shape{items: {:list-of t}, next?: :string}}
      PageOfInt: {:of Page :integer}
      Ints: %schema includes PageOfInt {total: :integer}

      Person: %schema{name: :string}
      Human: Person
      User: %schema extends Human {email: :string}
      Box: %schema{who: Person}
    }
    """

    test "a use of a generic standing for a shape is a base" do
      r = registry(@named)
      assert {:ok, _} = Dextrin.decode("%Ints{items: [1], total: 1}", registry: r)

      assert category(Dextrin.decode(~s|%Ints{items: ["a"], total: 1}|, registry: r)) ==
               "schema/type-mismatch"
    end

    test "a name standing for a schema is that schema, extending included" do
      r = registry(@named)
      assert {:ok, _} = Dextrin.decode(~s|%Box{who: %User{name: "a", email: "b"}}|, registry: r)
    end

    test "a named type standing for anything else is still no base" do
      assert compile_error("%{N: :integer, S: %schema includes N {}}") =~ "N"
      assert compile_error("%{N: {:list-of :integer}, S: %schema includes N {}}") =~ "N"
    end
  end

  describe "G7: format http-date" do
    defp http_date?(text) do
      r = registry("%{T: {:refine :string %{format: :http-date}}}")
      Schema.check(text, r, "T") == :ok
    end

    test "takes RFC 7231's IMF-fixdate" do
      assert http_date?("Sun, 06 Nov 1994 08:49:37 GMT")
      assert http_date?("Thu, 29 Feb 2024 23:59:60 GMT")
    end

    test "refuses the obsolete forms, a wrong weekday and a date that is none" do
      for text <- [
            "Sunday, 06-Nov-94 08:49:37 GMT",
            "Sun Nov  6 08:49:37 1994",
            "Mon, 06 Nov 1994 08:49:37 GMT",
            "Sun, 6 Nov 1994 08:49:37 GMT",
            "Wed, 31 Nov 1994 08:49:37 GMT",
            "Thu, 29 Feb 2023 08:49:37 GMT",
            "Sun, 06 Nov 1994 24:00:00 GMT",
            "Sun, 06 Nov 1994 08:49:37 +0000",
            "Sun, 06 nov 1994 08:49:37 GMT",
            "Sun, 06 Nov 1994 08:49:37 GMT\n"
          ] do
        refute http_date?(text), text
      end
    end
  end

  describe "G8: computed: :now" do
    @stamped """
    %{
      Note: %shape{text: :string, at: %field{type: :timestamp, computed: :now}}
      Day: %shape{on: %field{type: :date, computed: :now}}
    }
    """

    test "a missing field is filled with the time of the decode" do
      r = registry(@stamped)
      before = DateTime.utc_now()
      {:ok, %{%Dextrin.Keyword{name: "at"} => at}} = Schema.conform(%{text: "a"}, r, "Note")
      assert DateTime.compare(at, before) in [:gt, :eq]
      assert DateTime.diff(DateTime.utc_now(), at, :second) < 5
      assert at.utc_offset == 0
    end

    test "a field that is there is kept" do
      {:ok, at, 0} = DateTime.from_iso8601("2020-01-01T00:00:00Z")
      assert {:ok, %{at: ^at}} = Schema.conform(%{text: "a", at: at}, registry(@stamped), "Note")
    end

    test "a date is today's, in UTC" do
      assert {:ok, %{%Dextrin.Keyword{name: "on"} => on}} =
               Schema.conform(%{}, registry(@stamped), "Day")

      assert on == DateTime.to_date(DateTime.utc_now())
    end

    test "only a temporal type is computed, never beside a default, and :now is all there is" do
      assert compile_error("%{N: %shape{a: %field{type: :string, computed: :now}}}") =~ "computed"

      assert compile_error(
               "%{N: %shape{a: %field{type: :date, computed: :now, default: @date \"2020-01-01\"}}}"
             ) =~ "default"

      assert compile_error("%{N: %shape{a: %field{type: :date, computed: :later}}}") =~ "later"
    end
  end

  describe "G9: small sized integers" do
    test "are their ranges" do
      cases = [
        {":int8", "-128", "127", "-129", "128"},
        {":int16", "-32768", "32767", "-32769", "32768"},
        {":uint8", "0", "255", "-1", "256"},
        {":uint16", "0", "65535", "-1", "65536"}
      ]

      for {type, low, high, under, over} <- cases do
        r = registry("%{T: #{type}}")
        assert takes?(r, "T", low), "#{type} #{low}"
        assert takes?(r, "T", high), "#{type} #{high}"
        refute takes?(r, "T", under), "#{type} #{under}"
        refute takes?(r, "T", over), "#{type} #{over}"
      end
    end
  end
end
