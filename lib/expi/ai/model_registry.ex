defmodule Expi.ModelRegistry do
  @moduledoc """
  Model registry for hardcoded model definitions with easy extensibility.
  
  Provides model lookup, validation, and cost calculation functionality
  for supported AI providers: Anthropic, Google, and Ollama.
  """

  alias Expi.Types.{Cost, Model}

  # Registry state for dynamic model registration
  use Agent

  @registry_name __MODULE__

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: @registry_name)
  end

  @doc """
  Retrieves a model by provider and model ID.
  """
  @spec get_model(String.t(), String.t()) :: {:ok, Model.t()} | {:error, atom()}
  def get_model(provider, model_id) when is_binary(provider) and is_binary(model_id) do
    cond do
      provider == "" -> {:error, :invalid_provider}
      model_id == "" -> {:error, :invalid_model_id}
      true -> lookup_model(provider, model_id)
    end
  end

  def get_model(nil, _model_id), do: {:error, :invalid_provider}
  def get_model(_provider, nil), do: {:error, :invalid_model_id}

  @doc """
  Returns all supported providers.
  """
  @spec list_providers() :: [String.t()]
  def list_providers do
    ["anthropic", "google", "ollama"]
  end

  @doc """
  Returns all models for a specific provider.
  """
  @spec list_models(String.t()) :: {:ok, [Model.t()]} | {:error, atom()}
  def list_models(provider) do
    case provider do
      "anthropic" -> {:ok, anthropic_models()}
      "google" -> {:ok, google_models()}
      "ollama" -> {:ok, ollama_models()}
      _ -> {:error, :provider_not_found}
    end
  end

  @doc """
  Validates a model structure.
  """
  @spec validate_model(Model.t()) :: :ok | {:error, String.t()}
  def validate_model(%Model{} = model) do
    with :ok <- validate_required_strings(model),
         :ok <- validate_positive_integers(model),
         :ok <- validate_input_list(model) do
      :ok
    end
  end

  @doc """
  Calculates usage cost based on model pricing and token usage.
  """
  @spec calculate_usage_cost(Model.t(), map()) :: %{
          input: float(),
          output: float(),
          cache_read: float(),
          cache_write: float(),
          total: float()
        }
  def calculate_usage_cost(%Model{cost: model_cost}, usage) do
    input_cost = (usage.input || 0) * model_cost.input / 1_000_000
    output_cost = (usage.output || 0) * model_cost.output / 1_000_000
    cache_read_cost = (usage.cache_read || 0) * model_cost.cache_read / 1_000_000
    cache_write_cost = (usage.cache_write || 0) * model_cost.cache_write / 1_000_000

    %{
      input: input_cost,
      output: output_cost,
      cache_read: cache_read_cost,
      cache_write: cache_write_cost,
      total: input_cost + output_cost + cache_read_cost + cache_write_cost
    }
  end

  @doc """
  Registers a new model dynamically.
  """
  @spec register_model(String.t(), Model.t()) :: :ok | {:error, String.t()}
  def register_model(provider, %Model{} = model) do
    with :ok <- validate_model(model),
         :ok <- update_registry(provider, model) do
      :ok
    end
  end

  # Private validation functions

  defp update_registry(provider, model) do
    if Process.whereis(@registry_name) do
      Agent.update(@registry_name, fn state ->
        provider_models = Map.get(state, provider, [])
        Map.put(state, provider, [model | provider_models])
      end)
      :ok
    else
      {:error, "Registry not available"}
    end
  end

  defp validate_required_strings(%Model{} = model) do
    cond do
      model.id == "" -> {:error, "Model ID cannot be empty"}
      model.name == "" -> {:error, "Model name cannot be empty"}
      model.api == "" -> {:error, "Model API cannot be empty"}
      model.provider == "" -> {:error, "Model provider cannot be empty"}
      model.base_url == "" -> {:error, "Model base_url cannot be empty"}
      true -> :ok
    end
  end

  defp validate_positive_integers(%Model{} = model) do
    cond do
      model.context_window <= 0 -> {:error, "Context window must be positive"}
      model.max_tokens <= 0 -> {:error, "Max tokens must be positive"}
      true -> :ok
    end
  end

  defp validate_input_list(%Model{} = model) do
    cond do
      not is_list(model.input) -> {:error, "Input must be a list"}
      model.input == [] -> {:error, "Input list cannot be empty"}
      true -> :ok
    end
  end

  # Private functions

  defp lookup_model(provider, model_id) do
    # First check hardcoded models for known providers
    case get_hardcoded_model(provider, model_id) do
      {:ok, model} ->
        {:ok, model}

      {:error, :model_not_found} ->
        # For known providers, check dynamic models
        if provider in ["anthropic", "google", "ollama"] do
          get_dynamic_model_for_known_provider(provider, model_id)
        else
          # For unknown providers, check if they exist in dynamic registry
          get_dynamic_model_for_unknown_provider(provider, model_id)
        end
    end
  end

  defp get_hardcoded_model(provider, model_id) do
    case {provider, model_id} do
      {"anthropic", "claude-opus-4-5"} -> {:ok, claude_opus_4_5()}
      {"anthropic", "claude-sonnet-3-6"} -> {:ok, claude_sonnet_3_6()}
      {"google", "gemini-pro"} -> {:ok, gemini_pro()}
      {"google", "gemini-pro-vision"} -> {:ok, gemini_pro_vision()}
      {"ollama", "llama3.1:8b"} -> {:ok, llama3_1_8b()}
      {"ollama", "codellama:7b"} -> {:ok, codellama_7b()}
      {_, _} -> {:error, :model_not_found}
    end
  end

  defp get_dynamic_model_for_known_provider(provider, model_id) do
    if Process.whereis(@registry_name) do
      dynamic_models =
        Agent.get(@registry_name, fn state ->
          Map.get(state, provider, [])
        end)

      case Enum.find(dynamic_models, &(&1.id == model_id)) do
        nil -> {:error, :model_not_found}
        model -> {:ok, model}
      end
    else
      {:error, :model_not_found}
    end
  end

  defp get_dynamic_model_for_unknown_provider(provider, model_id) do
    if Process.whereis(@registry_name) do
      dynamic_models = get_provider_models(provider)
      handle_dynamic_model_lookup(provider, model_id, dynamic_models)
    else
      {:error, :provider_not_found}
    end
  end

  defp get_provider_models(provider) do
    Agent.get(@registry_name, fn state ->
      Map.get(state, provider, [])
    end)
  end

  defp handle_dynamic_model_lookup(provider, model_id, dynamic_models) do
    case Enum.find(dynamic_models, &(&1.id == model_id)) do
      nil -> check_provider_existence(provider)
      model -> {:ok, model}
    end
  end

  defp check_provider_existence(provider) do
    all_providers = Agent.get(@registry_name, fn state -> Map.keys(state) end)
    if provider in all_providers do
      {:error, :model_not_found}
    else
      {:error, :provider_not_found}
    end
  end

  # Hardcoded model definitions

  defp claude_opus_4_5 do
    %Model{
      id: "claude-opus-4-5",
      name: "Claude Opus 4.5",
      api: "anthropic-messages",
      provider: "anthropic",
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: ["text", "image"],
      cost: %Cost{
        input: 15.0,
        output: 75.0,
        cache_read: 0.15,
        cache_write: 18.75
      },
      context_window: 200_000,
      max_tokens: 4096,
      headers: %{},
      compat: %{}
    }
  end

  defp claude_sonnet_3_6 do
    %Model{
      id: "claude-sonnet-3-6",
      name: "Claude Sonnet 3.6",
      api: "anthropic-messages",
      provider: "anthropic",
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: ["text", "image"],
      cost: %Cost{
        input: 3.0,
        output: 15.0,
        cache_read: 0.03,
        cache_write: 3.75
      },
      context_window: 200_000,
      max_tokens: 8192,
      headers: %{},
      compat: %{}
    }
  end

  defp gemini_pro do
    %Model{
      id: "gemini-pro",
      name: "Gemini Pro",
      api: "google-generative-ai",
      provider: "google",
      base_url: "https://generativelanguage.googleapis.com",
      reasoning: false,
      input: ["text"],
      cost: %Cost{
        input: 0.5,
        output: 1.5,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 30_720,
      max_tokens: 8192,
      headers: %{},
      compat: %{}
    }
  end

  defp gemini_pro_vision do
    %Model{
      id: "gemini-pro-vision",
      name: "Gemini Pro Vision",
      api: "google-generative-ai",
      provider: "google",
      base_url: "https://generativelanguage.googleapis.com",
      reasoning: false,
      input: ["text", "image"],
      cost: %Cost{
        input: 0.5,
        output: 1.5,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 30_720,
      max_tokens: 8192,
      headers: %{},
      compat: %{}
    }
  end

  defp llama3_1_8b do
    %Model{
      id: "llama3.1:8b",
      name: "Llama 3.1 8B",
      api: "openai-completions",
      provider: "ollama",
      base_url: "http://localhost:11434/v1",
      reasoning: false,
      input: ["text"],
      cost: %Cost{
        input: 0.0,
        output: 0.0,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 8192,
      max_tokens: 4096,
      headers: %{},
      compat: %{}
    }
  end

  defp codellama_7b do
    %Model{
      id: "codellama:7b",
      name: "Code Llama 7B",
      api: "openai-completions",
      provider: "ollama",
      base_url: "http://localhost:11434/v1",
      reasoning: false,
      input: ["text"],
      cost: %Cost{
        input: 0.0,
        output: 0.0,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 4096,
      max_tokens: 2048,
      headers: %{},
      compat: %{}
    }
  end

  # Helper functions for list_models/1

  defp anthropic_models do
    [claude_opus_4_5(), claude_sonnet_3_6()]
  end

  defp google_models do
    [gemini_pro(), gemini_pro_vision()]
  end

  defp ollama_models do
    [llama3_1_8b(), codellama_7b()]
  end
end
