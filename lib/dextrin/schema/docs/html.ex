defmodule Dextrin.Schema.Docs.Html do
  @moduledoc """
  The pages of `Dextrin.Schema.Docs`: `index.html`, a page for each
  namespace (`global.html` for the names with none), and the stylesheet
  they share, `style.css`. Everything is plain HTML and CSS, so the site
  opens from disk and needs no script.
  """

  alias Dextrin.Schema.Docs
  alias Dextrin.Schema.Docs.Markdown
  alias Ichor.Syntax.{Node, Token}

  import Markdown, only: [escape: 1]

  @doc "The site's pages for `definitions`, under the name `title`."
  @spec pages(String.t(), [map()]) :: [Docs.page()]
  def pages(title, definitions) do
    known = Map.new(definitions, &{&1.name, &1})
    used_by = used_by(definitions)
    namespaces = definitions |> Enum.group_by(& &1.namespace) |> Enum.sort_by(&elem(&1, 0))

    ctx = %{
      known: known,
      used_by: used_by,
      title: title,
      namespaces: Enum.map(namespaces, &elem(&1, 0))
    }

    [{"style.css", stylesheet()}, {"index.html", index(namespaces, ctx)}] ++
      for {namespace, defs} <- namespaces,
          do: {page_of(namespace), namespace_page(namespace, defs, ctx)}
  end

  # ---- addresses -------------------------------------------------------------

  defp page_of(""), do: "global.html"
  defp page_of(namespace), do: namespace <> ".html"

  defp anchor(%{internal_to: nil, short: short}), do: short
  defp anchor(%{internal_to: owner, short: short}), do: short_of(owner) <> "." <> short

  defp short_of(name), do: name |> String.split("/") |> List.last()

  defp href(%{namespace: namespace} = definition),
    do: page_of(namespace) <> "#" <> anchor(definition)

  defp label_of(""), do: "No namespace"
  defp label_of(namespace), do: namespace

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

  defp types_of(%{versions: versions}),
    do: for(v <- versions, f <- v.fields, do: f.type)

  # ---- the frame -------------------------------------------------------------

  defp frame(title, current, ctx, body) do
    nav =
      Enum.map_join(ctx.namespaces, "", fn namespace ->
        current? = namespace == current

        ~s(<li><a href="#{page_of(namespace)}"#{if current?, do: ~s( aria-current="page"), else: ""}>) <>
          escape(label_of(namespace)) <> "</a></li>"
      end)

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
    </head>
    <body>
    <header class="site">
      <div class="site-inner">
        <a class="brand" href="index.html"><span class="brand-mark" aria-hidden="true">%{}</span>#{escape(ctx.title)}</a>
        <nav aria-label="Namespaces"><ul>#{nav}</ul></nav>
      </div>
    </header>
    <main>
    #{body}
    </main>
    <footer class="site-foot"><p>Generated from the <code>.dxns</code> sources by Dextrin. Positions are the order of a struct's fields in its binary form.</p></footer>
    </body>
    </html>
    """
  end

  # ---- the index ---------------------------------------------------------------

  defp index(namespaces, ctx) do
    rows =
      Enum.map_join(namespaces, "", fn {namespace, defs} ->
        public = Enum.filter(defs, &is_nil(&1.internal_to))
        note = defs |> Enum.find_value(& &1.namespace_note) |> first_paragraph()

        """
        <li class="ns-card">
          <h3><a href="#{page_of(namespace)}">#{escape(label_of(namespace))}</a></h3>
          <p class="counts">#{counts(public)}</p>
          #{if note, do: Markdown.to_html(note, fn _ -> nil end), else: ""}
        </li>
        """
      end)

    all =
      namespaces
      |> Enum.flat_map(&elem(&1, 1))
      |> Enum.filter(&is_nil(&1.internal_to))
      |> Enum.sort_by(&String.downcase(&1.short))
      |> Enum.map_join("", fn d ->
        ~s(<li><a href="#{href(d)}"><code>#{escape(d.short)}</code></a> ) <>
          kind_chip(d) <> ~s(<span class="ns">#{escape(label_of(d.namespace))}</span></li>)
      end)

    frame(ctx.title, nil, ctx, """
    <div class="page">
      <section class="intro">
        <p class="eyebrow">Schema reference</p>
        <h1>#{escape(ctx.title)}</h1>
        <p class="lede">Every struct schema, shape and named type, by namespace. A name links to its definition wherever it appears.</p>
      </section>
      <section aria-labelledby="ns-heading">
        <h2 id="ns-heading">Namespaces</h2>
        <ul class="ns-list">#{rows}</ul>
      </section>
      <section aria-labelledby="az-heading">
        <h2 id="az-heading">All definitions</h2>
        <ul class="az">#{all}</ul>
      </section>
    </div>
    """)
  end

  defp counts(defs) do
    by_kind = Enum.frequencies_by(defs, & &1.kind)

    [{:schema, "schema", "schemas"}, {:shape, "shape", "shapes"}, {:type, "type", "types"}]
    |> Enum.flat_map(fn {kind, one, many} ->
      case Map.get(by_kind, kind, 0) do
        0 -> []
        1 -> ["1 #{one}"]
        n -> ["#{n} #{many}"]
      end
    end)
    |> Enum.join(" · ")
  end

  defp first_paragraph(nil), do: nil
  defp first_paragraph(""), do: nil
  defp first_paragraph(text), do: text |> String.split(~r/\n\s*\n/) |> hd()

  # ---- a namespace's page ------------------------------------------------------

  defp namespace_page(namespace, defs, ctx) do
    public =
      defs |> Enum.filter(&is_nil(&1.internal_to)) |> Enum.sort_by(&String.downcase(&1.short))

    internal = Enum.group_by(Enum.reject(defs, &is_nil(&1.internal_to)), & &1.internal_to)

    toc =
      Enum.map_join(public, "", fn d ->
        inner =
          internal
          |> Map.get(d.name, [])
          |> Enum.sort_by(&String.downcase(&1.short))
          |> Enum.map_join("", &~s(<li><a href="##{anchor(&1)}">#{escape(&1.short)}</a></li>))

        ~s(<li><a href="##{anchor(d)}">#{escape(d.short)}</a>) <>
          if(inner == "", do: "", else: ~s(<ul>#{inner}</ul>)) <> "</li>"
      end)

    note = Enum.find_value(defs, & &1.namespace_note)

    body =
      Enum.map_join(public, "", fn d ->
        definition(d, ctx) <>
          (internal
           |> Map.get(d.name, [])
           |> Enum.sort_by(&String.downcase(&1.short))
           |> Enum.map_join("", &definition(&1, ctx)))
      end)

    frame("#{label_of(namespace)} · #{ctx.title}", namespace, ctx, """
    <div class="page with-toc">
      <aside class="toc" aria-label="On this page">
        <p class="toc-title">On this page</p>
        <ul>#{toc}</ul>
      </aside>
      <div class="content">
        <section class="intro">
          <p class="eyebrow">Namespace</p>
          <h1><code>#{escape(label_of(namespace))}</code></h1>
          #{if note && note != "", do: ~s(<div class="prose">) <> Markdown.to_html(note, linker(%{scope: %{}}, ctx)) <> "</div>", else: ""}
        </section>
        #{body}
      </div>
    </div>
    """)
  end

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

    .site { background: var(--surface); border-bottom: 1px solid var(--rule); }
    .site-inner, main, .site-foot {
      max-width: 72rem; margin: 0 auto;
      padding-left: max(16px, env(safe-area-inset-left, 0px));
      padding-right: max(16px, env(safe-area-inset-right, 0px));
    }
    .site-inner { display: flex; flex-wrap: wrap; align-items: center; gap: 0.5rem 2rem; padding-block: 0.75rem; }
    .brand { display: inline-flex; align-items: center; gap: 0.6rem; font-weight: 700; color: var(--ink); text-decoration: none; }
    .brand-mark { font-family: var(--font-code); font-size: 0.85rem; color: var(--accent); background: var(--accent-soft); border-radius: 6px; padding: 0.15rem 0.4rem; }
    .site nav ul { display: flex; flex-wrap: wrap; gap: 0.25rem 1rem; list-style: none; margin: 0; padding: 0; }
    .site nav a { font-family: var(--font-code); font-size: var(--step--1); color: var(--muted); text-decoration: none; }
    .site nav a[aria-current="page"], .site nav a:hover { color: var(--accent); }

    main { padding-block: 2rem 3rem; }
    .page { display: grid; gap: 2.5rem; }
    .page.with-toc { grid-template-columns: minmax(0, 13rem) minmax(0, 1fr); align-items: start; }
    .content { display: grid; gap: 1.5rem; min-width: 0; }
    .eyebrow { margin: 0 0 0.35rem; font-size: var(--step--1); letter-spacing: 0.08em; text-transform: uppercase; color: var(--muted); }
    h1 { font-size: var(--step-3); }
    h1 code { font-size: 0.85em; }
    .lede { color: var(--muted); max-width: 40rem; margin: 0.75rem 0 0; }
    .intro .prose { margin-top: 1rem; }
    section > h2 { font-size: var(--step-1); margin-bottom: 1rem; }

    .toc { position: sticky; top: 1rem; font-size: var(--step--1); }
    .toc-title { margin: 0 0 0.5rem; text-transform: uppercase; letter-spacing: 0.08em; color: var(--muted); }
    .toc ul { list-style: none; margin: 0; padding: 0; display: grid; gap: 0.2rem; }
    .toc ul ul { padding-left: 0.9rem; margin-top: 0.2rem; border-left: 1px solid var(--rule); }
    .toc a { font-family: var(--font-code); color: var(--ink); text-decoration: none; }
    .toc a:hover { color: var(--accent); }

    .ns-list { list-style: none; margin: 0; padding: 0; display: grid; gap: 1rem; grid-template-columns: repeat(auto-fill, minmax(min(100%, 19rem), 1fr)); }
    .ns-card { background: var(--surface); border: 1px solid var(--rule); border-radius: 10px; padding: 1rem 1.1rem; min-width: 0; }
    .ns-card h3 { font-family: var(--font-code); font-size: var(--step-0); }
    .ns-card h3 a { text-decoration: none; }
    .ns-card p { margin: 0.4rem 0 0; color: var(--muted); font-size: 0.95rem; }
    .ns-card .counts { font-size: var(--step--1); }
    .az { list-style: none; margin: 0; padding: 0; columns: 18rem auto; column-gap: 2rem; }
    .az li { break-inside: avoid; display: flex; flex-wrap: wrap; align-items: baseline; gap: 0.4rem; padding: 0.2rem 0; }
    .az .ns { font-family: var(--font-code); font-size: var(--step--1); color: var(--muted); }

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

    .site-foot { padding-block: 1.5rem 2.5rem; color: var(--muted); font-size: var(--step--1); border-top: 1px solid var(--rule); }

    @media (max-width: 52rem) {
      .page.with-toc { grid-template-columns: minmax(0, 1fr); }
      .toc { position: static; }
      .toc > ul { display: flex; flex-wrap: wrap; gap: 0.3rem 1rem; }
      .toc ul ul { display: none; }
      .def { padding: 1rem; }
    }
    @media (prefers-reduced-motion: reduce) { * { scroll-behavior: auto; } }
    """
  end
end
