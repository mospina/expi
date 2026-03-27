# ExpiAI Migration Guide

This guide helps you migrate from development/testing to production, upgrade between versions, and transition from other AI libraries.

## Table of Contents

1. [Development to Production Migration](#development-to-production-migration)
2. [API Key Management](#api-key-management)
3. [Configuration Changes](#configuration-changes)
4. [Performance Optimization](#performance-optimization)
5. [Monitoring Setup](#monitoring-setup)
6. [Version Upgrades](#version-upgrades)
7. [Migrating from Other Libraries](#migrating-from-other-libraries)

## Development to Production Migration

### Pre-Migration Checklist

Before deploying to production, ensure you have:

- [ ] **API Keys**: Valid API keys for all providers you plan to use
- [ ] **Rate Limits**: Understanding of provider rate limits and quotas
- [ ] **Cost Budgets**: Monitoring and alerting for AI costs
- [ ] **Error Handling**: Robust error handling for all failure scenarios
- [ ] **Connection Pooling**: Optimized connection pool settings
- [ ] **SSL Configuration**: Proper SSL/TLS verification enabled
- [ ] **Monitoring**: Telemetry and logging setup
- [ ] **Load Testing**: Performance testing under expected load

### Step 1: Replace Stub Implementations

In development, ExpiAI uses stub implementations for testing. For production:

```elixir
# Development (automatic stub detection)
config :expi,
  use_stubs: true  # This is set automatically in test environment

# Production (real implementations)
config :expi,
  use_stubs: false,  # Explicitly disable stubs
  
  # Connection pooling
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
```

### Step 2: Environment Variable Setup

Create a production environment file:

```bash
# .env.production
ANTHROPIC_API_KEY="sk-ant-api03-..."
GOOGLE_API_KEY="AIza..."
OLLAMA_ENDPOINT="http://ollama-server:11434"

# Optional: Custom endpoints
ANTHROPIC_BASE_URL="https://api.anthropic.com"
GOOGLE_BASE_URL="https://generativelanguage.googleapis.com"

# Connection settings
HTTP_MAX_CONNECTIONS="200"
HTTP_POOL_SIZE="100"
HTTP_TIMEOUT="30000"
HTTP_RECV_TIMEOUT="120000"

# Monitoring
TELEMETRY_ENABLED="true"
LOG_LEVEL="info"
```

### Step 3: Update Configuration

```elixir
# config/prod.exs
import Config

config :expi,
  log_level: :info,
  
  # Production timeouts
  http_timeout: 120_000,
  http_recv_timeout: 120_000,
  
  # Retry configuration
  max_retries: 5,
  base_retry_delay: 2000,
  max_retry_delay: 60_000,
  
  # Connection pooling
  http_pools: [
    ai_pool: [
      timeout: 30_000,
      max_connections: String.to_integer(System.get_env("HTTP_MAX_CONNECTIONS", "100")),
      pool_size: String.to_integer(System.get_env("HTTP_POOL_SIZE", "50"))
    ],
    ai_stream_pool: [
      timeout: :infinity,
      max_connections: 50,
      pool_size: 25
    ]
  ]

# Enhanced SSL configuration
config :ssl,
  verify: :verify_peer,
  depth: 3,
  verify_fun: {&:ssl_verify_hostname.verify_fun/3, []},
  customize_hostname_check: [
    match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
  ]
```

### Step 4: Runtime Configuration

```elixir
# config/runtime.exs
import Config

if config_env() == :prod do
  # Load API keys from environment
  api_keys = %{
    anthropic: System.get_env("ANTHROPIC_API_KEY"),
    google: System.get_env("GOOGLE_API_KEY"),
    ollama: System.get_env("OLLAMA_API_KEY")
  }
  |> Enum.filter(fn {_k, v} -> not is_nil(v) and v != "" end)
  |> Enum.into(%{})

  config :expi,
    api_keys: api_keys,
    
    # Provider endpoints
    anthropic_base_url: System.get_env("ANTHROPIC_BASE_URL", "https://api.anthropic.com"),
    google_base_url: System.get_env("GOOGLE_BASE_URL", "https://generativelanguage.googleapis.com"),
    ollama_endpoint: System.get_env("OLLAMA_ENDPOINT", "http://localhost:11434"),
    
    # Performance tuning
    max_connections: String.to_integer(System.get_env("HTTP_MAX_CONNECTIONS", "100")),
    pool_size: String.to_integer(System.get_env("HTTP_POOL_SIZE", "50"))

  # Logging configuration
  config :logger,
    level: String.to_atom(System.get_env("LOG_LEVEL", "info"))
end
```

## API Key Management

### Secure Key Storage

**❌ Don't do this:**
```elixir
# Never hardcode API keys
config :expi,
  api_keys: %{
    anthropic: "sk-ant-api03-hardcoded-key"  # NEVER DO THIS
  }
```

**✅ Do this:**
```elixir
# Use environment variables
config :expi,
  api_keys: %{
    anthropic: System.get_env("ANTHROPIC_API_KEY"),
    google: System.get_env("GOOGLE_API_KEY")
  }
```

### Key Rotation

Set up key rotation with zero downtime:

```elixir
defmodule MyApp.KeyRotation do
  def rotate_api_key(provider, new_key) do
    # Update runtime configuration
    current_keys = Application.get_env(:expi, :api_keys, %{})
    updated_keys = Map.put(current_keys, String.to_atom(provider), new_key)
    
    Application.put_env(:expi, :api_keys, updated_keys)
    
    # Test the new key
    case test_key(provider, new_key) do
      :ok ->
        Logger.info("API key rotated successfully for #{provider}")
        {:ok, :rotated}
      
      {:error, reason} ->
        # Rollback
        Application.put_env(:expi, :api_keys, current_keys)
        Logger.error("Key rotation failed for #{provider}: #{reason}")
        {:error, :rotation_failed}
    end
  end

  defp test_key(provider, key) do
    # Test with a minimal request
    try do
      {:ok, model} = Expi.AI.get_model(provider, get_test_model(provider))
      
      context = %Expi.Types.Context{
        messages: [
          %Expi.Types.UserMessage{
            role: :user,
            content: "test",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }
      
      case Expi.AI.complete_simple(model, context) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    rescue
      error -> {:error, error}
    end
  end

  defp get_test_model("anthropic"), do: "claude-sonnet-3-6"
  defp get_test_model("google"), do: "gemini-pro"
  defp get_test_model(_), do: "default"
end
```

### Key Validation on Startup

```elixir
defmodule MyApp.Application do
  def start(_type, _args) do
    # Validate API keys before starting services
    case validate_api_keys() do
      :ok ->
        start_services()
      
      {:error, missing_keys} ->
        Logger.error("Missing API keys: #{inspect(missing_keys)}")
        System.halt(1)
    end
  end

  defp validate_api_keys do
    required_keys = Application.get_env(:my_app, :required_providers, [])
    api_keys = Application.get_env(:expi, :api_keys, %{})
    
    missing_keys = 
      required_keys
      |> Enum.filter(fn provider ->
        key = Map.get(api_keys, String.to_atom(provider))
        is_nil(key) or key == ""
      end)
    
    case missing_keys do
      [] -> :ok
      keys -> {:error, keys}
    end
  end

  defp start_services do
    children = [
      # Your application's children
      {MyApp.Supervisor, []},
      {Expi.Application, []}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

## Configuration Changes

### Connection Pool Tuning

Based on your application load:

```elixir
# Low traffic (< 100 requests/hour)
config :expi,
  http_pools: [
    ai_pool: [max_connections: 10, pool_size: 5],
    ai_stream_pool: [max_connections: 5, pool_size: 3]
  ]

# Medium traffic (100-1000 requests/hour)  
config :expi,
  http_pools: [
    ai_pool: [max_connections: 50, pool_size: 25],
    ai_stream_pool: [max_connections: 25, pool_size: 10]
  ]

# High traffic (> 1000 requests/hour)
config :expi,
  http_pools: [
    ai_pool: [max_connections: 200, pool_size: 100],
    ai_stream_pool: [max_connections: 100, pool_size: 50]
  ]
```

### Timeout Configuration

Adjust timeouts based on your use case:

```elixir
config :expi,
  # Quick responses (chat, simple queries)
  http_timeout: 30_000,        # 30 seconds
  http_recv_timeout: 60_000,   # 1 minute
  
  # Long-form content (articles, analysis)
  # http_timeout: 60_000,      # 1 minute
  # http_recv_timeout: 180_000, # 3 minutes
  
  # Complex reasoning (research, coding)
  # http_timeout: 120_000,     # 2 minutes  
  # http_recv_timeout: 300_000, # 5 minutes
```

### Retry Strategy

Configure retries for your reliability needs:

```elixir
config :expi,
  # Conservative (low cost, high reliability)
  max_retries: 3,
  base_retry_delay: 1000,
  max_retry_delay: 10_000,
  
  # Aggressive (higher cost, maximum reliability)  
  # max_retries: 5,
  # base_retry_delay: 2000,
  # max_retry_delay: 60_000,
  
  # Minimal (cost-sensitive, basic reliability)
  # max_retries: 1,
  # base_retry_delay: 500,
  # max_retry_delay: 5_000,
```

## Performance Optimization

### Database Connection Optimization

If storing AI interactions:

```elixir
defmodule MyApp.AICache do
  use Ecto.Schema
  import Ecto.Changeset
  
  schema "ai_cache" do
    field :request_hash, :string
    field :provider, :string
    field :model_id, :string  
    field :request_data, :map
    field :response_data, :map
    field :cost, :decimal
    field :tokens_used, :integer
    
    timestamps()
  end

  def changeset(cache, attrs) do
    cache
    |> cast(attrs, [:request_hash, :provider, :model_id, :request_data, :response_data, :cost, :tokens_used])
    |> validate_required([:request_hash, :provider, :model_id])
    |> unique_constraint(:request_hash)
  end
end

# Usage with caching
defmodule MyApp.CachedAI do
  alias MyApp.{Repo, AICache}
  alias Expi.AI
  
  def cached_complete(model, context, opts \\ []) do
    cache_key = generate_cache_key(model, context, opts)
    
    case Repo.get_by(AICache, request_hash: cache_key) do
      %AICache{response_data: response_data} ->
        # Cache hit
        {:ok, deserialize_response(response_data)}
      
      nil ->
        # Cache miss - make request
        case AI.complete_simple(model, context, opts) do
          {:ok, response} ->
            # Store in cache
            %AICache{}
            |> AICache.changeset(%{
              request_hash: cache_key,
              provider: model.provider,
              model_id: model.model_id,
              request_data: serialize_request(model, context, opts),
              response_data: serialize_response(response),
              cost: calculate_cost(response),
              tokens_used: response.usage.input + response.usage.output
            })
            |> Repo.insert()
            
            {:ok, response}
          
          error ->
            error
        end
    end
  end

  # ... helper functions for serialization and key generation
end
```

### Memory Management

For high-volume applications:

```elixir
defmodule MyApp.AIWorker do
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end
  
  def complete_async(worker, model, context, callback_pid) do
    GenServer.cast(worker, {:complete, model, context, callback_pid})
  end

  def init(_opts) do
    # Force garbage collection periodically
    :timer.send_interval(60_000, self(), :gc)
    {:ok, %{requests_handled: 0}}
  end

  def handle_cast({:complete, model, context, callback_pid}, state) do
    # Handle request in separate process to isolate memory
    Task.start(fn ->
      result = Expi.AI.complete_simple(model, context)
      send(callback_pid, {:ai_result, result})
    end)
    
    new_state = %{state | requests_handled: state.requests_handled + 1}
    {:noreply, new_state}
  end

  def handle_info(:gc, state) do
    # Periodic garbage collection
    :erlang.garbage_collect(self())
    
    # Restart worker if it's handled too many requests (memory leak prevention)
    if state.requests_handled > 1000 do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end
end
```

## Monitoring Setup

### Telemetry Integration

Set up comprehensive monitoring:

```elixir
defmodule MyApp.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 30_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # AI Request metrics
      counter("expi.request.stop.count", tags: [:provider, :model_id]),
      distribution("expi.request.stop.duration", 
        unit: {:native, :millisecond},
        tags: [:provider, :model_id]
      ),
      
      # Token usage
      distribution("expi.tokens.usage.total_tokens", tags: [:provider, :model_id]),
      sum("expi.cost.tracking.total_cost", tags: [:provider, :model_id]),
      
      # Error metrics
      counter("expi.request.error.count", tags: [:provider, :error_type]),
      
      # Streaming metrics
      counter("expi.stream.event.count", tags: [:provider, :event_type]),
      distribution("expi.stream.session.duration", 
        unit: {:native, :millisecond},
        tags: [:provider]
      ),
      
      # System metrics
      last_value("vm.memory.total", unit: {:byte, :megabyte}),
      last_value("vm.total_run_queue_lengths.total"),
      distribution("expi.http.pool_stats.in_use_count", tags: [:pool])
    ]
  end

  defp periodic_measurements do
    [
      {Expi.AI.Telemetry, :collect_http_metrics, []},
      {Expi.AI.Telemetry, :collect_token_metrics, []},
      {Expi.AI.Telemetry, :collect_cost_metrics, []},
      {:vm, :memory},
      {:vm, :total_run_queue_lengths}
    ]
  end
end

# Attach handlers
:telemetry.attach_many(
  "my-app-ai-metrics",
  [
    [:expi, :request, :stop],
    [:expi, :request, :error],
    [:expi, :cost, :tracking]
  ],
  &MyApp.Telemetry.handle_event/4,
  %{}
)
```

### Alerting Setup

Set up alerts for critical issues:

```elixir
defmodule MyApp.Alerting do
  require Logger

  def setup_alerts do
    :telemetry.attach_many(
      "ai-alerts",
      [
        [:expi, :request, :error],
        [:expi, :cost, :tracking]
      ],
      &handle_alert/4,
      %{}
    )
  end

  def handle_alert([:expi, :request, :error], _measurements, metadata, _config) do
    case metadata.error_type do
      :rate_limited ->
        Logger.warn("Rate limit hit for #{metadata.provider}")
        maybe_alert(:rate_limit, metadata)
      
      :missing_api_key ->
        Logger.error("Missing API key for #{metadata.provider}")
        send_critical_alert(:missing_api_key, metadata)
      
      :network_error ->
        Logger.warn("Network error for #{metadata.provider}")
        maybe_alert(:network_error, metadata)
    end
  end

  def handle_alert([:expi, :cost, :tracking], measurements, metadata, _config) do
    daily_cost = get_daily_cost()
    
    cond do
      daily_cost > 500.0 ->
        send_critical_alert(:high_cost, %{cost: daily_cost})
      
      daily_cost > 100.0 ->
        send_warning_alert(:elevated_cost, %{cost: daily_cost})
      
      true ->
        :ok
    end
  end

  defp maybe_alert(type, metadata) do
    # Implement rate limiting for alerts
    key = "alert:#{type}:#{metadata.provider}"
    
    case :ets.lookup(:alert_throttle, key) do
      [{^key, last_sent}] when System.system_time(:second) - last_sent < 300 ->
        :throttled
      
      _ ->
        :ets.insert(:alert_throttle, {key, System.system_time(:second)})
        send_warning_alert(type, metadata)
    end
  end

  defp send_critical_alert(type, metadata) do
    # Send to your alerting system (PagerDuty, Slack, etc.)
    Logger.error("CRITICAL AI ALERT: #{type} - #{inspect(metadata)}")
  end

  defp send_warning_alert(type, metadata) do
    Logger.warn("AI Warning: #{type} - #{inspect(metadata)}")
  end

  defp get_daily_cost do
    # Implement cost tracking
    0.0
  end
end
```

## Version Upgrades

### Upgrade Process

1. **Read the Changelog**: Always check `CHANGELOG.md` for breaking changes
2. **Test in Staging**: Never upgrade directly in production
3. **Backup Configuration**: Save current configs before upgrading
4. **Update Dependencies**: Use `mix deps.update expi`
5. **Run Tests**: Ensure all tests pass with new version
6. **Deploy Gradually**: Use blue-green or rolling deployments

### Version 0.1.x to 0.2.x (Example)

```elixir
# Before (0.1.x)
{:ok, response} = Expi.AI.complete_simple(model, context)
content = response.content

# After (0.2.x) - hypothetical breaking change
{:ok, response} = Expi.AI.complete_simple(model, context)
content = response.message.content
```

Create a migration module:

```elixir
defmodule MyApp.ExpiAIMigration do
  @moduledoc """
  Helper module to ease migration between ExpiAI versions.
  """
  
  def extract_content(%{content: content}), do: content  # 0.1.x format
  def extract_content(%{message: %{content: content}}), do: content  # 0.2.x format
  
  def adapt_response(response) do
    # Normalize response format across versions
    %{
      content: extract_content(response),
      usage: extract_usage(response),
      cost: extract_cost(response)
    }
  end
  
  # Add more helper functions as needed
end
```

## Migrating from Other Libraries

### From OpenAI Library

```elixir
# Before (OpenAI library)
{:ok, response} = OpenAI.completions(model: "gpt-3.5-turbo", messages: messages)
content = response["choices"] |> hd() |> get_in(["message", "content"])

# After (ExpiAI)
{:ok, model} = Expi.AI.get_model("anthropic", "claude-sonnet-3-6")
context = %Expi.Types.Context{messages: convert_messages(messages)}
{:ok, response} = Expi.AI.complete_simple(model, context)
content = extract_text_content(response.content)

defp convert_messages(openai_messages) do
  Enum.map(openai_messages, fn msg ->
    %Expi.Types.UserMessage{
      role: String.to_atom(msg["role"]),
      content: msg["content"],
      timestamp: System.system_time(:millisecond)
    }
  end)
end
```

### From Custom HTTP Clients

```elixir
# Before (custom HTTP)
defmodule MyApp.AnthropicClient do
  def complete(prompt) do
    headers = [{"Authorization", "Bearer #{api_key()}"}]
    body = Jason.encode!(%{model: "claude-3", prompt: prompt})
    
    case HTTPoison.post("https://api.anthropic.com/v1/complete", body, headers) do
      {:ok, %{body: response_body}} ->
        Jason.decode(response_body)
    end
  end
end

# After (ExpiAI)
defmodule MyApp.AnthropicClient do
  def complete(prompt) do
    {:ok, model} = Expi.AI.get_model("anthropic", "claude-sonnet-3-6")
    
    context = %Expi.Types.Context{
      messages: [
        %Expi.Types.UserMessage{
          role: :user,
          content: prompt,
          timestamp: System.system_time(:millisecond)
        }
      ]
    }
    
    Expi.AI.complete_simple(model, context)
  end
end
```

### Migration Helper Module

Create a wrapper to ease transition:

```elixir
defmodule MyApp.AIAdapter do
  @moduledoc """
  Adapter to ease migration from other AI libraries to ExpiAI.
  Provides familiar interfaces while using ExpiAI under the hood.
  """
  
  alias Expi.AI
  alias Expi.Types.{Context, UserMessage}
  
  def chat_completion(opts) do
    # OpenAI-style interface
    model_name = opts[:model] || "claude-sonnet-3-6"
    messages = opts[:messages] || []
    
    {provider, model_id} = parse_model_name(model_name)
    {:ok, model} = AI.get_model(provider, model_id)
    
    context = %Context{
      messages: convert_openai_messages(messages)
    }
    
    case AI.complete_simple(model, context) do
      {:ok, response} ->
        # Convert to OpenAI-style response
        {:ok, %{
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "content" => extract_text_content(response.content)
              },
              "finish_reason" => map_stop_reason(response.stop_reason)
            }
          ],
          "usage" => %{
            "prompt_tokens" => response.usage.input,
            "completion_tokens" => response.usage.output,
            "total_tokens" => response.usage.input + response.usage.output
          }
        }}
      
      error ->
        error
    end
  end

  defp parse_model_name("gpt-" <> _), do: {"anthropic", "claude-sonnet-3-6"}
  defp parse_model_name("claude-" <> _), do: {"anthropic", "claude-sonnet-3-6"}
  defp parse_model_name("gemini-" <> _), do: {"google", "gemini-pro"}
  defp parse_model_name(name), do: {"anthropic", name}

  defp convert_openai_messages(messages) do
    Enum.map(messages, fn msg ->
      %UserMessage{
        role: String.to_atom(msg["role"]),
        content: msg["content"],
        timestamp: System.system_time(:millisecond)
      }
    end)
  end

  defp extract_text_content(content) when is_list(content) do
    content
    |> Enum.filter(& &1.type == :text)
    |> Enum.map(& &1.text)
    |> Enum.join(" ")
  end

  defp extract_text_content(content) when is_binary(content), do: content

  defp map_stop_reason(:stop), do: "stop"
  defp map_stop_reason(:length), do: "length"
  defp map_stop_reason(:tool_use), do: "function_call"
  defp map_stop_reason(_), do: "stop"
end
```

## Migrating from AI Module to Agent Module

The Agent module provides higher-level conversation orchestration built on top of the AI module. Here's how to migrate:

### Basic AI to Agent Migration

```elixir
# Before (AI Module - Low Level)
alias Expi.AI
alias Expi.Types.{Context, UserMessage}

{:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")

# Manual conversation management
messages = []

# First interaction
context = %Context{
  system_prompt: "You are a helpful assistant",
  messages: [
    %UserMessage{
      role: :user,
      content: "Hello, who are you?",
      timestamp: System.system_time(:millisecond)
    }
  ]
}

{:ok, response1} = AI.complete_simple(model, context)
messages = context.messages ++ [response1]

# Second interaction - manually manage history
context = %Context{
  system_prompt: "You are a helpful assistant",
  messages: messages ++ [
    %UserMessage{
      role: :user,
      content: "What can you help me with?",
      timestamp: System.system_time(:millisecond)
    }
  ]
}

{:ok, response2} = AI.complete_simple(model, context)

# After (Agent Module - High Level)
alias Expi.Agent

{:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")
{:ok, agent} = Agent.create(model, %{
  system_prompt: "You are a helpful assistant"
})

# Automatic conversation management
{:ok, agent, response1} = Agent.send_message(agent, "Hello, who are you?")
{:ok, agent, response2} = Agent.send_message(agent, "What can you help me with?")

# Agent automatically maintains conversation history
messages = Agent.get_messages(agent)  # Full conversation available
```

### Tool/Function Call Migration

```elixir
# Before (AI Module - Manual Tool Handling)
tools = [
  %Expi.Types.Tool{
    type: :function,
    function: %{
      name: "get_weather",
      description: "Get weather for a location",
      parameters: %{
        type: :object,
        properties: %{location: %{type: :string}},
        required: ["location"]
      }
    }
  }
]

context = %Context{
  system_prompt: "You can check weather",
  messages: [
    %UserMessage{
      role: :user,
      content: "What's the weather in Paris?",
      timestamp: System.system_time(:millisecond)
    }
  ],
  tools: tools
}

{:ok, response} = AI.complete_simple(model, context)

# Manually handle tool calls
if length(response.tool_calls) > 0 do
  tool_results = 
    response.tool_calls
    |> Enum.map(fn tool_call ->
      case tool_call.name do
        "get_weather" ->
          args = Jason.decode!(tool_call.arguments)
          result = get_weather(args["location"])
          
          %Expi.Types.ToolResult{
            tool_call_id: tool_call.id,
            content: [
              %Expi.Types.TextContent{type: :text, text: result}
            ]
          }
      end
    end)
  
  # Continue conversation with tool results...
  follow_up_context = %Context{
    messages: context.messages ++ [response] ++ tool_results ++ [
      %UserMessage{
        role: :user,
        content: "Thanks!",
        timestamp: System.system_time(:millisecond)
      }
    ]
  }
  
  {:ok, final_response} = AI.complete_simple(model, follow_up_context)
end

# After (Agent Module - Automatic Tool Handling)
{:ok, weather_tool} = Expi.Agent.Tool.new(
  "get_weather",
  "Get weather for a location",
  %{
    type: :object,
    properties: %{location: %{type: :string}},
    required: ["location"]
  },
  "Weather Tool",
  fn _tool_call_id, params, _abort_signal, _update_callback ->
    location = params["location"]
    weather_data = get_weather(location)
    
    {:ok, %Expi.Agent.Types.AgentToolResult{
      content: [
        %Expi.Types.TextContent{type: :text, text: weather_data}
      ]
    }}
  end
)

{:ok, agent} = Agent.create(model, %{
  system_prompt: "You can check weather",
  tools: [weather_tool]
})

# Tool calls are handled automatically
{:ok, agent, response} = Agent.send_message(agent, "What's the weather in Paris?")
# Agent automatically calls tool, incorporates results, and provides final response

{:ok, agent, thanks_response} = Agent.send_message(agent, "Thanks!")
# Conversation continues naturally
```

### Streaming Migration

```elixir
# Before (AI Module - Basic Streaming)
{:ok, stream} = AI.stream_simple(model, context)

accumulated_content = ""
stream
|> Stream.each(fn event ->
  case event.type do
    :text_delta -> 
      accumulated_content = accumulated_content <> event.delta
      IO.write(event.delta)
    :done -> 
      IO.puts("\n✅ Complete")
      # Manually manage conversation state
      messages = messages ++ [%{role: :assistant, content: accumulated_content}]
    :error ->
      IO.puts("❌ Error: #{event.error.message}")
  end
end)
|> Stream.run()

# After (Agent Module - State-Managed Streaming)
{:ok, agent, response} = Agent.stream_response(agent, fn event ->
  case event.type do
    :text_delta -> 
      IO.write(event.delta)
    :tool_start ->
      IO.puts("\n🛠️ Using #{event.tool_name}")
    :tool_end ->
      IO.puts("✅ Tool completed")
    :done ->
      IO.puts("\n🎯 Agent response complete")
      # Conversation state automatically managed
    :error ->
      IO.puts("❌ Error: #{event.error}")
  end
end)

# Agent state is automatically updated with the complete conversation
```

### State Management Migration

```elixir
# Before (Manual State Management)
defmodule MyApp.ConversationState do
  defstruct [
    :model,
    :system_prompt,
    :messages,
    :tools,
    :created_at,
    :total_cost
  ]

  def new(model, system_prompt) do
    %__MODULE__{
      model: model,
      system_prompt: system_prompt,
      messages: [],
      tools: [],
      created_at: System.system_time(:millisecond),
      total_cost: 0.0
    }
  end

  def add_message(state, message) do
    %{state | messages: state.messages ++ [message]}
  end

  def add_response(state, response) do
    new_cost = state.total_cost + (response.usage.cost.input + response.usage.cost.output)
    %{state | 
      messages: state.messages ++ [response],
      total_cost: new_cost
    }
  end

  def get_context(state) do
    %Expi.Types.Context{
      system_prompt: state.system_prompt,
      messages: state.messages,
      tools: state.tools
    }
  end
end

# Usage
state = MyApp.ConversationState.new(model, "You are helpful")
user_msg = %UserMessage{role: :user, content: "Hello", timestamp: System.system_time(:millisecond)}
state = MyApp.ConversationState.add_message(state, user_msg)

context = MyApp.ConversationState.get_context(state)
{:ok, response} = AI.complete_simple(model, context)
state = MyApp.ConversationState.add_response(state, response)

# After (Agent Handles State Automatically)
{:ok, agent} = Agent.create(model, %{
  system_prompt: "You are helpful"
})

{:ok, agent, response} = Agent.send_message(agent, "Hello")

# All state management is automatic:
messages = Agent.get_messages(agent)           # Get conversation history
config = Agent.get_config(agent)              # Get agent configuration
stats = Agent.get_stats(agent)                # Get usage statistics
%{total_cost: total_cost} = stats              # Cost tracking included
```

### Error Handling Migration

```elixir
# Before (Manual Error Handling)
defmodule MyApp.ResilientAI do
  def safe_complete(model, context, max_retries \\ 3) do
    do_complete(model, context, max_retries)
  end

  defp do_complete(model, context, 0) do
    {:error, :max_retries_exceeded}
  end

  defp do_complete(model, context, retries_left) do
    case AI.complete_simple(model, context) do
      {:ok, response} ->
        {:ok, response}
      
      {:error, :rate_limited} ->
        Process.sleep(2000)
        do_complete(model, context, retries_left - 1)
      
      {:error, :network_error} ->
        Process.sleep(1000)
        do_complete(model, context, retries_left - 1)
      
      {:error, reason} ->
        {:error, reason}
    end
  end
end

# After (Agent Has Built-in Resilience)
{:ok, agent} = Agent.create(model, %{
  system_prompt: "You are helpful",
  # Agent handles retries, rate limiting, and errors automatically
})

# Simple error handling with agents
case Agent.send_message(agent, "Hello") do
  {:ok, agent, response} ->
    # Success - agent state automatically updated
    handle_response(agent, response)
  
  {:error, :rate_limited} ->
    # Agent already handled retries, this is final failure
    schedule_retry_later()
  
  {:error, :network_error} ->
    # Agent already retried network issues
    handle_network_failure()
  
  {:error, reason} ->
    handle_other_error(reason)
end
```

### Event Monitoring Migration

```elixir
# Before (Manual Telemetry)
defmodule MyApp.AITelemetry do
  def track_request(start_time, end_time, provider, cost) do
    duration = end_time - start_time
    
    :telemetry.execute(
      [:my_app, :ai, :request],
      %{duration: duration, cost: cost},
      %{provider: provider}
    )
  end
end

# Manual tracking in every AI call
start_time = System.monotonic_time(:millisecond)
{:ok, response} = AI.complete_simple(model, context)
end_time = System.monotonic_time(:millisecond)

MyApp.AITelemetry.track_request(start_time, end_time, model.provider, 
  response.usage.cost.input + response.usage.cost.output)

# After (Agent Provides Rich Events)
event_handler = fn event ->
  case event.type do
    :agent_start -> 
      Logger.info("Agent processing started")
    
    :turn_start ->
      Logger.info("Turn started with #{length(event.messages)} messages")
    
    :tool_start ->
      Logger.info("Tool #{event.tool_name} started")
    
    :tool_end ->
      Logger.info("Tool #{event.tool_name} completed in #{event.duration_ms}ms")
    
    :turn_end ->
      Logger.info("Turn completed: #{event.messages_processed} messages, $#{event.total_cost}")
    
    :agent_end ->
      Logger.info("Agent completed in #{event.duration_ms}ms")
  end
end

# Rich event monitoring with single call
{:ok, agent, turn_data} = Agent.process_turn(agent, %{
  event_callback: event_handler
})
```

### Migration Strategy

1. **Gradual Migration**: Start with new features using Agent module
2. **Wrapper Pattern**: Create adapters for existing AI module code
3. **Side-by-Side**: Run both approaches during transition
4. **Feature Parity**: Ensure Agent provides all needed functionality

```elixir
defmodule MyApp.AIWrapper do
  @doc """
  Wrapper to provide Agent-like interface while using AI module internally.
  Use during migration period.
  """
  
  def create_conversation(model, opts \\ []) do
    system_prompt = Keyword.get(opts, :system_prompt, "You are helpful")
    
    %{
      model: model,
      system_prompt: system_prompt,
      messages: [],
      tools: Keyword.get(opts, :tools, [])
    }
  end
  
  def send_message(conversation, message) do
    user_msg = %UserMessage{
      role: :user,
      content: message,
      timestamp: System.system_time(:millisecond)
    }
    
    context = %Context{
      system_prompt: conversation.system_prompt,
      messages: conversation.messages ++ [user_msg],
      tools: conversation.tools
    }
    
    case AI.complete_simple(conversation.model, context) do
      {:ok, response} ->
        updated_conversation = %{conversation |
          messages: context.messages ++ [response]
        }
        {:ok, updated_conversation, response}
      
      error ->
        error
    end
  end
end

# Migrate incrementally
# conversation = MyApp.AIWrapper.create_conversation(model)  # Old wrapper
# {:ok, agent} = Agent.create(model)                         # New agent approach
```

This migration guide provides comprehensive coverage for transitioning ExpiAI from development to production and migrating from other AI libraries, including upgrading from the low-level AI module to the high-level Agent module.