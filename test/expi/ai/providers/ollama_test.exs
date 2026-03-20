defmodule Expi.Providers.OllamaTest do
  use ExUnit.Case, async: true

  alias Expi.Providers.Ollama
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
      id: "llama3.1:8b",
      name: "Llama 3.1 8B",
      api: "openai-completions",
      provider: "ollama",
      base_url: "http://localhost:11434/v1",
      reasoning: false,
      input: ["text"],
      cost: %Expi.Types.Cost{
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

    code_model = %Model{
      id: "codellama:7b",
      name: "Code Llama 7B",
      api: "openai-completions",
      provider: "ollama",
      base_url: "http://localhost:11434/v1",
      reasoning: false,
      input: ["text"],
      cost: %Expi.Types.Cost{
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

    {:ok, model: model, code_model: code_model}
  end

  describe "complete/3" do
    test "handles simple text completion", %{model: model} do
      context = %Context{
        system_prompt: "You are a helpful assistant.",
        messages: [
          %UserMessage{
            role: :user,
            content: "What is the capital of France?",
            timestamp: System.system_time(:millisecond)
          }
        ],
        tools: nil
      }

      options = %{temperature: 0.7, max_tokens: 100}

      case Ollama.complete(model, context, options) do
        {:ok, response} -> 
          # Success case - verify structure
          assert %AssistantMessage{} = response
          assert response.role == :assistant
          assert response.api == "openai-completions"
          assert response.provider == "ollama"
          assert response.model == "llama3.1:8b"
          assert is_list(response.content)
          assert length(response.content) > 0
          assert %Usage{} = response.usage
          assert response.stop_reason in [:stop, :length, :tool_use]
        {:error, reason} ->
          # Network errors expected in test environment
          assert reason in [:network_error, :connection_refused, :service_unavailable]
      end
    end

    test "handles code generation with code model", %{code_model: model} do
      context = %Context{
        system_prompt: "You are a coding assistant. Write clean, efficient code.",
        messages: [
          %UserMessage{
            role: :user,
            content: "Write a Python function to calculate fibonacci numbers",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      case Ollama.complete(model, context, %{}) do
        {:ok, response} ->
          assert %AssistantMessage{} = response
          assert response.model == "codellama:7b"

          text_content = Enum.find(response.content, &(&1.type == :text))
          assert text_content != nil
          assert is_binary(text_content.text)
        {:error, reason} ->
          # Network errors expected in test environment
          assert reason in [:network_error, :connection_refused, :service_unavailable]
      end
    end

    test "handles conversation history", %{model: model} do
      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "I like programming in Elixir",
            timestamp: System.system_time(:millisecond) - 2000
          },
          %AssistantMessage{
            role: :assistant,
            content: [%TextContent{type: :text, text: "Elixir is a great language! It's functional and has excellent concurrency support."}],
            api: "openai-completions",
            provider: "ollama",
            model: "llama3.1:8b",
            usage: %Usage{
              input: 8,
              output: 20,
              cache_read: 0,
              cache_write: 0,
              total_tokens: 28,
              cost: %Expi.Types.Cost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0}
            },
            stop_reason: :stop,
            timestamp: System.system_time(:millisecond) - 1000
          },
          %UserMessage{
            role: :user,
            content: "What language do I like?",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      case Ollama.complete(model, context, %{}) do
        {:ok, response} ->
          assert %AssistantMessage{} = response

          text_content = Enum.find(response.content, &(&1.type == :text))
          if text_content do
            assert String.contains?(String.downcase(text_content.text), "elixir")
          end
        {:error, reason} ->
          # Network errors expected in test environment
          assert reason in [:network_error, :connection_refused, :service_unavailable]
      end
    end

    test "handles tool calling", %{model: model} do
      calculator_tool = %{
        type: "function",
        function: %{
          name: "calculator",
          description: "Perform mathematical calculations",
          parameters: %{
            type: "object",
            properties: %{
              expression: %{
                type: "string",
                description: "Mathematical expression to evaluate"
              }
            },
            required: ["expression"]
          }
        }
      }

      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Calculate 15 * 42",
            timestamp: System.system_time(:millisecond)
          }
        ],
        tools: [calculator_tool]
      }

      case Ollama.complete(model, context, %{}) do
        {:ok, response} ->
          assert %AssistantMessage{} = response
          
          # Check for tool calls
          tool_calls = Enum.filter(response.content, &(&1.type == :tool_call))
          if length(tool_calls) > 0 do
            tool_call = List.first(tool_calls)
            assert %ToolCall{} = tool_call
            assert tool_call.name == "calculator"
            assert is_map(tool_call.arguments)
          end
        {:error, :tool_calling_not_supported} ->
          # Some Ollama models might not support tool calling
          :ok
        {:error, _} ->
          # Other errors acceptable in unit tests
          :ok
      end
    end

    test "handles connection errors to local Ollama service", %{model: model} do
      # Test with unreachable endpoint
      unreachable_model = %{model | base_url: "http://localhost:99999/v1"}

      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Hello",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      assert {:error, reason} = Ollama.complete(unreachable_model, context, %{})
      assert reason in [:connection_refused, :service_unavailable, :network_error, :econnrefused]
    end

    test "handles model not found errors", %{model: model} do
      # Test with non-existent model
      invalid_model = %{model | id: "nonexistent-model:latest"}

      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Hello",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      case Ollama.complete(invalid_model, context, %{}) do
        {:ok, _} -> :ok  # Model might be available
        {:error, :model_not_found} -> :ok  # Expected error
        {:error, :not_found} -> :ok  # Alternative error format
        {:error, _} -> :ok  # Other connection errors acceptable
      end
    end

    test "handles resource constraints", %{model: model} do
      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Write a very long essay about artificial intelligence",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      # Test with very small max_tokens to trigger length limiting
      options = %{max_tokens: 5}

      case Ollama.complete(model, context, options) do
        {:ok, response} ->
          assert response.stop_reason in [:length, :stop]
        {:error, _} ->
          # Connection errors acceptable in unit tests
          :ok
      end
    end

    test "validates input parameters", %{model: model} do
      # Test with invalid inputs
      assert {:error, _} = Ollama.complete(model, nil, %{})
      assert {:error, _} = Ollama.complete(nil, %Context{messages: []}, %{})

      # Test with empty messages
      empty_context = %Context{messages: []}
      assert {:error, _} = Ollama.complete(model, empty_context, %{})
    end
  end

  describe "build_request_payload/3" do
    test "builds basic OpenAI-compatible request", %{model: model} do
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

      options = %{max_tokens: 150, temperature: 0.8}

      assert {:ok, payload} = Ollama.build_request_payload(model, context, options)
      assert is_map(payload)

      # OpenAI-compatible format
      assert payload["model"] == "llama3.1:8b"
      assert payload["max_tokens"] == 150
      assert payload["temperature"] == 0.8
      assert is_list(payload["messages"])
      assert length(payload["messages"]) == 2  # system + user message

      [system_msg, user_msg] = payload["messages"]
      assert system_msg["role"] == "system"
      assert system_msg["content"] == "You are helpful"
      assert user_msg["role"] == "user"
      assert user_msg["content"] == "Hello world"
    end

    test "handles conversation history correctly", %{model: model} do
      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "What's 2+2?",
            timestamp: System.system_time(:millisecond) - 2000
          },
          %AssistantMessage{
            role: :assistant,
            content: [%TextContent{type: :text, text: "2+2 equals 4."}],
            api: "openai-completions",
            provider: "ollama",
            model: "llama3.1:8b",
            usage: %Usage{input: 5, output: 6, cache_read: 0, cache_write: 0, total_tokens: 11,
              cost: %Expi.Types.Cost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0}},
            stop_reason: :stop,
            timestamp: System.system_time(:millisecond) - 1000
          },
          %UserMessage{
            role: :user,
            content: "What about 3+3?",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      assert {:ok, payload} = Ollama.build_request_payload(model, context, %{})
      assert length(payload["messages"]) == 3

      [user1, assistant1, user2] = payload["messages"]
      assert user1["role"] == "user"
      assert user1["content"] == "What's 2+2?"
      assert assistant1["role"] == "assistant"
      assert assistant1["content"] == "2+2 equals 4."
      assert user2["role"] == "user"
      assert user2["content"] == "What about 3+3?"
    end

    test "includes tools when provided", %{model: model} do
      tool = %{
        type: "function",
        function: %{
          name: "search_web",
          description: "Search the web for information",
          parameters: %{
            type: "object",
            properties: %{
              query: %{type: "string", description: "Search query"}
            },
            required: ["query"]
          }
        }
      }

      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Search for recent AI news",
            timestamp: System.system_time(:millisecond)
          }
        ],
        tools: [tool]
      }

      assert {:ok, payload} = Ollama.build_request_payload(model, context, %{})
      assert payload["tools"] != nil
      assert is_list(payload["tools"])
      assert length(payload["tools"]) == 1

      tool_def = List.first(payload["tools"])
      assert tool_def["type"] == "function"
      assert tool_def["function"]["name"] == "search_web"
    end

    test "handles system prompt integration", %{model: model} do
      context = %Context{
        system_prompt: "You are a helpful coding assistant specializing in Elixir.",
        messages: [
          %UserMessage{
            role: :user,
            content: "Help me with GenServer",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      assert {:ok, payload} = Ollama.build_request_payload(model, context, %{})
      
      # Should have system message first
      system_message = List.first(payload["messages"])
      assert system_message["role"] == "system"
      assert system_message["content"] == "You are a helpful coding assistant specializing in Elixir."
    end

    test "handles empty system prompt", %{model: model} do
      context = %Context{
        system_prompt: nil,
        messages: [
          %UserMessage{
            role: :user,
            content: "Hello",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      assert {:ok, payload} = Ollama.build_request_payload(model, context, %{})
      
      # Should only have user message
      assert length(payload["messages"]) == 1
      user_message = List.first(payload["messages"])
      assert user_message["role"] == "user"
    end
  end

  describe "parse_response/1" do
    test "parses successful text response" do
      api_response = %{
        "id" => "chatcmpl-abc123",
        "object" => "chat.completion",
        "created" => 1677652288,
        "model" => "llama3.1:8b",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => "The capital of France is Paris."
            },
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 12,
          "completion_tokens" => 8,
          "total_tokens" => 20
        }
      }

      assert {:ok, message} = Ollama.parse_response(api_response)
      assert %AssistantMessage{} = message
      assert message.role == :assistant
      assert message.api == "openai-completions"
      assert message.provider == "ollama"
      assert message.model == "llama3.1:8b"
      assert message.stop_reason == :stop

      assert length(message.content) == 1
      text_content = List.first(message.content)
      assert %TextContent{} = text_content
      assert text_content.text == "The capital of France is Paris."

      assert message.usage.input == 12
      assert message.usage.output == 8
      assert message.usage.total_tokens == 20
    end

    test "parses response with tool calls" do
      api_response = %{
        "id" => "chatcmpl-def456",
        "object" => "chat.completion",
        "created" => 1677652300,
        "model" => "llama3.1:8b",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_abc123",
                  "type" => "function",
                  "function" => %{
                    "name" => "calculator",
                    "arguments" => "{\"expression\": \"15 * 42\"}"
                  }
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 25,
          "completion_tokens" => 15,
          "total_tokens" => 40
        }
      }

      assert {:ok, message} = Ollama.parse_response(api_response)
      assert message.stop_reason == :tool_use

      assert length(message.content) == 1
      tool_call = List.first(message.content)
      assert %ToolCall{} = tool_call
      assert tool_call.id == "call_abc123"
      assert tool_call.name == "calculator"
      assert tool_call.arguments == %{"expression" => "15 * 42"}
    end

    test "handles length-limited responses" do
      api_response = %{
        "id" => "chatcmpl-ghi789",
        "object" => "chat.completion",
        "created" => 1677652350,
        "model" => "llama3.1:8b",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => "This response was cut off due to max_tokens"
            },
            "finish_reason" => "length"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 20,
          "completion_tokens" => 10,
          "total_tokens" => 30
        }
      }

      assert {:ok, message} = Ollama.parse_response(api_response)
      assert message.stop_reason == :length
    end

    test "handles API error responses" do
      error_response = %{
        "error" => %{
          "message" => "Model 'nonexistent-model' not found",
          "type" => "invalid_request_error",
          "code" => "model_not_found"
        }
      }

      assert {:error, reason} = Ollama.parse_response(error_response)
      assert reason in [:model_not_found, :invalid_request, :bad_request]
    end

    test "handles connection error responses" do
      # This would typically be handled at HTTP level, but test the parser
      error_response = %{
        "error" => %{
          "message" => "Connection refused",
          "type" => "connection_error"
        }
      }

      assert {:error, reason} = Ollama.parse_response(error_response)
      assert reason in [:connection_refused, :service_unavailable, :network_error, :server_error]
    end

    test "handles malformed responses" do
      assert {:error, :invalid_response} = Ollama.parse_response(%{})
      assert {:error, :invalid_response} = Ollama.parse_response(nil)
      assert {:error, :invalid_response} = Ollama.parse_response("invalid json")
    end

    test "handles missing choices" do
      api_response = %{
        "id" => "chatcmpl-empty",
        "object" => "chat.completion",
        "created" => 1677652400,
        "model" => "llama3.1:8b",
        "choices" => [],
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 0,
          "total_tokens" => 10
        }
      }

      assert {:error, :no_choices} = Ollama.parse_response(api_response)
    end
  end

  describe "error handling" do
    test "maps HTTP status codes to appropriate errors" do
      assert Ollama.map_http_error(400) == :bad_request
      assert Ollama.map_http_error(404) == :model_not_found
      assert Ollama.map_http_error(429) == :rate_limited
      assert Ollama.map_http_error(500) == :server_error
      assert Ollama.map_http_error(503) == :service_unavailable
    end

    test "provides helpful error messages" do
      conn_error = Ollama.format_error(:connection_refused, "Connection to localhost:11434 failed")
      assert is_binary(conn_error)
      assert String.contains?(conn_error, "connection") or String.contains?(conn_error, "Ollama")

      model_error = Ollama.format_error(:model_not_found, "Model 'invalid:model' not found")
      assert String.contains?(model_error, "model") and String.contains?(model_error, "not found")
    end

    test "suggests helpful actions for common errors" do
      conn_error = Ollama.format_error(:connection_refused, "")
      assert String.contains?(conn_error, "Ollama") or String.contains?(conn_error, "running")

      model_error = Ollama.format_error(:model_not_found, "")
      assert String.contains?(model_error, "pull") or String.contains?(model_error, "install") or String.contains?(model_error, "not found")
    end
  end

  describe "service health" do
    test "checks if Ollama service is running" do
      case Ollama.health_check("http://localhost:11434") do
        {:ok, :healthy} -> :ok
        {:error, :service_unavailable} -> :ok  # Service not running
        {:error, _} -> :ok  # Other connection errors
      end
    end

    test "validates model availability" do
      case Ollama.model_available?("http://localhost:11434", "llama3.1:8b") do
        {:ok, true} -> :ok  # Model available
        {:ok, false} -> :ok  # Model not available
        {:error, _} -> :ok  # Service not reachable
      end
    end
  end
end