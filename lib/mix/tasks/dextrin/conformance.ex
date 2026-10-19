defmodule Mix.Tasks.Dextrin.Conformance do
  @moduledoc """
      $ mix dextrin.conformance REQUEST ANSWER

  This implementation's adapter for the Dextrin Conformance Suite: reads
  the JSON request at `REQUEST`, answers every case
  (`Dextrin.Conformance`), and writes the JSON answer to `ANSWER`.

  Exits non-zero only when the adapter itself cannot work — no request
  file, a request that is not JSON — never because a case failed: a
  failed case is an answer, and the suite judges it.
  """

  use Mix.Task

  @shortdoc "Answers a Dextrin Conformance Suite request"

  @impl Mix.Task
  def run(argv) do
    case argv do
      [request, answer] -> respond(request, answer)
      _ -> Mix.raise("usage: mix dextrin.conformance REQUEST ANSWER")
    end
  end

  defp respond(request, answer) do
    Mix.Task.run("app.config")

    response =
      request
      |> File.read!()
      |> JSON.decode!()
      |> Dextrin.Conformance.answer()

    File.write!(answer, JSON.encode!(response))
  end
end
