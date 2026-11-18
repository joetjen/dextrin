defmodule Mix.Tasks.Dextrin.FromTypespec do
  @moduledoc """
  Converts TypeSpec to DXNS (T682, design/typespec-emitter.md): runs
  TypeSpec's own compiler with the `@joetjen/dextrin-typespec` emitter,
  which writes one `.dxns` file per namespace -- per schema version in a
  versioned namespace -- in Dextrin's tree layout (DXNS.md §6).

      $ mix dextrin.from_typespec main.tsp --out schemas/

  It needs Node 22 or later, `npx`, and the emitter installed where the
  TypeSpec project is (`npm install --save-dev @typespec/compiler
  @joetjen/dextrin-typespec`). The files it writes say they are
  generated and are never edited: change the TypeSpec and run it again.

  Options:

    * `--out DIR` -- where the `.dxns` files go (default `schemas/`).
  """

  use Mix.Task

  @shortdoc "Converts TypeSpec to DXNS with the @joetjen/dextrin-typespec emitter"

  @emitter "@joetjen/dextrin-typespec"

  @impl Mix.Task
  def run(argv), do: run(argv, &System.cmd/3)

  @doc false
  # `runner` is `System.cmd/3`, or what a test puts in its place.
  def run(argv, runner) do
    {opts, files, _} = OptionParser.parse(argv, strict: [out: :string])

    main =
      case files do
        [main] -> main
        _ -> Mix.raise("usage: mix dextrin.from_typespec MAIN.tsp [--out DIR]")
      end

    out = Path.expand(opts[:out] || "schemas")
    args = command(main, out)

    case runner.("npx", args, stderr_to_stdout: true) do
      {output, 0} ->
        IO.write(output)
        Mix.shell().info("wrote #{out}")

      {output, status} ->
        Mix.raise("tsp compile failed (exit #{status}):\n#{output}")
    end
  rescue
    error in ErlangError ->
      if error.original == :enoent,
        do: Mix.raise("npx was not found: TypeSpec needs Node 22 or later, with npx on the PATH"),
        else: reraise(error, __STACKTRACE__)
  end

  @doc false
  # The npx arguments: TypeSpec's compiler, the emitter, and where it
  # writes, straight into `out` rather than a directory named after it.
  def command(main, out) do
    [
      "--no-install",
      "tsp",
      "compile",
      main,
      "--emit",
      @emitter,
      "--option",
      "#{@emitter}.emitter-output-dir=#{out}"
    ]
  end
end
