defmodule Dextrin.Schema.DocsTest do
  @moduledoc """
  `Dextrin.Schema.Docs` and `mix dextrin.docs` (Jan, 2026-10-20): a
  directory of `.dxns` files as a small HTML site -- names from file
  paths (DXNS.md §6), a definition's comments as its documentation,
  references as links, every version shown.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Schema.Docs
  alias Dextrin.Schema.Docs.{Comments, Markdown}

  doctest Comments
  doctest Markdown

  # Each site in a directory of its own, emptied first and removed after:
  # `unique_integer` is unique within one run only, so a directory an
  # earlier run left behind would lend this one its files.
  defp site(files) do
    root = Path.join(System.tmp_dir!(), "dextrin-docs-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    for {path, source} <- files do
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), source)
    end

    {:ok, pages} = Docs.site(root, title: "T")
    Map.new(pages, fn {path, html} -> {path, IO.iodata_to_binary(html)} end)
  end

  test "a namespace is a directory, and its page that directory's index" do
    pages = site(%{"acme/shop/Order/v1.dxns" => "%{Order: %schema{id: :uuid}}"})
    assert Map.has_key?(pages, "acme/index.html")
    assert Map.has_key?(pages, "acme/shop/index.html")
    assert pages["acme/shop/index.html"] =~ ~s(href="../../style.css")
  end

  test "every directory of the site has its own index.html" do
    pages =
      site(%{
        "a.b.c.dxns" => "%{T: :string}",
        "x/y/Z-v1.dxns" => "%{Z: %schema{v: :integer}}"
      })

    dirs = pages |> Map.keys() |> Enum.map(&Path.dirname/1) |> Enum.uniq()

    for dir <- dirs,
        do:
          assert(
            Map.has_key?(pages, Path.join(dir, "index.html") |> String.trim_leading("./")),
            dir
          )

    assert Map.has_key?(pages, "a/index.html") and Map.has_key?(pages, "a/b/index.html")
  end

  # Jan, 2026-10-20: light or dark, the choice kept in localStorage.
  test "every page offers light and dark, and remembers the choice" do
    pages = site(%{"a.dxns" => "%{T: :string}"})

    for path <- ["index.html", "a/index.html"] do
      html = pages[path]
      assert html =~ ~s(id="theme-toggle")
      assert html =~ "localStorage.getItem(\"dextrin-docs-theme\")"
      assert html =~ "localStorage.setItem(\"dextrin-docs-theme\""
    end
  end

  describe "names come from where a file lies" do
    test "a namespace file's entries are in its namespace" do
      pages = site(%{"acme.common.dxns" => "%{Money: %schema{a: :decimal}, Code: :string}"})
      assert pages["acme/common/index.html"] =~ ~s(id="Money")
      assert pages["acme/common/index.html"] =~ "acme.common/Code"
    end

    test "a versioned file holds the definition named like it, and every version shows" do
      pages =
        site(%{
          "acme/shop/Customer-v1.dxns" => "%{Customer: %schema{id: :uuid}}",
          "acme/shop/Customer-v2.dxns" => "%{Customer: %schema(2){id: :uuid, name: :string}}"
        })

      html = pages["acme/shop/index.html"]
      assert html =~ "acme.shop/Customer"
      assert html =~ "v2"
      assert html =~ "Version 1"
    end

    test "every other entry in such a file is internal to it" do
      pages =
        site(%{
          "acme/shop/Order/v1.dxns" => "%{Order: %schema{l: Line}, Line: %schema{q: :integer}}"
        })

      assert pages["acme/shop/index.html"] =~ ~s(id="Order.Line")
      assert pages["acme/shop/index.html"] =~ "internal to"
    end

    test "a name with no namespace is on the top page" do
      pages = site(%{"Ping.dxns" => "%{Ping: %schema{at: :timestamp}}"})
      assert pages["index.html"] =~ ~s(id="Ping")
    end
  end

  describe "comments are documentation" do
    test "the block directly above an entry, and the comment on its line, are its" do
      pages =
        site(%{
          "a.dxns" => """
          %{
            # About M.
            M: %schema{
              x: :integer   # the x

              # cut off by a blank line

              y: :integer
            }
          }
          """
        })

      html = pages["a/index.html"]
      assert html =~ "About M."
      assert html =~ "the x"
      refute html =~ "cut off"
    end

    test "a namespace file's leading comments describe the namespace" do
      pages = site(%{"a.dxns" => "# All about a.\n\n%{T: :string}"})
      assert pages["a/index.html"] =~ "All about a."
      assert pages["index.html"] =~ "All about a."
    end
  end

  test "a reference links to its definition, across files" do
    pages =
      site(%{
        "acme.common.dxns" => "%{Money: %schema{a: :decimal}}",
        "acme.shop.Product.dxns" => "%{Product: %schema{price: acme.common/Money}}"
      })

    assert pages["acme/shop/index.html"] =~ ~s(href="../../acme/common/index.html#Money")
    assert pages["acme/common/index.html"] =~ "Used by"
  end

  test "a field's position is its place in the binary form, and a shape has none" do
    pages = site(%{"a.dxns" => "%{S: %schema{x: :integer, y: :integer}, H: %shape{k: :string}}"})
    html = pages["a/index.html"]
    assert html =~ ~s(<td class="pos">2</td>)
    assert html =~ "shape"
  end

  test "a document that is not a map is refused, naming its file" do
    root = Path.join(System.tmp_dir!(), "dextrin-docs-bad-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "bad.dxns"), "[1 2]")
    assert {:error, message} = Docs.site(root)
    assert message =~ "bad.dxns"
  end

  test "the example builds" do
    assert {:ok, pages} = Docs.site("example/schemas", title: "Acme schemas")
    # index, acme, acme.billing, acme.common, acme.events, acme.shop, style.css
    assert length(pages) == 7
  end

  describe "annotations, {:doc T %{...}} (DXNS.md §1b)" do
    @annotated """
    %{
      Order: {:doc %schema(2){
        id: :integer
        email: {:doc :string %{description: "Where *receipts* go", read-only: true}}
        legacy?: {:doc :string %{deprecated: "use email"}}
      } %{title: "An order", description: "One checkout.", examples: [%Order(2){id: 1, email: "a@b"}]}}

      Port: {:doc {:refine :integer %{min: 1}} %{deprecated: true, meta: %{"acme.owner" => "net"}}}
    }
    """

    test "an annotated schema is still a schema, its fields still fields" do
      html =
        Enum.find_value(site(%{"shop.dxns" => @annotated}), fn {_, page} ->
          page =~ ~s(id="Order") && page
        end)

      assert html =~ "struct schema"
      assert html =~ ~s(<code>email</code>)
      refute html =~ "{:doc"
    end

    test "a title, a description, examples and meta are shown with the definition" do
      pages = site(%{"shop.dxns" => @annotated})
      html = Enum.find_value(pages, fn {_path, page} -> page =~ ~s(id="Order") && page end)
      assert html =~ "An order"
      assert html =~ "One checkout."
      assert html =~ "Examples"
      assert html =~ "a@b"
      assert html =~ "acme.owner"
    end

    test "deprecated, read-only and write-only are chips; a field's description is its note" do
      pages = site(%{"shop.dxns" => @annotated})
      html = Enum.find_value(pages, fn {_path, page} -> page =~ ~s(id="Order") && page end)
      assert html =~ ~s(class="chip chip-deprecated")
      assert html =~ "use email"
      assert html =~ ~s(class="chip chip-read-only")
      assert html =~ "<em>receipts</em>"
    end

    test "an enum's values are listed with their own notes" do
      pages =
        site(%{
          "c.dxns" =>
            ~s|%{Color: {:doc {:enum :red :old} %{values: %{:old => %{deprecated: true, description: "Use red"}}}}}|
        })

      html = Enum.find_value(pages, fn {_, page} -> page =~ ~s(id="Color") && page end)
      assert html =~ ~s(<dl class="values">)
      assert html =~ "Use red"
      assert html =~ ~s(<code>:old</code><span class="chip chip-deprecated">)
    end
  end

  # T696 (Jan, 2026-11-18): everything DXNS gained since the generator
  # was written is shown.
  describe "what DXNS gained since 2026-10-20" do
    defp page_with(pages, id),
      do: Enum.find_value(pages, fn {_, page} -> page =~ ~s(id="#{id}") && page end)

    test "a named type's versions are shown as a schema's are, latest first" do
      pages =
        site(%{
          "a/Tier.dxns" => "%{Tier: {:enum :bronze :silver}}",
          "a/Tier-v2.dxns" => "%{Tier: %type(2)[{:enum :bronze :silver :gold}]}"
        })

      html = page_with(pages, "Tier")
      assert html =~ ~s(<span class="chip chip-version" id="Tier-v2">v2</span>)
      assert html =~ ~s(<details class="older" id="Tier-v1">)
      assert html =~ ":gold"
      refute html =~ "%type"
    end

    test "a pinned reference links to the version it pins, in either spelling" do
      pages =
        site(%{
          "a/Tier.dxns" => "%{Tier: {:enum :bronze}}",
          "a/Tier-v2.dxns" => "%{Tier: %type(2)[{:enum :bronze :gold}]}",
          "a.dxns" => "%{C: %shape{t: a/Tier(1) u: {:at a/Tier 2}}}"
        })

      html = pages["a/index.html"]
      assert html =~ ~s|<a class="ref" href="../a/index.html#Tier-v1">a/Tier(1)</a>|
      assert html =~ ~s(<a class="ref" href="../a/index.html#Tier-v2">)
      assert page_with(pages, "Tier") =~ "Used by"
    end

    test "a head's bases are links, and a dropped field and the extras are rows" do
      pages =
        site(%{
          "a.dxns" => """
          %{
            P: %shape{name: :string nick: :string}
            C: %schema(1) includes P {
              - nick
              id: :uuid
              * :string => :integer
              - *
            }
          }
          """
        })

      html = pages["a/index.html"]

      assert html =~
               ~s(<p class="bases">includes <a class="ref" href="../a/index.html#P">P</a></p>)

      assert html =~ ~s(<tr class="dropped">)
      assert html =~ "<s>nick</s>"
      assert html =~ ~s(<code>* <span class="kw">:string</span></code>)
      assert html =~ ~s(<tr class="closed">)
    end

    test "a comment on a left-out field, the extras or the closing is its note" do
      pages =
        site(%{
          "a.dxns" => """
          %{
            P: %shape{a: :string nick: :string}
            C: %shape includes P {
              # why nick goes
              - nick
              # about id
              id: :uuid
              * :string => :integer # about the rest
              - * # nothing else
            }
          }
          """
        })

      html = pages["a/index.html"]
      assert html =~ ~s(<td class="notes">left out of the bases<p>why nick goes</p></td>)
      assert html =~ ~s(<td class="notes"><p>about id</p></td>)

      assert html =~
               ~s(<td class="notes">any other entry with such a key<p>about the rest</p></td>)

      assert html =~ ~s(<td class="notes">no entries beyond these<p>nothing else</p></td>)
    end

    test "a deprecated version is struck through, with its reason" do
      pages =
        site(%{
          "a/C-v1.dxns" => ~s|%{C: {:doc %schema{a: :string} %{deprecated: "use 2"}}}|,
          "a/C-v2.dxns" => "%{C: %schema(2){a: :string b?: {:doc :string %{deprecated: true}}}}"
        })

      html = page_with(pages, "C")

      assert html =~
               ~s(<summary><s>Version 1</s> <span class="chip chip-deprecated" title="use 2">deprecated: use 2</span>)

      assert html =~ "<code><s>b</s></code>"
    end

    test "a generic's parameters are listed with their bounds and defaults" do
      pages =
        site(%{
          "a.dxns" => "%{Page: {:generic [T {S :integer :int32}] %shape{items: {:list-of T}}}}"
        })

      html = pages["a/index.html"]
      assert html =~ ~s(<span class="chip chip-type">generic type</span>)
      assert html =~ ~s(<dl class="params">)

      assert html =~
               ~s(<dt><code>S</code></dt><dd>within <code><span class="kw">:integer</span></code>, default <code><span class="kw">:int32</span></code></dd>)

      refute html =~ ":generic"
    end

    test "a generic in a versioned file takes the file's version" do
      pages =
        site(%{
          "a/Page.dxns" => "%{Page: {:generic [T] {:list-of T}}}",
          "a/Page-v2.dxns" => "%{Page: {:generic [T] %shape{items: {:list-of T}}}}"
        })

      html = page_with(pages, "Page")
      assert html =~ ~s(<span class="chip chip-version" id="Page-v2">v2</span>)
      assert html =~ ~s(<details class="older" id="Page-v1">)
    end

    test "discriminator, secret, key, visibility and messages are shown" do
      pages =
        site(%{
          "a.dxns" => """
          %{
            P: {:doc {:one-of A B} %{discriminator: :kind}}
            A: %shape{kind: {:const "a"}}
            B: %shape{kind: {:const "b"}}
            S: %shape{
              id: {:doc :string %{key: true}}
              token: {:doc :string %{secret: true visibility: [:create :read]}}
              code: {:doc {:refine :string %{min-length: 2}} %{messages: %{min-length: "too short"}}}
            }
          }
          """
        })

      html = pages["a/index.html"]
      assert html =~ ~s(<span class="chip chip-discriminator">discriminator: kind</span>)
      assert html =~ ~s(<span class="chip chip-key">key</span>)
      assert html =~ ~s(<span class="chip chip-secret">secret</span>)
      assert html =~ ~s(<span class="chip chip-visibility">visible on create, read</span>)
      assert html =~ ~s(<dl class="messages">)
      assert html =~ "too short"
    end

    test "a computed default is shown as one" do
      pages = site(%{"a.dxns" => "%{S: %schema{at: %field{type: :timestamp computed: :now}}}"})

      assert pages["a/index.html"] =~
               ~s(<span class="label">computed</span> <code><span class="kw">:now</span></code>)
    end

    test "a generated file says what generated it, and that is not its prose" do
      pages =
        site(%{
          "a.dxns" =>
            "# Generated by some-tool from a.tsp; do not edit.\n\n# About a.\n\n%{T: :string}"
        })

      html = pages["a/index.html"]

      assert html =~
               ~s(<span class="provenance">generated by <code>some-tool</code> from <code>a.tsp</code></span>)

      assert html =~ "About a."
      refute html =~ "do not edit"
    end
  end
end
