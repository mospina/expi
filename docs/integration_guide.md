# ExpiAI Integration Guide

This guide provides comprehensive integration instructions for ExpiAI with real-world examples and best practices.

## Table of Contents

1. [Installation & Setup](#installation--setup)
2. [Provider Configuration](#provider-configuration)
3. [Basic Integration Patterns](#basic-integration-patterns)
4. [Advanced Use Cases](#advanced-use-cases)
5. [Error Handling](#error-handling)
6. [Production Considerations](#production-considerations)

## Installation & Setup

### 1. Add Dependency

```elixir
# mix.exs
def deps do
  [
    {:expi_ai, "~> 0.1.0"},
    {:jason, "~> 1.4"},      # For JSON handling
    {:httpoison, "~> 2.0"},  # HTTP client
    {:telemetry, "~> 1.0"}   # Monitoring
  ]
end
```

### 2. Configure Application

```elixir
# config/config.exs
import Config

config :expi_ai,
  log_level: :info,
  http_timeout: 60_000,
  max_retries: 3,
  base_retry_delay: 1000
```

### 3. Environment Variables

```bash
# .env or production environment
export ANTHROPIC_API_KEY="sk-ant-..."
export GOOGLE_API_KEY="AI..."
export OLLAMA_ENDPOINT="http://localhost:11434"
```

### 4. Application Startup

Add to your supervision tree:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    # ... your existing children
    {ExpiAi.Application, []}
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

## Provider Configuration

### Anthropic Claude Setup

```elixir
# Obtain API key from https://console.anthropic.com/
# Set environment variable
export ANTHROPIC_API_KEY="sk-ant-api03-..."

# Test connection
alias ExpiAi.AI

{:ok, model} = AI.get_model("anthropic", "claude-opus-4-5")
# => {:ok, %ExpiAi.Types.Model{...}}
```

Available Claude models:
- `claude-opus-4-5` - Highest capability, reasoning support
- `claude-sonnet-3-6` - Balanced performance and speed

### Google Gemini Setup

```elixir
# Obtain API key from https://ai.google.dev/
# Set environment variable
export GOOGLE_API_KEY="AI..."

# Test connection  
{:ok, model} = AI.get_model("google", "gemini-pro")
# => {:ok, %ExpiAi.Types.Model{...}}
```

Available Gemini models:
- `gemini-pro` - General purpose model
- `gemini-pro-vision` - Multi-modal with image support

### Ollama Local Setup

```bash
# Install Ollama: https://ollama.ai/
# Pull models
ollama pull llama3.1:8b
ollama pull codellama:7b

# Verify service
curl http://localhost:11434/api/tags
```

```elixir
# Test local connection
{:ok, model} = AI.get_model("ollama", "llama3.1:8b") 
# => {:ok, %ExpiAi.Types.Model{...}}
```

## Basic Integration Patterns

### 1. Simple Chat Interface

```elixir
defmodule MyApp.ChatService do
  alias ExpiAi.AI
  alias ExpiAi.Types.{Context, UserMessage}

  def chat(provider, model_id, message, system_prompt \\ nil) do
    with {:ok, model} <- AI.get_model(provider, model_id),
         context <- build_context(message, system_prompt),
         {:ok, response} <- AI.complete_simple(model, context) do
      {:ok, extract_content(response)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_context(message, system_prompt) do
    %Context{
      system_prompt: system_prompt,
      messages: [
        %UserMessage{
          role: :user,
          content: message,
          timestamp: System.system_time(:millisecond)
        }
      ]
    }
  end

  defp extract_content(response) do
    case response.content do
      [%ExpiAi.Types.TextContent{text: text} | _] -> text
      [] -> ""
      text when is_binary(text) -> text
    end
  end
end

# Usage
{:ok, reply} = MyApp.ChatService.chat(
  "anthropic", 
  "claude-opus-4-5",
  "What is the meaning of life?",
  "You are a philosophical AI assistant."
)
```

### 2. Streaming Chat Interface

```elixir
defmodule MyApp.StreamingChat do
  alias ExpiAi.AI
  alias ExpiAi.Types.{Context, UserMessage}

  def stream_chat(provider, model_id, message, callback_fn) do
    with {:ok, model} <- AI.get_model(provider, model_id),
         context <- build_context(message),
         {:ok, stream} <- AI.stream_simple(model, context) do
      
      # Process stream with callback
      stream
      |> Stream.each(callback_fn)
      |> Stream.run()
      
      {:ok, :streaming_complete}
    end
  end

  defp build_context(message) do
    %Context{
      messages: [
        %UserMessage{
          role: :user,
          content: message,
          timestamp: System.system_time(:millisecond)
        }
      ]
    }
  end
end

# Usage with Phoenix LiveView
def handle_event("send_message", %{"message" => message}, socket) do
  MyApp.StreamingChat.stream_chat(
    "anthropic",
    "claude-sonnet-3-6", 
    message,
    fn event ->
      case event.type do
        :text_delta ->
          send(self(), {:stream_chunk, event.delta})
        :done ->
          send(self(), :stream_complete)
        :error ->
          send(self(), {:stream_error, event.error.message})
      end
    end
  )
  
  {:noreply, socket}
end
```

### 3. Document Analysis with Vision

```elixir
defmodule MyApp.DocumentAnalyzer do
  alias ExpiAi.AI
  alias ExpiAi.Types.{Context, UserMessage, TextContent, ImageContent}

  def analyze_document(image_data, media_type, question) do
    with {:ok, model} <- AI.get_model("google", "gemini-pro-vision"),
         context <- build_vision_context(image_data, media_type, question),
         {:ok, response} <- AI.complete_simple(model, context) do
      {:ok, extract_analysis(response)}
    end
  end

  defp build_vision_context(image_data, media_type, question) do
    %Context{
      messages: [
        %UserMessage{
          role: :user,
          content: [
            %TextContent{
              type: :text, 
              text: question
            },
            %ImageContent{
              type: :image,
              source: %{
                type: :base64,
                media_type: media_type,
                data: image_data
              }
            }
          ],
          timestamp: System.system_time(:millisecond)
        }
      ]
    }
  end

  defp extract_analysis(response) do
    response.content
    |> Enum.filter(& &1.type == :text)
    |> Enum.map(& &1.text)
    |> Enum.join(" ")
  end
end

# Usage
{:ok, analysis} = MyApp.DocumentAnalyzer.analyze_document(
  base64_image_data,
  "image/jpeg",
  "Extract all text from this document and summarize the key points."
)
```

## Advanced Use Cases

### 1. Function Calling with Tool Execution

```elixir
defmodule MyApp.AIAssistant do
  alias ExpiAi.AI
  alias ExpiAi.Types.{Context, UserMessage, Tool}

  def assist_with_tools(message) do
    tools = define_tools()
    
    with {:ok, model} <- AI.get_model("anthropic", "claude-opus-4-5"),
         context <- build_context_with_tools(message, tools),
         {:ok, response} <- AI.complete_simple(model, context) do
      
      # Execute any tool calls
      results = execute_tool_calls(response.tool_calls)
      
      {:ok, %{
        response: extract_content(response),
        tool_results: results,
        usage: response.usage
      }}
    end
  end

  defp define_tools do
    [
      %Tool{
        type: :function,
        function: %{
          name: "get_weather",
          description: "Get current weather for a location",
          parameters: %{
            type: :object,
            properties: %{
              location: %{type: :string, description: "City name"},
              unit: %{type: :string, enum: ["celsius", "fahrenheit"]}
            },
            required: ["location"]
          }
        }
      },
      %Tool{
        type: :function,
        function: %{
          name: "search_web",
          description: "Search the web for information",
          parameters: %{
            type: :object,
            properties: %{
              query: %{type: :string, description: "Search query"}
            },
            required: ["query"]
          }
        }
      }
    ]
  end

  defp build_context_with_tools(message, tools) do
    %Context{
      messages: [
        %UserMessage{
          role: :user,
          content: message,
          timestamp: System.system_time(:millisecond)
        }
      ],
      tools: tools
    }
  end

  defp execute_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn tool_call ->
      case tool_call.name do
        "get_weather" ->
          args = Jason.decode!(tool_call.arguments)
          get_weather(args["location"], args["unit"] || "celsius")
        
        "search_web" ->
          args = Jason.decode!(tool_call.arguments)
          search_web(args["query"])
        
        _ ->
          {:error, "Unknown tool: #{tool_call.name}"}
      end
    end)
  end

  defp get_weather(location, unit) do
    # Implement weather API call
    {:ok, "Weather in #{location}: 22°C, partly cloudy"}
  end

  defp search_web(query) do
    # Implement web search
    {:ok, "Search results for: #{query}"}
  end

  defp extract_content(response) do
    case response.content do
      [%ExpiAi.Types.TextContent{text: text} | _] -> text
      [] -> ""
      text when is_binary(text) -> text
    end
  end
end

# Usage
{:ok, result} = MyApp.AIAssistant.assist_with_tools(
  "What's the weather like in San Francisco and find recent news about AI?"
)

IO.puts(result.response)
# => "I'll help you get the weather and AI news..."

IO.inspect(result.tool_results)
# => [
#   {:ok, "Weather in San Francisco: 22°C, partly cloudy"},
#   {:ok, "Search results for: recent AI news"}
# ]
```

### 2. Conversation Memory Management

```elixir
defmodule MyApp.ConversationManager do
  use GenServer
  
  alias ExpiAi.AI
  alias ExpiAi.Types.{Context, UserMessage, AssistantMessage}

  # Client API
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def send_message(message, opts \\ []) do
    GenServer.call(__MODULE__, {:send_message, message, opts})
  end

  def get_conversation do
    GenServer.call(__MODULE__, :get_conversation)
  end

  def clear_conversation do
    GenServer.call(__MODULE__, :clear_conversation)
  end

  # Server Implementation

  def init(opts) do
    provider = Keyword.get(opts, :provider, "anthropic")
    model_id = Keyword.get(opts, :model_id, "claude-sonnet-3-6")
    system_prompt = Keyword.get(opts, :system_prompt)
    
    {:ok, model} = AI.get_model(provider, model_id)
    
    state = %{
      model: model,
      system_prompt: system_prompt,
      messages: [],
      total_tokens: 0,
      total_cost: 0.0
    }
    
    {:ok, state}
  end

  def handle_call({:send_message, message, opts}, _from, state) do
    user_message = %UserMessage{
      role: :user,
      content: message,
      timestamp: System.system_time(:millisecond)
    }
    
    context = %Context{
      system_prompt: state.system_prompt,
      messages: state.messages ++ [user_message],
      tools: Keyword.get(opts, :tools)
    }
    
    case AI.complete_simple(state.model, context, opts) do
      {:ok, response} ->
        assistant_message = %AssistantMessage{
          role: :assistant,
          content: response.content,
          api: response.api,
          provider: response.provider,
          model: response.model,
          usage: response.usage,
          stop_reason: response.stop_reason,
          timestamp: response.timestamp
        }
        
        new_state = %{state |
          messages: state.messages ++ [user_message, assistant_message],
          total_tokens: state.total_tokens + response.usage.input + response.usage.output,
          total_cost: state.total_cost + response.usage.cost.input + response.usage.cost.output
        }
        
        {:reply, {:ok, response}, new_state}
      
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_conversation, _from, state) do
    {:reply, %{
      messages: state.messages,
      total_tokens: state.total_tokens,
      total_cost: state.total_cost
    }, state}
  end

  def handle_call(:clear_conversation, _from, state) do
    new_state = %{state |
      messages: [],
      total_tokens: 0,
      total_cost: 0.0
    }
    {:reply, :ok, new_state}
  end
end

# Usage
{:ok, _pid} = MyApp.ConversationManager.start_link([
  provider: "anthropic",
  model_id: "claude-opus-4-5",
  system_prompt: "You are a helpful programming assistant."
])

{:ok, response1} = MyApp.ConversationManager.send_message("Explain recursion")
{:ok, response2} = MyApp.ConversationManager.send_message("Give me a Python example")

%{messages: messages, total_cost: cost} = MyApp.ConversationManager.get_conversation()
IO.puts("Conversation cost: $#{cost}")
```

## Error Handling

### Comprehensive Error Handling Pattern

```elixir
defmodule MyApp.AIService do
  alias ExpiAi.AI
  require Logger

  def safe_completion(provider, model_id, message, retries \\ 3) do
    case AI.get_model(provider, model_id) do
      {:ok, model} ->
        context = build_context(message)
        attempt_completion(model, context, retries)
      
      {:error, :unknown_provider} ->
        {:error, :invalid_provider}
      
      {:error, :model_not_found} ->
        {:error, :invalid_model}
      
      error ->
        Logger.error("Failed to get model: #{inspect(error)}")
        {:error, :model_initialization_failed}
    end
  end

  defp attempt_completion(model, context, retries) when retries > 0 do
    case AI.complete_simple(model, context) do
      {:ok, response} ->
        {:ok, response}
      
      {:error, :rate_limited} ->
        Logger.warn("Rate limited, retrying in 2s...")
        Process.sleep(2000)
        attempt_completion(model, context, retries - 1)
      
      {:error, :network_error} ->
        Logger.warn("Network error, retrying...")
        Process.sleep(1000)
        attempt_completion(model, context, retries - 1)
      
      {:error, :timeout} ->
        Logger.warn("Request timeout, retrying...")
        attempt_completion(model, context, retries - 1)
      
      {:error, :missing_api_key} ->
        Logger.error("API key missing for provider")
        {:error, :authentication_failed}
      
      {:error, reason} ->
        Logger.error("AI completion failed: #{inspect(reason)}")
        {:error, :completion_failed}
    end
  end

  defp attempt_completion(_model, _context, 0) do
    Logger.error("Max retries exceeded")
    {:error, :max_retries_exceeded}
  end

  defp build_context(message) do
    %ExpiAi.Types.Context{
      messages: [
        %ExpiAi.Types.UserMessage{
          role: :user,
          content: message,
          timestamp: System.system_time(:millisecond)
        }
      ]
    }
  end
end

# Usage with pattern matching
case MyApp.AIService.safe_completion("anthropic", "claude-opus-4-5", "Hello") do
  {:ok, response} ->
    handle_success(response)
  
  {:error, :invalid_provider} ->
    # Log error, use fallback provider
    MyApp.AIService.safe_completion("ollama", "llama3.1:8b", "Hello")
  
  {:error, :authentication_failed} ->
    # Notify admin, return cached response
    get_cached_response()
  
  {:error, :max_retries_exceeded} ->
    # Service degraded, return default response
    {:ok, "I'm sorry, I'm experiencing technical difficulties."}
  
  {:error, reason} ->
    Logger.error("Unexpected AI service error: #{inspect(reason)}")
    {:error, :service_unavailable}
end
```

## Production Considerations

### 1. Connection Pool Configuration

```elixir
# config/prod.exs
config :expi_ai,
  http_pools: [
    ai_pool: [
      timeout: 30_000,
      max_connections: 200,
      pool_size: 100
    ],
    ai_stream_pool: [
      timeout: :infinity,
      max_connections: 100,
      pool_size: 50
    ]
  ],
  
  # Retry configuration
  max_retries: 5,
  base_retry_delay: 2000,
  max_retry_delay: 60_000
```

### 2. Monitoring and Alerting

```elixir
defmodule MyApp.AIMonitor do
  require Logger

  def setup_monitoring do
    # Attach telemetry handlers
    :telemetry.attach_many(
      "ai-monitoring",
      [
        [:expi_ai, :request, :stop],
        [:expi_ai, :request, :error],
        [:expi_ai, :cost, :tracking]
      ],
      &handle_telemetry/4,
      %{}
    )
  end

  defp handle_telemetry([:expi_ai, :request, :stop], measurements, metadata, _config) do
    # Track successful requests
    :telemetry.execute([:my_app, :ai, :success], measurements, metadata)
    
    # Alert on high latency
    if measurements.duration > 30_000 do
      Logger.warn("High AI request latency", 
        duration: measurements.duration,
        provider: metadata.provider
      )
    end
  end

  defp handle_telemetry([:expi_ai, :request, :error], measurements, metadata, _config) do
    # Track errors
    :telemetry.execute([:my_app, :ai, :error], measurements, metadata)
    
    # Alert on high error rate
    Logger.error("AI request failed",
      error: metadata.error_type,
      provider: metadata.provider,
      duration: measurements.duration
    )
  end

  defp handle_telemetry([:expi_ai, :cost, :tracking], measurements, metadata, _config) do
    # Track costs
    daily_cost = get_daily_cost() + measurements.total_cost
    
    # Alert on high daily cost
    if daily_cost > 100.0 do
      Logger.warn("High daily AI cost: $#{daily_cost}")
    end
    
    store_daily_cost(daily_cost)
  end

  defp get_daily_cost do
    # Implement cost tracking storage
    0.0
  end

  defp store_daily_cost(cost) do
    # Implement cost storage
    :ok
  end
end
```

### 3. Circuit Breaker Pattern

```elixir
defmodule MyApp.AICircuitBreaker do
  use GenServer

  @failure_threshold 10
  @timeout_ms 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def call_ai(fun) when is_function(fun, 0) do
    case GenServer.call(__MODULE__, :get_state) do
      :closed ->
        # Circuit is closed, try the call
        try do
          result = fun.()
          GenServer.cast(__MODULE__, :success)
          result
        catch
          error ->
            GenServer.cast(__MODULE__, :failure)
            {:error, error}
        end
      
      :open ->
        # Circuit is open, fail fast
        {:error, :circuit_breaker_open}
      
      :half_open ->
        # Circuit is half-open, try one call
        try do
          result = fun.()
          GenServer.cast(__MODULE__, :success)
          result
        catch
          error ->
            GenServer.cast(__MODULE__, :failure)
            {:error, error}
        end
    end
  end

  # GenServer implementation...
  def init(_opts) do
    state = %{
      state: :closed,
      failure_count: 0,
      last_failure_time: nil
    }
    {:ok, state}
  end

  def handle_call(:get_state, _from, state) do
    current_state = determine_state(state)
    {:reply, current_state, %{state | state: current_state}}
  end

  def handle_cast(:success, state) do
    {:noreply, %{state | state: :closed, failure_count: 0}}
  end

  def handle_cast(:failure, state) do
    new_failure_count = state.failure_count + 1
    new_state = if new_failure_count >= @failure_threshold do
      :open
    else
      state.state
    end
    
    {:noreply, %{state | 
      failure_count: new_failure_count,
      last_failure_time: System.system_time(:millisecond),
      state: new_state
    }}
  end

  defp determine_state(state) do
    case state.state do
      :open ->
        if System.system_time(:millisecond) - state.last_failure_time > @timeout_ms do
          :half_open
        else
          :open
        end
      other ->
        other
    end
  end
end

# Usage
result = MyApp.AICircuitBreaker.call_ai(fn ->
  ExpiAi.AI.complete_simple(model, context)
end)
```

This integration guide provides a solid foundation for incorporating ExpiAI into production applications with proper error handling, monitoring, and resilience patterns.