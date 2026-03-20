defmodule ExpiAi.Application do
  @moduledoc """
  OTP Application for ExpiAi AI module.
  
  Starts the supervision tree, configures connection pools, and initializes telemetry.
  """

  use Application
  require Logger

  @doc """
  Starts the ExpiAi application with production enhancements.
  """
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    # Initialize connection pools first
    :ok = setup_connection_pools()
    
    # Attach telemetry handlers
    :ok = ExpiAi.AI.Telemetry.attach_default_handlers()
    
    children = [
      {ExpiAi.ModelRegistry, []}  # Corrected to use proper module name
    ]

    opts = [strategy: :one_for_one, name: ExpiAi.Supervisor]
    
    Logger.info("Starting ExpiAi application with production configuration")
    
    Supervisor.start_link(children, opts)
  end

  @doc """
  Stops the ExpiAi application and cleans up resources.
  """
  @spec stop(term()) :: :ok
  def stop(_state) do
    # Clean up telemetry handlers
    ExpiAi.AI.Telemetry.detach_handlers()
    Logger.info("ExpiAi application stopped, resources cleaned up")
    :ok
  end

  # Private functions

  defp setup_connection_pools do
    # Get pool configurations from application config
    pool_configs = Application.get_env(:expi_ai, :http_pools, [])
    
    # Setup main HTTP pool for regular requests
    ai_pool_config = Keyword.get(pool_configs, :ai_pool, [
      timeout: 30_000,
      max_connections: 100,
      pool_size: 50
    ])

    # Setup streaming pool for Server-Sent Events
    stream_pool_config = Keyword.get(pool_configs, :ai_stream_pool, [
      timeout: :infinity,
      max_connections: 50,
      pool_size: 25
    ])

    # Start the pools
    case start_hackney_pools(ai_pool_config, stream_pool_config) do
      :ok ->
        Logger.info("HTTP connection pools initialized successfully")
        :ok
      
      {:error, reason} ->
        Logger.warning("Failed to initialize connection pools: #{inspect(reason)}")
        :ok  # Don't fail application start - pools can be started later
    end
  end

  defp start_hackney_pools(ai_config, stream_config) do
    try do
      # Start main AI pool for regular HTTP requests
      :hackney_pool.start_pool(:ai_pool, ai_config)
      
      # Start streaming pool for long-running SSE connections  
      :hackney_pool.start_pool(:ai_stream_pool, stream_config)
      
      Logger.debug("Hackney pools started", 
        ai_pool: ai_config, 
        stream_pool: stream_config
      )
      
      :ok
    rescue
      error ->
        {:error, error}
    end
  end
end
