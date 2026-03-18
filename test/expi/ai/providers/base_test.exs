defmodule ExpiAi.Providers.BaseTest do
  use ExUnit.Case, async: true

  alias ExpiAi.Providers.Base
  alias ExpiAi.Types.{
    AssistantMessage,
    Context,
    Model,
    TextContent,
    Usage,
    UserMessage
  }

  setup do
    model = %Model{
      id: "test-model",
      name: "Test Model",
      api: "test-api",
      provider: "test",
      base_url: "https://api.test.com",
      reasoning: false,
      input: ["text"],
      cost: %ExpiAi.Types.Cost{
        input: 1.0,
        output: 2.0,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 4000,
      max_tokens: 1000,
      headers: %{"Custom-Header" => "test-value"},
      compat: %{}
    }

    {:ok, model: model}
  end

  describe "validate_context/1" do
    test "validates valid context" do
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

      assert :ok = Base.validate_context(context)
    end

    test "rejects nil context" do
      assert {:error, :invalid_context} = Base.validate_context(nil)
    end

    test "rejects context with empty messages" do
      context = %Context{
        messages: [],
        system_prompt: nil,
        tools: nil
      }

      assert {:error, :empty_messages} = Base.validate_context(context)
    end

    test "rejects context with nil messages" do
      context = %Context{
        messages: nil,
        system_prompt: nil,
        tools: nil
      }

      assert {:error, :invalid_messages} = Base.validate_context(context)
    end

    test "validates context with tools" do
      tool = %{
        name: "test_tool",
        description: "A test tool",
        parameters: %{type: "object", properties: %{}}
      }

      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Use the tool",
            timestamp: System.system_time(:millisecond)
          }
        ],
        tools: [tool]
      }

      assert :ok = Base.validate_context(context)
    end
  end

  describe "validate_model/1" do
    test "validates valid model", %{model: model} do
      assert :ok = Base.validate_model(model)
    end

    test "rejects nil model" do
      assert {:error, :invalid_model} = Base.validate_model(nil)
    end

    test "rejects model with missing required fields", %{model: model} do
      invalid_model = %{model | id: ""}
      assert {:error, :invalid_model_id} = Base.validate_model(invalid_model)

      invalid_model = %{model | base_url: ""}
      assert {:error, :invalid_base_url} = Base.validate_model(invalid_model)

      invalid_model = %{model | provider: ""}
      assert {:error, :invalid_provider} = Base.validate_model(invalid_model)
    end
  end

  describe "validate_options/1" do
    test "validates valid options" do
      options = %{
        temperature: 0.7,
        max_tokens: 100,
        custom_param: "value"
      }

      assert :ok = Base.validate_options(options)
    end

    test "validates empty options" do
      assert :ok = Base.validate_options(%{})
      assert :ok = Base.validate_options(nil)
    end

    test "rejects invalid temperature" do
      assert {:error, :invalid_temperature} = Base.validate_options(%{temperature: -1})
      assert {:error, :invalid_temperature} = Base.validate_options(%{temperature: 3})
      assert {:error, :invalid_temperature} = Base.validate_options(%{temperature: "high"})
    end

    test "rejects invalid max_tokens" do
      assert {:error, :invalid_max_tokens} = Base.validate_options(%{max_tokens: -1})
      assert {:error, :invalid_max_tokens} = Base.validate_options(%{max_tokens: 0})
      assert {:error, :invalid_max_tokens} = Base.validate_options(%{max_tokens: "many"})
    end

    test "accepts valid temperature range" do
      assert :ok = Base.validate_options(%{temperature: 0.0})
      assert :ok = Base.validate_options(%{temperature: 1.0})
      assert :ok = Base.validate_options(%{temperature: 2.0})
    end

    test "accepts valid max_tokens values" do
      assert :ok = Base.validate_options(%{max_tokens: 1})
      assert :ok = Base.validate_options(%{max_tokens: 4096})
      assert :ok = Base.validate_options(%{max_tokens: 32_768})
    end
  end

  describe "prepare_headers/2" do
    test "combines default and custom headers", %{model: model} do
      custom_headers = [{"Authorization", "Bearer token123"}]

      headers = Base.prepare_headers(model, custom_headers)

      assert is_list(headers)
      assert {"Content-Type", "application/json"} in headers
      assert {"Authorization", "Bearer token123"} in headers
      assert {"Custom-Header", "test-value"} in headers
    end

    test "handles model without custom headers" do
      model_without_headers = %Model{
        id: "test-model",
        name: "Test Model",
        api: "test-api",
        provider: "test",
        base_url: "https://api.test.com",
        reasoning: false,
        input: ["text"],
        cost: %ExpiAi.Types.Cost{input: 1.0, output: 2.0, cache_read: 0.0, cache_write: 0.0},
        context_window: 4000,
        max_tokens: 1000,
        headers: %{},
        compat: %{}
      }

      headers = Base.prepare_headers(model_without_headers, [])

      assert is_list(headers)
      assert {"Content-Type", "application/json"} in headers
    end

    test "overrides default headers with custom ones", %{model: model} do
      custom_headers = [{"Content-Type", "application/xml"}]

      headers = Base.prepare_headers(model, custom_headers)

      # Custom header should override default
      content_type_headers = Enum.filter(headers, fn {key, _} -> key == "Content-Type" end)
      assert {"Content-Type", "application/xml"} in content_type_headers
    end
  end

  describe "calculate_cost/2" do
    test "calculates cost correctly", %{model: model} do
      usage = %{
        input: 1000,
        output: 500,
        cache_read: 100,
        cache_write: 200
      }

      cost = Base.calculate_cost(model, usage)

      assert is_map(cost)
      assert cost.input == 0.001  # 1000 * 1.0 / 1_000_000
      assert cost.output == 0.001  # 500 * 2.0 / 1_000_000
      assert cost.cache_read == 0.0
      assert cost.cache_write == 0.0
      assert cost.total == 0.002
    end

    test "handles zero usage" do
      usage = %{input: 0, output: 0, cache_read: 0, cache_write: 0}

      cost = Base.calculate_cost(%Model{
        cost: %ExpiAi.Types.Cost{input: 1.0, output: 2.0, cache_read: 0.5, cache_write: 1.5}
      }, usage)

      assert cost.input == 0.0
      assert cost.output == 0.0
      assert cost.cache_read == 0.0
      assert cost.cache_write == 0.0
      assert cost.total == 0.0
    end

    test "handles missing usage fields", %{model: model} do
      partial_usage = %{input: 100}

      cost = Base.calculate_cost(model, partial_usage)

      assert cost.input == 0.0001  # 100 * 1.0 / 1_000_000
      assert cost.output == 0.0
      assert cost.cache_read == 0.0
      assert cost.cache_write == 0.0
      assert cost.total == 0.0001
    end
  end

  describe "format_messages/1" do
    test "formats simple user message" do
      messages = [
        %UserMessage{
          role: :user,
          content: "Hello world",
          timestamp: System.system_time(:millisecond)
        }
      ]

      formatted = Base.format_messages(messages)

      assert is_list(formatted)
      assert length(formatted) == 1

      message = List.first(formatted)
      assert message["role"] == "user"
      assert message["content"] == "Hello world"
    end

    test "formats assistant message with text content" do
      messages = [
        %AssistantMessage{
          role: :assistant,
          content: [%TextContent{type: :text, text: "Hello there!"}],
          api: "test-api",
          provider: "test",
          model: "test-model",
          usage: %Usage{input: 1, output: 2, cache_read: 0, cache_write: 0, total_tokens: 3,
            cost: %ExpiAi.Types.Cost{input: 0.001, output: 0.002, cache_read: 0.0, cache_write: 0.0}},
          stop_reason: :stop,
          timestamp: System.system_time(:millisecond)
        }
      ]

      formatted = Base.format_messages(messages)

      assert length(formatted) == 1
      message = List.first(formatted)
      assert message["role"] == "assistant"
      assert message["content"] == "Hello there!"
    end

    test "formats conversation history" do
      messages = [
        %UserMessage{
          role: :user,
          content: "What's 2+2?",
          timestamp: System.system_time(:millisecond) - 1000
        },
        %AssistantMessage{
          role: :assistant,
          content: [%TextContent{type: :text, text: "2+2 equals 4."}],
          api: "test-api",
          provider: "test",
          model: "test-model",
          usage: %Usage{input: 5, output: 6, cache_read: 0, cache_write: 0, total_tokens: 11,
            cost: %ExpiAi.Types.Cost{input: 0.005, output: 0.012, cache_read: 0.0, cache_write: 0.0}},
          stop_reason: :stop,
          timestamp: System.system_time(:millisecond) - 500
        },
        %UserMessage{
          role: :user,
          content: "Thanks!",
          timestamp: System.system_time(:millisecond)
        }
      ]

      formatted = Base.format_messages(messages)

      assert length(formatted) == 3
      assert Enum.at(formatted, 0)["role"] == "user"
      assert Enum.at(formatted, 1)["role"] == "assistant"
      assert Enum.at(formatted, 2)["role"] == "user"
    end

    test "handles multi-modal user message" do
      messages = [
        %UserMessage{
          role: :user,
          content: [
            %ExpiAi.Types.TextContent{type: :text, text: "Describe this"},
            %ExpiAi.Types.ImageContent{type: :image, data: "base64data", mime_type: "image/png"}
          ],
          timestamp: System.system_time(:millisecond)
        }
      ]

      formatted = Base.format_messages(messages)

      message = List.first(formatted)
      assert message["role"] == "user"
      assert is_list(message["content"])
      assert length(message["content"]) == 2
    end
  end

  describe "handle_http_error/2" do
    test "maps common HTTP status codes" do
      assert Base.handle_http_error(400, "Bad request") == {:error, :bad_request}
      assert Base.handle_http_error(401, "Unauthorized") == {:error, :unauthorized}
      assert Base.handle_http_error(403, "Forbidden") == {:error, :forbidden}
      assert Base.handle_http_error(404, "Not found") == {:error, :not_found}
      assert Base.handle_http_error(429, "Rate limited") == {:error, :rate_limited}
      assert Base.handle_http_error(500, "Server error") == {:error, :server_error}
      assert Base.handle_http_error(503, "Service unavailable") == {:error, :service_unavailable}
    end

    test "handles unknown status codes" do
      assert Base.handle_http_error(418, "I'm a teapot") == {:error, :unknown_http_error}
      assert Base.handle_http_error(999, "Custom error") == {:error, :unknown_http_error}
    end

    test "includes error message context" do
      {:error, reason} = Base.handle_http_error(429, "Rate limit exceeded")
      assert reason == :rate_limited
    end
  end

  describe "parse_json_safely/1" do
    test "parses valid JSON" do
      json_string = ~s({"key": "value", "number": 42})

      assert {:ok, parsed} = Base.parse_json_safely(json_string)
      assert parsed["key"] == "value"
      assert parsed["number"] == 42
    end

    test "handles invalid JSON" do
      invalid_json = ~s({"key": "value", "invalid})

      assert {:error, :invalid_json} = Base.parse_json_safely(invalid_json)
    end

    test "handles empty strings" do
      assert {:error, :empty_response} = Base.parse_json_safely("")
      assert {:error, :empty_response} = Base.parse_json_safely(nil)
    end

    test "handles non-string input" do
      assert {:error, :invalid_input} = Base.parse_json_safely(123)
      assert {:error, :invalid_input} = Base.parse_json_safely(%{})
    end
  end

  describe "merge_default_options/2" do
    test "merges options with defaults" do
      defaults = %{temperature: 0.7, max_tokens: 100, top_p: 0.9}
      custom = %{temperature: 0.5, custom_param: "value"}

      merged = Base.merge_default_options(defaults, custom)

      assert merged.temperature == 0.5  # Custom overrides default
      assert merged.max_tokens == 100  # Default preserved
      assert merged.top_p == 0.9  # Default preserved
      assert merged.custom_param == "value"  # Custom added
    end

    test "handles nil custom options" do
      defaults = %{temperature: 0.7, max_tokens: 100}

      merged = Base.merge_default_options(defaults, nil)

      assert merged == defaults
    end

    test "handles empty custom options" do
      defaults = %{temperature: 0.7, max_tokens: 100}

      merged = Base.merge_default_options(defaults, %{})

      assert merged == defaults
    end
  end

  describe "extract_text_content/1" do
    test "extracts text from simple string content" do
      content = [%TextContent{type: :text, text: "Hello world"}]

      assert "Hello world" = Base.extract_text_content(content)
    end

    test "concatenates multiple text contents" do
      content = [
        %TextContent{type: :text, text: "Hello "},
        %TextContent{type: :text, text: "world!"}
      ]

      assert "Hello world!" = Base.extract_text_content(content)
    end

    test "ignores non-text content" do
      content = [
        %TextContent{type: :text, text: "Hello"},
        %{type: :thinking, thinking: "Let me think..."},
        %TextContent{type: :text, text: " world"}
      ]

      assert "Hello world" = Base.extract_text_content(content)
    end

    test "handles empty content list" do
      assert "" = Base.extract_text_content([])
    end
  end

  describe "create_usage/4" do
    test "creates usage struct with cost calculation", %{model: model} do
      usage = Base.create_usage(model, 100, 50, 150)

      assert usage.input == 100
      assert usage.output == 50
      assert usage.total_tokens == 150
      assert usage.cache_read == 0
      assert usage.cache_write == 0

      # Cost should be calculated based on model pricing
      assert usage.cost.input == 0.0001  # 100 * 1.0 / 1_000_000
      assert usage.cost.output == 0.0001  # 50 * 2.0 / 1_000_000
      assert ExpiAi.Types.Cost.total(usage.cost) == 0.0002
    end

    test "handles zero usage" do
      model = %Model{
        cost: %ExpiAi.Types.Cost{input: 1.0, output: 2.0, cache_read: 0.0, cache_write: 0.0}
      }

      usage = Base.create_usage(model, 0, 0, 0)

      assert usage.input == 0
      assert usage.output == 0
      assert usage.total_tokens == 0
      assert ExpiAi.Types.Cost.total(usage.cost) == 0.0
    end
  end

  describe "retry_with_backoff/3" do
    test "succeeds on first attempt" do
      success_fn = fn -> {:ok, "success"} end

      assert {:ok, "success"} = Base.retry_with_backoff(success_fn, 3, 100)
    end

    test "retries on failure and eventually succeeds" do
      # Function that fails twice, then succeeds
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      retry_fn = fn ->
        attempt = Agent.get_and_update(agent, fn count -> {count, count + 1} end)
        if attempt < 2 do
          {:error, :temporary_failure}
        else
          {:ok, "success after retries"}
        end
      end

      assert {:ok, "success after retries"} = Base.retry_with_backoff(retry_fn, 3, 10)

      Agent.stop(agent)
    end

    test "gives up after max retries" do
      failure_fn = fn -> {:error, :persistent_failure} end

      assert {:error, :persistent_failure} = Base.retry_with_backoff(failure_fn, 2, 10)
    end

    test "handles exceptions" do
      exception_fn = fn -> raise "Something went wrong" end

      assert {:error, _} = Base.retry_with_backoff(exception_fn, 2, 10)
    end
  end
end