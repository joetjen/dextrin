defmodule Dextrin.Codegen.ElixirTest do
  @moduledoc """
  Elixir code from DXNS (T684, design/codegen-elixir.md): generated
  modules read, check and write data with code of their own -- no schema
  is loaded when they run -- for every version a schema has; regenerating
  keeps what was written by hand, in the user's file and in the generated
  file's regions, and the module names as the user spells them.
  """

  use ExUnit.Case, async: false

  alias Dextrin.Codegen.Elixir, as: Gen

  # Reading a deprecated version warns through Logger (T698).
  @moduletag :capture_log

  @schemas %{
    "acme/shop.dxns" => """
    %{
      Money: %shape{amount: {:refine :decimal %{min: 0M}} currency: %field{type: :string default: "EUR"}}
      Code: {:refine :string %{pattern: @regex "^[A-Z]{3}$"}}
      Status: {:enum :open :closed}
    }
    """,
    "acme/shop/Customer.dxns" => "%{Customer: %schema{name: :string, code?: acme.shop/Code}}",
    "acme/shop/Order.dxns" => """
    %{Order: %schema{
      id: :uuid
      customer: acme.shop/Customer
      total: acme.shop/Money
      status: %field{type: acme.shop/Status default: :open}
      lines: {:list-of {:refine :string %{min-length: 1}}}
      note?: {:nilable :string}
    }}
    """,
    "acme/shop/Pet.dxns" => """
    %{Pet: {:doc %schema(1){name: :string colour: :string born: :integer} %{deprecated: "use Pet(2)"}}}
    """,
    "acme/shop/Pet-v2.dxns" => """
    %{Pet: %schema(2){
      name: :string
      color: {:doc :string %{meta: %{"typespec.renamed-from" => "colour"}}}
      born: :string
      tag?: :string
    }}
    """
  }

  # A fresh directory: one a previous run left, under the same number,
  # would hold files the generator rightly keeps.
  defp tmp do
    root = Path.join(System.tmp_dir!(), "dextrin-codegen-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    root
  end

  defp schemas_dir(files \\ @schemas) do
    root = tmp()

    for {path, text} <- files do
      full = Path.join([root, "schemas", path])
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, text)
    end

    root
  end

  defp generate(root, prefix) do
    {:ok, written} =
      Gen.write([Path.join(root, "schemas")], prefix: prefix, out: Path.join(root, "lib"))

    written
  end

  defp compile(root) do
    files = Path.wildcard(Path.join([root, "lib", "**", "*.ex"]))
    {:ok, modules, _} = Kernel.ParallelCompiler.compile(files, return_diagnostics: true)
    modules
  end

  defp prefix, do: "Gen#{System.unique_integer([:positive])}"

  defp mod(prefix, name), do: Module.concat([prefix | String.split(name, ".")])

  # The decoded value of `text`, structs left as Dextrin reads them.
  defp dxn(text) do
    {:ok, value} = Dextrin.decode(text)
    value
  end

  describe "the files" do
    test "a user's file and a generated one per schema, each naming the schema" do
      root = schemas_dir()
      p = prefix()
      written = generate(root, p)

      assert "acme/shop/order.ex" in Enum.map(
               written,
               &Path.relative_to(&1, Path.join(root, "lib"))
             )

      gen = File.read!(Path.join([root, "lib", "acme/shop/order.gen.ex"]))
      own = File.read!(Path.join([root, "lib", "acme/shop/order.ex"]))

      assert gen =~ "# dextrin:schema acme.shop/Order"
      assert gen =~ "do not edit"
      assert own =~ "# dextrin:schema acme.shop/Order"
      assert own =~ "defmodule #{p}.Acme.Shop.Order do"
      assert own =~ "use #{p}.Acme.Shop.Order.Gen"
    end

    test "a namespace written with capitals is a directory in lower case, as the file is" do
      root =
        schemas_dir(%{
          "acme/shop/Order/v1.dxns" =>
            "%{Order: %schema{line: OrderLine} OrderLine: %schema{sku: :string}}"
        })

      written =
        root |> generate(prefix()) |> Enum.map(&Path.relative_to(&1, Path.join(root, "lib")))

      assert "acme/shop/order/order_line.gen.ex" in written
    end

    test "a computed default is computed when a value is read, not when the code is written" do
      root =
        schemas_dir(%{
          "a/Stamp.dxns" => "%{Stamp: %schema{at: %field{type: :timestamp computed: :now}}}"
        })

      p = prefix()
      generate(root, p)
      first = File.read!(Path.join([root, "lib", "a/stamp.gen.ex"]))
      generate(root, p)
      assert File.read!(Path.join([root, "lib", "a/stamp.gen.ex"])) == first

      compile(root)
      before = DateTime.utc_now()
      assert {:ok, %{at: %DateTime{} = at}} = mod(p, "A.Stamp").read(dxn("%a/Stamp{}"))
      assert DateTime.compare(at, before) != :lt
    end

    test "a field that must be absent compiles without a warning, and refuses a value" do
      root =
        schemas_dir(%{
          "a/Gone.dxns" => "%{Gone: %schema{old?: :never inner: %shape{x?: :never y: :string}}}"
        })

      p = prefix()
      generate(root, p)
      files = Path.wildcard(Path.join([root, "lib", "**", "*.ex"]))

      assert {:ok, _, %{compile_warnings: [], runtime_warnings: []}} =
               Kernel.ParallelCompiler.compile(files, return_diagnostics: true)

      gone = mod(p, "A.Gone")
      assert {:ok, _} = gone.read(dxn(~S|%a/Gone{inner: %{y: "a"}}|))
      assert {:error, why} = gone.read(dxn(~S|%a/Gone{old: 1 inner: %{y: "a"}}|))
      assert why =~ "old"
      assert {:error, _} = gone.read(dxn(~S|%a/Gone{inner: %{x: 1 y: "a"}}|))
    end

    test "the same schemas give the same bytes" do
      root = schemas_dir()
      p = prefix()
      generate(root, p)
      first = File.read!(Path.join([root, "lib", "acme/shop/order.gen.ex"]))
      generate(root, p)
      assert File.read!(Path.join([root, "lib", "acme/shop/order.gen.ex"])) == first
    end
  end

  describe "reading and checking" do
    setup do
      root = schemas_dir()
      p = prefix()
      generate(root, p)
      compile(root)
      %{p: p}
    end

    test "a struct is read into the module's struct, its defaults filled", %{p: p} do
      order = mod(p, "Acme.Shop.Order")
      customer = mod(p, "Acme.Shop.Customer")

      value =
        dxn(~S"""
        %acme.shop/Order{
          id: @uuid "550e8400-e29b-41d4-a716-446655440000"
          customer: %acme.shop/Customer{name: "Ada"}
          total: %{amount: 9.5M}
          lines: ["a" "b"]
        }
        """)

      assert {:ok, %^order{} = read} = order.read(value)
      assert %^customer{name: "Ada"} = read.customer
      assert read.status == :open or read.status == %Dextrin.Keyword{name: "open"}

      assert read.total[%Dextrin.Keyword{name: "currency"}] == "EUR" or
               read.total[:currency] == "EUR"

      assert :ok = order.validate(read)
    end

    test "a value that does not match says which field", %{p: p} do
      order = mod(p, "Acme.Shop.Order")

      value =
        dxn(~S"""
        %acme.shop/Order{
          id: @uuid "550e8400-e29b-41d4-a716-446655440000"
          customer: %acme.shop/Customer{name: "Ada" code: "nope"}
          total: %{amount: -1M}
          lines: [""]
        }
        """)

      assert {:error, message} = order.read(value)
      assert message =~ "customer" or message =~ "total" or message =~ "lines"
    end

    test "a missing required field is refused", %{p: p} do
      customer = mod(p, "Acme.Shop.Customer")
      assert {:error, message} = customer.read(dxn("%acme.shop/Customer{}"))
      assert message =~ "name"
    end

    test "to_dxn writes the struct back at the latest version", %{p: p} do
      customer = mod(p, "Acme.Shop.Customer")
      {:ok, read} = customer.read(dxn(~S|%acme.shop/Customer{name: "Ada"}|))
      assert {:ok, text} = Dextrin.encode(customer.to_dxn(read))
      assert text =~ ~S|%acme.shop/Customer(1){name:"Ada"}|
    end
  end

  describe "versions" do
    test "an older version is read and upgraded: renamed, dropped and added fields by themselves, a changed type by hand" do
      root = schemas_dir()
      p = prefix()
      generate(root, p)

      # The upgrade generated code can't make: `born` changed type.
      own = Path.join([root, "lib", "acme/shop/pet.ex"])

      File.write!(
        own,
        String.replace(
          File.read!(own),
          "\nend",
          "\n  def upgrade_v1(fields), do: Map.update!(fields, \"born\", &Integer.to_string/1)\nend"
        )
      )

      compile(root)
      pet = mod(p, "Acme.Shop.Pet")

      assert {:ok, %^pet{name: "Rex", color: "red", born: "2019", tag: nil}} =
               pet.read(dxn(~S|%acme.shop/Pet(1){name: "Rex" colour: "red" born: 2019}|))

      assert {:ok, %^pet{color: "blue"}} =
               pet.read(dxn(~S|%acme.shop/Pet(2){name: "Rex" color: "blue" born: "2019"}|))
    end

    test "a deprecated version's functions are marked" do
      root = schemas_dir()
      generate(root, prefix())
      gen = File.read!(Path.join([root, "lib", "acme/shop/pet.gen.ex"]))
      assert gen =~ ~r/@deprecated "use Pet\(2\)"\s+def read_v1\(/
      refute gen =~ ~r/@deprecated[^\n]*\n\s+def read_v2\(/
    end
  end

  describe "what is written by hand is kept" do
    test "a region of the generated file survives regenerating" do
      root = schemas_dir()
      p = prefix()
      generate(root, p)
      gen = Path.join([root, "lib", "acme/shop/order.gen.ex"])

      File.write!(
        gen,
        String.replace(
          File.read!(gen),
          "  # dextrin:keep bottom\n",
          "  # dextrin:keep bottom\n  def hello, do: :world\n"
        )
      )

      generate(root, p)

      assert File.read!(gen) =~
               "  # dextrin:keep bottom\n  def hello, do: :world\n  # dextrin:end bottom"
    end

    test "a region whose slot is gone is kept as an orphan, and --check fails" do
      root = schemas_dir()
      p = prefix()
      generate(root, p)
      gen = Path.join([root, "lib", "acme/shop/pet.gen.ex"])

      File.write!(
        gen,
        String.replace(
          File.read!(gen),
          "    # dextrin:keep upgrade_v1\n",
          "    # dextrin:keep upgrade_v1\n    fields = Map.put(fields, \"x\", 1)\n"
        )
      )

      File.rm!(Path.join([root, "schemas", "acme/shop/Pet.dxns"]))
      generate(root, p)
      text = File.read!(gen)
      assert text =~ "# dextrin:keep orphaned_upgrade_v1"
      assert text =~ ~S|fields = Map.put(fields, "x", 1)|

      assert {:error, problems} =
               Gen.check([Path.join(root, "schemas")], prefix: p, out: Path.join(root, "lib"))

      assert Enum.any?(problems, &(&1 =~ "orphaned"))
    end

    test "the user's file is never rewritten, and its module name is kept as spelled" do
      root = schemas_dir()
      p = prefix()
      generate(root, p)
      own = Path.join([root, "lib", "acme/shop/customer.ex"])
      renamed = "#{p}.ACME.Shop.Customer"

      File.write!(
        own,
        File.read!(own)
        |> String.replace("defmodule #{p}.Acme.Shop.Customer do", "defmodule #{renamed} do")
        |> String.replace("use #{p}.Acme.Shop.Customer.Gen", "use #{renamed}.Gen")
        |> String.replace("\nend", "\n  def mine, do: :kept\nend")
      )

      generate(root, p)
      assert File.read!(own) =~ "def mine, do: :kept"

      assert File.read!(Path.join([root, "lib", "acme/shop/customer.gen.ex"])) =~
               "defmodule #{renamed}.Gen do"
    end
  end

  describe "--check" do
    test "passes when the files are up to date, and names the stale ones otherwise" do
      root = schemas_dir()
      p = prefix()
      generate(root, p)
      opts = [prefix: p, out: Path.join(root, "lib")]
      assert :ok = Gen.check([Path.join(root, "schemas")], opts)

      File.write!(
        Path.join([root, "schemas", "acme/shop/Customer.dxns"]),
        "%{Customer: %schema{name: :string, code?: acme.shop/Code, vip?: :boolean}}"
      )

      assert {:error, problems} = Gen.check([Path.join(root, "schemas")], opts)
      assert Enum.any?(problems, &(&1 =~ "customer.gen.ex"))
    end
  end

  describe "decoding into the generated structs (Q3)" do
    test "Prefix.Decoder.decode/2 reads every known struct with the generated functions" do
      root = schemas_dir()
      p = prefix()
      generate(root, p)
      compile(root)
      decoder = Module.concat([p, "Decoder"])
      customer = mod(p, "Acme.Shop.Customer")

      assert {:ok, [%^customer{name: "Ada"}, %^customer{name: "Bo"}, 3]} =
               decoder.decode(
                 ~S|[%acme.shop/Customer{name: "Ada"} %acme.shop/Customer{name: "Bo"} 3]|
               )

      assert {:error, message} = decoder.decode(~S|[%acme.shop/Customer{}]|)
      assert message =~ "name"
      assert decoder.modules()["acme.shop/Customer"] == customer
    end
  end

  # T698 (Jan, 2026-11-18, on T684's deviation b): "code generated to
  # parse something marked deprecated should also log a warning" -- as
  # Dextrin's own reader does (DXNS.md §1b), without loading a schema.
  describe "deprecation warnings when data goes through generated code" do
    @deprecated_schemas %{
      "dep/Box.dxns" => ~S|%{Box: {:doc %schema(1){a: :string} %{deprecated: "use Box(2)"}}}|,
      "dep/Box-v2.dxns" => "%{Box: %schema(2){a: :string b?: :string}}",
      "dep/Old.dxns" => "%{Old: {:doc %schema{a: :string} %{deprecated: true}}}",
      "dep.dxns" => """
      %{
        Color: {:doc {:enum :red :old} %{values: %{:old => %{deprecated: "use red"}}}}
        Legacy: {:doc :string %{deprecated: "use text"}}
        Cat: %shape{meows: :boolean}
        Dog: {:doc %shape{barks: :boolean} %{deprecated: "no dogs"}}
      }
      """,
      "dep/Item.dxns" => """
      %{Item: %schema{
        color?: dep/Color
        note?: dep/Legacy
        pet?: {:any-of dep/Dog dep/Cat}
      }}
      """
    }

    setup do
      root = schemas_dir(@deprecated_schemas)
      p = prefix()
      generate(root, p)
      compile(root)
      me = self()
      %{p: p, collect: [on_deprecated: &send(me, {:deprecated, &1})]}
    end

    test "a struct read at a deprecated version warns, once by default", %{p: p, collect: collect} do
      box = mod(p, "Dep.Box")
      v1 = dxn(~S|%dep/Box(1){a: "x"}|)

      assert {:ok, %^box{a: "x"}} = box.read(v1, collect)
      assert {:ok, _} = box.read(v1, collect)

      assert_received {:deprecated,
                       %{
                         name: "dep/Box",
                         version: 1,
                         message: "use Box(2)",
                         category: "schema/deprecated"
                       }}

      refute_received {:deprecated, _}

      assert {:ok, _} = box.read(dxn(~S|%dep/Box(2){a: "x"}|), collect)
      refute_received {:deprecated, _}
    end

    test "a schema whose latest version is deprecated warns whatever version is read", %{
      p: p,
      collect: collect
    } do
      assert {:ok, _} = mod(p, "Dep.Old").read(dxn(~S|%dep/Old{a: "x"}|), collect)
      assert_received {:deprecated, %{name: "dep/Old", version: 1, message: nil}}
    end

    test ":every warns at each use, :off never, :error refuses", %{p: p, collect: collect} do
      box = mod(p, "Dep.Box")
      v1 = dxn(~S|%dep/Box(1){a: "x"}|)

      for _ <- 1..2, do: assert({:ok, _} = box.read(v1, [deprecations: :every] ++ collect))
      assert_received {:deprecated, _}
      assert_received {:deprecated, _}

      assert {:ok, _} = box.read(v1, [deprecations: :off] ++ collect)
      refute_received {:deprecated, _}

      assert {:error, message} = box.read(v1, [deprecations: :error] ++ collect)
      assert message == "dep/Box(1) is deprecated: use Box(2)"
      refute_received {:deprecated, _}
    end

    test "a deprecated type, enum value or variant warns when a value goes through it", %{
      p: p,
      collect: collect
    } do
      item = mod(p, "Dep.Item")
      every = [deprecations: :every] ++ collect

      assert {:ok, _} = item.read(dxn(~S|%dep/Item{color: :old}|), every)
      assert_received {:deprecated, %{message: "use red"}}

      assert {:ok, _} = item.read(dxn(~S|%dep/Item{color: :red note: "n"}|), every)
      assert_received {:deprecated, %{message: "use text"}}
      refute_received {:deprecated, _}

      assert {:ok, _} = item.read(dxn(~S|%dep/Item{pet: %{barks: true}}|), every)
      assert_received {:deprecated, %{message: "no dogs"}}
    end

    test "a deprecated variant tried and refused stays silent", %{p: p, collect: collect} do
      item = mod(p, "Dep.Item")

      assert {:ok, _} =
               item.read(
                 dxn(~S|%dep/Item{pet: %{meows: true}}|),
                 [deprecations: :every] ++ collect
               )

      refute_received {:deprecated, _}
    end

    test "with :error, a deprecated value refuses the struct holding it", %{p: p} do
      item = mod(p, "Dep.Item")
      assert {:error, message} = item.read(dxn(~S|%dep/Item{color: :old}|), deprecations: :error)
      assert message =~ "deprecated: use red"
    end

    test "without on_deprecated, the warning goes to Logger", %{p: p} do
      box = mod(p, "Dep.Box")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _} = box.read(dxn(~S|%dep/Box(1){a: "x"}|))
        end)

      assert log =~ "dep/Box(1) is deprecated: use Box(2)"
    end

    test "Prefix.Decoder.decode/2 takes the same options", %{p: p, collect: collect} do
      decoder = Module.concat([p, "Decoder"])

      assert {:ok, [_, _]} =
               decoder.decode(
                 ~S|[%dep/Box(1){a: "x"} %dep/Box(1){a: "y"}]|,
                 [deprecations: :every] ++ collect
               )

      assert_received {:deprecated, %{name: "dep/Box"}}
      assert_received {:deprecated, %{name: "dep/Box"}}

      assert {:error, _} = decoder.decode(~S|[%dep/Box(1){a: "x"}]|, deprecations: :error)
    end
  end

  describe "what the generator does not write yet" do
    test "is refused, naming every schema, version and field that uses it, and nothing is written" do
      root =
        schemas_dir(%{
          "a/Pair.dxns" => "%{Pair: %schema{pair: {:tuple-of :string :integer} name: :string}}",
          "a/Tags.dxns" => "%{Tags: %schema{tags: {:set-of :string}}}",
          "a/Fine.dxns" => "%{Fine: %schema{name: :string}}"
        })

      assert {:error, problems} =
               Gen.write([Path.join(root, "schemas")],
                 prefix: prefix(),
                 out: Path.join(root, "lib")
               )

      assert [pair, tags] = problems
      assert pair == "a/Pair(1): field pair: {:tuple-of ...} is not generated yet"
      assert tags =~ "a/Tags(1): field tags:"
      refute File.exists?(Path.join(root, "lib"))
    end
  end

  describe "mix dextrin.gen.elixir" do
    test "writes the files, and --check reports what is out of date" do
      root = schemas_dir()
      p = prefix()
      args = [Path.join(root, "schemas"), "--prefix", p, "--out", Path.join(root, "lib")]

      ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Dextrin.Gen.Elixir.run(args) end)
      assert File.exists?(Path.join([root, "lib", "acme/shop/order.gen.ex"]))

      assert ExUnit.CaptureIO.capture_io(fn ->
               Mix.Tasks.Dextrin.Gen.Elixir.run(args ++ ["--check"])
             end) =~ "up to date"

      File.rm!(Path.join([root, "lib", "acme/shop/order.gen.ex"]))

      assert_raise Mix.Error, ~r/order.gen.ex is missing/, fn ->
        Mix.Tasks.Dextrin.Gen.Elixir.run(args ++ ["--check"])
      end
    end
  end
end
