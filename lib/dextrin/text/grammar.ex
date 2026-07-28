defmodule Dextrin.Text.Grammar do
  @moduledoc """
  Compiles `priv/grammar/dxn.aether` via Ichor's `Grammar.Native`
  backend (`use Ichor, grammar:, actions:`) at *this module's own*
  compile time, not `Grammar.VM`'s interpreted backend — the grammar
  is fixed at `dextrin`'s own compile time (there's no scenario where
  a caller supplies a different grammar at runtime), so there's no
  reason to pay for bytecode interpretation when a compiled parser is
  available for free.

  Generates `tokenize/1`, `parse/1`, `run/1,2`, `run_sequence/2` —
  `run/2` is what `Dextrin.decode/2` calls, threading a
  `Dextrin.Registry.t()` through as the grammar's `context`.
  """

  use Ichor, grammar: "../../../priv/grammar/dxn.aether", actions: Dextrin.Text.Actions
end
