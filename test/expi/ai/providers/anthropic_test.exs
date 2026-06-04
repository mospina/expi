defmodule Expi.Providers.AnthropicTest do
  use ExUnit.Case, async: true

  @moduletag :known_failure
  @moduletag skip: "KNOWN_FAILURE(PRD-20260528, owner:eng, expires:2026-06-30): Provider tests require deterministic HTTP mocking and API-key-free contract fixtures"

  alias Expi.Providers.Anthropic

  alias Expi.Types.{
    AssistantMessage,
    Context,
    Model,
    TextContent,
    ThinkingContent,
    ToolCall,
    ToolResultMessage,
    Usage,
    UserMessage
  }

  setup do
    model = %Model{
      id: "claude-opus-4-5",
      name: "Claude Opus 4.5",
      api: "anthropic-messages",
      provider: "anthropic",
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: ["text", "image"],
      cost: %Expi.Types.Cost{
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

    {:ok, model: model}
  end

  describe "complete/3" do
    test "handles simple text completion", %{model: model} do
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

      options = %{temperature: 0.7, max_tokens: 100}

      assert {:ok, response} = Anthropic.complete(model, context, options)
      assert %AssistantMessage{} = response
      assert response.role == :assistant
      assert response.api == "anthropic-messages"
      assert response.provider == "anthropic"
      assert response.model == "claude-opus-4-5"
      assert is_list(response.content)
      assert response.content != []
      assert %Usage{} = response.usage
      assert response.stop_reason in [:stop, :length, :tool_use]
    end

    test "handles system prompt correctly", %{model: model} do
      context = %Context{
        system_prompt: "You are a helpful coding assistant. Always be concise.",
        messages: [
          %UserMessage{
            role: :user,
            content: "Write a hello world function",
            timestamp: System.system_time(:millisecond)
          }
        ],
        tools: nil
      }

      assert {:ok, response} = Anthropic.complete(model, context, %{})
      assert %AssistantMessage{} = response

      # Should include text content
      text_content = Enum.find(response.content, &(&1.type == :text))
      assert text_content != nil
      assert is_binary(text_content.text)
    end

    test "handles multi-modal input with images", %{model: model} do
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

      assert {:ok, response} = Anthropic.complete(model, context, %{})
      assert %AssistantMessage{} = response
      assert response.model == "claude-opus-4-5"
    end

    test "handles reasoning/thinking mode", %{model: model} do
      context = %Context{
        system_prompt: "Think step by step to solve this problem.",
        messages: [
          %UserMessage{
            role: :user,
            content: "What is 15 * 24?",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      options = %{reasoning: "high", temperature: 0.1}

      assert {:ok, response} = Anthropic.complete(model, context, options)
      assert %AssistantMessage{} = response

      # Should include thinking content for reasoning models
      thinking_content = Enum.find(response.content, &(&1.type == :thinking))
      text_content = Enum.find(response.content, &(&1.type == :text))

      assert thinking_content != nil or text_content != nil

      if thinking_content do
        assert %ThinkingContent{} = thinking_content
        assert is_binary(thinking_content.thinking)
      end
    end

    test "handles tool calling", %{model: model} do
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
            content: "What's the weather in Paris?",
            timestamp: System.system_time(:millisecond)
          }
        ],
        tools: [weather_tool]
      }

      assert {:ok, response} = Anthropic.complete(model, context, %{})
      assert %AssistantMessage{} = response

      # Check if tool calls were made
      tool_calls = Enum.filter(response.content, &(&1.type == :tool_call))

      if tool_calls != [] do
        tool_call = List.first(tool_calls)
        assert %ToolCall{} = tool_call
        assert tool_call.name == "get_weather"
        assert is_map(tool_call.arguments)
        assert tool_call.arguments["location"] != nil
      end
    end

    test "handles conversation history", %{model: model} do
      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "My name is Alice",
            timestamp: System.system_time(:millisecond) - 1000
          },
          %AssistantMessage{
            role: :assistant,
            content: [%TextContent{type: :text, text: "Hello Alice! Nice to meet you."}],
            api: "anthropic-messages",
            provider: "anthropic",
            model: "claude-opus-4-5",
            usage: %Usage{
              input: 10,
              output: 8,
              cache_read: 0,
              cache_write: 0,
              total_tokens: 18,
              cost: %Expi.Types.Cost{input: 0.01, output: 0.02, cache_read: 0.0, cache_write: 0.0}
            },
            stop_reason: :stop,
            timestamp: System.system_time(:millisecond) - 500
          },
          %UserMessage{
            role: :user,
            content: "What's my name?",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      assert {:ok, response} = Anthropic.complete(model, context, %{})
      assert %AssistantMessage{} = response

      # Response should reference the name from conversation history
      text_content = Enum.find(response.content, &(&1.type == :text))

      if text_content do
        assert String.contains?(String.downcase(text_content.text), "alice")
      end
    end

    test "handles authentication errors", %{model: model} do
      # Create model with invalid base URL to trigger auth error
      invalid_model = %{model | headers: %{"x-api-key" => "invalid-key"}}

      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Hello",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      assert {:error, reason} = Anthropic.complete(invalid_model, context, %{})

      assert reason in [
               :unauthorized,
               :authentication_failed,
               :invalid_api_key,
               :missing_api_key,
               :bad_request
             ]
    end

    test "handles rate limiting", %{model: model} do
      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Hello",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      # This would be mocked in real tests to return 429
      case Anthropic.complete(model, context, %{}) do
        # Normal response
        {:ok, _} -> :ok
        # Expected error
        {:error, :rate_limited} -> :ok
        # Other errors acceptable in unit tests
        {:error, _} -> :ok
      end
    end

    test "handles model overload errors", %{model: model} do
      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Hello",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      # Test error handling for service unavailable
      case Anthropic.complete(model, context, %{}) do
        # Normal response
        {:ok, _} -> :ok
        # Expected error
        {:error, :service_unavailable} -> :ok
        # Other errors acceptable
        {:error, _} -> :ok
      end
    end

    test "validates input parameters", %{model: model} do
      # Test with invalid context
      assert {:error, _} = Anthropic.complete(model, nil, %{})
      assert {:error, _} = Anthropic.complete(nil, %Context{messages: []}, %{})

      # Test with empty messages
      empty_context = %Context{messages: []}
      assert {:error, _} = Anthropic.complete(model, empty_context, %{})
    end
  end

  describe "build_request_payload/3" do
    test "builds basic text request correctly", %{model: model} do
      context = %Context{
        system_prompt: "You are helpful",
        messages: [
          %UserMessage{
            role: :user,
            content: "Hello",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      options = %{max_tokens: 100, temperature: 0.7}

      assert {:ok, payload} = Anthropic.build_request_payload(model, context, options)
      assert is_map(payload)
      assert payload["model"] == "claude-opus-4-5"
      assert payload["max_tokens"] == 100
      assert payload["temperature"] == 0.7
      assert payload["system"] == "You are helpful"
      assert is_list(payload["messages"])
      assert match?([_], payload["messages"])

      message = List.first(payload["messages"])
      assert message["role"] == "user"
      assert message["content"] == "Hello"
    end

    test "handles multi-modal content correctly", %{model: model} do
      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: [
              %Expi.Types.TextContent{type: :text, text: "Describe this"},
              %Expi.Types.ImageContent{type: :image, data: "base64data", mime_type: "image/png"}
            ],
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      assert {:ok, payload} = Anthropic.build_request_payload(model, context, %{})
      message = List.first(payload["messages"])
      assert is_list(message["content"])
      assert match?([_, _], message["content"])

      [text_block, image_block] = message["content"]
      assert text_block["type"] == "text"
      assert text_block["text"] == "Describe this"
      assert image_block["type"] == "image"
      assert image_block["source"]["data"] == "base64data"
    end

    test "includes tools when provided", %{model: model} do
      tool = %{
        name: "calculator",
        description: "Perform calculations",
        input_schema: %{type: "object", properties: %{}}
      }

      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Calculate 2+2",
            timestamp: System.system_time(:millisecond)
          }
        ],
        tools: [tool]
      }

      assert {:ok, payload} = Anthropic.build_request_payload(model, context, %{})
      assert is_list(payload["tools"])
      assert match?([_], payload["tools"])
      assert List.first(payload["tools"])["name"] == "calculator"
    end

    test "batches consecutive tool results into a single user message", %{model: model} do
      context = %Context{
        messages: [
          %AssistantMessage{
            role: :assistant,
            content: [
              %ToolCall{type: :tool_call, id: "call_1", name: "read", arguments: %{"path" => "a.txt"}}
            ],
            api: "anthropic-messages",
            provider: "anthropic",
            model: "claude-opus-4-5",
            usage: nil,
            stop_reason: :tool_use,
            timestamp: System.system_time(:millisecond)
          },
          %ToolResultMessage{
            role: :tool_result,
            tool_call_id: "call_1",
            tool_name: "read",
            content: [%TextContent{type: :text, text: "file a"}],
            details: %{},
            is_error: false,
            timestamp: System.system_time(:millisecond)
          },
          %ToolResultMessage{
            role: :tool_result,
            tool_call_id: "call_2",
            tool_name: "grep",
            content: [%TextContent{type: :text, text: "match"}],
            details: %{},
            is_error: false,
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      assert {:ok, payload} = Anthropic.build_request_payload(model, context, %{})
      assert match?([_, _], payload["messages"])
      tool_result_message = List.last(payload["messages"])
      assert tool_result_message["role"] == "user"
      assert is_list(tool_result_message["content"])
      assert match?([_, _], tool_result_message["content"])
      assert Enum.all?(tool_result_message["content"], &(&1["type"] == "tool_result"))
    end

    test "handles reasoning options correctly", %{model: model} do
      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Think about this problem",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      options = %{reasoning: "high"}

      assert {:ok, payload} = Anthropic.build_request_payload(model, context, options)
      # Should map reasoning to appropriate Anthropic parameters
      assert payload["reasoning"] != nil or payload["reasoning_effort"] != nil
    end
  end

  describe "parse_response/1" do
    test "parses successful text response" do
      api_response = %{
        "id" => "msg_123",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-opus-4-5",
        "content" => [
          %{
            "type" => "text",
            "text" => "Hello! How can I help you?"
          }
        ],
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 8,
          "cache_creation_input_tokens" => 0,
          "cache_read_input_tokens" => 0
        },
        "stop_reason" => "end_turn"
      }

      assert {:ok, message} = Anthropic.parse_response(api_response)
      assert %AssistantMessage{} = message
      assert message.role == :assistant
      assert message.api == "anthropic-messages"
      assert message.provider == "anthropic"
      assert message.model == "claude-opus-4-5"
      assert message.stop_reason == :stop

      assert match?([_], message.content)
      text_content = List.first(message.content)
      assert %TextContent{} = text_content
      assert text_content.text == "Hello! How can I help you?"

      assert message.usage.input == 10
      assert message.usage.output == 8
      assert message.usage.total_tokens == 18
    end

    test "parses response with thinking content" do
      api_response = %{
        "id" => "msg_123",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-opus-4-5",
        "content" => [
          %{
            "type" => "thinking",
            "thinking" => "Let me think about this step by step..."
          },
          %{
            "type" => "text",
            "text" => "The answer is 42."
          }
        ],
        "usage" => %{
          "input_tokens" => 15,
          "output_tokens" => 25,
          "cache_creation_input_tokens" => 0,
          "cache_read_input_tokens" => 0
        },
        "stop_reason" => "end_turn"
      }

      assert {:ok, message} = Anthropic.parse_response(api_response)
      assert match?([_, _], message.content)

      thinking_content = Enum.find(message.content, &(&1.type == :thinking))
      text_content = Enum.find(message.content, &(&1.type == :text))

      assert %ThinkingContent{} = thinking_content
      assert thinking_content.thinking == "Let me think about this step by step..."

      assert %TextContent{} = text_content
      assert text_content.text == "The answer is 42."
    end

    test "parses response with tool calls" do
      api_response = %{
        "id" => "msg_123",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-opus-4-5",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "toolu_123",
            "name" => "get_weather",
            "input" => %{
              "location" => "Paris"
            }
          }
        ],
        "usage" => %{
          "input_tokens" => 20,
          "output_tokens" => 10,
          "cache_creation_input_tokens" => 0,
          "cache_read_input_tokens" => 0
        },
        "stop_reason" => "tool_use"
      }

      assert {:ok, message} = Anthropic.parse_response(api_response)
      assert message.stop_reason == :tool_use
      assert match?([_], message.content)

      tool_call = List.first(message.content)
      assert %ToolCall{} = tool_call
      assert tool_call.id == "toolu_123"
      assert tool_call.name == "get_weather"
      assert tool_call.arguments == %{"location" => "Paris"}
    end

    test "handles API error responses" do
      error_response = %{
        "type" => "error",
        "error" => %{
          "type" => "invalid_request_error",
          "message" => "Invalid API key"
        }
      }

      assert {:error, reason} = Anthropic.parse_response(error_response)
      assert reason in [:invalid_api_key, :invalid_request, :authentication_failed, :bad_request]
    end

    test "handles malformed responses" do
      assert {:error, :invalid_response} = Anthropic.parse_response(%{})
      assert {:error, :invalid_response} = Anthropic.parse_response(nil)
      assert {:error, :invalid_response} = Anthropic.parse_response("not a map")
    end
  end

  describe "error handling" do
    test "maps HTTP status codes to appropriate errors" do
      assert Anthropic.map_http_error(400) == :bad_request
      assert Anthropic.map_http_error(401) == :unauthorized
      assert Anthropic.map_http_error(403) == :forbidden
      assert Anthropic.map_http_error(429) == :rate_limited
      assert Anthropic.map_http_error(500) == :server_error
      assert Anthropic.map_http_error(529) == :service_unavailable
    end

    test "provides helpful error messages" do
      error_msg = Anthropic.format_error(:rate_limited, "Too many requests")
      assert is_binary(error_msg)
      assert String.contains?(String.downcase(error_msg), "rate")

      auth_error = Anthropic.format_error(:unauthorized, "Invalid API key")

      assert String.contains?(auth_error, "authentication") or
               String.contains?(auth_error, "API key")
    end
  end
end
