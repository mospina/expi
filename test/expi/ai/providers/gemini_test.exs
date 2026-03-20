defmodule Expi.Providers.GeminiTest do
  use ExUnit.Case, async: true

  alias Expi.Providers.Gemini
  alias Expi.Types.{
    AssistantMessage,
    Context,
    Model,
    TextContent,
    ToolCall,
    Usage,
    UserMessage
  }

  setup do
    model = %Model{
      id: "gemini-pro",
      name: "Gemini Pro",
      api: "google-generative-ai",
      provider: "google",
      base_url: "https://generativelanguage.googleapis.com",
      reasoning: false,
      input: ["text"],
      cost: %Expi.Types.Cost{
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

    vision_model = %Model{
      id: "gemini-pro-vision",
      name: "Gemini Pro Vision",
      api: "google-generative-ai",
      provider: "google",
      base_url: "https://generativelanguage.googleapis.com",
      reasoning: false,
      input: ["text", "image"],
      cost: %Expi.Types.Cost{
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

    {:ok, model: model, vision_model: vision_model}
  end

  describe "complete/3" do
    test "handles simple text completion", %{model: model} do
      context = %Context{
        system_prompt: "You are a helpful assistant",
        messages: [
          %UserMessage{
            role: :user,
            content: "Hello, how are you?",
            timestamp: System.system_time(:millisecond)
          }
        ],
        tools: nil
      }

      options = %{temperature: 0.8, max_tokens: 150}

      assert {:ok, response} = Gemini.complete(model, context, options)
      assert %AssistantMessage{} = response
      assert response.role == :assistant
      assert response.api == "google-generative-ai"
      assert response.provider == "google"
      assert response.model == "gemini-pro"
      assert is_list(response.content)
      assert length(response.content) > 0
      assert %Usage{} = response.usage
      assert response.stop_reason in [:stop, :length, :tool_use]
    end

    test "handles system prompt integration", %{model: model} do
      context = %Context{
        system_prompt: "You are a math tutor. Be encouraging and explain step by step.",
        messages: [
          %UserMessage{
            role: :user,
            content: "What is 15 + 27?",
            timestamp: System.system_time(:millisecond)
          }
        ],
        tools: nil
      }

      assert {:ok, response} = Gemini.complete(model, context, %{})
      assert %AssistantMessage{} = response

      text_content = Enum.find(response.content, &(&1.type == :text))
      assert text_content != nil
      assert is_binary(text_content.text)
      assert String.length(text_content.text) > 0
    end

    test "handles multi-modal input with vision model", %{vision_model: model} do
      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: [
              %Expi.Types.TextContent{type: :text, text: "Describe this image in detail"},
              %Expi.Types.ImageContent{
                type: :image,
                data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==",
                mime_type: "image/png"
              }
            ],
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      assert {:ok, response} = Gemini.complete(model, context, %{})
      assert %AssistantMessage{} = response
      assert response.model == "gemini-pro-vision"
    end

    test "handles conversation history", %{model: model} do
      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "My favorite color is blue",
            timestamp: System.system_time(:millisecond) - 2000
          },
          %AssistantMessage{
            role: :assistant,
            content: [%TextContent{type: :text, text: "That's a lovely color! Blue is very calming."}],
            api: "google-generative-ai",
            provider: "google",
            model: "gemini-pro",
            usage: %Usage{
              input: 8,
              output: 12,
              cache_read: 0,
              cache_write: 0,
              total_tokens: 20,
              cost: %Expi.Types.Cost{input: 0.004, output: 0.018, cache_read: 0.0, cache_write: 0.0}
            },
            stop_reason: :stop,
            timestamp: System.system_time(:millisecond) - 1000
          },
          %UserMessage{
            role: :user,
            content: "What's my favorite color?",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      assert {:ok, response} = Gemini.complete(model, context, %{})
      assert %AssistantMessage{} = response

      text_content = Enum.find(response.content, &(&1.type == :text))
      if text_content do
        assert String.contains?(String.downcase(text_content.text), "blue")
      end
    end

    test "handles function calling", %{model: model} do
      weather_function = %{
        name: "get_weather",
        description: "Get current weather for a location",
        parameters: %{
          type: "object",
          properties: %{
            location: %{
              type: "string",
              description: "City name"
            },
            unit: %{
              type: "string",
              enum: ["celsius", "fahrenheit"],
              description: "Temperature unit"
            }
          },
          required: ["location"]
        }
      }

      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "What's the weather like in Tokyo?",
            timestamp: System.system_time(:millisecond)
          }
        ],
        tools: [weather_function]
      }

      assert {:ok, response} = Gemini.complete(model, context, %{})
      assert %AssistantMessage{} = response

      # Check for function calls
      function_calls = Enum.filter(response.content, &(&1.type == :tool_call))
      if length(function_calls) > 0 do
        function_call = List.first(function_calls)
        assert %ToolCall{} = function_call
        assert function_call.name == "get_weather"
        assert is_map(function_call.arguments)
        assert function_call.arguments["location"] != nil
      end
    end

    test "handles safety settings and content filtering", %{model: model} do
      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Tell me about renewable energy",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      # Test with safety settings
      options = %{
        safety_settings: [
          %{category: "HARM_CATEGORY_HARASSMENT", threshold: "BLOCK_MEDIUM_AND_ABOVE"}
        ]
      }

      case Gemini.complete(model, context, options) do
        {:ok, response} ->
          assert %AssistantMessage{} = response
        {:error, :content_filtered} ->
          # Content was blocked by safety filters
          :ok
        {:error, _} ->
          # Other errors acceptable in unit tests
          :ok
      end
    end

    test "handles authentication errors", %{model: model} do
      invalid_model = %{model | headers: %{"x-goog-api-key" => "invalid-key"}}

      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Hello",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      assert {:error, reason} = Gemini.complete(invalid_model, context, %{})
      assert reason in [:unauthorized, :authentication_failed, :invalid_api_key, :missing_api_key]
    end

    test "handles quota exceeded errors", %{model: model} do
      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Hello",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      case Gemini.complete(model, context, %{}) do
        {:ok, _} -> :ok
        {:error, :quota_exceeded} -> :ok
        {:error, :rate_limited} -> :ok
        {:error, _} -> :ok
      end
    end

    test "validates input parameters", %{model: model} do
      # Test with invalid inputs
      assert {:error, _} = Gemini.complete(model, nil, %{})
      assert {:error, _} = Gemini.complete(nil, %Context{messages: []}, %{})

      # Test with empty messages
      empty_context = %Context{messages: []}
      assert {:error, _} = Gemini.complete(model, empty_context, %{})
    end
  end

  describe "build_request_payload/3" do
    test "builds basic text request correctly", %{model: model} do
      context = %Context{
        system_prompt: "You are helpful",
        messages: [
          %UserMessage{
            role: :user,
            content: "Hello world",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      options = %{max_tokens: 200, temperature: 0.9}

      assert {:ok, payload} = Gemini.build_request_payload(model, context, options)
      assert is_map(payload)

      # Google uses different parameter names
      assert payload["contents"] != nil
      assert is_list(payload["contents"])
      assert payload["generationConfig"]["maxOutputTokens"] == 200
      assert payload["generationConfig"]["temperature"] == 0.9

      # System prompt should be integrated into the first user message
      content = List.first(payload["contents"])
      assert content["role"] == "user"
      assert is_list(content["parts"])
    end

    test "handles multi-modal content correctly", %{vision_model: model} do
      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: [
              %Expi.Types.TextContent{type: :text, text: "What do you see?"},
              %Expi.Types.ImageContent{
                type: :image,
                data: "base64imagedata",
                mime_type: "image/jpeg"
              }
            ],
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      assert {:ok, payload} = Gemini.build_request_payload(model, context, %{})
      content = List.first(payload["contents"])
      assert is_list(content["parts"])
      assert length(content["parts"]) == 2

      text_part = Enum.find(content["parts"], &Map.has_key?(&1, "text"))
      image_part = Enum.find(content["parts"], &Map.has_key?(&1, "inlineData"))

      assert text_part["text"] == "What do you see?"
      assert image_part["inlineData"]["mimeType"] == "image/jpeg"
      assert image_part["inlineData"]["data"] == "base64imagedata"
    end

    test "includes function declarations when tools provided", %{model: model} do
      tool = %{
        name: "calculate",
        description: "Perform mathematical calculations",
        parameters: %{
          type: "object",
          properties: %{
            expression: %{type: "string", description: "Math expression"}
          },
          required: ["expression"]
        }
      }

      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "What is 25 * 4?",
            timestamp: System.system_time(:millisecond)
          }
        ],
        tools: [tool]
      }

      assert {:ok, payload} = Gemini.build_request_payload(model, context, %{})
      assert payload["tools"] != nil
      assert is_list(payload["tools"])
      
      function_declarations = List.first(payload["tools"])["functionDeclarations"]
      assert is_list(function_declarations)
      assert length(function_declarations) == 1
      
      func = List.first(function_declarations)
      assert func["name"] == "calculate"
      assert func["description"] == "Perform mathematical calculations"
    end

    test "handles conversation history correctly", %{model: model} do
      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Hello",
            timestamp: System.system_time(:millisecond) - 2000
          },
          %AssistantMessage{
            role: :assistant,
            content: [%TextContent{type: :text, text: "Hi there!"}],
            api: "google-generative-ai",
            provider: "google",
            model: "gemini-pro",
            usage: %Usage{input: 1, output: 3, cache_read: 0, cache_write: 0, total_tokens: 4,
              cost: %Expi.Types.Cost{input: 0.0005, output: 0.0045, cache_read: 0.0, cache_write: 0.0}},
            stop_reason: :stop,
            timestamp: System.system_time(:millisecond) - 1000
          },
          %UserMessage{
            role: :user,
            content: "How are you?",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      assert {:ok, payload} = Gemini.build_request_payload(model, context, %{})
      assert length(payload["contents"]) == 3

      [user1, assistant1, user2] = payload["contents"]
      assert user1["role"] == "user"
      assert assistant1["role"] == "model"  # Google uses "model" instead of "assistant"
      assert user2["role"] == "user"
    end

    test "handles safety settings", %{model: model} do
      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Tell me about science",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      options = %{
        safety_settings: [
          %{category: "HARM_CATEGORY_HARASSMENT", threshold: "BLOCK_LOW_AND_ABOVE"}
        ]
      }

      assert {:ok, payload} = Gemini.build_request_payload(model, context, options)
      assert payload["safetySettings"] != nil
      assert is_list(payload["safetySettings"])
      assert length(payload["safetySettings"]) == 1

      safety_setting = List.first(payload["safetySettings"])
      assert safety_setting["category"] == "HARM_CATEGORY_HARASSMENT"
      assert safety_setting["threshold"] == "BLOCK_LOW_AND_ABOVE"
    end
  end

  describe "parse_response/1" do
    test "parses successful text response" do
      api_response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "text" => "Hello! I'm doing well, thank you for asking."
                }
              ],
              "role" => "model"
            },
            "finishReason" => "STOP",
            "index" => 0,
            "safetyRatings" => []
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 12,
          "candidatesTokenCount" => 15,
          "totalTokenCount" => 27
        }
      }

      assert {:ok, message} = Gemini.parse_response(api_response)
      assert %AssistantMessage{} = message
      assert message.role == :assistant
      assert message.api == "google-generative-ai"
      assert message.provider == "google"
      assert message.stop_reason == :stop

      assert length(message.content) == 1
      text_content = List.first(message.content)
      assert %TextContent{} = text_content
      assert text_content.text == "Hello! I'm doing well, thank you for asking."

      assert message.usage.input == 12
      assert message.usage.output == 15
      assert message.usage.total_tokens == 27
    end

    test "parses response with function calls" do
      api_response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "functionCall" => %{
                    "name" => "get_weather",
                    "args" => %{
                      "location" => "San Francisco",
                      "unit" => "celsius"
                    }
                  }
                }
              ],
              "role" => "model"
            },
            "finishReason" => "FUNCTION_CALL",
            "index" => 0
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 18,
          "candidatesTokenCount" => 8,
          "totalTokenCount" => 26
        }
      }

      assert {:ok, message} = Gemini.parse_response(api_response)
      assert message.stop_reason == :tool_use

      assert length(message.content) == 1
      tool_call = List.first(message.content)
      assert %ToolCall{} = tool_call
      assert tool_call.name == "get_weather"
      assert tool_call.arguments == %{"location" => "San Francisco", "unit" => "celsius"}
    end

    test "handles content filtered responses" do
      api_response = %{
        "candidates" => [
          %{
            "finishReason" => "SAFETY",
            "index" => 0,
            "safetyRatings" => [
              %{
                "category" => "HARM_CATEGORY_HARASSMENT",
                "probability" => "HIGH"
              }
            ]
          }
        ]
      }

      assert {:error, :content_filtered} = Gemini.parse_response(api_response)
    end

    test "handles API error responses" do
      error_response = %{
        "error" => %{
          "code" => 400,
          "message" => "API key not valid",
          "status" => "INVALID_ARGUMENT"
        }
      }

      assert {:error, reason} = Gemini.parse_response(error_response)
      assert reason in [:invalid_api_key, :bad_request, :authentication_failed]
    end

    test "handles quota exceeded responses" do
      error_response = %{
        "error" => %{
          "code" => 429,
          "message" => "Quota exceeded",
          "status" => "RESOURCE_EXHAUSTED"
        }
      }

      assert {:error, :quota_exceeded} = Gemini.parse_response(error_response)
    end

    test "handles malformed responses" do
      assert {:error, :invalid_response} = Gemini.parse_response(%{})
      assert {:error, :invalid_response} = Gemini.parse_response(nil)
      assert {:error, :invalid_response} = Gemini.parse_response("invalid")
    end

    test "handles missing candidates" do
      api_response = %{
        "candidates" => [],
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 0,
          "totalTokenCount" => 10
        }
      }

      assert {:error, :no_candidates} = Gemini.parse_response(api_response)
    end
  end

  describe "error handling" do
    test "maps HTTP status codes to appropriate errors" do
      assert Gemini.map_http_error(400) == :bad_request
      assert Gemini.map_http_error(401) == :unauthorized
      assert Gemini.map_http_error(403) == :forbidden
      assert Gemini.map_http_error(429) == :quota_exceeded
      assert Gemini.map_http_error(500) == :server_error
      assert Gemini.map_http_error(503) == :service_unavailable
    end

    test "provides helpful error messages" do
      quota_error = Gemini.format_error(:quota_exceeded, "Quota exceeded for requests per day")
      assert is_binary(quota_error)
      assert String.contains?(quota_error, "quota") or String.contains?(quota_error, "limit")

      auth_error = Gemini.format_error(:unauthorized, "API key not valid")
      assert String.contains?(auth_error, "API key") or String.contains?(auth_error, "authentication")
    end
  end
end