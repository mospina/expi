import Config

# Production environment configuration
config :expi,
  # Higher timeouts for production reliability
  http_timeout: 120_000,
  http_recv_timeout: 120_000,
  
  # More conservative retry settings
  max_retries: 5,
  base_retry_delay: 2000,
  max_retry_delay: 60_000,
  
  # Production logging
  log_level: :info,
  
  # Production API endpoints
  anthropic_base_url: "https://api.anthropic.com",
  google_base_url: "https://generativelanguage.googleapis.com",
  ollama_endpoint: "http://localhost:11434",
  
  # Connection pooling configuration
  http_pools: [
    ai_pool: [
      timeout: 30_000,
      max_connections: 100,
      pool_size: 50
    ],
    ai_stream_pool: [
      timeout: :infinity,
      max_connections: 50, 
      pool_size: 25
    ]
  ]

# Configure HTTPoison with enhanced production settings
config :httpoison,
  timeout: 30_000,
  recv_timeout: 120_000,
  follow_redirect: true,
  max_redirect: 3

# Configure Hackney connection pools for production load
config :hackney,
  pool_timeout: 30_000,
  max_connections: 100,
  pool_size: 50

# Enhanced SSL configuration for production security
config :ssl,
  verify: :verify_peer,
  depth: 3,
  verify_fun: {&:ssl_verify_hostname.verify_fun/3, []},
  customize_hostname_check: [
    match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
  ]

# Telemetry configuration for monitoring and observability
config :telemetry_poller, 
  measurements: [
    {ExpiAi.Telemetry, :collect_http_metrics, []},
    {ExpiAi.Telemetry, :collect_token_metrics, []},
    {ExpiAi.Telemetry, :collect_cost_metrics, []}
  ],
  period: 30_000