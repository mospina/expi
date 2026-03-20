defmodule Expi.Config do
  @moduledoc """
  Configuration management for the Expi AI module.
  
  Handles loading and validation of configuration values from application
  environment following Elixir best practices.
  """

  @doc """
  Gets the Anthropic API key from configuration.
  """
  @spec anthropic_api_key() :: String.t() | nil
  def anthropic_api_key do
    get_env(:anthropic_api_key)
  end

  @doc """
  Gets the Gemini API key from configuration.
  """
  @spec gemini_api_key() :: String.t() | nil
  def gemini_api_key do
    get_env(:gemini_api_key)
  end

  @doc """
  Gets the Ollama base URL from configuration.
  """
  @spec ollama_base_url() :: String.t()
  def ollama_base_url do
    get_env(:ollama_base_url, "http://localhost:11434")
  end

  @doc """
  Gets the HTTP timeout configuration.
  """
  @spec http_timeout() :: pos_integer()
  def http_timeout do
    get_env(:http_timeout, 60_000)
  end

  @doc """
  Gets the HTTP receive timeout configuration.
  """
  @spec http_recv_timeout() :: pos_integer()
  def http_recv_timeout do
    get_env(:http_recv_timeout, 60_000)
  end

  @doc """
  Gets the connection pool size configuration.
  """
  @spec connection_pool_size() :: pos_integer()
  def connection_pool_size do
    get_env(:connection_pool_size, 10)
  end

  @doc """
  Gets the maximum number of retries configuration.
  """
  @spec max_retries() :: non_neg_integer()
  def max_retries do
    get_env(:max_retries, 3)
  end

  @doc """
  Gets the base retry delay configuration.
  """
  @spec base_retry_delay() :: pos_integer()
  def base_retry_delay do
    get_env(:base_retry_delay, 1000)
  end

  @doc """
  Gets the maximum retry delay configuration.
  """
  @spec max_retry_delay() :: pos_integer()
  def max_retry_delay do
    get_env(:max_retry_delay, 30_000)
  end

  # Private helper functions

  defp get_env(key, default \\ nil) do
    case Application.get_env(:expi, key, default) do
      {:system, env_var} ->
        System.get_env(env_var)
      {:system, env_var, fallback} ->
        System.get_env(env_var, fallback)
      value ->
        value
    end
  end
end
