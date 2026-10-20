defmodule Dextrin.Schema.DocsTest do
  @moduledoc """
  `Dextrin.Schema.Docs` and `mix dextrin.docs` (Jan, 2026-10-20): a
  directory of `.dxns` files as a small HTML site -- names from file
  paths (DXN.md §4.6), a definition's comments as its documentation,
  references as links, every version shown.
  """

  use ExUnit.Case, async: true

  alias Dextrin.Schema.Docs
  alias Dextrin.Schema.Docs.{Comments, Markdown}

  doctest Comments
  doctest Markdown

  defp site(files) do
    root = Path.join(System.tmp_dir!(), "dextrin-docs-#{System.unique_integer([:positive])}")

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
    # index, acme, acme.common, acme.events, acme.shop, style.css
    assert length(pages) == 6
  end
end
