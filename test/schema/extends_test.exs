defmodule Dextrin.Schema.ExtendsTest do
  @moduledoc """
  A schema or a shape built from others (DXNS.md §4b, Jan, 2026-11-17):
  `extends` and `includes` in its head, `- field` in its body. The result
  is an ordinary schema or shape; an `extends` result is accepted where
  its base is expected, when it is a valid base as well; an `includes`
  result is not.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Schema
  alias Dextrin.Schema.Compiled

  defp compiled(text, registry \\ Dextrin.Registry.new()) do
    with {:ok, doc} <- Dextrin.decode(text), do: Schema.compile(doc, registry)
  end

  defp registry(text, base \\ Dextrin.Registry.new()) do
    {:ok, registry} = compiled(text, base)
    registry
  end

  defp schema(registry, name) do
    {:ok, %Compiled{} = compiled, _} = Dextrin.Registry.fetch_struct_schema(registry, name)
    compiled
  end

  defp fields(registry, name) do
    Enum.map(schema(registry, name).fields, fn f ->
      {if(f.required, do: f.name, else: f.name <> "?"), short(f.type)}
    end)
  end

  # A primitive by its keyword, as the schema writes it.
  defp short({:primitive, name}), do: String.to_atom(name)
  defp short({:refine, type, constraints}), do: {:refine, short(type), constraints}
  defp short(type), do: type

  defp category({:error, %Dextrin.Error{category: category}}), do: category
  defp category(other), do: other

  @users """
  %{
    Person: %shape{name: :string, born?: :date}

    User: %schema(3) extends Person {
      email: :string
      password: :string
      nick?: :string
    }

    Audit: %shape{changed_by: :string}

    Admin: %schema(1) extends User includes Audit {
      - nick
      email: {:refine :string %{format: "email"}}
      role: :string
    }
  }
  """

  describe "the head and the body, read as text" do
    test "a schema's head carries its bases, the body its dropped fields" do
      assert {:ok,
              %Dextrin.Struct{
                name: "schema",
                version: 2,
                bases: [
                  {:extends, "User", 3},
                  {:extends, "Staff", nil},
                  {:includes, "Audit", nil}
                ],
                drops: ["password"]
              }} =
               Dextrin.decode(
                 "%schema(2) extends User(3) Staff includes Audit {- password, role: :string}"
               )
    end

    test "a shape takes them as well" do
      assert {:ok,
              %Dextrin.Struct{name: "shape", bases: [{:includes, "Audit", nil}], drops: ["x"]}} =
               Dextrin.decode("%shape includes Audit {-x}")
    end

    test "any other struct taking a clause or a dropped field is a syntax error" do
      assert category(Dextrin.decode("%User extends Person {name: \"a\"}")) == "syntax"
      assert category(Dextrin.decode("%User{- name}")) == "syntax"
    end

    test "a clause given twice, or with no base, is a syntax error" do
      assert category(Dextrin.decode("%schema extends A extends B {}")) == "syntax"
      assert category(Dextrin.decode("%schema extends {}")) == "syntax"
      assert category(Dextrin.decode("%schema A {}")) == "syntax"
    end

    test "writes back as it was read" do
      text = "%schema(2) extends User(3) Staff includes Audit {- password role: :string}"
      {:ok, value} = Dextrin.decode(text)
      assert {:ok, written} = Dextrin.encode(value)
      assert Dextrin.decode(written) == {:ok, value}
      assert written =~ "extends User(3) Staff includes Audit"
      assert written =~ "- password"
    end

    test "is written back over lines, and by the formatter that keeps comments" do
      text = "%schema(2) extends User(3) includes Audit {- password, role: :string}"
      {:ok, value} = Dextrin.decode(text)
      assert {:ok, pretty} = Dextrin.encode(value, pretty: true)
      assert Dextrin.decode(pretty) == {:ok, value}

      source =
        "%{\n  Admin: %schema extends User {\n    - password  # gone\n    role: :string\n  }\n}\n"

      {:ok, doc} = Dextrin.Document.parse(source)
      assert Dextrin.Document.format(doc) == source
    end

    test "has no .dxnb form" do
      {:ok, value} = Dextrin.decode("%schema extends User {role: :string}")
      assert category(Dextrin.encode_binary(value)) == "encode/unsupported"
    end
  end

  describe "the result" do
    test "is the bases' fields in order, overrides in place, drops gone, its own last" do
      registry = registry(@users)

      assert [
               {"name", :string},
               {"born?", :date},
               {"email", {:refine, :string, _}},
               {"password", :string},
               {"changed_by", :string},
               {"role", :string}
             ] = fields(registry, "Admin")

      assert schema(registry, "Admin").version == 1
    end

    test "a shape may be built from a schema, and a schema from a shape" do
      registry =
        registry(@users <> "")
        |> then(fn r ->
          registry(
            """
            %{Card: %shape includes User {- password}
              Holder: %schema{card: Card}}
            """,
            r
          )
        end)

      assert {:ok, _} =
               Dextrin.decode(
                 ~s|%Holder{card: %{name: "a", email: "a@x"}}|,
                 registry: registry
               )

      assert category(Dextrin.decode(~s|%Holder{card: %{name: "a"}}|, registry: registry)) ==
               "schema/type-mismatch"
    end

    test "a field reached twice through a common base is one field" do
      registry =
        registry("""
        %{
          Person: %shape{name: :string}
          User: %schema extends Person {email: :string}
          Staff: %schema extends Person {desk: :integer}
          Both: %schema extends User Staff {}
        }
        """)

      assert [{"name", :string}, {"email", :string}, {"desk", :integer}] =
               fields(registry, "Both")
    end

    test "a field is the same however its base was found" do
      loaded =
        registry("""
        %{Id: {:refine :integer %{min: 1}}
          Person: %shape{id: Id}
          Staff: %schema extends Person {desk: :integer}}
        """)

      text = """
      %{Id: {:refine :integer %{min: 1}}
        Person: %shape{id: Id}
        User: %schema extends Person {email: :string}
        Both: %schema extends User Staff {}}
      """

      assert [{"id", _}, {"email", _}, {"desk", _}] = fields(registry(text, loaded), "Both")
    end

    test "two different fields of one name are refused, unless the body settles it" do
      clash = """
      %{
        A: %shape{x: :string}
        B: %shape{x: :integer}
        C: %schema includes A B {}
      }
      """

      assert category(compiled(clash)) == "schema/compile"

      assert {:ok, _} = compiled(String.replace(clash, "{}\n", "{x: :boolean}\n"))
      assert {:ok, _} = compiled(String.replace(clash, "{}\n", "{- x}\n"))
    end

    test "every mistake against a base is schema/compile" do
      for text <- [
            "%{A: %schema extends Nobody {}}",
            "%{P: %shape{x: :string}, A: %schema extends P(2) {}}",
            "%{U: %schema(1){x: :string}, A: %schema extends U(2) {}}",
            "%{P: %shape{x: :string}, A: %schema includes P P {}}",
            "%{P: %shape{x: :string}, A: %schema extends P includes P {}}",
            "%{P: %shape{x: :string}, A: %schema includes P {- y}}",
            "%{P: %shape{x?: :string}, A: %schema includes P {- x, - x}}",
            "%{P: %shape{x?: :string}, A: %schema includes P {- x, x: :string}}",
            "%{P: %shape{x: :string}, A: %schema extends P {- x}}",
            "%{A: %schema extends B {}, B: %schema extends A {}}",
            "%{N: :integer, A: %schema extends N {}}",
            "%{P: %shape{x: :string}, A: %shape(2) extends P {}}",
            "%{P: %shape{x: :string}, A: %schema{y: %shape extends P {}}}"
          ] do
        assert category(compiled(text)) == "schema/compile", text
      end
    end

    test "an optional field of an extends base may be dropped, and any field of an includes base" do
      assert {:ok, _} = compiled("%{P: %shape{x?: :string}, A: %schema extends P {- x}}")
      assert {:ok, _} = compiled("%{P: %shape{x: :string}, A: %schema includes P {- x}}")
    end
  end

  describe "a base in another document" do
    @v1 "%{User: %schema(1){name: :string}}"
    @v2 "%{User: %schema(2){name: :string, email: :string}}"

    test "is its latest loaded version, unless one is named" do
      base = registry(@v2, registry(@v1))

      assert [{"name", _}, {"email", _}, {"role", _}] =
               fields(registry("%{A: %schema extends User {role: :string}}", base), "A")

      assert [{"name", _}, {"role", _}] =
               fields(registry("%{A: %schema extends User(1) {role: :string}}", base), "A")
    end

    test "the latest version may be one only the resolver knows" do
      {:ok, newer} = Schema.compile(elem(Dextrin.decode(@v2), 1))
      {:ok, v2, _} = Dextrin.Registry.fetch_struct_schema(newer, "User")

      base =
        Dextrin.Registry.put_resolver(Dextrin.Registry.new(), fn
          "User" -> {:ok, [v2]}
          _ -> {:ok, []}
        end)

      text = "%{User: %schema(1){name: :string}, A: %schema extends User {role: :string}}"
      assert [{"name", _}, {"email", _}, {"role", _}] = fields(registry(text, base), "A")
    end

    test "a newer version loaded later changes no result already loaded" do
      registry = registry("%{A: %schema extends User {role: :string}}", registry(@v1))
      registry = registry(@v2, registry)
      assert [{"name", _}, {"role", _}] = fields(registry, "A")
    end
  end

  describe "where a base is expected" do
    defp holder(registry) do
      registry(
        """
        %{
          UserBox: %schema{u: User}
          Wide: %schema extends User {email: :integer}
          Mixed: %schema includes User {}
        }
        """,
        registry
      )
    end

    test "an extending struct is accepted, and keeps what it is" do
      r = holder(registry(@users))

      assert {:ok, %Dextrin.Struct{fields: {:keyed, [{"u", %Dextrin.Struct{name: "Admin"}}]}}} =
               Dextrin.decode(
                 ~s|%UserBox{u: %Admin{name: "a", email: "a@x", password: "p", changed_by: "b", role: "r"}}|,
                 registry: r
               )
    end

    test "only when it is a valid base as well" do
      r = holder(registry(@users))

      assert category(
               Dextrin.decode(
                 ~s|%UserBox{u: %Wide{name: "a", email: 1, password: "p"}}|,
                 registry: r
               )
             ) == "schema/type-mismatch"
    end

    test "a positional struct, on its way out, as well" do
      r = holder(registry(@users))

      {:ok, admin} =
        Dextrin.decode(~s|%Admin[nil nil "a@x" "p" "b" "r"]|, registry: Dextrin.Registry.new())

      admin = %{admin | fields: {:positional, ["a", ~D[2000-01-01], "a@x", "p", "b", "r"]}}
      box = Dextrin.Struct.keyed("UserBox", [{"u", admin}])
      assert {:ok, _} = Dextrin.encode(box, registry: r)
    end

    test "through a chain of extends, and not past an includes" do
      r =
        registry("""
        %{
          Root: %schema{id: :integer}
          Mid: %schema extends Root {}
          Leaf: %schema extends Mid {}
          Cut: %schema includes Mid {}
          RootBox: %schema{r: Root}
        }
        """)

      assert {:ok, _} = Dextrin.decode("%RootBox{r: %Leaf{id: 1}}", registry: r)

      assert category(Dextrin.decode("%RootBox{r: %Cut{id: 1}}", registry: r)) ==
               "schema/type-mismatch"
    end

    test "including is not extending" do
      r = holder(registry(@users))

      assert category(
               Dextrin.decode(
                 ~s|%UserBox{u: %Mixed{name: "a", email: "a@x", password: "p"}}|,
                 registry: r
               )
             ) == "schema/type-mismatch"
    end
  end
end
