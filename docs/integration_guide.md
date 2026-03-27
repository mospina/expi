# ExpiAI Integration Guide

This guide provides comprehensive integration instructions for ExpiAI with real-world examples and best practices, covering both the low-level AI module and the high-level Agent module.

## Table of Contents

1. [Installation & Setup](#installation--setup)
2. [Provider Configuration](#provider-configuration)
3. [Basic Integration Patterns](#basic-integration-patterns)
4. [Agent Integration Patterns](#agent-integration-patterns)
5. [Advanced Use Cases](#advanced-use-cases)
6. [Error Handling](#error-handling)
7. [Production Considerations](#production-considerations)

## Installation & Setup

### 1. Add Dependency

```elixir
# mix.exs
def deps do
  [
    {:expi, "~> 0.1.0"},
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

config :expi,
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
    {Expi.Application, []}
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
alias Expi.AI

{:ok, model} = AI.get_model("anthropic", "claude-opus-4-5")
# => {:ok, %Expi.Types.Model{...}}
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
# => {:ok, %Expi.Types.Model{...}}
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
# => {:ok, %Expi.Types.Model{...}}
```

## Basic Integration Patterns

### 1. Simple Chat Interface

```elixir
defmodule MyApp.ChatService do
  alias Expi.AI
  alias Expi.Types.{Context, UserMessage}

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
      [%Expi.Types.TextContent{text: text} | _] -> text
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
  alias Expi.AI
  alias Expi.Types.{Context, UserMessage}

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
  alias Expi.AI
  alias Expi.Types.{Context, UserMessage, TextContent, ImageContent}

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
  alias Expi.AI
  alias Expi.Types.{Context, UserMessage, Tool}

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
      [%Expi.Types.TextContent{text: text} | _] -> text
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
  
  alias Expi.AI
  alias Expi.Types.{Context, UserMessage, AssistantMessage}

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
  alias Expi.AI
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
    %Expi.Types.Context{
      messages: [
        %Expi.Types.UserMessage{
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
config :expi,
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
        [:expi, :request, :stop],
        [:expi, :request, :error],
        [:expi, :cost, :tracking]
      ],
      &handle_telemetry/4,
      %{}
    )
  end

  defp handle_telemetry([:expi, :request, :stop], measurements, metadata, _config) do
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

  defp handle_telemetry([:expi, :request, :error], measurements, metadata, _config) do
    # Track errors
    :telemetry.execute([:my_app, :ai, :error], measurements, metadata)
    
    # Alert on high error rate
    Logger.error("AI request failed",
      error: metadata.error_type,
      provider: metadata.provider,
      duration: measurements.duration
    )
  end

  defp handle_telemetry([:expi, :cost, :tracking], measurements, metadata, _config) do
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
  Expi.AI.complete_simple(model, context)
end)
```

## Agent Integration Patterns

The Agent module provides higher-level conversation orchestration. Here are common integration patterns:

### 1. Conversational Web Service

```elixir
defmodule MyAppWeb.ChatController do
  use MyAppWeb, :controller
  
  alias Expi.Agent
  alias Expi.AI

  def create_session(conn, %{"model" => model_config}) do
    with {:ok, model} <- AI.get_model(model_config["provider"], model_config["model_id"]),
         {:ok, agent} <- Agent.create(model, %{
           system_prompt: model_config["system_prompt"] || "You are a helpful assistant"
         }) do
      
      session_id = generate_session_id()
      store_agent(session_id, agent)
      
      json(conn, %{session_id: session_id, status: "created"})
    else
      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})
    end
  end

  def send_message(conn, %{"session_id" => session_id, "message" => message}) do
    case get_agent(session_id) do
      {:ok, agent} ->
        case Agent.send_message(agent, message) do
          {:ok, updated_agent, response} ->
            store_agent(session_id, updated_agent)
            
            json(conn, %{
              response: extract_content(response),
              session_id: session_id,
              usage: response.usage
            })
          
          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: reason})
        end
      
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Session not found"})
    end
  end

  def stream_message(conn, %{"session_id" => session_id, "message" => message}) do
    case get_agent(session_id) do
      {:ok, agent} ->
        conn = 
          conn
          |> put_resp_header("content-type", "text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> send_chunked(200)
        
        callback = fn event ->
          case event.type do
            :text_delta ->
              chunk(conn, "data: #{Jason.encode!(%{type: "text", delta: event.delta})}\n\n")
            
            :done ->
              chunk(conn, "data: #{Jason.encode!(%{type: "done"})}\n\n")
              
            :error ->
              chunk(conn, "data: #{Jason.encode!(%{type: "error", message: event.error})}\n\n")
          end
        end
        
        case Agent.stream_response(agent, callback) do
          {:ok, updated_agent, _response} ->
            store_agent(session_id, updated_agent)
            conn
          
          {:error, reason} ->
            chunk(conn, "data: #{Jason.encode!(%{type: "error", message: reason})}\n\n")
            conn
        end
      
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Session not found"})
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp store_agent(session_id, agent) do
    # Store in ETS, Redis, or your preferred session store
    :ets.insert(:agent_sessions, {session_id, agent})
  end

  defp get_agent(session_id) do
    case :ets.lookup(:agent_sessions, session_id) do
      [{^session_id, agent}] -> {:ok, agent}
      [] -> {:error, :not_found}
    end
  end

  defp extract_content(response) do
    case response.content do
      [%{text: text} | _] -> text
      [] -> ""
      text when is_binary(text) -> text
    end
  end
end
```

### 2. Phoenix LiveView Chat Interface

```elixir
defmodule MyAppWeb.ChatLive do
  use MyAppWeb, :live_view
  
  alias Expi.Agent
  alias Expi.AI

  def mount(_params, _session, socket) do
    {:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")
    {:ok, agent} = Agent.create(model, %{
      system_prompt: "You are a helpful assistant"
    })
    
    socket = assign(socket,
      agent: agent,
      messages: [],
      current_message: "",
      streaming: false,
      input_value: ""
    )
    
    {:ok, socket}
  end

  def handle_event("send_message", %{"message" => message}, socket) do
    if String.trim(message) == "" or socket.assigns.streaming do
      {:noreply, socket}
    else
      # Add user message to UI immediately
      user_message = %{role: :user, content: message, timestamp: System.system_time(:millisecond)}
      messages = socket.assigns.messages ++ [user_message]
      
      # Start streaming response
      pid = self()
      
      Task.start(fn ->
        case Agent.stream_response(socket.assigns.agent, fn event ->
          send(pid, {:stream_event, event})
        end) do
          {:ok, updated_agent, _response} ->
            send(pid, {:agent_updated, updated_agent})
          
          {:error, reason} ->
            send(pid, {:stream_error, reason})
        end
      end)
      
      socket = assign(socket,
        messages: messages,
        current_message: "",
        streaming: true,
        input_value: ""
      )
      
      {:noreply, socket}
    end
  end

  def handle_info({:stream_event, event}, socket) do
    case event.type do
      :start ->
        # Start new assistant message
        assistant_message = %{
          role: :assistant, 
          content: "", 
          timestamp: System.system_time(:millisecond),
          streaming: true
        }
        messages = socket.assigns.messages ++ [assistant_message]
        {:noreply, assign(socket, messages: messages)}
      
      :text_delta ->
        # Update the last message with new content
        messages = 
          socket.assigns.messages
          |> List.update_at(-1, fn msg ->
            %{msg | content: msg.content <> event.delta}
          end)
        
        {:noreply, assign(socket, messages: messages)}
      
      :done ->
        # Mark streaming as complete
        messages = 
          socket.assigns.messages
          |> List.update_at(-1, fn msg ->
            Map.delete(msg, :streaming)
          end)
        
        socket = assign(socket,
          messages: messages,
          streaming: false
        )
        
        {:noreply, socket}
      
      :error ->
        # Handle error
        error_message = %{
          role: :assistant,
          content: "Sorry, I encountered an error: #{event.error}",
          timestamp: System.system_time(:millisecond),
          error: true
        }
        
        messages = socket.assigns.messages ++ [error_message]
        
        socket = assign(socket,
          messages: messages,
          streaming: false
        )
        
        {:noreply, socket}
      
      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:agent_updated, agent}, socket) do
    {:noreply, assign(socket, agent: agent)}
  end

  def handle_info({:stream_error, reason}, socket) do
    error_message = %{
      role: :assistant,
      content: "I'm sorry, I encountered an error: #{reason}",
      timestamp: System.system_time(:millisecond),
      error: true
    }
    
    messages = socket.assigns.messages ++ [error_message]
    
    socket = assign(socket,
      messages: messages,
      streaming: false
    )
    
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div id="chat-container" class="flex flex-col h-full">
      <div class="flex-1 overflow-y-auto p-4 space-y-4">
        <%= for message <- @messages do %>
          <div class={["message", message.role]}>
            <div class="message-content">
              <%= message.content %>
              <%= if Map.get(message, :streaming) do %>
                <span class="cursor animate-pulse">|</span>
              <% end %>
            </div>
            <div class="message-time text-sm text-gray-500">
              <%= format_timestamp(message.timestamp) %>
            </div>
          </div>
        <% end %>
      </div>
      
      <div class="border-t p-4">
        <form phx-submit="send_message" class="flex space-x-2">
          <input 
            type="text" 
            name="message" 
            value={@input_value}
            placeholder="Type your message..."
            class="flex-1 border rounded px-3 py-2"
            disabled={@streaming}
            phx-debounce="300"
          />
          <button 
            type="submit" 
            disabled={@streaming}
            class="px-4 py-2 bg-blue-500 text-white rounded disabled:bg-gray-300"
          >
            <%= if @streaming, do: "Sending...", else: "Send" %>
          </button>
        </form>
      </div>
    </div>
    """
  end

  defp format_timestamp(timestamp) do
    timestamp
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_time()
    |> Time.to_string()
  end
end
```

### 3. Multi-Agent System

```elixir
defmodule MyApp.MultiAgentService do
  use GenServer
  
  alias Expi.Agent
  alias Expi.AI

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def create_research_team(topic) do
    GenServer.call(__MODULE__, {:create_research_team, topic})
  end

  def collaborate(team_id, task) do
    GenServer.call(__MODULE__, {:collaborate, team_id, task})
  end

  def get_team_results(team_id) do
    GenServer.call(__MODULE__, {:get_results, team_id})
  end

  # Server implementation
  def init(_opts) do
    {:ok, %{teams: %{}}}
  end

  def handle_call({:create_research_team, topic}, _from, state) do
    team_id = generate_team_id()
    
    # Create specialized agents
    {:ok, researcher} = create_researcher_agent(topic)
    {:ok, analyzer} = create_analyzer_agent()
    {:ok, writer} = create_writer_agent()
    
    team = %{
      id: team_id,
      topic: topic,
      researcher: researcher,
      analyzer: analyzer,
      writer: writer,
      results: %{}
    }
    
    new_state = put_in(state.teams[team_id], team)
    {:reply, {:ok, team_id}, new_state}
  end

  def handle_call({:collaborate, team_id, task}, _from, state) do
    case get_in(state.teams, [team_id]) do
      nil ->
        {:reply, {:error, :team_not_found}, state}
      
      team ->
        # Step 1: Research
        {:ok, researcher, research_result} = Agent.send_message(
          team.researcher, 
          "Research the following task: #{task}"
        )
        
        # Step 2: Analysis
        research_summary = extract_content(research_result)
        {:ok, analyzer, analysis_result} = Agent.send_message(
          team.analyzer,
          "Analyze this research data: #{research_summary}"
        )
        
        # Step 3: Writing
        analysis_summary = extract_content(analysis_result)
        {:ok, writer, final_result} = Agent.send_message(
          team.writer,
          "Write a comprehensive report based on this analysis: #{analysis_summary}"
        )
        
        # Update team state
        updated_team = %{team |
          researcher: researcher,
          analyzer: analyzer,
          writer: writer,
          results: Map.put(team.results, task, %{
            research: research_summary,
            analysis: analysis_summary,
            final_report: extract_content(final_result),
            completed_at: System.system_time(:millisecond)
          })
        }
        
        new_state = put_in(state.teams[team_id], updated_team)
        {:reply, {:ok, extract_content(final_result)}, new_state}
    end
  end

  def handle_call({:get_results, team_id}, _from, state) do
    case get_in(state.teams, [team_id]) do
      nil -> {:reply, {:error, :team_not_found}, state}
      team -> {:reply, {:ok, team.results}, state}
    end
  end

  defp create_researcher_agent(topic) do
    {:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")
    research_tools = [create_search_tool(), create_data_collection_tool()]
    
    Agent.create(model, %{
      system_prompt: """
      You are a research specialist focusing on #{topic}. Your role is to gather 
      comprehensive information, identify key sources, and provide detailed research 
      findings. You have access to search and data collection tools.
      
      Always cite your sources and provide factual, well-researched information.
      """,
      tools: research_tools
    })
  end

  defp create_analyzer_agent do
    {:ok, model} = AI.get_model("anthropic", "claude-opus-4-5")
    analysis_tools = [create_statistical_tool(), create_pattern_analyzer()]
    
    Agent.create(model, %{
      system_prompt: """
      You are an analytical specialist. Your role is to analyze research data,
      identify patterns, draw insights, and provide structured analysis.
      You have access to statistical and pattern analysis tools.
      
      Focus on objective analysis and evidence-based conclusions.
      """,
      tools: analysis_tools,
      thinking_level: :high
    })
  end

  defp create_writer_agent do
    {:ok, model} = AI.get_model("google", "gemini-pro")
    writing_tools = [create_formatting_tool(), create_citation_tool()]
    
    Agent.create(model, %{
      system_prompt: """
      You are a technical writing specialist. Your role is to synthesize
      research and analysis into clear, comprehensive reports. You have
      access to formatting and citation tools.
      
      Write clearly, structure content logically, and ensure proper citations.
      """,
      tools: writing_tools
    })
  end

  defp generate_team_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp extract_content(response) do
    case response.content do
      [%{text: text} | _] -> text
      [] -> ""
      text when is_binary(text) -> text
    end
  end

  # Tool creation functions (implement as needed)
  defp create_search_tool, do: nil
  defp create_data_collection_tool, do: nil
  defp create_statistical_tool, do: nil
  defp create_pattern_analyzer, do: nil
  defp create_formatting_tool, do: nil
  defp create_citation_tool, do: nil
end

# Usage
{:ok, _} = MyApp.MultiAgentService.start_link([])

{:ok, team_id} = MyApp.MultiAgentService.create_research_team("renewable energy")
{:ok, report} = MyApp.MultiAgentService.collaborate(team_id, "Analyze solar panel efficiency trends")

{:ok, all_results} = MyApp.MultiAgentService.get_team_results(team_id)
```

### 4. Agent-Based Task Queue

```elixir
defmodule MyApp.AgentTaskQueue do
  use GenServer
  
  alias Expi.Agent
  alias Expi.AI

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def enqueue_task(task_type, payload, priority \\ 5) do
    GenServer.cast(__MODULE__, {:enqueue_task, task_type, payload, priority})
  end

  def get_queue_status do
    GenServer.call(__MODULE__, :get_queue_status)
  end

  # Server implementation
  def init(opts) do
    max_workers = Keyword.get(opts, :max_workers, 5)
    
    # Create worker agents
    workers = 
      1..max_workers
      |> Enum.map(fn worker_id ->
        {:ok, agent} = create_worker_agent(worker_id)
        %{id: worker_id, agent: agent, status: :idle, current_task: nil}
      end)
    
    state = %{
      workers: workers,
      task_queue: :queue.new(),
      completed_tasks: [],
      failed_tasks: []
    }
    
    # Start processing
    send(self(), :process_queue)
    
    {:ok, state}
  end

  def handle_cast({:enqueue_task, task_type, payload, priority}, state) do
    task = %{
      id: generate_task_id(),
      type: task_type,
      payload: payload,
      priority: priority,
      enqueued_at: System.system_time(:millisecond)
    }
    
    new_queue = :queue.in({priority, task}, state.task_queue)
    new_state = %{state | task_queue: new_queue}
    
    # Trigger processing
    send(self(), :process_queue)
    
    {:noreply, new_state}
  end

  def handle_call(:get_queue_status, _from, state) do
    status = %{
      queue_length: :queue.len(state.task_queue),
      workers: Enum.map(state.workers, fn worker ->
        %{id: worker.id, status: worker.status, current_task: worker.current_task}
      end),
      completed_count: length(state.completed_tasks),
      failed_count: length(state.failed_tasks)
    }
    
    {:reply, status, state}
  end

  def handle_info(:process_queue, state) do
    # Find idle worker
    case Enum.find(state.workers, fn worker -> worker.status == :idle end) do
      nil ->
        # No idle workers, try again later
        Process.send_after(self(), :process_queue, 1000)
        {:noreply, state}
      
      worker ->
        case :queue.out(state.task_queue) do
          {{:value, {_priority, task}}, new_queue} ->
            # Assign task to worker
            updated_worker = %{worker | status: :busy, current_task: task}
            updated_workers = 
              Enum.map(state.workers, fn w ->
                if w.id == worker.id, do: updated_worker, else: w
              end)
            
            new_state = %{state | workers: updated_workers, task_queue: new_queue}
            
            # Start task processing
            pid = self()
            Task.start(fn ->
              process_task(worker.agent, task, pid)
            end)
            
            # Continue processing
            send(self(), :process_queue)
            
            {:noreply, new_state}
          
          {:empty, _} ->
            # No tasks in queue
            {:noreply, state}
        end
    end
  end

  def handle_info({:task_completed, worker_id, task, result}, state) do
    # Update worker status
    updated_workers = 
      Enum.map(state.workers, fn worker ->
        if worker.id == worker_id do
          %{worker | status: :idle, current_task: nil}
        else
          worker
        end
      end)
    
    # Record completion
    completed_task = %{
      task: task,
      result: result,
      completed_at: System.system_time(:millisecond)
    }
    
    new_state = %{state |
      workers: updated_workers,
      completed_tasks: [completed_task | state.completed_tasks]
    }
    
    # Continue processing
    send(self(), :process_queue)
    
    {:noreply, new_state}
  end

  def handle_info({:task_failed, worker_id, task, error}, state) do
    # Update worker status
    updated_workers = 
      Enum.map(state.workers, fn worker ->
        if worker.id == worker_id do
          %{worker | status: :idle, current_task: nil}
        else
          worker
        end
      end)
    
    # Record failure
    failed_task = %{
      task: task,
      error: error,
      failed_at: System.system_time(:millisecond)
    }
    
    new_state = %{state |
      workers: updated_workers,
      failed_tasks: [failed_task | state.failed_tasks]
    }
    
    # Continue processing
    send(self(), :process_queue)
    
    {:noreply, new_state}
  end

  defp create_worker_agent(worker_id) do
    {:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")
    
    Agent.create(model, %{
      system_prompt: """
      You are Worker Agent ##{worker_id}. You process various tasks including:
      - Text analysis and summarization
      - Data processing and transformation  
      - Code generation and review
      - Research and information gathering
      
      Always provide structured, accurate results for the tasks you're assigned.
      """,
      tools: create_worker_tools()
    })
  end

  defp process_task(agent, task, callback_pid) do
    try do
      prompt = create_task_prompt(task)
      
      case Agent.send_message(agent, prompt) do
        {:ok, _updated_agent, response} ->
          result = extract_content(response)
          send(callback_pid, {:task_completed, agent.id, task, result})
        
        {:error, reason} ->
          send(callback_pid, {:task_failed, agent.id, task, reason})
      end
    rescue
      error ->
        send(callback_pid, {:task_failed, agent.id, task, Exception.message(error)})
    end
  end

  defp create_task_prompt(task) do
    case task.type do
      :summarize ->
        "Please summarize the following text:\n\n#{task.payload.text}"
      
      :analyze ->
        "Please analyze the following data and provide insights:\n\n#{task.payload.data}"
      
      :generate_code ->
        "Please generate code for the following requirements:\n\n#{task.payload.requirements}"
      
      :research ->
        "Please research and provide information about:\n\n#{task.payload.topic}"
      
      _ ->
        "Please process this task: #{inspect(task.payload)}"
    end
  end

  defp create_worker_tools do
    # Return list of tools for worker agents
    []
  end

  defp generate_task_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp extract_content(response) do
    case response.content do
      [%{text: text} | _] -> text
      [] -> ""
      text when is_binary(text) -> text
    end
  end
end

# Usage
{:ok, _} = MyApp.AgentTaskQueue.start_link(max_workers: 3)

# Enqueue various tasks
MyApp.AgentTaskQueue.enqueue_task(:summarize, %{text: "Long article text..."}, 1)
MyApp.AgentTaskQueue.enqueue_task(:analyze, %{data: "Dataset..."}, 3)
MyApp.AgentTaskQueue.enqueue_task(:research, %{topic: "Machine Learning trends"}, 2)

# Check status
%{queue_length: queue_len, workers: workers} = MyApp.AgentTaskQueue.get_queue_status()
```

This integration guide provides a solid foundation for incorporating ExpiAI into production applications with proper error handling, monitoring, and resilience patterns.