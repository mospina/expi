defmodule ExpiAi.AI do
  @moduledoc """
  Main AI module for ExpiAi project.
  
  Provides the core public API for interacting with Large Language Models,
  supporting Anthropic Claude, Google Gemini, and Ollama models.
  
  ## Main Functions
  
  - `get_model/2` - Retrieve model configuration by provider and model ID
  - `complete_simple/2` - Synchronous request-response interaction
  - `stream_simple/2` - Real-time streaming responses
  
  ## Usage
  
      # Get a model
      {:ok, model} = ExpiAi.AI.get_model("anthropic", "claude-opus-4-5")
      
      # Synchronous completion
      context = %ExpiAi.Types.Context{
        messages: [%ExpiAi.Types.UserMessage{
          role: :user,
          content: "Hello",
          timestamp: System.system_time(:millisecond)
        }]
      }
      
      {:ok, response} = ExpiAi.AI.complete_simple(model, context)
      
      # Streaming completion
      {:ok, stream} = ExpiAi.AI.stream_simple(model, context)
  """
  alias ExpiAi.Types.{AssistantMessage, Context, Model}

  @type provider :: String.t()
  @type model_id :: String.t()
  @type stream :: Enumerable.t()

  @doc """
  Retrieves a model configuration by provider and model ID.
  
  This function gets model configurations from the built-in registry, including
  pricing information, API endpoints, and capability metadata.
  
  ## Parameters
  
  - `provider` - Provider name: "anthropic", "google", or "ollama"
  - `model_id` - Specific model identifier (e.g., "claude-opus-4-5")
  
  ## Returns
  
  - `{:ok, %Model{}}` - Model configuration with pricing and capabilities
  - `{:error, :unknown_provider}` - Unsupported provider
  - `{:error, :model_not_found}` - Model not available for provider
  
  ## Examples
  
      # High-capability reasoning model
      iex> ExpiAi.AI.get_model("anthropic", "claude-opus-4-5")
      {:ok, %ExpiAi.Types.Model{
        provider: "anthropic",
        model_id: "claude-opus-4-5", 
        capabilities: [:text, :images, :tools, :reasoning],
        pricing: %{input_tokens: 15.0, output_tokens: 75.0}
      }}
      
      # Vision-enabled model
      iex> ExpiAi.AI.get_model("google", "gemini-pro-vision") 
      {:ok, %ExpiAi.Types.Model{capabilities: [:text, :images, :tools]}}
      
      # Free local model
      iex> ExpiAi.AI.get_model("ollama", "llama3.1:8b")
      {:ok, %ExpiAi.Types.Model{pricing: %{input_tokens: 0.0, output_tokens: 0.0}}}
      
      # Error cases  
      iex> ExpiAi.AI.get_model("invalid", "model")
      {:error, :unknown_provider}
      
      iex> ExpiAi.AI.get_model("anthropic", "nonexistent")
      {:error, :model_not_found}
      
  ## Available Models
  
  ### Anthropic Claude
  - `claude-opus-4-5` - Premium reasoning and analysis ($15/$75 per 1M tokens)
  - `claude-sonnet-3-6` - Balanced performance ($3/$15 per 1M tokens)
  
  ### Google Gemini
  - `gemini-pro` - General purpose text model  
  - `gemini-pro-vision` - Multi-modal image understanding
  
  ### Ollama (Local)
  - `llama3.1:8b` - Fast general purpose (free, requires local setup)
  - `codellama:7b` - Code generation specialist (free)
  """
  @spec get_model(provider(), model_id()) :: {:ok, Model.t()} | {:error, atom()}
  def get_model(provider, model_id) do
    ExpiAi.ModelRegistry.get_model(provider, model_id)
  end

  @doc """
  Performs a synchronous request-response interaction with an LLM.
  
  This function sends a complete context to the model and waits for the full
  response. Use `stream_simple/2` for real-time streaming responses.
  
  ## Parameters
  
  - `model` - Model configuration from `get_model/2`
  - `context` - Conversation context with messages and optional tools
  - `options` - Optional parameters (temperature, max_tokens, etc.)
  
  ## Returns
  
  - `{:ok, %AssistantMessage{}}` - Complete response with usage/cost info
  - `{:error, :missing_api_key}` - Authentication failure
  - `{:error, :rate_limited}` - Provider rate limit exceeded
  - `{:error, :network_error}` - Connection or timeout issues
  
  ## Examples
  
      # Basic text completion
      {:ok, model} = ExpiAi.AI.get_model("anthropic", "claude-sonnet-3-6")
      
      context = %ExpiAi.Types.Context{
        system_prompt: "You are a helpful assistant",
        messages: [
          %ExpiAi.Types.UserMessage{
            role: :user,
            content: "Explain quantum computing in simple terms",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }
      
      {:ok, response} = ExpiAi.AI.complete_simple(model, context)
      
      # Access response content
      content = response.content |> hd() |> Map.get(:text)
      IO.puts("AI Response: \#{content}")
      
      # Check usage and cost
      IO.puts("Tokens: \#{response.usage.input + response.usage.output}")
      IO.puts("Cost: $\#{response.usage.cost.input + response.usage.cost.output}")
      
      # Multi-modal input with images (Gemini Vision)
      {:ok, vision_model} = ExpiAi.AI.get_model("google", "gemini-pro-vision")
      
      context = %ExpiAi.Types.Context{
        messages: [
          %ExpiAi.Types.UserMessage{
            role: :user,
            content: [
              %ExpiAi.Types.TextContent{type: :text, text: "What's in this image?"},
              %ExpiAi.Types.ImageContent{
                type: :image,
                source: %{type: :base64, media_type: "image/jpeg", data: "..."}
              }
            ],
            timestamp: System.system_time(:millisecond)
          }
        ]
      }
      
      {:ok, response} = ExpiAi.AI.complete_simple(vision_model, context)
      
      # Tool calling example
      tools = [
        %ExpiAi.Types.Tool{
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
      
      context = %ExpiAi.Types.Context{
        messages: [%ExpiAi.Types.UserMessage{
          role: :user, 
          content: "What's the weather in Paris?",
          timestamp: System.system_time(:millisecond)
        }],
        tools: tools
      }
      
      {:ok, response} = ExpiAi.AI.complete_simple(model, context)
      
      # Handle tool calls
      Enum.each(response.tool_calls, fn tool_call ->
        IO.puts("Tool: \#{tool_call.name}")
        args = Jason.decode!(tool_call.arguments)
        # Execute your tool function here...
      end)
      
      # With options (temperature, max tokens, etc.)
      {:ok, response} = ExpiAi.AI.complete_simple(model, context, %{
        temperature: 0.7,
        max_tokens: 1000,
        thinking: true  # Enable reasoning mode (Claude only)
      })
      
  ## Error Handling
  
      case ExpiAi.AI.complete_simple(model, context) do
        {:ok, response} ->
          handle_success(response)
        
        {:error, :missing_api_key} ->
          Logger.error("API key not configured")
          
        {:error, :rate_limited} ->
          Logger.warn("Rate limited, retrying later")
          Process.sleep(60_000)
          
        {:error, :network_error} ->
          Logger.warn("Network issue, check connection")
          
        {:error, reason} ->
          Logger.error("Unexpected error: \#{inspect(reason)}")
      end
  """
  @spec complete_simple(Model.t(), Context.t()) :: {:ok, AssistantMessage.t()} | {:error, atom()}
  @spec complete_simple(Model.t(), Context.t(), map()) :: {:ok, AssistantMessage.t()} | {:error, atom()}
  
  def complete_simple(model, context), do: complete_simple(model, context, %{})

  def complete_simple(nil, _context, _options) do
    {:error, :invalid_model}
  end

  def complete_simple(_model, nil, _options) do
    {:error, :invalid_context}
  end

  def complete_simple(%Model{provider: "anthropic"} = model, context, options) do
    ExpiAi.Providers.Anthropic.complete(model, context, options)
  end

  def complete_simple(%Model{provider: "google"} = model, context, options) do
    ExpiAi.Providers.Gemini.complete(model, context, options)
  end

  def complete_simple(%Model{provider: "ollama"} = model, context, options) do
    ExpiAi.Providers.Ollama.complete(model, context, options)
  end

  def complete_simple(%Model{provider: provider}, _context, _options) do
    {:error, {:unsupported_provider, provider}}
  end

  @doc """
  Performs a streaming interaction with an LLM, returning real-time events.
  
  This function returns a stream of `ExpiAi.Types.AssistantMessageEvent` structs
  that are emitted as the model generates its response. Perfect for chat interfaces,
  live coding assistance, or any scenario requiring progressive response display.
  
  ## Parameters
  
  - `model` - Model configuration from `get_model/2`
  - `context` - Conversation context with messages and optional tools
  - `options` - Optional streaming parameters (temperature, thinking mode, etc.)
  
  ## Returns
  
  - `{:ok, Stream.t()}` - Enumerable stream of AssistantMessageEvent structs
  - `{:error, reason}` - Error starting the stream
  
  ## Stream Event Types
  
  The stream emits 12 different event types providing full visibility into the
  model's response generation process:
  
  **Lifecycle Events:**
  - `:start` - Stream begins, includes initial message structure  
  - `:done` - Stream completes, includes final message with usage/cost
  - `:error` - Stream failed, includes error details
  
  **Text Generation:**
  - `:text_start` - Text content block starts
  - `:text_delta` - Incremental text content (most frequent)
  - `:text_end` - Text content block ends
  
  **Reasoning (Claude only):**
  - `:thinking_start` - Model reasoning begins  
  - `:thinking_delta` - Incremental reasoning content
  - `:thinking_end` - Reasoning process ends
  
  **Tool Calling:**
  - `:toolcall_start` - Tool call initiation
  - `:toolcall_delta` - Incremental tool call data  
  - `:toolcall_end` - Tool call completion
  
  ## Examples
  
      # Basic streaming with real-time text display
      {:ok, model} = ExpiAi.AI.get_model("anthropic", "claude-sonnet-3-6")
      
      context = %ExpiAi.Types.Context{
        messages: [%ExpiAi.Types.UserMessage{
          role: :user,
          content: "Write a haiku about programming",
          timestamp: System.system_time(:millisecond)
        }]
      }
      
      {:ok, stream} = ExpiAi.AI.stream_simple(model, context)
      
      stream
      |> Stream.each(fn event ->
        case event.type do
          :start -> IO.puts("🎯 Composing haiku...")
          :text_delta -> IO.write(event.delta)
          :done -> 
            IO.puts("\\n✅ Haiku complete!")
            cost = event.message.usage.cost
            IO.puts("Cost: $" <> to_string(cost.input + cost.output))
        end
      end)
      |> Stream.run()
      
      # Streaming with Claude's reasoning mode
      {:ok, opus} = ExpiAi.AI.get_model("anthropic", "claude-opus-4-5")
      
      {:ok, stream} = ExpiAi.AI.stream_simple(opus, context, %{thinking: true})
      
      stream
      |> Stream.each(fn event ->
        case event.type do
          :thinking_start -> IO.puts("\\n🤔 Claude is thinking...")
          :thinking_delta -> IO.write("[thinking: " <> event.delta <> "]")
          :text_start -> IO.puts("\\n💡 Response:")
          :text_delta -> IO.write(event.delta)
        end
      end)
      |> Stream.run()
      
      # Accumulate complete response from stream
      {:ok, stream} = ExpiAi.AI.stream_simple(model, context)
      
      complete_text = 
        stream
        |> Stream.filter(& &1.type == :text_delta)
        |> Stream.map(& &1.delta)
        |> Enum.join("")
      
      IO.puts("Complete response: " <> complete_text)
      
      # Phoenix LiveView integration
      def start_streaming(socket, message) do
        {:ok, model} = ExpiAi.AI.get_model("anthropic", "claude-sonnet-3-6")
        context = build_context(message)
        
        Task.async(fn ->
          case ExpiAi.AI.stream_simple(model, context) do
            {:ok, stream} ->
              stream
              |> Stream.each(fn event ->
                send(self(), {:stream_event, event})
              end)
              |> Stream.run()
          end
        end)
        
        assign(socket, streaming: true, current_response: "")
      end
      
      # Batch processing for performance  
      {:ok, stream} = ExpiAi.AI.stream_simple(model, context)
      
      stream
      |> Stream.chunk_every(5)  # Process events in batches
      |> Stream.each(fn batch ->
        text_content = 
          batch
          |> Enum.filter(& &1.type == :text_delta)
          |> Enum.map(& &1.delta)
          |> Enum.join("")
        
        if text_content != "", do: IO.write(text_content)
      end)
      |> Stream.run()
      
      # Error handling with stream recovery
      case ExpiAi.AI.stream_simple(model, context) do
        {:ok, stream} ->
          try do
            stream
            |> Stream.each(&process_event/1)
            |> Stream.run()
          rescue
            error ->
              Logger.error("Stream interrupted: " <> inspect(error))
              # Implement recovery logic here
          end
        
        {:error, :missing_api_key} ->
          Logger.error("Configure API key for streaming")
        
        {:error, :rate_limited} ->
          Logger.warn("Rate limited, waiting before retry")
          Process.sleep(60_000)
      end
      
  ## Integration Patterns
  
      # GenServer for stateful streaming
      defmodule StreamingHandler do
        use GenServer
        
        def start_streaming(message) do
          GenServer.cast(__MODULE__, {:start_stream, message})
        end
        
        def handle_cast({:start_stream, message}, state) do
          {:ok, model} = ExpiAi.AI.get_model("anthropic", "claude-sonnet-3-6")
          context = build_context(message)
          
          Task.start(fn ->
            case ExpiAi.AI.stream_simple(model, context) do
              {:ok, stream} ->
                stream |> Stream.each(fn event ->
                  GenServer.cast(__MODULE__, {:stream_event, event})
                end) |> Stream.run()
            end
          end)
          
          {:noreply, %{state | streaming: true}}
        end
        
        def handle_cast({:stream_event, event}, state) do
          # Handle each streaming event
          new_state = process_stream_event(event, state)
          {:noreply, new_state}
        end
      end
  """
  @spec stream_simple(Model.t(), Context.t()) :: {:ok, stream()} | {:error, atom()}
  @spec stream_simple(Model.t(), Context.t(), map()) :: {:ok, stream()} | {:error, atom()}
  
  def stream_simple(model, context), do: stream_simple(model, context, %{})

  def stream_simple(nil, _context, _options) do
    {:error, :invalid_model}
  end

  def stream_simple(_model, nil, _options) do
    {:error, :invalid_context}
  end

  def stream_simple(model, context, options) do
    ExpiAi.AI.Streaming.stream_events(model, context, options)
  end
end
