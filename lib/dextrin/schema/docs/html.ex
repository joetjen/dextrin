defmodule Dextrin.Schema.Docs.Html do
  @moduledoc """
  The pages of `Dextrin.Schema.Docs`: `index.html` at the top -- a
  section per root namespace, then the names with no namespace -- an
  `index.html` in a directory per namespace, and the stylesheet they
  share, `style.css`. Everything is plain HTML and CSS, so the site opens
  from disk; one small script only switches light and dark.
  """

  alias Dextrin.Schema.Docs
  alias Dextrin.Schema.Docs.Markdown
  alias Ichor.Syntax.{Node, Token}

  import Markdown, only: [escape: 1]

  @doc "The site's pages for `definitions`, under the name `title`."
  @spec pages(String.t(), [map()]) :: [Docs.page()]
  def pages(title, definitions) do
    known = Map.new(definitions, &{&1.name, &1})
    by_namespace = Enum.group_by(definitions, & &1.namespace)
    named = by_namespace |> Map.keys() |> Enum.reject(&(&1 == ""))
    all = named |> Enum.flat_map(&prefixes/1) |> Enum.uniq() |> Enum.sort()

    ctx = %{
      known: known,
      used_by: used_by(definitions),
      title: title,
      by_namespace: by_namespace,
      all: all,
      notes: notes(definitions)
    }

    [{"style.css", stylesheet()}, {"index.html", namespace_page(nil, ctx)}] ++
      for(namespace <- all, do: {page_of(namespace), namespace_page(namespace, ctx)})
  end

  # ---- the namespace tree ------------------------------------------------------

  # `acme.shop` and every namespace above it: `acme`, `acme.shop`.
  defp prefixes(namespace) do
    segments = String.split(namespace, ".")
    for n <- 1..length(segments), do: segments |> Enum.take(n) |> Enum.join(".")
  end

  # The namespaces directly below `parent` (nil: the roots), in order.
  defp children(nil, ctx), do: Enum.filter(ctx.all, &(not String.contains?(&1, ".")))

  defp children(parent, ctx) do
    depth = length(String.split(parent, "."))

    Enum.filter(ctx.all, fn namespace ->
      String.starts_with?(namespace, parent <> ".") and
        length(String.split(namespace, ".")) == depth + 1
    end)
  end

  # The public definitions of `namespace`, in order, and the internal ones
  # by owner.
  defp own(namespace, ctx) do
    defs = Map.get(ctx.by_namespace, namespace || "", [])

    public =
      defs |> Enum.filter(&is_nil(&1.internal_to)) |> Enum.sort_by(&String.downcase(&1.short))

    {public, Enum.group_by(Enum.reject(defs, &is_nil(&1.internal_to)), & &1.internal_to)}
  end

  defp internals_of(definition, internal),
    do: internal |> Map.get(definition.name, []) |> Enum.sort_by(&String.downcase(&1.short))

  # What a namespace file says about each namespace.
  defp notes(definitions) do
    definitions
    |> Enum.filter(&(&1.namespace_note not in [nil, ""]))
    |> Map.new(&{&1.namespace, &1.namespace_note})
  end

  # Every public definition in `namespace` and below it.
  defp total(namespace, ctx) do
    ctx.by_namespace
    |> Enum.filter(fn {ns, _} -> ns == namespace or String.starts_with?(ns, namespace <> ".") end)
    |> Enum.flat_map(&elem(&1, 1))
    |> Enum.count(&is_nil(&1.internal_to))
  end

  # ---- addresses -------------------------------------------------------------

  # A namespace is a directory, its page the directory's `index.html`:
  # `acme.shop` is `acme/shop/index.html` (Jan, 2026-10-20). The top -- the
  # index, and the names with no namespace -- is `index.html`. Every link
  # is written from the site's root here, and made relative to the page
  # it is on when the page is put together (`relative/2`).
  defp page_of(nil), do: "index.html"
  defp page_of(""), do: "index.html"
  defp page_of(namespace), do: (namespace |> String.split(".") |> Enum.join("/")) <> "/index.html"

  # Every link in `html` that names a page or file of the site, from the
  # site's root, made relative to the page at `path`.
  defp relative(html, path) do
    base = String.duplicate("../", length(String.split(path, "/")) - 1)
    Regex.replace(~r/(href)="(?!https?:|#|mailto:)([^"]*)"/, html, "\\1=\"#{base}\\2\"")
  end

  defp anchor(%{internal_to: nil, short: short}), do: short
  defp anchor(%{internal_to: owner, short: short}), do: short_of(owner) <> "." <> short

  defp short_of(name), do: name |> String.split("/") |> List.last()

  defp href(%{namespace: namespace} = definition),
    do: page_of(namespace) <> "#" <> anchor(definition)

  defp last_segment(namespace), do: namespace |> String.split(".") |> List.last()

  # Who refers to whom: for each name, the definitions whose types name it.
  defp used_by(definitions) do
    definitions
    |> Enum.flat_map(fn definition ->
      definition
      |> types_of()
      |> Enum.flat_map(&Docs.references(&1, definition.scope))
      |> Enum.uniq()
      |> Enum.reject(&(&1 == definition.name))
      |> Enum.map(&{&1, definition.name})
    end)
    |> Enum.uniq()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp types_of(%{kind: :type, versions: versions}), do: Enum.map(versions, & &1.value)
  defp types_of(%{versions: versions}), do: for(v <- versions, f <- v.fields, do: f.type)

  # ---- the frame: the sidebar, then the page ----------------------------------

  defp frame(title, current, ctx, body) do
    current
    |> page_of()
    |> then(&relative(page(title, current, ctx, body), &1))
  end

  defp page(title, current, ctx, body) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="claude:viewport-fit-sides" content="cover">
    <title>#{escape(title)}</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Atkinson+Hyperlegible:ital,wght@0,400;0,700;1,400&family=JetBrains+Mono:wght@400;600&display=swap">
    <link rel="stylesheet" href="style.css">
    <script>#{theme_early()}</script>
    </head>
    <body>
    <div class="layout">
      <nav class="sidebar" aria-label="All namespaces and definitions">
        <div class="sidebar-head">
          <a class="brand" href="index.html"><span class="brand-mark" aria-hidden="true">%{}</span>#{escape(ctx.title)}</a>
          <button class="theme-toggle" type="button" id="theme-toggle" aria-label="Switch between light and dark">Dark</button>
        </div>
        <details class="sidebar-toggle" open>
          <summary>Browse</summary>
          #{sidebar(current, ctx)}
        </details>
      </nav>
      <main class="main">
        #{body}
        <footer class="site-foot"><p>Generated from the <code>.dxns</code> sources by Dextrin. A field's # is its position in the binary form.</p></footer>
      </main>
    </div>
    <script>#{theme_switch()}</script>
    </body>
    </html>
    """
  end

  # ---- light and dark ---------------------------------------------------------

  # Light or dark, as the reader chose it (Jan, 2026-10-20): the choice is
  # kept in localStorage under one key, and with none the page follows the
  # system. The first script runs before the page is drawn, so a stored
  # choice never flashes the other theme; storage that refuses -- a
  # private window -- leaves the page working, only forgetful.

  defp theme_early do
    ~s|try { var t = localStorage.getItem("dextrin-docs-theme"); | <>
      ~s|if (t === "light" \|\| t === "dark") document.documentElement.setAttribute("data-theme", t); } catch (e) {}|
  end

  defp theme_switch do
    """
    (function () {
      var root = document.documentElement, button = document.getElementById("theme-toggle");
      function current() {
        var t = root.getAttribute("data-theme");
        if (t) return t;
        return window.matchMedia && matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
      }
      function label() {
        var next = current() === "dark" ? "light" : "dark";
        button.textContent = next === "dark" ? "Dark" : "Light";
        button.setAttribute("aria-label", "Switch to " + next);
      }
      button.addEventListener("click", function () {
        var next = current() === "dark" ? "light" : "dark";
        root.setAttribute("data-theme", next);
        try { localStorage.setItem("dextrin-docs-theme", next); } catch (e) {}
        label();
      });
      label();
    })();
    """
  end

  # The tree of every namespace and definition, the branch of `current`
  # (a namespace, "" for the names with none, nil for the index) open.
  defp sidebar(current, ctx) do
    roots = children(nil, ctx) |> Enum.map_join("", &tree_node(&1, current, ctx))

    global =
      case own("", ctx) do
        {[], _} ->
          ""

        {public, internal} ->
          open = if current == nil, do: " open", else: ""

          ~s(<li><details#{open}><summary><a href="#{page_of(nil)}">No namespace</a></summary><ul>) <>
            Enum.map_join(public, "", &tree_definition(&1, internal)) <> "</ul></details></li>"
      end

    ~s(<ul class="tree">) <> roots <> global <> "</ul>"
  end

  defp tree_node(namespace, current, ctx) do
    on_path? =
      current not in [nil, ""] and
        (current == namespace or String.starts_with?(current, namespace <> "."))

    {public, internal} = own(namespace, ctx)

    inner =
      Enum.map_join(children(namespace, ctx), "", &tree_node(&1, current, ctx)) <>
        Enum.map_join(public, "", &tree_definition(&1, internal))

    ~s(<li><details#{if on_path?, do: " open", else: ""}><summary><a href="#{page_of(namespace)}"#{aria(current == namespace)}>) <>
      escape(last_segment(namespace)) <> ~s(</a></summary><ul>) <> inner <> "</ul></details></li>"
  end

  defp tree_definition(d, internal) do
    inner =
      case internals_of(d, internal) do
        [] -> ""
        list -> "<ul>" <> Enum.map_join(list, "", &tree_definition(&1, %{})) <> "</ul>"
      end

    ~s(<li class="def-leaf"><a href="#{href(d)}"><span class="dot dot-#{d.kind}" aria-hidden="true"></span>#{escape(d.short)}</a>#{inner}</li>)
  end

  defp aria(true), do: ~s( aria-current="page")
  defp aria(false), do: ""

  # ---- a namespace's page, and the index ---------------------------------------

  # One design for both (Jan, 2026-10-20): the index is the page of the
  # level above the roots. A section for each namespace directly below,
  # listing its own namespaces and definitions; then this namespace's own
  # definitions in full.
  defp namespace_page(namespace, ctx) do
    {public, internal} = own(namespace, ctx)
    below = children(namespace, ctx)
    sections = Enum.map_join(below, "", &child_section(&1, ctx))

    note = if namespace, do: Map.get(ctx.notes, namespace), else: nil

    # The top's own definitions are the names with no namespace.
    cards =
      Enum.map_join(public, "", fn d ->
        definition(d, ctx) <> Enum.map_join(internals_of(d, internal), "", &definition(&1, ctx))
      end)

    own_heading =
      cond do
        cards == "" or below == [] -> ""
        namespace == nil -> ~s(<h2 class="own-heading">Names with no namespace</h2>)
        true -> ~s(<h2 class="own-heading">Definitions in <code>#{escape(namespace)}</code></h2>)
      end

    {eyebrow, heading, title} =
      case namespace do
        nil -> {"Schema reference", escape(ctx.title), ctx.title}
        ns -> {"Namespace", "<code>" <> escape(ns) <> "</code>", ns <> " · " <> ctx.title}
      end

    frame(title, namespace, ctx, """
    <div class="page">
      <header class="intro">
        #{crumbs(namespace)}
        <p class="eyebrow">#{eyebrow}</p>
        <h1>#{heading}</h1>
        #{if namespace == nil, do: ~s(<p class="lede">Every struct schema, shape and named type, by namespace. A name links to its definition wherever it appears.</p>), else: ""}
        #{if note, do: ~s(<div class="prose">) <> Markdown.to_html(note, linker(%{scope: %{}}, ctx)) <> "</div>", else: ""}
      </header>
      #{if sections == "", do: "", else: ~s(<div class="sections">) <> sections <> "</div>"}
      #{own_heading}
      #{cards}
    </div>
    """)
  end

  defp crumbs(nil), do: ""

  defp crumbs(namespace) do
    parents = namespace |> prefixes() |> Enum.drop(-1)

    links =
      [~s(<a href="index.html">All namespaces</a>)] ++
        Enum.map(parents, &~s(<a href="#{page_of(&1)}">#{escape(last_segment(&1))}</a>))

    ~s(<p class="crumbs">) <>
      Enum.join(links, " › ") <> " › <b>" <> escape(last_segment(namespace)) <> "</b></p>"
  end

  # A namespace directly below the page's: a link to it, its own
  # namespaces and its definitions.
  defp child_section(namespace, ctx) do
    {public, _internal} = own(namespace, ctx)
    note = ctx.notes |> Map.get(namespace) |> first_paragraph()

    subs =
      Enum.map_join(children(namespace, ctx), "", fn sub ->
        ~s(<li><a class="ns-link" href="#{page_of(sub)}"><code>#{escape(last_segment(sub))}</code></a><span class="count">#{total(sub, ctx)}</span></li>)
      end)

    defs = Enum.map_join(public, "", &def_link/1)

    """
    <section class="ns-section">
      <h2><a href="#{page_of(namespace)}"><code>#{escape(namespace)}</code></a></h2>
      #{if note, do: ~s(<div class="prose summary">) <> Markdown.to_html(note, fn _ -> nil end) <> "</div>", else: ""}
      #{if subs == "", do: "", else: ~s(<div class="group"><p class="label">Namespaces</p><ul class="links">) <> subs <> "</ul></div>"}
      #{if defs == "", do: "", else: ~s(<div class="group"><p class="label">Definitions</p><ul class="links">) <> defs <> "</ul></div>"}
    </section>
    """
  end

  defp def_link(d),
    do: ~s(<li><a href="#{href(d)}"><code>#{escape(d.short)}</code></a>#{kind_chip(d)}</li>)

  defp first_paragraph(nil), do: nil
  defp first_paragraph(""), do: nil
  defp first_paragraph(text), do: text |> String.split(~r/\n\s*\n/) |> hd()

  # ---- one definition ----------------------------------------------------------

  defp definition(d, ctx) do
    [latest | older] = d.versions

    used =
      ctx.used_by
      |> Map.get(d.name, [])
      |> Enum.sort()
      |> Enum.map_join(", ", fn name ->
        case Map.fetch(ctx.known, name) do
          {:ok, user} -> ~s(<a href="#{href(user)}"><code>#{escape(display(user))}</code></a>)
          :error -> "<code>#{escape(name)}</code>"
        end
      end)

    """
    <article class="def kind-#{d.kind}" id="#{escape(anchor(d))}">
      <header class="def-head">
        <h2><a class="self" href="##{escape(anchor(d))}"><code>#{escape(d.short)}</code></a></h2>
        <div class="chips">#{kind_chip(d)}#{internal_chip(d, ctx)}#{version_chips(d)}</div>
        <p class="full-name"><code>#{escape(d.name)}</code></p>
      </header>
      #{prose(d.doc, d, ctx)}
      #{version_body(d, latest, ctx, true)}
      #{Enum.map_join(older, "", &older_version(d, &1, ctx))}
      #{if used == "", do: "", else: ~s(<p class="used-by"><span class="label">Used by</span> #{used}</p>)}
    </article>
    """
  end

  defp display(%{internal_to: nil, name: name}), do: name
  defp display(%{internal_to: owner, short: short}), do: short_of(owner) <> " › " <> short

  defp prose("", _d, _ctx), do: ""
  defp prose(nil, _d, _ctx), do: ""

  defp prose(text, d, ctx),
    do: ~s(<div class="prose">) <> Markdown.to_html(text, linker(d, ctx)) <> "</div>"

  defp kind_chip(%{kind: :schema}), do: ~s(<span class="chip chip-schema">struct schema</span>)
  defp kind_chip(%{kind: :shape}), do: ~s(<span class="chip chip-shape">shape</span>)
  defp kind_chip(%{kind: :type}), do: ~s(<span class="chip chip-type">type</span>)

  defp internal_chip(%{internal_to: nil}, _ctx), do: ""

  defp internal_chip(%{internal_to: owner}, ctx) do
    case Map.fetch(ctx.known, owner) do
      {:ok, o} ->
        ~s(<span class="chip chip-internal">internal to <a href="#{href(o)}">#{escape(o.short)}</a></span>)

      :error ->
        ~s(<span class="chip chip-internal">internal</span>)
    end
  end

  defp version_chips(%{kind: :schema, versions: [latest | older]}) do
    ~s(<span class="chip chip-version">v#{latest.version}</span>) <>
      if older == [],
        do: "",
        else: ~s(<span class="chip chip-quiet">#{length(older) + 1} versions</span>)
  end

  defp version_chips(_d), do: ""

  defp older_version(d, version, ctx) do
    """
    <details class="older">
      <summary>Version #{version.version} <span class="file">#{escape(version.file)}</span></summary>
      #{version_body(d, version, ctx, false)}
    </details>
    """
  end

  defp version_body(%{kind: :type} = d, version, ctx, _latest?) do
    """
    <div class="type-def">
      <p class="label">Definition</p>
      <pre class="expr"><code>#{type_html(version.value, d, ctx)}</code></pre>
      <p class="file">#{escape(version.file)}</p>
    </div>
    """
  end

  defp version_body(d, version, ctx, _latest?) do
    note =
      if version.note && version.note != "",
        do:
          ~s(<div class="prose version-note">) <>
            Markdown.to_html(version.note, linker(d, ctx)) <> "</div>",
        else: ""

    position_head =
      if d.kind == :schema,
        do: ~s(<th scope="col" class="pos" title="Position in the binary form">#</th>),
        else: ""

    rows =
      Enum.map_join(version.fields, "", fn f ->
        notes =
          [f.description, f.doc]
          |> Enum.reject(&(&1 in [nil, ""]))
          |> Enum.map_join("", &Markdown.to_html(&1, linker(d, ctx)))

        default =
          if f.default,
            do:
              ~s(<div class="default"><span class="label">default</span> <code>#{type_html(f.default, d, ctx)}</code></div>),
            else: ""

        """
        <tr>
          #{if d.kind == :schema, do: ~s(<td class="pos">#{f.position}</td>), else: ""}
          <th scope="row" class="field"><code>#{escape(f.name)}</code>#{if f.optional?, do: ~s(<span class="opt">optional</span>), else: ""}</th>
          <td class="type"><code>#{type_html(f.type, d, ctx)}</code>#{default}</td>
          <td class="notes">#{notes}</td>
        </tr>
        """
      end)

    """
    #{note}
    <div class="table-wrap">
      <table class="fields">
        <thead><tr>#{position_head}<th scope="col">Field</th><th scope="col">Type</th><th scope="col">Notes</th></tr></thead>
        <tbody>#{rows}</tbody>
      </table>
    </div>
    <p class="file">#{escape(version.file)}</p>
    """
  end

  # ---- type expressions ----------------------------------------------------------

  # A code span names a definition when the file's own names, or the full
  # names, know it.
  defp linker(d, ctx) do
    fn code ->
      name = Docs.resolve(code, Map.get(d, :scope, %{}))

      case Map.fetch(ctx.known, name) do
        {:ok, target} -> href(target)
        :error -> nil
      end
    end
  end

  @doc false
  def type_html(nil, _d, _ctx), do: ""

  def type_html(node, d, ctx) do
    node
    |> render(d, ctx)
    |> IO.iodata_to_binary()
    |> String.replace(~r/ {2,}/, " ")
    |> String.trim()
  end

  defp render(%Token{trivia: true}, _d, _ctx), do: " "
  defp render(%Token{text: text}, _d, _ctx), do: escape(text)

  defp render(%Node{rule: :symbol} = node, d, ctx) do
    written = Docs.text(node)
    name = Docs.resolve(written, d.scope)

    case Map.fetch(ctx.known, name) do
      {:ok, target} -> ~s(<a class="ref" href="#{href(target)}">#{escape(written)}</a>)
      :error -> ~s(<span class="sym">#{escape(written)}</span>)
    end
  end

  defp render(%Node{rule: :keyword} = node, _d, _ctx),
    do: ~s(<span class="kw">#{escape(Docs.text(node))}</span>)

  defp render(%Node{rule: :string} = node, _d, _ctx),
    do: ~s(<span class="str">#{escape(Docs.text(node))}</span>)

  defp render(%Node{rule: :tuple, children: children} = node, d, ctx) do
    values = Enum.filter(children, &match?(%Node{rule: :value}, &1))

    case values do
      [head, field, table] ->
        if Docs.text(head) == ":case",
          do: case_html(field, table, d, ctx),
          else: plain(node, d, ctx)

      _ ->
        plain(node, d, ctx)
    end
  end

  defp render(node, d, ctx), do: plain(node, d, ctx)

  defp plain(%Node{children: children}, d, ctx), do: Enum.map(children, &render(&1, d, ctx))

  # `{:case field %{value => type, ...}}`: the type chosen by a field's
  # value, as a table from value to type.
  defp case_html(field, table, d, ctx) do
    rows =
      case Docs.body(table) do
        %Node{rule: :map_lit, children: children} ->
          for %Node{rule: :map_entry} = entry <- children do
            key =
              case Enum.reject(entry.children, &match?(%Token{trivia: true}, &1)) do
                [%Token{name: :MAP_KEY, text: text} | _] -> escape(text)
                [%Node{} = k | _] -> render(k, d, ctx)
              end

            ~s(<tr><td>) <>
              key_text(key) <>
              ~s(</td><td>) <> type_html(Docs.value_of(entry), d, ctx) <> "</td></tr>"
          end

        _ ->
          []
      end

    [
      ~s(<span class="case">by <span class="case-field">),
      escape(Docs.text(field)),
      ~s(</span><span class="case-table"><span class="case-rows"><table><tbody>),
      rows,
      ~s(</tbody></table></span></span></span>)
    ]
  end

  defp key_text(iodata), do: iodata |> IO.iodata_to_binary() |> String.trim()

  # ---- the stylesheet ----------------------------------------------------------

  @doc false
  def stylesheet do
    """
    /* Layout: a quiet reference -- a namespace rail, a page of definition
       cards, each field a table row with its binary position first.
       Iodine violet: dextrin turns violet-brown with iodine. */
    :root {
      --bg: #f7f7fa;
      --surface: #ffffff;
      --ink: #1c1b29;
      --muted: #5d5b72;
      --rule: #e3e1ec;
      --accent: #5b3fa0;
      --accent-soft: #ece6f8;
      --code-bg: #f1eff7;
      --kw: #7a3e6a;
      --str: #2f6b4f;
      --shape: #2e6a87;
      --shape-soft: #e2f0f6;
      --type: #6b5a1f;
      --type-soft: #f4efdc;
      --font-body: "Atkinson Hyperlegible", "Segoe UI", system-ui, sans-serif;
      --font-code: "JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, monospace;
      --step--1: 0.8125rem;
      --step-0: 1rem;
      --step-1: 1.25rem;
      --step-2: 1.6rem;
      --step-3: 2.1rem;
    }
    @media (prefers-color-scheme: dark) {
      :root:not([data-theme="light"]) {
        --bg: #14131c; --surface: #1c1b27; --ink: #ecebf4; --muted: #a6a3bd; --rule: #2f2d3e;
        --accent: #b9a4f0; --accent-soft: #2c2445; --code-bg: #24222f; --kw: #e2a3cf; --str: #8fd3ad;
        --shape: #8cc9e6; --shape-soft: #1d3340; --type: #e3cf88; --type-soft: #35301c;
        color-scheme: dark;
      }
    }
    :root[data-theme="dark"] {
      --bg: #14131c; --surface: #1c1b27; --ink: #ecebf4; --muted: #a6a3bd; --rule: #2f2d3e;
      --accent: #b9a4f0; --accent-soft: #2c2445; --code-bg: #24222f; --kw: #e2a3cf; --str: #8fd3ad;
      --shape: #8cc9e6; --shape-soft: #1d3340; --type: #e3cf88; --type-soft: #35301c;
      color-scheme: dark;
    }
    *, *::before, *::after { box-sizing: border-box; }
    html { -webkit-text-size-adjust: 100%; }
    body {
      margin: 0; background: var(--bg); color: var(--ink);
      font-family: var(--font-body); font-size: var(--step-0); line-height: 1.6;
    }
    code, pre { font-family: var(--font-code); font-size: 0.875em; }
    a { color: var(--accent); text-underline-offset: 0.18em; }
    a:focus-visible, summary:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; border-radius: 3px; }
    h1, h2, h3 { text-wrap: balance; line-height: 1.25; margin: 0; }

    /* The sidebar holds the far left edge on every page and scrolls on its
       own; the page beside it. Below 52rem it moves on top, folded. */
    .layout { display: grid; grid-template-columns: minmax(15rem, 18rem) minmax(0, 1fr); min-height: 100vh; }
    .sidebar {
      position: sticky; top: 0; align-self: start; height: 100vh; overflow-y: auto;
      background: var(--surface); border-right: 1px solid var(--rule);
      padding-block: calc(1rem + env(safe-area-inset-top, 0px)) 2rem;
      padding-left: max(16px, env(safe-area-inset-left, 0px)); padding-right: 1rem;
      display: grid; align-content: start; gap: 1rem; font-size: 0.9rem;
    }
    .sidebar-head { display: flex; align-items: center; justify-content: space-between; gap: 0.75rem; }
    .brand { display: inline-flex; align-items: center; gap: 0.6rem; font-weight: 700; color: var(--ink); text-decoration: none; min-width: 0; }
    .theme-toggle {
      font: inherit; font-size: 0.75rem; letter-spacing: 0.04em; color: var(--muted); background: transparent;
      border: 1px solid var(--rule); border-radius: 999px; padding: 0.15rem 0.65rem; cursor: pointer; flex: none;
    }
    .theme-toggle:hover { color: var(--accent); border-color: var(--accent); }
    .theme-toggle:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
    .brand-mark { font-family: var(--font-code); font-size: 0.85rem; color: var(--accent); background: var(--accent-soft); border-radius: 6px; padding: 0.15rem 0.4rem; }
    .sidebar-toggle > summary { display: none; }
    .tree, .tree ul { list-style: none; margin: 0; padding: 0; }
    .tree ul { padding-left: 0.85rem; margin-left: 0.3rem; border-left: 1px solid var(--rule); }
    .tree li { padding: 0.08rem 0; }
    .tree summary { cursor: pointer; font-family: var(--font-code); font-size: 0.85rem; padding: 0.1rem 0; }
    .tree summary::marker { color: var(--muted); }
    .tree a { color: var(--ink); text-decoration: none; font-family: var(--font-code); font-size: 0.85rem; }
    .tree a:hover { color: var(--accent); }
    .tree a[aria-current="page"] { color: var(--accent); font-weight: 600; }
    .def-leaf > a { display: inline-flex; align-items: center; gap: 0.4rem; }
    .dot { width: 0.45rem; height: 0.45rem; border-radius: 50%; flex: none; }
    .dot-schema { background: var(--accent); }
    .dot-shape { background: var(--shape); }
    .dot-type { background: var(--type); }

    .main {
      min-width: 0; padding-block: 2rem 0;
      padding-left: max(16px, 2.5rem); padding-right: max(16px, env(safe-area-inset-right, 0px), 2.5rem);
    }
    .page { display: grid; gap: 1.5rem; max-width: 64rem; }
    .eyebrow { margin: 0 0 0.35rem; font-size: var(--step--1); letter-spacing: 0.08em; text-transform: uppercase; color: var(--muted); }
    h1 { font-size: var(--step-3); }
    h1 code { font-size: 0.85em; }
    .lede { color: var(--muted); max-width: 40rem; margin: 0.75rem 0 0; }
    .intro .prose { margin-top: 1rem; }
    .crumbs { margin: 0 0 0.75rem; font-family: var(--font-code); font-size: var(--step--1); color: var(--muted); }
    .crumbs a { text-decoration: none; }
    .crumbs b { color: var(--ink); font-weight: 600; }

    .sections { display: grid; gap: 1rem; }
    .ns-section { background: var(--surface); border: 1px solid var(--rule); border-radius: 12px; padding: 1.1rem 1.3rem; display: grid; gap: 0.75rem; min-width: 0; }
    .ns-section h2 { font-size: var(--step-1); }
    .ns-section h2 a { text-decoration: none; }
    .ns-section .summary { color: var(--muted); font-size: 0.95rem; }
    .group { display: grid; gap: 0.35rem; }
    .group .label { margin: 0; }
    .links { list-style: none; margin: 0; padding: 0; display: flex; flex-wrap: wrap; gap: 0.4rem 1.25rem; }
    .links li { display: inline-flex; align-items: baseline; gap: 0.4rem; }
    .links a { text-decoration: none; }
    .count { font-size: 0.75rem; color: var(--muted); font-variant-numeric: tabular-nums; }
    .own-heading { font-size: var(--step-1); margin-top: 0.5rem; }

    .def { background: var(--surface); border: 1px solid var(--rule); border-radius: 12px; padding: 1.25rem 1.4rem; display: grid; gap: 0.9rem; min-width: 0; scroll-margin-top: 1rem; }
    .def-head { display: grid; gap: 0.35rem; }
    .def-head h2 { font-size: var(--step-2); }
    .def-head .self { color: var(--ink); text-decoration: none; }
    .def-head .self:hover { color: var(--accent); }
    .full-name { margin: 0; font-size: var(--step--1); color: var(--muted); }
    .chips { display: flex; flex-wrap: wrap; gap: 0.4rem; }
    .chip { font-size: 0.75rem; letter-spacing: 0.04em; border-radius: 999px; padding: 0.1rem 0.6rem; border: 1px solid transparent; }
    .chip-schema { background: var(--accent-soft); color: var(--accent); }
    .chip-shape { background: var(--shape-soft); color: var(--shape); }
    .chip-type { background: var(--type-soft); color: var(--type); }
    .chip-internal { border-color: var(--rule); color: var(--muted); }
    .chip-version { border-color: var(--accent); color: var(--accent); font-family: var(--font-code); }
    .chip-quiet { color: var(--muted); }

    .prose { max-width: 42rem; }
    .prose > * + * { margin-top: 0.6rem; }
    .prose p, .prose ul, .prose ol { margin: 0; }
    .prose ul, .prose ol { padding-left: 1.2rem; }
    .prose code, .notes code, .used-by code { background: var(--code-bg); border-radius: 4px; padding: 0.05rem 0.3rem; }
    .version-note { color: var(--muted); font-size: 0.95rem; }
    .label { font-size: 0.72rem; letter-spacing: 0.08em; text-transform: uppercase; color: var(--muted); }

    .table-wrap { overflow-x: auto; }
    table.fields { width: 100%; border-collapse: collapse; font-size: 0.95rem; }
    .fields th, .fields td { text-align: left; vertical-align: top; padding: 0.55rem 0.75rem 0.55rem 0; border-top: 1px solid var(--rule); }
    .fields thead th { border-top: 0; font-size: 0.72rem; letter-spacing: 0.08em; text-transform: uppercase; color: var(--muted); font-weight: 400; }
    .fields .pos { width: 2.5rem; font-variant-numeric: tabular-nums; color: var(--muted); font-family: var(--font-code); font-size: var(--step--1); }
    .fields .field { white-space: nowrap; font-weight: 400; }
    .fields .field code { font-weight: 600; }
    .opt { display: block; font-size: 0.72rem; color: var(--muted); letter-spacing: 0.04em; }
    .fields .type { min-width: 12rem; }
    .fields .notes { min-width: 14rem; color: var(--ink); }
    .fields .notes p + p { margin-top: 0.4rem; }
    .fields .notes p { margin: 0; }
    .default { margin-top: 0.3rem; }
    .kw { color: var(--kw); }
    .str { color: var(--str); }
    .sym { color: var(--muted); }
    a.ref { text-decoration: none; border-bottom: 1px solid var(--accent-soft); }
    a.ref:hover { border-bottom-color: var(--accent); }

    .case { display: inline-grid; gap: 0.3rem; vertical-align: top; }
    .case-field { font-weight: 600; }
    .case table { border-collapse: collapse; }
    .case td { padding: 0.15rem 0.9rem 0.15rem 0; border-top: 1px dashed var(--rule); white-space: nowrap; }

    .type-def .expr { margin: 0.3rem 0 0; background: var(--code-bg); border-radius: 8px; padding: 0.75rem 0.9rem; overflow-x: auto; white-space: pre-wrap; }
    .file { margin: 0; font-family: var(--font-code); font-size: 0.75rem; color: var(--muted); }
    details.older { border-top: 1px dashed var(--rule); padding-top: 0.75rem; }
    details.older summary { cursor: pointer; color: var(--muted); }
    details.older summary .file { display: inline; margin-left: 0.5rem; }
    details.older[open] > *:not(summary) { margin-top: 0.75rem; }
    .used-by { margin: 0; font-size: 0.95rem; display: flex; flex-wrap: wrap; gap: 0.4rem; align-items: baseline; }

    .site-foot { margin-top: 3rem; padding-block: 1.5rem 2.5rem; color: var(--muted); font-size: var(--step--1); border-top: 1px solid var(--rule); max-width: 64rem; }

    @media (max-width: 52rem) {
      .layout { grid-template-columns: minmax(0, 1fr); }
      .sidebar { position: static; height: auto; border-right: 0; border-bottom: 1px solid var(--rule); padding-right: max(16px, env(safe-area-inset-right, 0px)); }
      .sidebar-toggle > summary { display: list-item; cursor: pointer; color: var(--muted); }
      .main { padding-left: max(16px, env(safe-area-inset-left, 0px)); padding-right: max(16px, env(safe-area-inset-right, 0px)); }
      .def { padding: 1rem; }
    }
    @media (prefers-reduced-motion: reduce) { * { scroll-behavior: auto; } }
    """
  end
end
