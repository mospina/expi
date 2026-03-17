import Config

# Production environment configuration
config :expi_ai,
  # Higher timeouts for production reliability
  http_timeout: 120_000,
  http_recv_timeout: 120_000,
  
  # More conservative retry settings
  max_retries: 5,
  base_retry_delay: 2000,
  max_retry_delay: 60_000,
  
  # Production logging
  log_level: :info