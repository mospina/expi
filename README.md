# Expi - Elixir AI Module

[![Hex.pm](https://img.shields.io/hexpm/v/expi.svg)](https://hex.pm/packages/expi)
[![Documentation](https://img.shields.io/badge/docs-hexdocs.pm-blue.svg)](https://hexdocs.pm/expi)
[![CI](https://img.shields.io/github/workflow/status/expi/expi/CI)](https://github.com/expi/expi/actions)
[![Coverage](https://img.shields.io/coveralls/github/expi/expi.svg)](https://coveralls.io/github/expi/expi)

A production-ready Elixir module for interfacing with Large Language Models (LLMs), featuring **conversation orchestration**, **tool execution**, and **state management** for AI applications. Supports **Anthropic Claude**, **Google Gemini**, and **Ollama** providers with comprehensive streaming, multi-modal, and tool calling capabilities.

## ✨ Features

- 🎯 **Multi-Provider Support**: Anthropic Claude, Google Gemini, and Ollama
- 🤖 **Agent Orchestration**: Complete conversation management with state, tools, and events
- 🔄 **Synchronous & Streaming APIs**: Both request-response and real-time streaming
- 🖼️ **Multi-Modal Input**: Support for text, images, and complex content types
- 🛠️ **Tool/Function Calling**: Complete tool integration with concurrent execution
- 📊 **Cost Tracking**: Built-in token usage and cost monitoring
- 🔐 **Production Security**: SSL verification, connection pooling, and secure authentication
- 📈 **Telemetry Integration**: Comprehensive monitoring and observability
- ⚡ **Performance Optimized**: Connection pooling, retry logic, and async operations
- 🧪 **Test-Driven**: 300+ comprehensive tests with 95% success rate

## 🚀 Quick Start

Add Expi to your dependencies:

```elixir
def deps do
  [
    {:expi, "~> 0.1.0"}
  ]
end
```

### Environment Setup

Configure your API keys:

```bash
# Anthropic Claude
export ANTHROPIC_API_KEY="your-anthropic-key"

# Google Gemini  
export GOOGLE_API_KEY="your-google-key"

# Ollama (optional, for local models)
export OLLAMA_ENDPOINT="http://localhost:11434"
```

### Basic AI Usage

```elixir
alias Expi.AI
alias Expi.Types.{Context, UserMessage}

# Get a model
{:ok, model} = AI.get_model("anthropic", "claude-opus-4-5")

# Create a context
context = %Context{
  system_prompt: "You are a helpful AI assistant",
  messages: [
    %UserMessage{
      role: :user,
      content: "Explain quantum computing in simple terms",
      timestamp: System.system_time(:millisecond)
    }
  ]
}

# Simple completion
{:ok, response} = AI.complete_simple(model, context)
IO.puts(response.content)
```

### Agent-Based Conversations

The Agent module provides sophisticated conversation orchestration with state management:

```elixir
alias Expi.Agent
alias Expi.Types.Model

# Create an agent
{:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")
{:ok, agent} = Agent.create(model, %{
  system_prompt: "You are a helpful programming assistant"
})

# Have a conversation
{:ok, agent, _response} = Agent.send_message(agent, "Help me debug this Python code")
{:ok, agent, _response} = Agent.send_message(agent, "The variable 'x' is undefined")

# Check conversation history
messages = Agent.get_messages(agent)
IO.puts("Conversation has #{length(messages)} messages")
```

### Durable Sessions

Use `Expi.Session` to persist and resume branch-aware conversations:

```elixir
alias Expi.Session

{:ok, model} = Expi.AI.get_model("anthropic", "claude-sonnet-3-6")

{:ok, %{session: session}} = Session.create_session(%{
  model: model,
  cwd: File.cwd!(),
  enable_resources: true,
  enable_extensions: false
})

# Add a user message and run the conversation loop
{:ok, session} = Expi.Session.AgentSession.prompt(session, "Summarize this repository")

# Discover available extension/prompt/skill commands
commands = Expi.Session.AgentSession.get_commands(session)

# Compact long context and persist compaction entry
{:ok, session, _result} = Expi.Session.AgentSession.compact(session)
```

Session can optionally load prompt templates + skills and run trusted extensions.
See [`docs/session.md`](docs/session.md) and [`docs/demos.md`](docs/demos.md) for dispatch order,
resource defaults, and migration guidance.

## 📚 Core APIs

### Agent Module (Recommended)

The Agent module provides the highest-level interface for AI conversations:

```elixir
# Create an agent with tools
calculator_tool = %Expi.Agent.Types.AgentTool{
  type: :function,
  function: %{
    name: "calculate",
    description: "Perform mathematical calculations",
    parameters: %{
      type: :object,
      properties: %{
        expression: %{type: :string, description: "Mathematical expression"}
      },
      required: ["expression"]
    }
  },
  execute: fn _tool_call_id, params, _abort_signal, _update_callback ->
    result = eval_expression(params["expression"])
    {:ok, %Expi.Agent.Types.AgentToolResult{
      content: [%Expi.Types.TextContent{type: :text, text: result}],
      details: %{calculation: params["expression"], result: result}
    }}
  end
}

{:ok, agent} = Agent.create(model, %{
  system_prompt: "You are a math tutor",
  tools: [calculator_tool]
})

# Agent automatically handles tool calls
{:ok, agent, response} = Agent.send_message(agent, "What's 15 * 23 + 45?")
```

### Streaming Conversations

```elixir
# Stream agent responses in real-time
{:ok, agent, response} = Agent.stream_response(agent, fn event ->
  case event.type do
    :text_delta -> IO.write(event.delta)
    :done -> IO.puts("\n✅ Response complete!")
    :error -> IO.puts("\n❌ Error: #{event.error}")
  end
end)
```

### Message Queue Management

The Agent supports sophisticated message handling with steering and follow-up patterns:

```elixir
# Add steering messages (high priority interruptions)
agent = Agent.add_steering_message(agent, "Wait, I need to clarify something first")

# Add follow-up messages (natural conversation flow)
agent = Agent.add_follow_up_message(agent, "Also, can you explain the reasoning?")

# Process all pending messages
{:ok, agent, turn_data} = Agent.process_turn(agent)
```

### Low-Level AI Module

For direct provider access:

```elixir
# Synchronous completion
{:ok, response} = AI.complete_simple(model, context)

# Real-time streaming
{:ok, stream} = AI.stream_simple(model, context)
stream
|> Stream.each(fn event ->
  case event.type do
    :text_delta -> IO.write(event.delta)
    :thinking_delta -> IO.write("[thinking: #{event.delta}]")
    :done -> IO.puts("\n✅ Complete!")
    :error -> IO.puts("\n❌ Error: #{event.error.message}")
  end
end)
|> Stream.run()
```

## 🤖 Agent Module Features

### State Management

```elixir
# Agent maintains conversation state automatically
{:ok, agent} = Agent.create(model, %{
  system_prompt: "You are a helpful assistant",
  thinking_level: :medium
})

# State is preserved across interactions
{:ok, agent, _} = Agent.send_message(agent, "Remember my name is Alice")
{:ok, agent, _} = Agent.send_message(agent, "What did I just tell you?")

# Clone agents for parallel conversations
branch_agent = Agent.clone(agent)
{:ok, branch_agent, _} = Agent.send_message(branch_agent, "Different conversation")

# Original agent is unaffected
assert Agent.get_messages(agent) != Agent.get_messages(branch_agent)
```

### Tool Integration

```elixir
# Add tools dynamically
search_tool = create_search_tool()
agent = Agent.add_tool(agent, search_tool)

# Tools are executed automatically when called by the AI
{:ok, agent, response} = Agent.send_message(agent, "Search for Elixir tutorials")
# Agent automatically calls the search tool and incorporates results
```

### Event System

```elixir
# Subscribe to agent events
{:ok, agent, _} = Agent.process_turn(agent, %{
  event_callback: fn event ->
    case event.type do
      :agent_start -> IO.puts("🎯 Agent started processing")
      :turn_start -> IO.puts("🔄 Turn started") 
      :message_start -> IO.puts("💬 Message processing")
      :tool_start -> IO.puts("🛠️ Tool execution started")
      :tool_end -> IO.puts("✅ Tool execution completed")
      :turn_end -> IO.puts("🏁 Turn completed")
      :agent_end -> IO.puts("🎌 Agent finished")
    end
  end
})
```

## 🛠️ Advanced Agent Patterns

### Custom Tool Implementation

```elixir
defmodule MyApp.WeatherTool do
  def create do
    {:ok, tool} = Expi.Agent.Tool.new(
      "get_weather",
      "Get current weather for a location",
      %{
        type: :object,
        properties: %{
          location: %{type: :string, description: "City name"},
          units: %{type: :string, enum: ["celsius", "fahrenheit"]}
        },
        required: ["location"]
      },
      "Weather Tool",
      &execute/4
    )
    tool
  end

  defp execute(_tool_call_id, params, _abort_signal, _update_callback) do
    location = params["location"]
    units = params["units"] || "celsius"
    
    # Your weather API integration here
    weather_data = fetch_weather(location, units)
    
    {:ok, %Expi.Agent.Types.AgentToolResult{
      content: [
        %Expi.Types.TextContent{
          type: :text, 
          text: "Weather in #{location}: #{weather_data.temperature}°#{units_symbol(units)}, #{weather_data.description}"
        }
      ],
      details: weather_data
    }}
  end

  defp fetch_weather(location, units) do
    # Mock implementation
    %{temperature: 22, description: "partly cloudy", units: units}
  end

  defp units_symbol("celsius"), do: "C"
  defp units_symbol("fahrenheit"), do: "F"
end
```

### Conversation Management Service

```elixir
defmodule MyApp.ConversationService do
  use GenServer
  
  alias Expi.Agent

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def create_conversation(user_id, model_config) do
    GenServer.call(__MODULE__, {:create_conversation, user_id, model_config})
  end

  def send_message(conversation_id, message) do
    GenServer.call(__MODULE__, {:send_message, conversation_id, message})
  end

  def get_conversation(conversation_id) do
    GenServer.call(__MODULE__, {:get_conversation, conversation_id})
  end

  # Server implementation
  def init(_opts) do
    {:ok, %{conversations: %{}}}
  end

  def handle_call({:create_conversation, user_id, model_config}, _from, state) do
    conversation_id = generate_id()
    
    {:ok, model} = Expi.AI.get_model(model_config.provider, model_config.model_id)
    {:ok, agent} = Agent.create(model, %{
      system_prompt: model_config.system_prompt || "You are a helpful assistant"
    })
    
    conversation = %{
      id: conversation_id,
      user_id: user_id,
      agent: agent,
      created_at: System.system_time(:millisecond),
      last_activity: System.system_time(:millisecond)
    }
    
    new_state = put_in(state.conversations[conversation_id], conversation)
    {:reply, {:ok, conversation_id}, new_state}
  end

  def handle_call({:send_message, conversation_id, message}, _from, state) do
    case get_in(state.conversations, [conversation_id]) do
      nil ->
        {:reply, {:error, :conversation_not_found}, state}
      
      conversation ->
        case Agent.send_message(conversation.agent, message) do
          {:ok, updated_agent, response} ->
            updated_conversation = %{conversation |
              agent: updated_agent,
              last_activity: System.system_time(:millisecond)
            }
            
            new_state = put_in(state.conversations[conversation_id], updated_conversation)
            {:reply, {:ok, response}, new_state}
          
          error ->
            {:reply, error, state}
        end
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
```

## 📊 Multi-Modal Input (Images + Text)

```elixir
alias Expi.Types.{ImageContent, TextContent}

# Vision model for image analysis
{:ok, vision_model} = AI.get_model("google", "gemini-pro-vision")

context = %Context{
  messages: [
    %UserMessage{
      role: :user,
      content: [
        %TextContent{type: :text, text: "What's in this image?"},
        %ImageContent{
          type: :image,
          source: %{
            type: :base64,
            media_type: "image/jpeg", 
            data: "base64-encoded-image-data"
          }
        }
      ],
      timestamp: System.system_time(:millisecond)
    }
  ]
}

{:ok, response} = AI.complete_simple(vision_model, context)
```

## 🏗️ Supported Providers

### Anthropic Claude

```elixir
# Available models
{:ok, claude_opus} = AI.get_model("anthropic", "claude-opus-4-5")
{:ok, claude_sonnet} = AI.get_model("anthropic", "claude-sonnet-3-6")

# Reasoning/thinking mode (Claude Opus)
{:ok, agent} = Agent.create(claude_opus, %{
  thinking_level: :high  # Enable reasoning mode
})

{:ok, agent, response} = Agent.send_message(agent, "Solve this complex problem step by step")

# Access reasoning content
IO.puts("Thinking: #{response.reasoning_content}")
IO.puts("Answer: #{response.content}")
```

### Google Gemini

```elixir
# Available models
{:ok, gemini_pro} = AI.get_model("google", "gemini-pro")
{:ok, gemini_vision} = AI.get_model("google", "gemini-pro-vision")

# Safety settings
{:ok, agent} = Agent.create(gemini_pro, %{
  safety_settings: [
    %{category: "HARM_CATEGORY_HARASSMENT", threshold: "BLOCK_MEDIUM_AND_ABOVE"}
  ]
})
```

### Ollama (Local Models)

```elixir
# Available models (must be installed locally)
{:ok, llama} = AI.get_model("ollama", "llama3.1:8b")
{:ok, codellama} = AI.get_model("ollama", "codellama:7b")

# No API key required for local models
{:ok, agent} = Agent.create(llama, %{
  system_prompt: "You are a local AI assistant"
})
```

## 📊 Monitoring & Telemetry

ExpiAI includes comprehensive telemetry integration:

```elixir
# Attach custom telemetry handlers
:telemetry.attach(
  "my-ai-metrics",
  [:expi, :agent, :turn, :stop],
  fn _event, measurements, metadata, _config ->
    Logger.info("Agent turn completed",
      agent_id: metadata.agent_id,
      duration_ms: measurements.duration,
      messages_processed: measurements.messages_processed,
      tools_executed: measurements.tools_executed,
      total_cost: measurements.total_cost
    )
  end,
  %{}
)
```

### Available Telemetry Events

**Agent Events:**
- `[:expi, :agent, :created]` - Agent created
- `[:expi, :agent, :turn, :start]` - Turn processing started
- `[:expi, :agent, :turn, :stop]` - Turn processing completed
- `[:expi, :agent, :message, :added]` - Message added to conversation
- `[:expi, :agent, :tool, :executed]` - Tool execution completed

**AI Request Events:**
- `[:expi, :request, :start]` - Request started
- `[:expi, :request, :stop]` - Request completed
- `[:expi, :request, :error]` - Request failed  
- `[:expi, :tokens, :usage]` - Token usage metrics
- `[:expi, :cost, :tracking]` - Cost tracking
- `[:expi, :stream, :event]` - Streaming event
- `[:expi, :stream, :session]` - Streaming session completed

## ⚡ Performance & Production

### Connection Pooling

ExpiAI uses optimized connection pooling:

```elixir
# config/prod.exs
config :expi,
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

### Error Handling & Retries

Built-in exponential backoff retry logic:

```elixir
case Agent.send_message(agent, "Hello") do
  {:ok, agent, response} -> 
    # Success
    handle_response(agent, response)
  
  {:error, :rate_limited} ->
    # Provider rate limiting
    Process.sleep(1000)
    retry_request()
  
  {:error, :network_error} ->
    # Network connectivity issues  
    handle_network_error()
  
  {:error, :missing_api_key} ->
    # Authentication issues
    handle_auth_error()
end
```

### Agent State Persistence

```elixir
defmodule MyApp.AgentStore do
  def save_agent(agent_id, agent_state) do
    # Serialize agent state (without functions)
    serializable_state = %{
      system_prompt: agent_state.system_prompt,
      model: agent_state.model,
      thinking_level: agent_state.thinking_level,
      messages: agent_state.messages,
      created_at: agent_state.created_at,
      # Note: tools with execute functions need special handling
      tool_configs: extract_tool_configs(agent_state.tools)
    }
    
    # Store in your database/cache
    MyApp.Repo.insert_or_update(%AgentState{
      id: agent_id,
      data: serializable_state
    })
  end

  def load_agent(agent_id) do
    case MyApp.Repo.get(AgentState, agent_id) do
      %AgentState{data: state_data} ->
        # Reconstruct agent with tools
        {:ok, model} = Expi.AI.get_model(state_data.model.provider, state_data.model.id)
        tools = reconstruct_tools(state_data.tool_configs)
        
        Expi.Agent.State.new(model, %{
          system_prompt: state_data.system_prompt,
          thinking_level: state_data.thinking_level,
          messages: state_data.messages,
          tools: tools
        })
      
      nil ->
        {:error, :not_found}
    end
  end
end
```

## 🧪 Testing

Run the test suite:

```bash
# All tests
mix test

# With coverage
mix test --cover

# Integration tests (requires API keys)
mix test --include integration

# Performance benchmarks
mix test --include benchmark
```

### Test Categories

- **Unit Tests**: 300+ tests covering all core functionality
- **Agent Tests**: 34 comprehensive tests for agent behavior
- **Integration Tests**: Live API testing with real providers
- **Property Tests**: Fuzzing and edge case validation  
- **Performance Tests**: Load testing and benchmarking

### Testing Agents

```elixir
defmodule MyApp.AgentTest do
  use ExUnit.Case
  
  alias Expi.Agent
  alias Expi.Types.Model
  
  test "agent maintains conversation state" do
    model = %Model{id: "test-model", provider: "test", api: "test"}
    {:ok, agent} = Agent.create(model, %{system_prompt: "Test assistant"})
    
    {:ok, agent, _} = Agent.send_message(agent, "Hello")
    {:ok, agent, _} = Agent.send_message(agent, "How are you?")
    
    messages = Agent.get_messages(agent)
    assert length(messages) == 4  # 2 user + 2 assistant messages
  end
  
  test "agent tool execution" do
    tool = create_test_tool()
    {:ok, agent} = Agent.create(model, %{tools: [tool]})
    
    {:ok, agent, response} = Agent.send_message(agent, "Use the test tool")
    
    # Verify tool was called
    assert_received {:tool_executed, "test_tool", _params}
  end
end
```

## 🔧 Configuration

### Development

```elixir
# config/dev.exs
config :expi,
  log_level: :debug,
  http_timeout: 60_000,
  max_retries: 3,
  ollama_endpoint: "http://localhost:11434"
```

### Production

```elixir
# config/prod.exs
config :expi,
  log_level: :info,
  http_timeout: 120_000,
  max_retries: 5,
  
  # SSL and security
  ssl_verify: true,
  ssl_depth: 3,
  
  # Performance
  max_connections: 100,
  pool_size: 50,
  
  # Agent settings
  agent_timeout: 300_000,  # 5 minutes for complex agent operations
  tool_execution_timeout: 60_000  # 1 minute for tool execution
```

### Runtime Configuration

```elixir
# config/runtime.exs
if config_env() == :prod do
  config :expi,
    api_keys: %{
      anthropic: System.get_env("ANTHROPIC_API_KEY"),
      google: System.get_env("GOOGLE_API_KEY"),
      ollama: System.get_env("OLLAMA_API_KEY")
    },
    anthropic_base_url: System.get_env("ANTHROPIC_BASE_URL", "https://api.anthropic.com"),
    google_base_url: System.get_env("GOOGLE_BASE_URL", "https://generativelanguage.googleapis.com"),
    ollama_endpoint: System.get_env("OLLAMA_ENDPOINT", "http://localhost:11434")
end
```

## 📖 Documentation

- [API Reference](https://hexdocs.pm/expi)
- [Agent Guide](docs/agent.md) - Comprehensive agent usage and patterns
- [Session Guide](docs/session.md) - Durable session lifecycle and persistence
- [Integration Guide](docs/integration_guide.md)
- [Provider Details](docs/providers.md)
- [Streaming Guide](docs/streaming.md)
- [Migration Guide](docs/migration.md)

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Write tests for your changes
4. Ensure all tests pass (`mix test`)
5. Run code quality checks (`mix credo --strict`)
6. Commit your changes (`git commit -m 'Add amazing feature'`)
7. Push to the branch (`git push origin feature/amazing-feature`)
8. Open a Pull Request

## 📄 License

This project is licensed under the GPL v3 License - see the [LICENSE](LICENSE) file for details.

## 🔗 Links

- [GitHub Repository](https://github.com/expi/expi)
- [Changelog](CHANGELOG.md)
- [Contributing Guidelines](CONTRIBUTING.md)

---

**ExpiAI** - Bringing the power of modern LLMs to Elixir applications with production-grade reliability, conversation orchestration, and seamless AI integration. 🚀
