defmodule Dextrin.Text.Grammar do
  @moduledoc """
  Compiles `priv/grammar/dxn.aether` via Ichor's `Grammar.Native`
  backend, not `Grammar.VM`'s interpreted backend — the grammar is
  fixed at `dextrin`'s own build time (there's no scenario where a
  caller supplies a different grammar at runtime), so there's no
  reason to pay for bytecode interpretation when a compiled parser is
  available for free.

  The compiled lexer/parser itself lives in this module's own
  `Native` alias (undocumented on purpose — it's generated, not
  hand-authored) — generated ahead of time by `mix ichor.gen`, checked
  in like any other source file, rather than produced by `use Ichor`
  at *this module's own* compile time. That's a deliberate choice, not
  just a
  style preference: `use Ichor` needs `ichor` proper (the Aether
  front-end, `Grammar.Analysis`, the native codegen backend — most of
  that library) at `dextrin`'s own compile time, every time `dextrin`
  compiles; a generated `Native` module only ever calls into
  `ichor_runtime`, the small support library the generated code
  actually needs at runtime (capture dispatch, error formatting, the
  compiled Tokenizer/Parser). Generating ahead of time is what lets
  `mix.exs` mark `ichor` itself `only: :dev, runtime: false` — the bulk
  of Ichor genuinely never ships in a `dextrin` release, dev tooling
  only. This module exists so that split is invisible to every other
  caller in `dextrin`: `Dextrin.decode/2`, `Dextrin.Text.Printer`, and
  everything else still just calls `Dextrin.Text.Grammar.run/2` (or
  `tokenize/1`), exactly as if the grammar were compiled the old way.

  `priv/grammar/dxn.aether`'s own Unicode-derived identifier ranges are
  the reason `Native`'s generated source is thousands of lines despite
  the grammar itself being small — not something to read, only to
  regenerate:

      mix ichor.gen priv/grammar/dxn.aether \\
        --module Dextrin.Text.Grammar.Native \\
        --actions Dextrin.Text.Actions \\
        --out lib/dextrin/text/grammar/native.ex

  Rerun that command (`mix dextrin.gen.unicode` already reminds you to)
  any time `priv/grammar/dxn.aether` changes — there's no automatic
  staleness check between the checked-in file and its source grammar.
  """

  alias Dextrin.Text.Grammar.Native

  @doc "Tokenizes `input`. See `Native.tokenize/2`'s own doc for `context`."
  defdelegate tokenize(input, context \\ nil), to: Native

  @doc "Matches `input` against the grammar's root rule with no `Ichor.Actions` involved — a bare recognizer."
  defdelegate parse(input, context \\ nil), to: Native

  @doc """
  Matches and evaluates `input` through `Dextrin.Text.Actions` —
  what `Dextrin.decode/2` calls, threading a `Dextrin.Registry.t()`
  through as `initial_context`.
  """
  defdelegate run(input, initial_context \\ nil), to: Native

  @doc "Like `run/2`, but evaluates `input` as a sequence of top-level matches, threading context from each into the next."
  defdelegate run_sequence(input, initial_context), to: Native
end
