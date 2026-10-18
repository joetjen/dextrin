[
  # Dextrin.decode/2 passes on a Dextrin.Error that one of its own
  # actions returned (a map key DXN.md §1.6 does not allow, with its
  # key/not-allowed category). Ichor passes an action's error through
  # unchanged at run time, but the generated parser's typespec admits
  # only Ichor.Error, so dialyzer calls this clause unreachable. The fix
  # is an optional data field on Ichor.Error, which Dextrin would fill
  # with its own error; it lands with the Ichor release in phase C of
  # design/implementation-plan.md, and this entry goes with it.
  {"lib/dextrin.ex", :pattern_match, {82, 16}}
]
