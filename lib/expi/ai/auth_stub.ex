defmodule ExpiAi.AI.Auth do
  @moduledoc """
  Stub authentication module for AI providers.
  In production this would handle API key retrieval from environment or config.
  """

  @doc """
  Retrieves API key for a provider.
  Returns error to simulate missing keys in test environment.
  """
  @spec get_api_key(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def get_api_key("anthropic") do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil -> {:error, :missing_api_key}
      key -> {:ok, key}
    end
  end

  def get_api_key("google") do
    case System.get_env("GOOGLE_API_KEY") do
      nil -> {:error, :missing_api_key}
      key -> {:ok, key}
    end
  end

  def get_api_key("ollama") do
    # Ollama typically doesn't require API keys for local usage
    {:ok, ""}
  end

  def get_api_key(_provider) do
    {:error, :unsupported_provider}
  end
end