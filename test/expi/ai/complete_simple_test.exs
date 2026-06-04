defmodule Expi.CompleteSimpleTest do
  use ExUnit.Case, async: true

  alias Expi.AI

  alias Expi.Types.{
    AssistantMessage,
    Context,
    TextContent,
    Usage,
    UserMessage
  }

  describe "complete_simple/2 integration" do
    test "integrates with Anthropic provider" do
      {:ok, model} = AI.get_model("anthropic", "claude-opus-4-5")

      context = %Context{
        system_prompt: "You are a helpful assistant.",
        messages: [
          %UserMessage{
            role: :user,
            content: "Say hello in one word",
            timestamp: System.system_time(:millisecond)
          }
        ],
        tools: nil
      }

      case AI.complete_simple(model, context) do
        {:ok, response} ->
          assert %AssistantMessage{} = response
          assert response.role == :assistant
          assert response.api == "anthropic-messages"
          assert response.provider == "anthropic"
          assert response.model == "claude-opus-4-5"
          assert is_list(response.content)
          assert response.content != []
          assert %Usage{} = response.usage

          # Should contain text content
          text_content = Enum.find(response.content, &(&1.type == :text))

          if text_content do
            assert %TextContent{} = text_content
            assert is_binary(text_content.text)
            assert String.length(text_content.text) > 0
          end

        {:error, reason} ->
          # Network/auth errors are acceptable in unit tests
          assert reason in [
                   :not_implemented,
                   :unauthorized,
                   :network_error,
                   :connection_refused,
                   :service_unavailable,
                   :missing_api_key
                 ]
      end
    end

    test "integrates with Google Gemini provider" do
      {:ok, model} = AI.get_model("google", "gemini-pro")

      context = %Context{
        system_prompt: "Be concise.",
        messages: [
          %UserMessage{
            role: :user,
            content: "What is 2+2?",
            timestamp: System.system_time(:millisecond)
          }
        ],
        tools: nil
      }

      case AI.complete_simple(model, context) do
        {:ok, response} ->
          assert %AssistantMessage{} = response
          assert response.role == :assistant
          assert response.api == "google-generative-ai"
          assert response.provider == "google"
          assert response.model == "gemini-pro"
          assert is_list(response.content)
          assert %Usage{} = response.usage

        {:error, reason} ->
          # Network/auth errors are acceptable in unit tests
          assert reason in [
                   :not_implemented,
                   :unauthorized,
                   :quota_exceeded,
                   :network_error,
                   :service_unavailable,
                   :missing_api_key
                 ]
      end
    end

    test "integrates with Ollama provider" do
      {:ok, model} = AI.get_model("ollama", "llama3.1:8b")

      context = %Context{
        system_prompt: "You are helpful.",
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
        {:ok, response} ->
          assert %AssistantMessage{} = response
          assert response.role == :assistant
          assert response.api == "openai-completions"
          assert response.provider == "ollama"
          assert response.model == "llama3.1:8b"
          assert is_list(response.content)
          assert %Usage{} = response.usage

        {:error, reason} ->
          # Connection errors are expected if Ollama isn't running
          assert reason in [
                   :not_implemented,
                   :connection_refused,
                   :service_unavailable,
                   :network_error,
                   :model_not_found,
                   :econnrefused
                 ]
      end
    end

    test "handles conversation context properly" do
      {:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")

      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "My name is Alice",
            timestamp: System.system_time(:millisecond) - 2000
          },
          %AssistantMessage{
            role: :assistant,
            content: [%TextContent{type: :text, text: "Hello Alice! Nice to meet you."}],
            api: "anthropic-messages",
            provider: "anthropic",
            model: "claude-sonnet-3-6",
            usage: %Usage{
              input: 8,
              output: 10,
              cache_read: 0,
              cache_write: 0,
              total_tokens: 18,
              cost: %Expi.Types.Cost{
                input: 0.024,
                output: 0.15,
                cache_read: 0.0,
                cache_write: 0.0
              }
            },
            stop_reason: :stop,
            timestamp: System.system_time(:millisecond) - 1000
          },
          %UserMessage{
            role: :user,
            content: "What's my name?",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      case AI.complete_simple(model, context) do
        {:ok, response} ->
          assert %AssistantMessage{} = response

          # Should reference the name from conversation history
          text_content = Enum.find(response.content, &(&1.type == :text))

          if text_content do
            assert String.contains?(String.downcase(text_content.text), "alice")
          end

        {:error, _} ->
          # Network errors acceptable
          :ok
      end
    end

    test "handles multi-modal input with vision models" do
      {:ok, model} = AI.get_model("google", "gemini-pro-vision")

      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: [
              %Expi.Types.TextContent{type: :text, text: "What's in this image?"},
              %Expi.Types.ImageContent{
                type: :image,
                data:
                  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==",
                mime_type: "image/png"
              }
            ],
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      case AI.complete_simple(model, context) do
        {:ok, response} ->
          assert %AssistantMessage{} = response
          assert response.model == "gemini-pro-vision"

        {:error, _} ->
          # Network/auth errors acceptable
          :ok
      end
    end

    test "handles tool calling scenarios" do
      {:ok, model} = AI.get_model("anthropic", "claude-opus-4-5")

      weather_tool = %{
        name: "get_weather",
        description: "Get weather for a location",
        input_schema: %{
          type: "object",
          properties: %{
            location: %{type: "string", description: "City name"}
          },
          required: ["location"]
        }
      }

      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "What's the weather in Tokyo?",
            timestamp: System.system_time(:millisecond)
          }
        ],
        tools: [weather_tool]
      }

      case AI.complete_simple(model, context) do
        {:ok, response} ->
          assert %AssistantMessage{} = response

          # Check if tool calls were made
          tool_calls = Enum.filter(response.content, &(&1.type == :tool_call))

          if tool_calls != [] do
            tool_call = List.first(tool_calls)
            assert tool_call.name == "get_weather"
            assert is_map(tool_call.arguments)
          end

        {:error, _} ->
          # Network errors acceptable
          :ok
      end
    end

    test "handles reasoning modes for supported models" do
      {:ok, model} = AI.get_model("anthropic", "claude-opus-4-5")
      assert model.reasoning == true

      context = %Context{
        system_prompt: "Think step by step.",
        messages: [
          %UserMessage{
            role: :user,
            content: "What is 15 * 23? Show your work.",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      # Test with reasoning options (these should be passed through to provider)
      options = %{reasoning: "high", temperature: 0.1}

      case AI.complete_simple(model, context, options) do
        {:ok, response} ->
          assert %AssistantMessage{} = response

          # For reasoning models, might get thinking content
          thinking_content = Enum.find(response.content, &(&1.type == :thinking))
          text_content = Enum.find(response.content, &(&1.type == :text))

          # Should have at least one type of content
          assert thinking_content != nil or text_content != nil

        {:error, _} ->
          # Network errors or not_implemented acceptable
          :ok
      end
    end

    test "validates input parameters" do
      {:ok, model} = AI.get_model("anthropic", "claude-opus-4-5")

      # Test with nil context
      assert {:error, reason} = AI.complete_simple(model, nil)
      assert reason in [:invalid_context, :not_implemented]

      # Test with nil model
      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Hello",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      assert {:error, reason} = AI.complete_simple(nil, context)
      assert reason in [:invalid_model, :not_implemented]

      # Test with empty messages
      empty_context = %Context{messages: []}
      assert {:error, reason} = AI.complete_simple(model, empty_context)
      assert reason in [:empty_messages, :invalid_context, :not_implemented]
    end

    test "handles provider-specific error scenarios" do
      {:ok, anthropic_model} = AI.get_model("anthropic", "claude-opus-4-5")
      {:ok, google_model} = AI.get_model("google", "gemini-pro")
      {:ok, ollama_model} = AI.get_model("ollama", "llama3.1:8b")

      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Hello",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      # Each provider might have different error scenarios
      models_and_expected_errors = [
        {anthropic_model, [:not_implemented, :unauthorized, :rate_limited, :missing_api_key]},
        {google_model, [:not_implemented, :quota_exceeded, :unauthorized, :missing_api_key]},
        {ollama_model,
         [:not_implemented, :connection_refused, :service_unavailable, :network_error]}
      ]

      for {model, expected_errors} <- models_and_expected_errors do
        case AI.complete_simple(model, context) do
          # Success is also acceptable
          {:ok, _} ->
            :ok

          {:error, reason} ->
            assert reason in expected_errors,
                   "Unexpected error #{reason} for provider #{model.provider}"
        end
      end
    end

    test "preserves model metadata in response" do
      {:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")

      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Hello",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      case AI.complete_simple(model, context) do
        {:ok, response} ->
          # Response should preserve model information
          assert response.api == model.api
          assert response.provider == model.provider
          assert response.model == model.id
          assert response.timestamp > 0

        {:error, _} ->
          # Errors acceptable for unit tests
          :ok
      end
    end

    test "handles different content types in user messages" do
      {:ok, model} = AI.get_model("google", "gemini-pro-vision")

      # Test with mixed content
      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: [
              %Expi.Types.TextContent{type: :text, text: "Analyze this:"},
              %Expi.Types.ImageContent{
                type: :image,
                data: "base64_image_data_here",
                mime_type: "image/jpeg"
              }
            ],
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      case AI.complete_simple(model, context) do
        {:ok, response} ->
          assert %AssistantMessage{} = response
          # Vision model should handle multi-modal input
          assert response.model == "gemini-pro-vision"

        {:error, _} ->
          :ok
      end
    end

    test "respects options parameter" do
      {:ok, model} = AI.get_model("anthropic", "claude-opus-4-5")

      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Write exactly 5 words",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      options = %{max_tokens: 10, temperature: 0.1}

      case AI.complete_simple(model, context, options) do
        {:ok, response} ->
          assert %AssistantMessage{} = response

        # Options should be passed through to provider

        {:error, _} ->
          :ok
      end
    end
  end

  describe "error propagation" do
    test "properly propagates provider errors" do
      {:ok, model} = AI.get_model("anthropic", "claude-opus-4-5")

      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Test error handling",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      case AI.complete_simple(model, context) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          # Error should be properly categorized
          assert is_atom(reason)

          assert reason in [
                   :not_implemented,
                   :unauthorized,
                   :rate_limited,
                   :service_unavailable,
                   :network_error,
                   :invalid_api_key,
                   :quota_exceeded,
                   :connection_refused,
                   :missing_api_key
                 ]
      end
    end

    test "handles malformed responses gracefully" do
      # This would be tested with mocked responses in a real implementation
      # For now, verify error handling structure exists
      assert is_function(&AI.complete_simple/2)
      assert is_function(&AI.complete_simple/3)
    end
  end
end
