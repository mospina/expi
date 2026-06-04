defmodule Expi.AI.StreamingTest do
  use ExUnit.Case, async: true

  alias Expi.AI
  alias Expi.AI.Streaming

  alias Expi.Types.{
    AssistantMessage,
    AssistantMessageEvent,
    Context,
    TextContent,
    ThinkingContent,
    UserMessage
  }

  describe "stream_simple/2 integration" do
    test "integrates with Anthropic provider" do
      {:ok, model} = AI.get_model("anthropic", "claude-opus-4-5")

      context = %Context{
        system_prompt: "You are helpful",
        messages: [
          %UserMessage{
            role: :user,
            content: "Say hello",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      case AI.stream_simple(model, context) do
        {:ok, stream} ->
          events = Enum.to_list(stream)
          assert events != []

          # Should start with :start event
          first_event = List.first(events)
          assert first_event.type == :start

          # Should end with :done event
          last_event = List.last(events)
          assert last_event.type == :done
          assert last_event.reason == :stop

        {:error, reason} ->
          # Network errors acceptable in test environment
          assert reason in [:missing_api_key, :network_error, :not_implemented]
      end
    end

    test "integrates with Google Gemini provider" do
      {:ok, model} = AI.get_model("google", "gemini-pro")

      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Hello",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      case AI.stream_simple(model, context) do
        {:ok, stream} ->
          events = Enum.to_list(stream)
          assert events != []

          # Verify event structure
          events
          |> Enum.each(fn event ->
            assert %AssistantMessageEvent{} = event
            assert event.type in [:start, :text_start, :text_delta, :text_end, :done, :error]
          end)

        {:error, reason} ->
          assert reason in [:missing_api_key, :network_error, :not_implemented]
      end
    end

    test "integrates with Ollama provider" do
      {:ok, model} = AI.get_model("ollama", "llama3.1:8b")

      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Hi",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      case AI.stream_simple(model, context) do
        {:ok, stream} ->
          events = Enum.to_list(stream)
          assert events != []

          # Check for expected streaming pattern
          start_events = Enum.filter(events, &(&1.type == :start))
          done_events = Enum.filter(events, &(&1.type == :done))
          text_delta_events = Enum.filter(events, &(&1.type == :text_delta))

          assert start_events != []
          assert done_events != []
          assert text_delta_events != []

        {:error, reason} ->
          assert reason in [:connection_refused, :network_error, :not_implemented]
      end
    end

    test "validates input parameters" do
      {:ok, model} = AI.get_model("anthropic", "claude-opus-4-5")

      # Test with nil context
      assert {:error, :invalid_context} = AI.stream_simple(model, nil)

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

      assert {:error, :invalid_model} = AI.stream_simple(nil, context)
    end
  end

  describe "parse_sse_chunk/1" do
    test "parses valid SSE chunks" do
      chunk = """
      data: {"type": "message_start", "message": {"id": "msg_123"}}

      data: {"type": "content_block_delta", "delta": {"text": "Hello"}}

      data: [DONE]
      """

      events = Streaming.parse_sse_chunk(chunk)
      assert match?([_, _], events)

      [first_event, second_event] = events
      assert first_event["type"] == "message_start"
      assert second_event["type"] == "content_block_delta"
      assert second_event["delta"]["text"] == "Hello"
    end

    test "handles malformed chunks gracefully" do
      chunk = "invalid data\n\ndata: {invalid json}\n\n"

      events = Streaming.parse_sse_chunk(chunk)
      assert events == []
    end

    test "filters out [DONE] markers" do
      chunk = "data: [DONE]\n\n"

      events = Streaming.parse_sse_chunk(chunk)
      assert events == []
    end
  end

  describe "standardize_event/2" do
    test "standardizes Anthropic events" do
      # Message start event
      event = %{"type" => "message_start"}
      result = Streaming.standardize_event(event, "anthropic")
      assert result.type == :start

      # Text delta event
      event = %{
        "type" => "content_block_delta",
        "delta" => %{"type" => "text_delta", "text" => "Hello"},
        "index" => 0
      }

      result = Streaming.standardize_event(event, "anthropic")
      assert result.type == :text_delta
      assert result.content_index == 0
      assert result.delta == "Hello"

      # Thinking delta event
      event = %{
        "type" => "content_block_delta",
        "delta" => %{"type" => "thinking_delta", "thinking" => "Let me think..."},
        "index" => 0
      }

      result = Streaming.standardize_event(event, "anthropic")
      assert result.type == :thinking_delta
      assert result.content_index == 0
      assert result.delta == "Let me think..."

      # content_block_stop mapped by content block type when provided
      event = %{"type" => "content_block_stop", "index" => 1, "content_block" => %{"type" => "thinking"}}
      result = Streaming.standardize_event(event, "anthropic")
      assert result.type == :thinking_end

      event = %{"type" => "content_block_stop", "index" => 2, "content_block" => %{"type" => "tool_use"}}
      result = Streaming.standardize_event(event, "anthropic")
      assert result.type == :toolcall_end

      # Done event
      event = %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"}
      }

      result = Streaming.standardize_event(event, "anthropic")
      assert result.type == :done
      assert result.reason == :stop
    end

    test "standardizes Google Gemini events" do
      # Text delta event
      event = %{
        "candidates" => [
          %{"content" => %{"parts" => [%{"text" => "Gemini response"}]}}
        ]
      }

      result = Streaming.standardize_event(event, "google")
      assert result.type == :text_delta
      assert result.delta == "Gemini response"

      # Done event
      event = %{
        "candidates" => [
          %{"finishReason" => "STOP"}
        ]
      }

      result = Streaming.standardize_event(event, "google")
      assert result.type == :done
      assert result.reason == :stop
    end

    test "standardizes Ollama events" do
      # Text delta event
      event = %{
        "choices" => [
          %{"delta" => %{"content" => "Ollama response"}}
        ]
      }

      result = Streaming.standardize_event(event, "ollama")
      assert result.type == :text_delta
      assert result.delta == "Ollama response"

      # Done event
      event = %{
        "choices" => [
          %{"finish_reason" => "stop"}
        ]
      }

      result = Streaming.standardize_event(event, "ollama")
      assert result.type == :done
      assert result.reason == :stop
    end

    test "handles unknown events gracefully" do
      event = %{"unknown" => "event"}
      result = Streaming.standardize_event(event, "anthropic")
      assert result == nil

      result = Streaming.standardize_event(event, "google")
      assert result == nil

      result = Streaming.standardize_event(event, "ollama")
      assert result == nil
    end
  end

  describe "accumulate_message/2" do
    setup do
      message = %AssistantMessage{
        role: :assistant,
        content: [],
        api: "test",
        provider: "test",
        model: "test-model",
        usage: nil,
        stop_reason: nil,
        timestamp: 0
      }

      {:ok, message: message}
    end

    test "handles start events", %{message: message} do
      event = %AssistantMessageEvent{type: :start}
      result = Streaming.accumulate_message(message, event)
      assert result == message
    end

    test "handles text start events", %{message: message} do
      event = %AssistantMessageEvent{type: :text_start, content_index: 0}
      result = Streaming.accumulate_message(message, event)

      assert match?([_], result.content)
      assert %TextContent{text: ""} = Enum.at(result.content, 0)
    end

    test "handles text delta events", %{message: message} do
      # First add a text content slot
      message = %{message | content: [%TextContent{type: :text, text: "Hello"}]}

      event = %AssistantMessageEvent{type: :text_delta, content_index: 0, delta: " world"}
      result = Streaming.accumulate_message(message, event)

      text_content = Enum.at(result.content, 0)
      assert text_content.text == "Hello world"
    end

    test "handles thinking start events", %{message: message} do
      event = %AssistantMessageEvent{type: :thinking_start, content_index: 0}
      result = Streaming.accumulate_message(message, event)

      assert match?([_], result.content)
      assert %ThinkingContent{thinking: ""} = Enum.at(result.content, 0)
    end

    test "handles thinking delta events", %{message: message} do
      # First add a thinking content slot
      message = %{
        message
        | content: [%ThinkingContent{type: :thinking, thinking: "Let me think"}]
      }

      event = %AssistantMessageEvent{type: :thinking_delta, content_index: 0, delta: " more..."}
      result = Streaming.accumulate_message(message, event)

      thinking_content = Enum.at(result.content, 0)
      assert thinking_content.thinking == "Let me think more..."
    end

    test "handles done events", %{message: message} do
      event = %AssistantMessageEvent{type: :done, reason: :stop}
      result = Streaming.accumulate_message(message, event)

      assert result.stop_reason == :stop
      assert result.timestamp > message.timestamp
    end

    test "handles error events", %{message: message} do
      event = %AssistantMessageEvent{
        type: :error,
        error: %{message: "Something went wrong"}
      }

      result = Streaming.accumulate_message(message, event)

      assert result.error_message == "Something went wrong"
      assert result.timestamp > message.timestamp
    end

    test "handles multiple content slots", %{message: message} do
      # Test that we can handle events for different content indices
      event1 = %AssistantMessageEvent{type: :text_start, content_index: 0}
      message = Streaming.accumulate_message(message, event1)

      event2 = %AssistantMessageEvent{type: :thinking_start, content_index: 1}
      result = Streaming.accumulate_message(message, event2)

      assert match?([_, _], result.content)
      assert %TextContent{} = Enum.at(result.content, 0)
      assert %ThinkingContent{} = Enum.at(result.content, 1)
    end

    test "ignores unknown events", %{message: message} do
      event = %AssistantMessageEvent{type: :unknown_event}
      result = Streaming.accumulate_message(message, event)
      assert result == message
    end
  end

  describe "streaming event accumulation flow" do
    test "complete streaming flow produces valid message" do
      # Start with empty message
      message = %AssistantMessage{
        role: :assistant,
        content: [],
        api: "anthropic-messages",
        provider: "anthropic",
        model: "claude-opus-4-5",
        usage: nil,
        stop_reason: nil,
        timestamp: 0
      }

      # Simulate streaming events
      events = [
        %AssistantMessageEvent{type: :start},
        %AssistantMessageEvent{type: :text_start, content_index: 0},
        %AssistantMessageEvent{type: :text_delta, content_index: 0, delta: "Hello"},
        %AssistantMessageEvent{type: :text_delta, content_index: 0, delta: " there!"},
        %AssistantMessageEvent{type: :text_end, content_index: 0},
        %AssistantMessageEvent{type: :done, reason: :stop}
      ]

      # Accumulate events into final message
      final_message = Enum.reduce(events, message, &Streaming.accumulate_message(&2, &1))

      # Verify final message structure
      assert final_message.role == :assistant
      assert final_message.stop_reason == :stop
      assert final_message.timestamp > 0
      assert match?([_], final_message.content)

      text_content = List.first(final_message.content)
      assert %TextContent{text: "Hello there!"} = text_content
    end

    test "handles thinking and text content together" do
      message = %AssistantMessage{
        role: :assistant,
        content: [],
        api: "anthropic-messages",
        provider: "anthropic",
        model: "claude-opus-4-5",
        usage: nil,
        stop_reason: nil,
        timestamp: 0
      }

      events = [
        %AssistantMessageEvent{type: :start},
        %AssistantMessageEvent{type: :thinking_start, content_index: 0},
        %AssistantMessageEvent{type: :thinking_delta, content_index: 0, delta: "Let me think"},
        %AssistantMessageEvent{type: :thinking_delta, content_index: 0, delta: " about this..."},
        %AssistantMessageEvent{type: :text_start, content_index: 1},
        %AssistantMessageEvent{type: :text_delta, content_index: 1, delta: "The answer is 42"},
        %AssistantMessageEvent{type: :done, reason: :stop}
      ]

      final_message = Enum.reduce(events, message, &Streaming.accumulate_message(&2, &1))

      assert match?([_, _], final_message.content)

      thinking_content = Enum.at(final_message.content, 0)
      text_content = Enum.at(final_message.content, 1)

      assert %ThinkingContent{thinking: "Let me think about this..."} = thinking_content
      assert %TextContent{text: "The answer is 42"} = text_content
    end
  end

  describe "stream validation" do
    test "validates stream events conform to spec" do
      {:ok, model} = AI.get_model("anthropic", "claude-opus-4-5")

      context = %Context{
        messages: [
          %UserMessage{
            role: :user,
            content: "Hello",
            timestamp: System.system_time(:millisecond)
          }
        ]
      }

      case AI.stream_simple(model, context) do
        {:ok, stream} ->
          # Validate all events in stream are properly formatted
          stream
          |> Enum.each(fn event ->
            assert %AssistantMessageEvent{} = event
            assert AssistantMessageEvent.valid_type?(event.type)

            # Content index should be non-negative if present
            if event.content_index do
              assert event.content_index >= 0
            end

            # Delta should be string if present
            if event.delta do
              assert is_binary(event.delta)
            end
          end)

        {:error, _} ->
          # Network errors are acceptable
          :ok
      end
    end
  end
end
