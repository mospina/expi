import Config

# Runtime configuration for ExpiAI
# This configuration is loaded at runtime, allowing for dynamic environment variable loading

if config_env() == :prod do
  # Load API keys from environment variables at runtime
  api_keys = %{
    anthropic: System.get_env("ANTHROPIC_API_KEY"),
    google: System.get_env("GOOGLE_API_KEY"),
    gemini: System.get_env("GOOGLE_API_KEY"),  # Gemini uses Google API key
    ollama: System.get_env("OLLAMA_API_KEY")   # Optional for Ollama
  }

  # Remove nil values from the map
  api_keys = 
    api_keys
    |> Enum.filter(fn {_k, v} -> not is_nil(v) and v != "" end)
    |> Enum.into(%{})

  config :expi,
    api_keys: api_keys,
    
    # Override endpoints from environment if provided
    anthropic_base_url: System.get_env("ANTHROPIC_BASE_URL", "https://api.anthropic.com"),
    google_base_url: System.get_env("GOOGLE_BASE_URL", "https://generativelanguage.googleapis.com"),
    ollama_endpoint: System.get_env("OLLAMA_ENDPOINT", "http://localhost:11434"),
    
    # Connection pool configuration from environment variables
    max_connections: String.to_integer(System.get_env("HTTP_MAX_CONNECTIONS", "100")),
    pool_size: String.to_integer(System.get_env("HTTP_POOL_SIZE", "50")),
    request_timeout: String.to_integer(System.get_env("HTTP_TIMEOUT", "30000")),
    recv_timeout: String.to_integer(System.get_env("HTTP_RECV_TIMEOUT", "120000"))

  # Configure logging level from environment
  log_level = 
    case System.get_env("LOG_LEVEL", "info") do
      "debug" -> :debug
      "info" -> :info  
      "warn" -> :warn
      "error" -> :error
      _ -> :info
    end

  config :logger, level: log_level

  # Configure telemetry from environment
  telemetry_enabled = System.get_env("TELEMETRY_ENABLED", "true") == "true"
  
  if telemetry_enabled do
    config :telemetry_poller,
      period: String.to_integer(System.get_env("TELEMETRY_PERIOD", "30000"))
  end

  # SSL configuration based on environment
  ssl_verify = System.get_env("SSL_VERIFY", "true") == "true"
  
  if ssl_verify do
    config :ssl,
      verify: :verify_peer,
      depth: String.to_integer(System.get_env("SSL_DEPTH", "3"))
  else
    # Only for development/testing - not recommended for production
    config :ssl,
      verify: :verify_none
  end
end

if config_env() == :dev do
  # Development runtime overrides
  config :expi,
    # Use local endpoints for development if specified
    ollama_endpoint: System.get_env("OLLAMA_ENDPOINT", "http://localhost:11434"),
    
    # Allow API keys to be loaded from environment in dev too
    api_keys: %{
      anthropic: System.get_env("ANTHROPIC_API_KEY"),
      google: System.get_env("GOOGLE_API_KEY"),
      gemini: System.get_env("GOOGLE_API_KEY"),
      ollama: System.get_env("OLLAMA_API_KEY")
    }
    |> Enum.filter(fn {_k, v} -> not is_nil(v) and v != "" end)
    |> Enum.into(%{})
end

if config_env() == :test do
  # Test environment - use stub implementations
  config :expi,
    api_keys: %{},  # Empty in test
    use_stubs: true
end