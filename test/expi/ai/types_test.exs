defmodule ExpiAi.TypesTest do
  use ExUnit.Case, async: true
  alias ExpiAi.Types.{
    AssistantMessage,
    AssistantMessageEvent,
    Context,
    Cost,
    ImageContent,
    Model,
    TextContent,
    ThinkingContent,
    ToolCall,
    ToolResultMessage,
    Usage,
    UserMessage
  }

  describe "Model struct" do
    test "creates valid model with all required fields" do
      model = %Model{
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
          cache_read: 0.0,
          cache_write: 0.0
        },
        context_window: 200_000,
        max_tokens: 4096,
        headers: %{},
        compat: %{}
      }

      assert model.id == "claude-opus-4-5"
      assert model.provider == "anthropic"
      assert model.reasoning == true
      assert is_list(model.input)
    end

    test "validates model ID format" do
      assert Model.valid_model_id?("claude-opus-4-5")
      assert Model.valid_model_id?("gpt-4o")
      assert Model.valid_model_id?("gemini-pro")
      refute Model.valid_model_id?("")
      refute Model.valid_model_id?(nil)
    end

    test "validates provider format" do
      assert Model.valid_provider?("anthropic")
      assert Model.valid_provider?("openai")
      assert Model.valid_provider?("google")
      assert Model.valid_provider?("ollama")
      refute Model.valid_provider?("")
      refute Model.valid_provider?(nil)
    end
  end

  describe "Context struct" do
    test "creates valid context with messages" do
      messages = [
        %UserMessage{
          role: :user,
          content: "Hello",
          timestamp: System.system_time(:millisecond)
        }
      ]

      context = %Context{
        system_prompt: "You are helpful",
        messages: messages,
        tools: nil
      }

      assert context.system_prompt == "You are helpful"
      assert length(context.messages) == 1
      assert context.tools == nil
    end

    test "validates context structure" do
      context = %Context{
        system_prompt: nil,
        messages: [],
        tools: nil
      }

      assert Context.valid?(context)

      invalid_context = %Context{
        system_prompt: nil,
        messages: nil,  # Invalid: should be a list
        tools: nil
      }

      refute Context.valid?(invalid_context)
    end
  end

  describe "UserMessage struct" do
    test "creates valid user message with string content" do
      timestamp = System.system_time(:millisecond)

      message = %UserMessage{
        role: :user,
        content: "Hello world",
        timestamp: timestamp
      }

      assert message.role == :user
      assert message.content == "Hello world"
      assert message.timestamp == timestamp
    end

    test "creates valid user message with content array" do
      timestamp = System.system_time(:millisecond)

      content = [
        %TextContent{type: :text, text: "Describe this image"},
        %ImageContent{type: :image, data: "base64data", mime_type: "image/png"}
      ]

      message = %UserMessage{
        role: :user,
        content: content,
        timestamp: timestamp
      }

      assert message.role == :user
      assert is_list(message.content)
      assert length(message.content) == 2
    end
  end

  describe "AssistantMessage struct" do
    test "creates valid assistant message" do
      timestamp = System.system_time(:millisecond)

      content = [
        %TextContent{type: :text, text: "Hello!", text_signature: nil}
      ]

      usage = %Usage{
        input: 10,
        output: 5,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 15,
        cost: %Cost{input: 0.01, output: 0.02, cache_read: 0.0, cache_write: 0.0}
      }

      message = %AssistantMessage{
        role: :assistant,
        content: content,
        api: "anthropic-messages",
        provider: "anthropic",
        model: "claude-opus-4-5",
        usage: usage,
        stop_reason: :stop,
        error_message: nil,
        timestamp: timestamp
      }

      assert message.role == :assistant
      assert length(message.content) == 1
      assert message.stop_reason == :stop
    end
  end

  describe "Content types" do
    test "TextContent struct" do
      content = %TextContent{
        type: :text,
        text: "Hello world",
        text_signature: nil
      }

      assert content.type == :text
      assert content.text == "Hello world"
    end

    test "ThinkingContent struct" do
      content = %ThinkingContent{
        type: :thinking,
        thinking: "Let me think about this...",
        thinking_signature: nil,
        redacted: false
      }

      assert content.type == :thinking
      assert content.thinking == "Let me think about this..."
      assert content.redacted == false
    end

    test "ToolCall struct" do
      tool_call = %ToolCall{
        type: :tool_call,
        id: "call_123",
        name: "get_weather",
        arguments: %{"location" => "Paris"},
        thought_signature: nil
      }

      assert tool_call.type == :tool_call
      assert tool_call.id == "call_123"
      assert tool_call.name == "get_weather"
      assert is_map(tool_call.arguments)
    end

    test "ImageContent struct" do
      content = %ImageContent{
        type: :image,
        data: "base64encodeddata",
        mime_type: "image/jpeg"
      }

      assert content.type == :image
      assert content.mime_type == "image/jpeg"
    end
  end

  describe "AssistantMessageEvent types" do
    test "start event" do
      partial_message = %AssistantMessage{
        role: :assistant,
        content: [],
        api: "anthropic-messages",
        provider: "anthropic",
        model: "claude-opus-4-5",
        usage: nil,
        stop_reason: nil,
        error_message: nil,
        timestamp: System.system_time(:millisecond)
      }

      event = %AssistantMessageEvent{
        type: :start,
        partial: partial_message
      }

      assert event.type == :start
      assert event.partial.role == :assistant
    end

    test "text_delta event" do
      partial_message = %AssistantMessage{
        role: :assistant,
        content: [],
        api: "anthropic-messages",
        provider: "anthropic",
        model: "claude-opus-4-5",
        usage: nil,
        stop_reason: nil,
        error_message: nil,
        timestamp: System.system_time(:millisecond)
      }

      event = %AssistantMessageEvent{
        type: :text_delta,
        content_index: 0,
        delta: "Hello",
        partial: partial_message
      }

      assert event.type == :text_delta
      assert event.content_index == 0
      assert event.delta == "Hello"
    end

    test "done event" do
      final_message = %AssistantMessage{
        role: :assistant,
        content: [%TextContent{type: :text, text: "Complete response"}],
        api: "anthropic-messages",
        provider: "anthropic",
        model: "claude-opus-4-5",
        usage: %Usage{
          input: 10,
          output: 5,
          cache_read: 0,
          cache_write: 0,
          total_tokens: 15,
          cost: %Cost{input: 0.01, output: 0.02, cache_read: 0.0, cache_write: 0.0}
        },
        stop_reason: :stop,
        error_message: nil,
        timestamp: System.system_time(:millisecond)
      }

      event = %AssistantMessageEvent{
        type: :done,
        reason: :stop,
        message: final_message
      }

      assert event.type == :done
      assert event.reason == :stop
      assert event.message.role == :assistant
    end

    test "validates all 12 event types exist" do
      event_types = [
        :start,
        :text_start, :text_delta, :text_end,
        :thinking_start, :thinking_delta, :thinking_end,
        :toolcall_start, :toolcall_delta, :toolcall_end,
        :done, :error
      ]

      # This test will ensure we implement all 12 event types
      for event_type <- event_types do
        assert AssistantMessageEvent.valid_type?(event_type)
      end
    end
  end

  describe "Usage and Cost tracking" do
    test "Usage struct" do
      cost = %Cost{
        input: 0.01,
        output: 0.02,
        cache_read: 0.0,
        cache_write: 0.0
      }

      usage = %Usage{
        input: 100,
        output: 50,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 150,
        cost: cost
      }

      assert usage.input == 100
      assert usage.output == 50
      assert usage.total_tokens == 150
      assert usage.cost.input == 0.01
    end

    test "calculates total cost" do
      cost = %Cost{
        input: 0.01,
        output: 0.02,
        cache_read: 0.0,
        cache_write: 0.0
      }

      total = Cost.total(cost)
      assert total == 0.03
    end
  end
end
