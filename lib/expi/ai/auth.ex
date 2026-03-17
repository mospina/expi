defmodule ExpiAi.Auth do
  @moduledoc """
  Authentication management for API keys and provider connections.
  
  Handles API key validation, header construction, and connection
  validation for Anthropic, Google, and Ollama providers.
  """

  alias ExpiAi.Config
  alias ExpiAi.Types.Model

  @doc """
  Gets API key for a provider from configuration.
  """
  @spec get_api_key(String.t()) :: {:ok, String.t() | nil} | {:error, atom()}
  def get_api_key("anthropic"), do: {:ok, Config.anthropic_api_key()}
  def get_api_key("google"), do: {:ok, Config.gemini_api_key()}
  def get_api_key("ollama"), do: {:ok, nil}
  def get_api_key(_), do: {:error, :unknown_provider}

  @doc """
  Validates API key format for a provider.
  """
  @spec validate_api_key(String.t(), String.t() | nil) :: :ok | {:error, atom()}
  def validate_api_key("anthropic", key) when is_binary(key) do
    if String.starts_with?(key, "sk-ant-api03-") and String.length(key) > 20 do
      :ok
    else
      {:error, :invalid_key_format}
    end
  end

  def validate_api_key("google", key) when is_binary(key) do
    if String.starts_with?(key, "AIzaSy") and String.length(key) > 30 do
      :ok
    else
      {:error, :invalid_key_format}
    end
  end

  def validate_api_key("ollama", _), do: :ok
  def validate_api_key(_, _), do: {:error, :unknown_provider}

  @doc """
  Builds authentication headers for a provider.
  """
  @spec build_auth_headers(String.t(), String.t() | nil) :: list() | {:error, atom()}
  def build_auth_headers("anthropic", api_key) when is_binary(api_key) do
    [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"}
    ]
  end

  def build_auth_headers("google", api_key) when is_binary(api_key) do
    [
      {"x-goog-api-key", api_key}
    ]
  end

  def build_auth_headers("ollama", _), do: []
  def build_auth_headers(_, _), do: {:error, :unknown_provider}

  @doc """
  Gets complete authenticated headers for a model.
  """
  @spec get_authenticated_headers(Model.t()) :: {:ok, list()} | {:error, atom()}
  def get_authenticated_headers(%Model{provider: provider, headers: model_headers}) do
    with {:ok, api_key} <- get_api_key(provider),
         {:ok, auth_headers} <- build_auth_headers_result(provider, api_key) do
      model_header_list = convert_headers_to_list(model_headers)
      all_headers = auth_headers ++ model_header_list
      {:ok, all_headers}
    end
  end

  @doc """
  Validates connection to a provider.
  """
  @spec validate_connection(String.t()) :: {:ok, :connected} | {:error, atom()}
  def validate_connection("anthropic") do
    # In real implementation, would ping Anthropic API
    {:ok, :connected}
  end

  def validate_connection("google") do
    # In real implementation, would ping Google API
    {:ok, :connected}
  end

  def validate_connection("ollama") do
    # In real implementation, would ping Ollama endpoint
    {:ok, :connected}
  end

  def validate_connection(_), do: {:error, :unknown_provider}

  @doc """
  Gets authentication configuration.
  """
  @spec get_auth_config() :: map()
  def get_auth_config do
    %{
      anthropic_api_key: Config.anthropic_api_key(),
      gemini_api_key: Config.gemini_api_key(),
      ollama_base_url: Config.ollama_base_url()
    }
  end

  @doc """
  Validates environment configuration for all providers.
  """
  @spec validate_environment() :: map()
  def validate_environment do
    %{
      anthropic: validate_provider_env("anthropic"),
      google: validate_provider_env("google"),
      ollama: validate_provider_env("ollama")
    }
  end

  @doc """
  Masks API key for safe logging.
  """
  @spec mask_api_key(String.t() | nil) :: String.t()
  def mask_api_key(nil), do: "nil"
  def mask_api_key(""), do: ""

  def mask_api_key(key) when is_binary(key) do
    cond do
      String.starts_with?(key, "sk-ant-api03-") ->
        "sk-ant-api03-***"

      String.starts_with?(key, "AIzaSy") ->
        "AIzaSy***"

      String.length(key) > 8 ->
        String.slice(key, 0..7) <> "***"

      true ->
        "***"
    end
  end

  @doc """
  Authenticates a request with provider credentials.
  """
  @spec authenticate_request(String.t(), String.t()) :: {:ok, :authenticated} | {:error, atom()}
  def authenticate_request(provider, api_key) do
    case validate_api_key(provider, api_key) do
      :ok -> {:ok, :authenticated}
      {:error, _} -> {:error, :authentication_failed}
    end
  end

  @doc """
  Gets human-readable error message for authentication errors.
  """
  @spec get_auth_error(atom(), String.t()) :: String.t()
  def get_auth_error(:invalid_key_format, provider) do
    case provider do
      "anthropic" ->
        "Invalid Anthropic API key format. Expected key starting with 'sk-ant-api03-'"

      "google" ->
        "Invalid Google API key format. Expected key starting with 'AIzaSy'"

      _ ->
        "Invalid API key format for #{provider}"
    end
  end

  def get_auth_error(:missing_key, provider) do
    "Missing API key for #{provider}. Please configure the appropriate environment variable."
  end

  def get_auth_error(:unknown_provider, provider) do
    "Unknown provider: #{provider}. Supported providers: anthropic, google, ollama"
  end

  def get_auth_error(reason, provider) do
    "Authentication error for #{provider}: #{reason}"
  end

  # Private helper functions

  defp build_auth_headers_result(provider, api_key) do
    case build_auth_headers(provider, api_key) do
      {:error, reason} -> {:error, reason}
      headers -> {:ok, headers}
    end
  end

  defp convert_headers_to_list(model_headers) do
    if is_map(model_headers), do: Map.to_list(model_headers), else: []
  end

  defp validate_provider_env("anthropic") do
    case get_api_key("anthropic") do
      {:ok, nil} -> :missing_key
      {:ok, key} -> if validate_api_key("anthropic", key) == :ok, do: :ok, else: :invalid_key
      {:error, _} -> :missing_key
    end
  end

  defp validate_provider_env("google") do
    case get_api_key("google") do
      {:ok, nil} -> :missing_key
      {:ok, key} -> if validate_api_key("google", key) == :ok, do: :ok, else: :invalid_key
      {:error, _} -> :missing_key
    end
  end

  defp validate_provider_env("ollama") do
    # For Ollama, just check if the base URL is configured
    case Config.ollama_base_url() do
      url when is_binary(url) and url != "" -> :ok
      _ -> :unreachable
    end
  end

  defp validate_provider_env(_), do: :unknown_provider
end
