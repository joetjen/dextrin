defmodule Dextrin.Test.Support.GenSchemaFixture do
  @moduledoc "Exercises every `Mix.Tasks.Dextrin.Gen.Schema` default-value type guess."
  defstruct nil_field: nil,
            bool_field: true,
            int_field: 0,
            float_field: 0.0,
            string_field: "",
            list_field: [],
            map_field: %{},
            other_field: {:tuple, :not, :guessable}
end
