defmodule Dextrin.Test.Support.ProviderPoint do
  @moduledoc "Stand-in for a struct defined by a library that doesn't depend on dextrin."
  defstruct [:x, :y]
end

defmodule Dextrin.Test.Support.ProviderPoint.DXN do
  @moduledoc "Stand-in for the small, optionally-compiled companion module such a library ships."
  @behaviour Dextrin.Schema.Provider

  @impl true
  def dxn_schema do
    """
    %{
      PositiveInt: {:refine :integer %{min: 1}}
      Point: %schema{
        fields: @ordered %{ x: PositiveInt, y: :integer }
      }
    }
    """
  end

  @impl true
  def dxn_schema_name, do: "Point"

  @impl true
  def dxn_struct, do: Dextrin.Test.Support.ProviderPoint

  @impl true
  def dxn_materialize(%{x: x, y: y}), do: {:ok, %Dextrin.Test.Support.ProviderPoint{x: x, y: y}}
end

defmodule Dextrin.Test.Support.ProviderPointNoMaterializer do
  @moduledoc "Same as ProviderPoint.DXN, but exercises the no-materializer default path."
  @behaviour Dextrin.Schema.Provider

  @impl true
  def dxn_schema do
    """
    %{
      Plain: %schema{
        fields: @ordered %{ a: :integer }
      }
    }
    """
  end

  @impl true
  def dxn_schema_name, do: "Plain"

  @impl true
  def dxn_struct, do: Dextrin.Test.Support.ProviderPoint
end

defmodule Dextrin.Test.Support.ProviderWithWrongName do
  @moduledoc "Exercises register_provider/2's error path: a schema_name absent from its own document."
  @behaviour Dextrin.Schema.Provider

  @impl true
  def dxn_schema do
    """
    %{
      Real: %schema{ fields: @ordered %{ a: :integer } }
    }
    """
  end

  @impl true
  def dxn_schema_name, do: "TypoedName"

  @impl true
  def dxn_struct, do: Dextrin.Test.Support.ProviderPoint
end
