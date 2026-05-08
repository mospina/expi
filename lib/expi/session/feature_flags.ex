defmodule Expi.Session.FeatureFlags do
  @moduledoc """
  Feature flags for staged rollout of Session extensibility capabilities.
  """

  @type t :: %__MODULE__{
          enable_resources: boolean(),
          enable_extensions: boolean(),
          compatibility_mode: boolean()
        }

  defstruct enable_resources: false,
            enable_extensions: false,
            compatibility_mode: true

  @spec from_options(map()) :: t()
  def from_options(options) do
    default = %__MODULE__{}

    %__MODULE__{
      enable_resources: Map.get(options, :enable_resources, default.enable_resources),
      enable_extensions: Map.get(options, :enable_extensions, default.enable_extensions),
      compatibility_mode: Map.get(options, :compatibility_mode, default.compatibility_mode)
    }
  end
end
