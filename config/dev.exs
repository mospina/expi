import Config

# Development environment configuration
config :expi,
  # Enable debug logging in development
  log_level: :debug,
  
  # Lower timeouts for faster development feedback
  http_timeout: 30_000,
  http_recv_timeout: 30_000