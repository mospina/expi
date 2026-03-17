import Config

# Test environment configuration
config :expi_ai,
  # Use test API keys
  anthropic_api_key: "test_anthropic_key",
  gemini_api_key: "test_gemini_key",
  ollama_base_url: "http://localhost:11434",
  
  # Fast timeouts for tests
  http_timeout: 5_000,
  http_recv_timeout: 5_000,
  
  # Disable retries in tests for faster feedback
  max_retries: 0,
  
  # Test-specific settings
  log_level: :warn