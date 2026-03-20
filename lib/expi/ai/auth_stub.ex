defmodule ExpiAi.AI.Auth do
  @moduledoc """
  Production authentication module for AI providers.
  Handles API key management from environment variables and application config.
  """

  @doc """
  Retrieves API key for a provider from environment variables or config.
  """
  @spec get_api_key(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def get_api_key("anthropic") do
    case get_key_with_fallback("ANTHROPIC_API_KEY", :anthropic) do
      nil -> {:error, :missing_api_key}
      "" -> {:error, :missing_api_key}
      key -> {:ok, key}
    end
  end

  def get_api_key("google") do
    case get_key_with_fallback("GOOGLE_API_KEY", :google) do
      nil -> {:error, :missing_api_key}
      "" -> {:error, :missing_api_key}
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

  @doc """
  Validates API key for a provider.
  """
  @spec validate_api_key(String.t()) :: {:ok, String.t()} | {:error, :missing_api_key}
  def validate_api_key(provider) do
    get_api_key(provider)
  end

  @doc """
  Gets authentication headers for a provider with the appropriate format.
  """
  @spec get_auth_headers(String.t()) :: {:ok, list()} | {:error, :missing_api_key}
  def get_auth_headers(provider) do
    case get_api_key(provider) do
      {:ok, api_key} ->
        headers = build_auth_headers(provider, api_key)
        {:ok, headers}
      
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Validates connection for a provider.
  """
  @spec validate_connection(String.t()) :: {:ok, :valid} | {:error, atom()}
  def validate_connection(provider) do
    case provider do
      "anthropic" -> validate_api_key("anthropic") |> map_to_connection_result()
      "google" -> validate_api_key("google") |> map_to_connection_result()
      "ollama" -> validate_ollama_connection()
      _ -> {:error, :unsupported_provider}
    end
  end

  # Private functions

  defp get_key_with_fallback(env_var, config_key) do
    # Try environment variable first, then application config
    System.get_env(env_var) ||
      Application.get_env(:expi_ai, :api_keys, %{})[config_key]
  end

  defp build_auth_headers("anthropic", api_key) do
    [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"},
      {"anthropic-version", "2023-06-01"}
    ]
  end

  defp build_auth_headers("google", api_key) do
    [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]
  end

  defp build_auth_headers("ollama", _api_key) do
    [
      {"Content-Type", "application/json"}
    ]
  end

  defp build_auth_headers(_, api_key) do
    [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]
  end

  defp map_to_connection_result({:ok, _}), do: {:ok, :valid}
  defp map_to_connection_result({:error, reason}), do: {:error, reason}

  defp validate_ollama_connection do
    ollama_url = get_ollama_endpoint()
    
    case ExpiAi.AI.HttpClient.get("#{ollama_url}/api/tags", []) do
      {:ok, %{status: 200}} -> {:ok, :valid}
      {:ok, %{status: _}} -> {:error, :connection_failed}
      {:error, :connection_refused} -> {:error, :ollama_not_running}
      {:error, _} -> {:error, :connection_failed}
    end
  end

  defp get_ollama_endpoint do
    System.get_env("OLLAMA_ENDPOINT") || 
      Application.get_env(:expi_ai, :ollama_endpoint, "http://localhost:11434")
  end
end