defmodule Mix.Tasks.Dextrin.FromTypespecTest do
  @moduledoc """
  `mix dextrin.from_typespec` (T682): runs TypeSpec's compiler with the
  @joetjen/dextrin-typespec emitter through npx. The emitter itself is
  tested in node-dextrin/packages/dextrin-typespec; here only the command
  the task runs, and what it does with the answer.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Dextrin.FromTypespec

  import ExUnit.CaptureIO

  test "runs tsp compile with the emitter, writing into --out" do
    me = self()

    runner = fn cmd, args, _opts ->
      send(me, {:ran, cmd, args})
      {"", 0}
    end

    capture_io(fn -> FromTypespec.run(["main.tsp", "--out", "/tmp/out"], runner) end)

    assert_received {:ran, "npx", args}

    assert args ==
             ~w(--no-install tsp compile main.tsp --emit @joetjen/dextrin-typespec --option) ++
               ["@joetjen/dextrin-typespec.emitter-output-dir=/tmp/out"]
  end

  test "a failing compile is an error carrying TypeSpec's output" do
    runner = fn _cmd, _args, _opts -> {"main.tsp:1:1 - error something", 1} end

    assert_raise Mix.Error, ~r/error something/, fn ->
      FromTypespec.run(["main.tsp"], runner)
    end
  end

  test "it takes one TypeSpec file" do
    assert_raise Mix.Error, ~r/usage/, fn -> FromTypespec.run([], fn _, _, _ -> {"", 0} end) end
  end
end
