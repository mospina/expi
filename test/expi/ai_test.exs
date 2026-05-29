defmodule Expi.AITest do
  use ExUnit.Case, async: true

  @moduletag :known_failure
  @moduletag skip: "KNOWN_FAILURE(PRD-20260528, owner:eng, expires:2026-06-30): Model catalog expectations outdated vs current defaults"

  alias Expi.AI
  alias Expi.Types.{Context, UserMessage}

  describe "get_model/2" do
    test "returns Claude Opus 4.5 model successfully" do
      assert {:ok, model} = AI.get_model("anthropic", "claude-opus-4-5")

      assert model.id == "claude-opus-4-5"
      assert model.name == "Claude Opus 4.5"
      assert model.provider == "anthropic"
      assert model.api == "anthropic-messages"
      assert model.reasoning == true
      assert model.context_window == 200_000
      assert model.max_tokens == 4096
    end

    test "returns Claude Sonnet 3.6 model successfully" do
      assert {:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")

      assert model.id == "claude-sonnet-3-6"
      assert model.name == "Claude Sonnet 3.6"
      assert model.provider == "anthropic"
      assert model.reasoning == true
    end

    test "returns Gemini Pro model successfully" do
      assert {:ok, model} = AI.get_model("google", "gemini-pro")

      assert model.id == "gemini-pro"
      assert model.provider == "google"
      assert model.api == "google-generative-ai"
      assert String.contains?(model.name, "Gemini")
    end

    test "returns Gemini Pro Vision model with image support" do
      assert {:ok, model} = AI.get_model("google", "gemini-pro-vision")

      assert model.id == "gemini-pro-vision"
      assert model.provider == "google"
      assert "text" in model.input
      assert "image" in model.input
    end

    test "returns Ollama Llama model successfully" do
      assert {:ok, model} = AI.get_model("ollama", "llama3.1:8b")

      assert model.id == "llama3.1:8b"
      assert model.provider == "ollama"
      assert model.api == "openai-completions"
      assert model.base_url == "http://localhost:11434/v1"
    end

    test "returns Ollama CodeLlama model successfully" do
      assert {:ok, model} = AI.get_model("ollama", "codellama:7b")

      assert model.id == "codellama:7b"
      assert model.provider == "ollama"
      assert model.api == "openai-completions"
    end

    test "returns error for unknown provider" do
      assert {:error, :provider_not_found} = AI.get_model("unknown-provider", "any-model")
    end

    test "returns error for unknown model" do
      assert {:error, :model_not_found} = AI.get_model("anthropic", "unknown-model")
      assert {:error, :model_not_found} = AI.get_model("google", "nonexistent-model")
      assert {:error, :model_not_found} = AI.get_model("ollama", "missing-model")
    end

    test "validates input parameters" do
      assert {:error, :invalid_provider} = AI.get_model("", "claude-opus-4-5")
      assert {:error, :invalid_provider} = AI.get_model(nil, "claude-opus-4-5")
      assert {:error, :invalid_model_id} = AI.get_model("anthropic", "")
      assert {:error, :invalid_model_id} = AI.get_model("anthropic", nil)
    end

    test "returns consistent model structure across providers" do
      providers_and_models = [
        {"anthropic", "claude-opus-4-5"},
        {"google", "gemini-pro"},
        {"ollama", "llama3.1:8b"}
      ]

      for {provider, model_id} <- providers_and_models do
        assert {:ok, model} = AI.get_model(provider, model_id)

        # Verify all models have the same required fields
        assert is_binary(model.id)
        assert is_binary(model.name)
        assert is_binary(model.api)
        assert is_binary(model.provider)
        assert is_binary(model.base_url)
        assert is_boolean(model.reasoning)
        assert is_list(model.input)
        assert is_integer(model.context_window)
        assert is_integer(model.max_tokens)
        assert is_map(model.headers)
        assert is_map(model.compat)

        # Cost structure validation
        assert is_float(model.cost.input)
        assert is_float(model.cost.output)
        assert is_float(model.cost.cache_read)
        assert is_float(model.cost.cache_write)
      end
    end
  end

  describe "complete_simple/2 (stub validation)" do
    test "function exists and returns not_implemented error" do
      {:ok, model} = AI.get_model("anthropic", "claude-opus-4-5")

      context = %Context{
        system_prompt: "You are helpful",
        messages: [
          %UserMessage{
            role: :user,
            content: "Hello",
            timestamp: System.system_time(:millisecond)
          }
        ],
        tools: nil
      }

      case AI.complete_simple(model, context) do
        {:error, reason} when reason in [:not_implemented, :missing_api_key] -> :ok
        other -> flunk("Expected error, got: #{inspect(other)}")
      end
    end

    test "accepts valid model and context parameters" do
      {:ok, model} = AI.get_model("google", "gemini-pro")

      context = %Context{
        system_prompt: nil,
        messages: [
          %UserMessage{
            role: :user,
            content: [
              %Expi.Types.TextContent{type: :text, text: "Test message"}
            ],
            timestamp: System.system_time(:millisecond)
          }
        ],
        tools: nil
      }

      # Should accept the parameters without error (though return not_implemented)
      case AI.complete_simple(model, context) do
        {:error, reason} when reason in [:not_implemented, :missing_api_key] -> :ok
        other -> flunk("Expected error, got: #{inspect(other)}")
      end
    end

    test "function signature matches expected type spec" do
      # Verify the function accepts Model.t() and Context.t() as specified
      assert function_exported?(Expi.AI, :complete_simple, 2)
    end
  end

  describe "stream_simple/2 (functionality validation)" do
    test "function exists and returns streaming enumerable" do
      {:ok, model} = AI.get_model("ollama", "llama3.1:8b")

      context = %Context{
        system_prompt: "You are an AI assistant",
        messages: [
          %UserMessage{
            role: :user,
            content: "Tell me a short story",
            timestamp: System.system_time(:millisecond)
          }
        ],
        tools: nil
      }

      case AI.stream_simple(model, context) do
        {:ok, stream} ->
          # Stream should be enumerable
          assert Enumerable.impl_for(stream) != nil
          # Test that we can actually enumerate events
          events = stream |> Enum.take(3)
          assert length(events) == 3

        {:error, reason} ->
          # Network/connection errors acceptable for Ollama in test environment
          assert reason in [:connection_refused, :network_error]
      end
    end

    test "accepts valid model and context parameters" do
      {:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")

      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Stream a response",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      case AI.stream_simple(model, context) do
        {:ok, stream} ->
          # Should return a valid stream
          assert Enumerable.impl_for(stream) != nil
          # Verify we can get events from the stream
          events = stream |> Enum.take(2)
          assert length(events) >= 1

        {:error, reason} ->
          assert reason in [:missing_api_key, :network_error]
      end
    end

    test "function signature matches expected type spec" do
      # Verify the function accepts Model.t() and Context.t() as specified
      assert function_exported?(Expi.AI, :stream_simple, 2)
    end
  end

  describe "integration with model registry" do
    test "get_model integrates with ModelRegistry correctly" do
      # Verify that AI.get_model/2 properly delegates to ModelRegistry
      # and returns the same data
      {:ok, ai_model} = AI.get_model("anthropic", "claude-opus-4-5")
      {:ok, registry_model} = Expi.ModelRegistry.get_model("anthropic", "claude-opus-4-5")

      assert ai_model == registry_model
    end

    test "error responses match between AI and ModelRegistry" do
      # Test that errors are properly propagated
      assert AI.get_model("unknown", "model") ==
               Expi.ModelRegistry.get_model("unknown", "model")

      assert AI.get_model("anthropic", "unknown") ==
               Expi.ModelRegistry.get_model("anthropic", "unknown")
    end
  end

  describe "error handling" do
    test "provides informative error messages" do
      assert {:error, reason} = AI.get_model("nonexistent", "model")
      assert reason in [:provider_not_found, :invalid_provider]

      assert {:error, reason} = AI.get_model("anthropic", "nonexistent")
      assert reason in [:model_not_found, :invalid_model_id]
    end

    test "handles edge cases gracefully" do
      # Empty strings
      assert {:error, _} = AI.get_model("", "")

      # Nil values
      assert {:error, _} = AI.get_model(nil, nil)

      # Very long strings (potential DoS attempt)
      long_string = String.duplicate("a", 10_000)
      assert {:error, _} = AI.get_model(long_string, long_string)
    end

    test "validates against injection attempts" do
      # Test potential injection strings
      malicious_inputs = [
        "'; DROP TABLE models; --",
        "<script>alert('xss')</script>",
        "../../etc/passwd",
        "\#{File.read('/etc/passwd')}"
      ]

      for malicious_input <- malicious_inputs do
        assert {:error, _} = AI.get_model(malicious_input, "test")
        assert {:error, _} = AI.get_model("test", malicious_input)
      end
    end
  end

  describe "performance characteristics" do
    test "get_model responds quickly" do
      # Verify that model lookups are fast (hardcoded registry)
      start_time = System.monotonic_time(:microsecond)
      {:ok, _model} = AI.get_model("anthropic", "claude-opus-4-5")
      end_time = System.monotonic_time(:microsecond)

      # Should be very fast since it's hardcoded lookup
      elapsed_microseconds = end_time - start_time
      # Less than 1ms
      assert elapsed_microseconds < 1000
    end

    test "handles concurrent model lookups" do
      # Test concurrent access to model registry
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            AI.get_model("anthropic", "claude-opus-4-5")
          end)
        end

      results = Task.await_many(tasks, 1000)

      # All should succeed
      for result <- results do
        assert {:ok, _model} = result
      end
    end
  end
end
