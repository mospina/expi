defmodule Expi.ModelRegistryTest do
  use ExUnit.Case, async: true

  alias Expi.ModelRegistry
  alias Expi.Types.{Cost, Model}

  describe "get_model/2" do
    test "returns Claude Opus 4.5 model" do
      {:ok, model} = ModelRegistry.get_model("anthropic", "claude-opus-4-5")

      assert model.id == "claude-opus-4-5"
      assert model.name == "Claude Opus 4.5"
      assert model.api == "anthropic-messages"
      assert model.provider == "anthropic"
      assert model.base_url == "https://api.anthropic.com"
      assert model.reasoning == true
      assert "text" in model.input
      assert "image" in model.input
      assert model.context_window == 200_000
      assert model.max_tokens == 4096
      assert is_map(model.headers)
      assert is_map(model.compat)
    end

    test "returns Claude Sonnet 3.6 model" do
      {:ok, model} = ModelRegistry.get_model("anthropic", "claude-sonnet-3-6")

      assert model.id == "claude-sonnet-3-6"
      assert model.name == "Claude Sonnet 3.6"
      assert model.api == "anthropic-messages"
      assert model.provider == "anthropic"
      assert model.reasoning == true
      assert model.context_window == 200_000
    end

    test "returns Gemini Pro model" do
      {:ok, model} = ModelRegistry.get_model("google", "gemini-pro")

      assert model.id == "gemini-pro"
      assert model.name =~ "Gemini"
      assert model.api == "google-generative-ai"
      assert model.provider == "google"
      assert model.base_url =~ "googleapis.com"
      assert model.reasoning == false
      assert model.context_window > 0
    end

    test "returns Gemini Pro Vision model" do
      {:ok, model} = ModelRegistry.get_model("google", "gemini-pro-vision")

      assert model.id == "gemini-pro-vision"
      assert model.provider == "google"
      assert "text" in model.input
      assert "image" in model.input
    end

    test "returns Ollama Llama model" do
      {:ok, model} = ModelRegistry.get_model("ollama", "llama3.1:8b")

      assert model.id == "llama3.1:8b"
      assert model.name =~ "Llama"
      assert model.api == "openai-completions"
      assert model.provider == "ollama"
      assert model.base_url == "http://localhost:11434/v1"
      assert model.reasoning == false
    end

    test "returns Ollama CodeLlama model" do
      {:ok, model} = ModelRegistry.get_model("ollama", "codellama:7b")

      assert model.id == "codellama:7b"
      assert model.provider == "ollama"
      assert model.api == "openai-completions"
    end

    test "returns error for unknown provider" do
      assert {:error, :provider_not_found} = ModelRegistry.get_model("unknown", "model")
    end

    test "returns error for unknown model" do
      assert {:error, :model_not_found} = ModelRegistry.get_model("anthropic", "unknown-model")
    end

    test "returns error for invalid input" do
      assert {:error, :invalid_provider} = ModelRegistry.get_model("", "model")
      assert {:error, :invalid_model_id} = ModelRegistry.get_model("anthropic", "")
      assert {:error, :invalid_provider} = ModelRegistry.get_model(nil, "model")
      assert {:error, :invalid_model_id} = ModelRegistry.get_model("anthropic", nil)
    end
  end

  describe "list_providers/0" do
    test "returns all supported providers" do
      providers = ModelRegistry.list_providers()

      assert is_list(providers)
      assert "anthropic" in providers
      assert "google" in providers
      assert "ollama" in providers
      assert length(providers) >= 3
    end
  end

  describe "list_models/1" do
    test "returns all models for anthropic provider" do
      {:ok, models} = ModelRegistry.list_models("anthropic")

      assert is_list(models)
      assert length(models) >= 2

      model_ids = Enum.map(models, & &1.id)
      assert "claude-opus-4-5" in model_ids
      assert "claude-sonnet-3-6" in model_ids
    end

    test "returns all models for google provider" do
      {:ok, models} = ModelRegistry.list_models("google")

      assert is_list(models)
      assert length(models) >= 2

      model_ids = Enum.map(models, & &1.id)
      assert "gemini-pro" in model_ids
      assert "gemini-pro-vision" in model_ids
    end

    test "returns all models for ollama provider" do
      {:ok, models} = ModelRegistry.list_models("ollama")

      assert is_list(models)
      assert length(models) >= 2

      model_ids = Enum.map(models, & &1.id)
      assert "llama3.1:8b" in model_ids
      assert "codellama:7b" in model_ids
    end

    test "returns error for unknown provider" do
      assert {:error, :provider_not_found} = ModelRegistry.list_models("unknown")
    end
  end

  describe "validate_model/1" do
    test "validates complete model struct" do
      model = %Model{
        id: "test-model",
        name: "Test Model",
        api: "test-api",
        provider: "test",
        base_url: "https://test.com",
        reasoning: false,
        input: ["text"],
        cost: %Cost{input: 1.0, output: 2.0, cache_read: 0.0, cache_write: 0.0},
        context_window: 4000,
        max_tokens: 1000,
        headers: %{},
        compat: %{}
      }

      assert ModelRegistry.validate_model(model) == :ok
    end

    test "returns error for invalid model" do
      invalid_model = %Model{
        # Invalid empty ID
        id: "",
        name: "Test",
        api: "test-api",
        provider: "test",
        base_url: "https://test.com",
        reasoning: false,
        input: ["text"],
        cost: %Cost{input: 1.0, output: 2.0, cache_read: 0.0, cache_write: 0.0},
        context_window: 4000,
        max_tokens: 1000,
        headers: %{},
        compat: %{}
      }

      assert {:error, _reason} = ModelRegistry.validate_model(invalid_model)
    end
  end

  describe "cost calculations" do
    test "models have proper cost structures" do
      {:ok, model} = ModelRegistry.get_model("anthropic", "claude-opus-4-5")

      assert model.cost.input > 0
      assert model.cost.output > 0
      assert is_float(model.cost.input)
      assert is_float(model.cost.output)
    end

    test "calculates usage cost correctly" do
      {:ok, model} = ModelRegistry.get_model("anthropic", "claude-opus-4-5")

      cost =
        ModelRegistry.calculate_usage_cost(model, %{
          input: 1000,
          output: 500,
          cache_read: 0,
          cache_write: 0
        })

      expected_input_cost = 1000 * model.cost.input / 1_000_000
      expected_output_cost = 500 * model.cost.output / 1_000_000
      expected_total = expected_input_cost + expected_output_cost

      assert_in_delta(cost.total, expected_total, 0.0001)
      assert_in_delta(cost.input, expected_input_cost, 0.0001)
      assert_in_delta(cost.output, expected_output_cost, 0.0001)
    end
  end

  describe "model registration" do
    test "allows registering new models" do
      new_model = %Model{
        id: "custom-model",
        name: "Custom Model",
        api: "custom-api",
        provider: "custom",
        base_url: "https://custom.com",
        reasoning: true,
        input: ["text"],
        cost: %Cost{input: 5.0, output: 10.0, cache_read: 0.0, cache_write: 0.0},
        context_window: 8000,
        max_tokens: 2000,
        headers: %{},
        compat: %{}
      }

      assert :ok = ModelRegistry.register_model("custom", new_model)
      assert {:ok, ^new_model} = ModelRegistry.get_model("custom", "custom-model")
    end

    test "prevents registering invalid models" do
      invalid_model = %Model{
        # Invalid
        id: "",
        name: "Invalid",
        api: "test",
        provider: "test",
        base_url: "test",
        reasoning: false,
        input: [],
        cost: %Cost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
        context_window: 0,
        max_tokens: 0,
        headers: %{},
        compat: %{}
      }

      assert {:error, _reason} = ModelRegistry.register_model("test", invalid_model)
    end
  end
end
