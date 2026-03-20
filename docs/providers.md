# ExpiAI Provider Guide

This guide provides detailed information about each supported AI provider, their capabilities, configuration options, and best practices.

## Table of Contents

1. [Anthropic Claude](#anthropic-claude)
2. [Google Gemini](#google-gemini)  
3. [Ollama (Local Models)](#ollama-local-models)
4. [Provider Comparison](#provider-comparison)
5. [Cost Optimization](#cost-optimization)

## Anthropic Claude

Claude is Anthropic's family of AI assistants, known for their helpful, harmless, and honest approach to AI interactions.

### Available Models

| Model ID | Name | Capabilities | Cost (Input/Output per 1M tokens) |
|----------|------|--------------|-----------------------------------|
| `claude-opus-4-5` | Claude 3.5 Opus | Highest reasoning, analysis, complex tasks | $15.00 / $75.00 |
| `claude-sonnet-3-6` | Claude 3.6 Sonnet | Balanced performance and speed | $3.00 / $15.00 |

### Authentication

```elixir
# Set your API key
export ANTHROPIC_API_KEY="sk-ant-api03-..."

# Or in runtime config
config :expi,
  api_keys: %{
    anthropic: System.get_env("ANTHROPIC_API_KEY")
  }
```

Get your API key from [Anthropic Console](https://console.anthropic.com/).

### Capabilities

#### 1. Basic Text Generation

```elixir
alias Expi.AI
alias Expi.Types.{Context, UserMessage}

{:ok, model} = AI.get_model("anthropic", "claude-opus-4-5")

context = %Context{
  system_prompt: "You are a helpful assistant that answers questions clearly and concisely.",
  messages: [
    %UserMessage{
      role: :user,
      content: "Explain quantum computing in simple terms",
      timestamp: System.system_time(:millisecond)
    }
  ]
}

{:ok, response} = AI.complete_simple(model, context)
```

#### 2. Reasoning and Thinking Mode

Claude Opus supports "thinking mode" where the model shows its reasoning process:

```elixir
# Enable thinking mode
{:ok, response} = AI.complete_simple(model, context, %{thinking: true})

# Access reasoning content  
IO.puts("Claude's thinking:")
IO.puts(response.reasoning_content)

IO.puts("\nFinal answer:")
IO.puts(response.content)
```

Example output:
```
Claude's thinking:
Let me think through this step by step...
1. The user is asking about quantum computing
2. I should explain it in simple terms
3. I'll use analogies they can understand...

Final answer:
Quantum computing is like having a computer that can explore many possible solutions simultaneously...
```

#### 3. Multi-Modal Input (Images)

```elixir
alias Expi.Types.{ImageContent, TextContent}

context = %Context{
  messages: [
    %UserMessage{
      role: :user,
      content: [
        %TextContent{
          type: :text,
          text: "What's happening in this image?"
        },
        %ImageContent{
          type: :image,
          source: %{
            type: :base64,
            media_type: "image/jpeg",
            data: base64_encoded_image
          }
        }
      ],
      timestamp: System.system_time(:millisecond)
    }
  ]
}

{:ok, response} = AI.complete_simple(model, context)
```

#### 4. Function/Tool Calling

```elixir
alias Expi.Types.Tool

tools = [
  %Tool{
    type: :function,
    function: %{
      name: "get_weather",
      description: "Get current weather for a location",
      parameters: %{
        type: :object,
        properties: %{
          location: %{type: :string, description: "City name"},
          unit: %{type: :string, enum: ["celsius", "fahrenheit"], default: "celsius"}
        },
        required: ["location"]
      }
    }
  }
]

context = %Context{
  messages: [
    %UserMessage{
      role: :user,
      content: "What's the weather like in Paris?",
      timestamp: System.system_time(:millisecond)
    }
  ],
  tools: tools
}

{:ok, response} = AI.complete_simple(model, context)

# Check for tool calls
Enum.each(response.tool_calls, fn tool_call ->
  IO.puts("Tool: #{tool_call.name}")
  IO.puts("Arguments: #{tool_call.arguments}")
end)
```

### Streaming with Claude

```elixir
{:ok, stream} = AI.stream_simple(model, context)

stream
|> Stream.each(fn event ->
  case event.type do
    :start -> IO.puts("🎯 Claude is thinking...")
    :thinking_start -> IO.puts("💭 Reasoning mode activated")
    :thinking_delta -> IO.write("[thinking: #{event.delta}]")
    :text_start -> IO.puts("\n📝 Response:")
    :text_delta -> IO.write(event.delta)
    :done -> IO.puts("\n✅ Complete")
    :error -> IO.puts("\n❌ Error: #{event.error.message}")
  end
end)
|> Stream.run()
```

### Best Practices

1. **Use Opus for Complex Analysis**: For tasks requiring deep reasoning, use `claude-opus-4-5`
2. **Use Sonnet for Speed**: For faster responses, use `claude-sonnet-3-6`
3. **Enable Thinking Mode**: For complex problems, enable thinking mode to see Claude's reasoning
4. **System Prompts**: Claude responds well to detailed system prompts that set context and expectations
5. **Error Handling**: Claude may refuse certain requests for safety reasons - handle gracefully

### Rate Limits

- **Free Tier**: 5 requests per minute
- **Pro Tier**: 1000 requests per minute
- **Team Tier**: 5000 requests per minute

Handle rate limiting:

```elixir
case AI.complete_simple(model, context) do
  {:ok, response} -> handle_response(response)
  {:error, :rate_limited} -> 
    Process.sleep(60_000)  # Wait 1 minute
    retry_request()
end
```

## Google Gemini

Google's Gemini models offer strong multi-modal capabilities and competitive performance.

### Available Models

| Model ID | Name | Capabilities | Cost (Input/Output per 1M chars) |
|----------|------|--------------|-----------------------------------|
| `gemini-pro` | Gemini 1.5 Pro | General purpose, function calling | $3.50 / $10.50 |
| `gemini-pro-vision` | Gemini Pro Vision | Multi-modal, image analysis | $3.50 / $10.50 |

### Authentication

```elixir
# Set your API key
export GOOGLE_API_KEY="AI..."

# Get API key from Google AI Studio
# https://makersuite.google.com/app/apikey
```

### Capabilities

#### 1. Text Generation

```elixir
{:ok, model} = AI.get_model("google", "gemini-pro")

context = %Context{
  system_prompt: "You are a creative writing assistant.",
  messages: [
    %UserMessage{
      role: :user,
      content: "Write a short story about a time-traveling detective",
      timestamp: System.system_time(:millisecond)
    }
  ]
}

{:ok, response} = AI.complete_simple(model, context)
```

#### 2. Vision and Image Analysis

Gemini excels at understanding and analyzing images:

```elixir
{:ok, vision_model} = AI.get_model("google", "gemini-pro-vision")

# Analyze an image
context = %Context{
  messages: [
    %UserMessage{
      role: :user,
      content: [
        %TextContent{
          type: :text,
          text: "Analyze this chart and explain the trends you see"
        },
        %ImageContent{
          type: :image,
          source: %{
            type: :base64,
            media_type: "image/png",
            data: chart_image_base64
          }
        }
      ],
      timestamp: System.system_time(:millisecond)
    }
  ]
}

{:ok, response} = AI.complete_simple(vision_model, context)
```

#### 3. Function Calling

```elixir
tools = [
  %Tool{
    type: :function,
    function: %{
      name: "search_recipes",
      description: "Search for recipes based on ingredients",
      parameters: %{
        type: :object,
        properties: %{
          ingredients: %{
            type: :array,
            items: %{type: :string},
            description: "List of available ingredients"
          },
          cuisine: %{
            type: :string,
            description: "Preferred cuisine type"
          },
          dietary_restrictions: %{
            type: :array,
            items: %{type: :string},
            description: "Any dietary restrictions"
          }
        },
        required: ["ingredients"]
      }
    }
  }
]

context = %Context{
  messages: [
    %UserMessage{
      role: :user,
      content: "I have chicken, rice, and vegetables. Suggest a healthy recipe.",
      timestamp: System.system_time(:millisecond)
    }
  ],
  tools: tools
}

{:ok, response} = AI.complete_simple(model, context)
```

#### 4. Safety Settings

Gemini provides fine-grained safety controls:

```elixir
safety_settings = [
  %{
    category: "HARM_CATEGORY_HARASSMENT",
    threshold: "BLOCK_MEDIUM_AND_ABOVE"
  },
  %{
    category: "HARM_CATEGORY_HATE_SPEECH", 
    threshold: "BLOCK_MEDIUM_AND_ABOVE"
  },
  %{
    category: "HARM_CATEGORY_SEXUALLY_EXPLICIT",
    threshold: "BLOCK_MEDIUM_AND_ABOVE"
  },
  %{
    category: "HARM_CATEGORY_DANGEROUS_CONTENT",
    threshold: "BLOCK_MEDIUM_AND_ABOVE"
  }
]

{:ok, response} = AI.complete_simple(model, context, %{
  safety_settings: safety_settings
})
```

Safety thresholds:
- `BLOCK_NONE`
- `BLOCK_LOW_AND_ABOVE`
- `BLOCK_MEDIUM_AND_ABOVE` 
- `BLOCK_HIGH_AND_ABOVE`

### Best Practices

1. **Use Vision Model for Images**: Always use `gemini-pro-vision` when working with images
2. **Safety Settings**: Configure appropriate safety settings for your use case
3. **Multi-Modal Prompts**: Combine text and images for better context understanding
4. **Function Calling**: Gemini excels at function calling - use structured tools
5. **Batch Requests**: For multiple similar requests, consider batching

### Rate Limits

- **Free Tier**: 15 requests per minute, 1500 requests per day
- **Paid Tier**: Higher limits based on usage

## Ollama (Local Models)

Ollama enables running LLMs locally, providing privacy and cost benefits.

### Installation

```bash
# Install Ollama
curl -fsSL https://ollama.ai/install.sh | sh

# Start Ollama service
ollama serve

# Pull models
ollama pull llama3.1:8b
ollama pull codellama:7b
ollama pull llama3.1:70b  # Requires significant RAM
```

### Available Models

| Model ID | Name | Size | RAM Required | Strengths |
|----------|------|------|--------------|-----------|
| `llama3.1:8b` | Llama 3.1 8B | ~4.7GB | 8GB | General purpose, fast |
| `llama3.1:70b` | Llama 3.1 70B | ~40GB | 64GB | High capability |
| `codellama:7b` | Code Llama 7B | ~3.8GB | 8GB | Code generation |

### Configuration

```elixir
# Default local endpoint
export OLLAMA_ENDPOINT="http://localhost:11434"

# Custom endpoint (if running on different host/port)
export OLLAMA_ENDPOINT="http://ollama-server:11434"
```

### Usage

```elixir
# Check available models
{:ok, model} = AI.get_model("ollama", "llama3.1:8b")

context = %Context{
  system_prompt: "You are a helpful assistant running locally.",
  messages: [
    %UserMessage{
      role: :user,
      content: "Explain the benefits of running AI models locally",
      timestamp: System.system_time(:millisecond)
    }
  ]
}

{:ok, response} = AI.complete_simple(model, context)
```

### Code Generation with CodeLlama

```elixir
{:ok, code_model} = AI.get_model("ollama", "codellama:7b")

context = %Context{
  system_prompt: "You are an expert programmer. Provide clean, well-documented code.",
  messages: [
    %UserMessage{
      role: :user,
      content: "Write a Python function to calculate fibonacci numbers with memoization",
      timestamp: System.system_time(:millisecond)
    }
  ]
}

{:ok, response} = AI.complete_simple(code_model, context)
```

### Health Checking

```elixir
# Check if Ollama is running and model is available
case AI.get_model("ollama", "llama3.1:8b") do
  {:ok, model} ->
    IO.puts("✅ Ollama is running and model is available")
  
  {:error, :connection_refused} ->
    IO.puts("❌ Ollama service is not running")
  
  {:error, :model_not_found} ->
    IO.puts("❌ Model not found. Run: ollama pull llama3.1:8b")
end
```

### Streaming with Ollama

```elixir
{:ok, stream} = AI.stream_simple(model, context)

stream
|> Stream.each(fn event ->
  case event.type do
    :text_delta -> IO.write(event.delta)
    :done -> IO.puts("\n✅ Local completion finished")
    :error -> IO.puts("\n❌ Error: #{event.error.message}")
  end
end)
|> Stream.run()
```

### Best Practices

1. **Model Selection**: Choose model size based on available RAM
2. **Local Performance**: Local models are slower but private
3. **No API Costs**: Perfect for development and high-volume use cases
4. **Model Management**: Regularly update models with `ollama pull`
5. **Resource Monitoring**: Monitor CPU/RAM usage during inference

## Provider Comparison

| Feature | Anthropic Claude | Google Gemini | Ollama |
|---------|------------------|---------------|--------|
| **Cost** | $$$ | $$ | Free |
| **Speed** | Fast | Fast | Slower |
| **Privacy** | Cloud | Cloud | Local |
| **Multi-Modal** | Yes (Images) | Yes (Images) | No |
| **Function Calling** | Yes | Yes | Limited |
| **Reasoning** | Excellent | Good | Good |
| **Code Generation** | Good | Good | Excellent |
| **Safety Features** | Built-in | Configurable | None |
| **Rate Limits** | Yes | Yes | None |
| **Offline Use** | No | No | Yes |

## Cost Optimization

### 1. Choose the Right Model

```elixir
defmodule MyApp.ModelSelector do
  def select_model(task_type, complexity) do
    case {task_type, complexity} do
      # Simple tasks - use local or cheaper models
      {:chat, :simple} -> {:ok, "ollama", "llama3.1:8b"}
      {:summarize, :simple} -> {:ok, "google", "gemini-pro"}
      
      # Complex analysis - use premium models
      {:analysis, :complex} -> {:ok, "anthropic", "claude-opus-4-5"}
      {:reasoning, :complex} -> {:ok, "anthropic", "claude-opus-4-5"}
      
      # Code tasks
      {:code, _} -> {:ok, "ollama", "codellama:7b"}
      
      # Vision tasks
      {:vision, _} -> {:ok, "google", "gemini-pro-vision"}
      
      # Default
      _ -> {:ok, "anthropic", "claude-sonnet-3-6"}
    end
  end
end

# Usage
{:ok, provider, model_id} = MyApp.ModelSelector.select_model(:chat, :simple)
{:ok, model} = AI.get_model(provider, model_id)
```

### 2. Token Management

```elixir
defmodule MyApp.TokenOptimizer do
  def optimize_context(context, max_tokens \\ 4000) do
    # Calculate current token count (approximate)
    current_tokens = estimate_tokens(context)
    
    if current_tokens > max_tokens do
      # Trim older messages
      trimmed_messages = 
        context.messages
        |> Enum.reverse()
        |> Enum.take(10)  # Keep last 10 messages
        |> Enum.reverse()
      
      %{context | messages: trimmed_messages}
    else
      context
    end
  end

  defp estimate_tokens(%Context{messages: messages, system_prompt: system_prompt}) do
    message_tokens = 
      messages
      |> Enum.map(&estimate_message_tokens/1)
      |> Enum.sum()
    
    system_tokens = estimate_text_tokens(system_prompt || "")
    
    message_tokens + system_tokens
  end

  defp estimate_message_tokens(%{content: content}) when is_binary(content) do
    estimate_text_tokens(content)
  end

  defp estimate_message_tokens(%{content: content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{text: text} -> estimate_text_tokens(text)
      %{type: :image} -> 85  # Approximate tokens for image
      _ -> 0
    end)
    |> Enum.sum()
  end

  defp estimate_text_tokens(text) when is_binary(text) do
    # Rough approximation: 1 token ≈ 4 characters
    String.length(text) |> div(4)
  end

  defp estimate_text_tokens(_), do: 0
end
```

### 3. Caching Strategy

```elixir
defmodule MyApp.AICache do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_or_compute(key, computation_fn) do
    case GenServer.call(__MODULE__, {:get, key}) do
      {:hit, value} ->
        {:ok, value}
      
      :miss ->
        case computation_fn.() do
          {:ok, value} ->
            GenServer.cast(__MODULE__, {:put, key, value})
            {:ok, value}
          
          error ->
            error
        end
    end
  end

  # GenServer implementation
  def init(_opts) do
    {:ok, %{}}
  end

  def handle_call({:get, key}, _from, cache) do
    response = case Map.get(cache, key) do
      nil -> :miss
      value -> {:hit, value}
    end
    {:reply, response, cache}
  end

  def handle_cast({:put, key, value}, cache) do
    # Simple cache with no eviction
    new_cache = Map.put(cache, key, value)
    {:noreply, new_cache}
  end
end

# Usage
cache_key = :crypto.hash(:md5, "#{provider}_#{model_id}_#{message}") |> Base.encode16()

{:ok, response} = MyApp.AICache.get_or_compute(cache_key, fn ->
  AI.complete_simple(model, context)
end)
```

### 4. Cost Tracking

```elixir
defmodule MyApp.CostTracker do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def track_usage(provider, model_id, usage) do
    GenServer.cast(__MODULE__, {:track, provider, model_id, usage})
  end

  def get_daily_cost do
    GenServer.call(__MODULE__, :get_daily_cost)
  end

  def get_usage_report do
    GenServer.call(__MODULE__, :get_report)
  end

  # Implementation
  def init(_opts) do
    {:ok, %{daily_cost: 0.0, usage_by_provider: %{}}}
  end

  def handle_cast({:track, provider, model_id, usage}, state) do
    cost = usage.cost.input + usage.cost.output
    
    new_state = %{state |
      daily_cost: state.daily_cost + cost,
      usage_by_provider: update_usage(state.usage_by_provider, provider, cost)
    }
    
    {:noreply, new_state}
  end

  def handle_call(:get_daily_cost, _from, state) do
    {:reply, state.daily_cost, state}
  end

  def handle_call(:get_report, _from, state) do
    report = %{
      daily_cost: state.daily_cost,
      usage_by_provider: state.usage_by_provider
    }
    {:reply, report, state}
  end

  defp update_usage(usage_map, provider, cost) do
    Map.update(usage_map, provider, cost, &(&1 + cost))
  end
end

# Usage in your AI calls
{:ok, response} = AI.complete_simple(model, context)
MyApp.CostTracker.track_usage(model.provider, model.model_id, response.usage)

# Check costs
%{daily_cost: cost, usage_by_provider: usage} = MyApp.CostTracker.get_usage_report()
IO.puts("Today's AI cost: $#{Float.round(cost, 4)}")
```

This provider guide gives you detailed information to make informed decisions about which AI provider and model to use for different scenarios, along with practical strategies for cost optimization.