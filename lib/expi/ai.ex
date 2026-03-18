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
  
  ## Examples
  
      iex> ExpiAi.AI.get_model("anthropic", "claude-opus-4-5")
      {:ok, %ExpiAi.Types.Model{id: "claude-opus-4-5", provider: "anthropic"}}
      
      iex> ExpiAi.AI.get_model("invalid", "model")
      {:error, :model_not_found}
  """
  @spec get_model(provider(), model_id()) :: {:ok, Model.t()} | {:error, atom()}
  def get_model(provider, model_id) do
    ExpiAi.ModelRegistry.get_model(provider, model_id)
  end

  @doc """
  Performs a synchronous request-response interaction with the LLM.
  
  ## Examples
  
      iex> {:ok, model} = ExpiAi.AI.get_model("anthropic", "claude-opus-4-5")
      iex> context = %ExpiAi.Types.Context{messages: [...]}
      iex> ExpiAi.AI.complete_simple(model, context)
      {:ok, %ExpiAi.Types.AssistantMessage{...}}
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
  Performs a streaming interaction with the LLM, returning real-time events.
  
  The returned stream emits `ExpiAi.Types.AssistantMessageEvent` structs
  as the model generates its response.
  
  ## Examples
  
      iex> {:ok, model} = ExpiAi.AI.get_model("anthropic", "claude-opus-4-5")
      iex> context = %ExpiAi.Types.Context{messages: [...]}
      iex> {:ok, stream} = ExpiAi.AI.stream_simple(model, context)
      iex> Enum.each(stream, fn event -> IO.inspect(event.type) end)
  """
  @spec stream_simple(Model.t(), Context.t()) :: {:ok, stream()} | {:error, atom()}
  def stream_simple(_model, _context) do
    # Stub implementation - will be implemented in Phase 4
    {:error, :not_implemented}
  end
end
