import Config

# AI Module Configuration
config :expi,
  # Provider API Keys (set via environment variables)
  anthropic_api_key: {:system, "ANTHROPIC_API_KEY"},
  gemini_api_key: {:system, "GEMINI_API_KEY"},

  # Ollama Configuration
  ollama_base_url: {:system, "OLLAMA_BASE_URL", "http://localhost:11434"},

  # HTTP Client Configuration
  http_timeout: 60_000,
  http_recv_timeout: 60_000,
  connection_pool_size: 10,

  # Retry Configuration
  max_retries: 3,
  base_retry_delay: 1000,
  max_retry_delay: 30_000

# Import environment specific config files
import_config "#{config_env()}.exs"
