defmodule SymphonyElixir.Runtime.Profile do
  @moduledoc """
  Resolved runtime profile with its adapter module.

  Combines a `RuntimeProfile` config struct with the concrete adapter
  module that implements `Runtime.Adapter`.
  """

  alias SymphonyElixir.Config.Schema.RuntimeProfile

  @type t :: %__MODULE__{
          config: RuntimeProfile.t(),
          adapter_module: module()
        }

  defstruct [:config, :adapter_module]

  @spec new(RuntimeProfile.t(), module()) :: t()
  def new(%RuntimeProfile{} = config, adapter_module) when is_atom(adapter_module) do
    %__MODULE__{config: config, adapter_module: adapter_module}
  end
end
