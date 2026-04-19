defmodule Expi do
  @moduledoc """
  Expi - Elixir AI Module

  A production-ready Elixir module for interfacing with Large Language Models (LLMs), 
  supporting **Anthropic Claude**, **Google Gemini**, and **Ollama** providers with 
  comprehensive streaming, multi-modal, and tool calling capabilities.

  ## Quick Start

      alias Expi.AI
      alias Expi.Types.{Context, UserMessage}
      
      # Get a model
      {:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")
      
      # Create a context
      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Hello, how can you help me today?",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }
      
      # Synchronous completion
      {:ok, response} = AI.complete_simple(model, context)
      
      # Streaming completion
      {:ok, stream} = AI.stream_simple(model, context)
      
  ## Main Modules

  - `Expi.AI` - Main API for model interactions
  - `Expi.Agent` - Conversation orchestration and tool loop
  - `Expi.Session` - Durable session lifecycle and persistence API
  - `Expi.Types` - Core type definitions and structs
  - `Expi.ModelRegistry` - Model configuration and registry

  ## Features

  - 🎯 **Multi-Provider Support**: Anthropic Claude, Google Gemini, and Ollama
  - 🔄 **Synchronous & Streaming APIs**: Both request-response and real-time streaming
  - 🖼️ **Multi-Modal Input**: Support for text, images, and complex content types
  - 🛠️ **Tool/Function Calling**: Complete tool integration across all providers
  - 📊 **Cost Tracking**: Built-in token usage and cost monitoring
  - 🔐 **Production Security**: SSL verification, connection pooling, and secure authentication
  - 📈 **Telemetry Integration**: Comprehensive monitoring and observability
  """

  # Delegate main functions to AI module for convenience
  defdelegate get_model(provider, model_id), to: Expi.AI
  defdelegate complete_simple(model, context), to: Expi.AI
  defdelegate complete_simple(model, context, options), to: Expi.AI
  defdelegate stream_simple(model, context), to: Expi.AI
  defdelegate stream_simple(model, context, options), to: Expi.AI
  defdelegate create_session(options), to: Expi.Session

  @doc """
  Backward-compatible hello helper used by the default generated test.
  """
  @spec hello() :: :world
  def hello, do: :world

  @doc """
  Returns the version of the Expi library.

  ## Examples

      iex> Expi.version()
      "0.1.0"
      
  """
  @spec version() :: String.t()
  def version do
    Application.spec(:expi, :vsn) |> to_string()
  end
end
