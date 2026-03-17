defmodule ExpiAi.Application do
  @moduledoc """
  OTP Application for ExpiAi AI module.
  
  Starts the supervision tree and configures the application.
  """

  use Application

  @doc """
  Starts the ExpiAi application.
  """
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    children = [
      {ExpiAi.ModelRegistry, []},
      # Future: Add HTTP connection pool supervisor here
      # Future: Add telemetry supervisor here
    ]

    opts = [strategy: :one_for_one, name: ExpiAi.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
