defmodule Dextrin.Text.Grammar do
  @moduledoc """
  Compiles `priv/grammar/dxn.aether` via Ichor's `Grammar.Native`
  backend at compile time (DESIGN.md §2's "`Grammar.Native`, not
  `Grammar.VM`" — the grammar is fixed at `dextrin`'s own compile
  time, so there's no reason to pay for the interpreted backend).

  Generates `tokenize/1`, `parse/1`, `run/1,2`, `run_sequence/2`.
  """

  use Ichor, grammar: "../../../priv/grammar/dxn.aether", actions: Dextrin.Text.Actions
end
