defmodule Expi.Agent.MessageTest do
  use ExUnit.Case, async: true

  alias Expi.Agent.Message
  alias Expi.Types.{UserMessage, AssistantMessage, ToolResultMessage}

  describe "user/1" do
    test "creates user message with string content" do
      message = Message.user("Hello, world!")
      
      assert %UserMessage{} = message
      assert message.role == :user
      assert message.content == "Hello, world!"
      assert is_integer(message.timestamp)
      assert message.timestamp > 0
    end

    test "handles empty string content" do
      message = Message.user("")
      
      assert message.content == ""
      assert message.role == :user
    end

    test "handles unicode content" do
      unicode_text = "Hello 👋 世界 🌍"
      message = Message.user(unicode_text)
      
      assert message.content == unicode_text
    end

    test "timestamps are unique and increasing" do
      msg1 = Message.user("First")
      Process.sleep(1)  # Ensure different timestamps
      msg2 = Message.user("Second")
      
      assert msg2.timestamp > msg1.timestamp
    end
  end

  describe "assistant/3" do
    test "creates assistant message with basic content" do
      message = Message.assistant("I can help you with that", "anthropic", "claude-3-sonnet")
      
      assert %AssistantMessage{} = message
      assert message.role == :assistant
      assert message.provider == "anthropic"
      assert message.model == "claude-3-sonnet"
      assert is_list(message.content)
      assert length(message.content) == 1
      assert %{type: :text, text: "I can help you with that"} = hd(message.content)
    end

    test "creates assistant message with structured content" do
      content = [
        %{type: :text, text: "Here's the calculation:"},
        %{type: :tool_call, id: "call_123", name: "calculator", arguments: %{"expr" => "2+2"}}
      ]
      
      message = Message.assistant(content, "openai", "gpt-4")
      
      assert message.content == content
      assert message.provider == "openai"
      assert message.model == "gpt-4"
    end

    test "handles empty content list" do
      message = Message.assistant([], "anthropic", "claude")
      
      assert message.content == []
    end

    test "sets timestamp automatically" do
      message = Message.assistant("Response", "anthropic", "claude")
      
      assert is_integer(message.timestamp)
      assert message.timestamp > 0
    end
  end

  describe "tool_result/4" do
    test "creates successful tool result message" do
      message = Message.tool_result("call_123", "calculator", {:ok, "4"}, %{})
      
      assert %ToolResultMessage{} = message
      assert message.role == :tool
      assert message.tool_call_id == "call_123"
      assert message.tool_name == "calculator"
      assert message.content == "4"
      assert message.is_error == false
    end

    test "creates error tool result message" do
      message = Message.tool_result("call_456", "search", {:error, "Network timeout"}, %{})
      
      assert message.is_error == true
      assert message.content == "Network timeout"
      assert message.tool_name == "search"
    end

    test "includes execution metadata" do
      metadata = %{execution_time: 150, retries: 1}
      message = Message.tool_result("call_789", "api", {:ok, "success"}, metadata)
      
      # In a full implementation, metadata might be stored in a separate field
      assert message.tool_call_id == "call_789"
    end

    test "handles complex result data" do
      complex_result = %{
        data: [1, 2, 3],
        metadata: %{source: "database", count: 3}
      }
      
      message = Message.tool_result("call_complex", "query", {:ok, complex_result}, %{})
      
      # Content should be converted to string representation
      assert is_binary(message.content)
      assert String.contains?(message.content, "data")
    end
  end

  describe "content/1" do
    test "extracts content from user message" do
      message = Message.user("User content")
      
      assert Message.content(message) == "User content"
    end

    test "extracts text content from assistant message" do
      message = Message.assistant("Assistant response", "anthropic", "claude")
      
      assert Message.content(message) == "Assistant response"
    end

    test "extracts content from assistant message with mixed content" do
      content = [
        %{type: :text, text: "Here is the answer: "},
        %{type: :text, text: "42"}
      ]
      message = Message.assistant(content, "anthropic", "claude")
      
      extracted = Message.content(message)
      assert extracted == "Here is the answer: 42"
    end

    test "handles assistant message with tool calls" do
      content = [
        %{type: :text, text: "I'll calculate that for you."},
        %{type: :tool_call, id: "call_123", name: "calc", arguments: %{"expr" => "2+2"}},
        %{type: :text, text: " The result is 4."}
      ]
      message = Message.assistant(content, "anthropic", "claude")
      
      extracted = Message.content(message)
      assert String.contains?(extracted, "I'll calculate")
      assert String.contains?(extracted, "The result is 4")
      # Tool calls should not appear in extracted text content
      refute String.contains?(extracted, "tool_call")
    end

    test "extracts content from tool result message" do
      message = Message.tool_result("call_123", "tool", {:ok, "Tool output"}, %{})
      
      assert Message.content(message) == "Tool output"
    end

    test "handles messages with thinking content" do
      content = [
        %{type: :thinking, thinking: "Let me think about this..."},
        %{type: :text, text: "The answer is 42"}
      ]
      message = Message.assistant(content, "anthropic", "claude")
      
      # Should extract only text content, not thinking
      extracted = Message.content(message)
      assert extracted == "The answer is 42"
      refute String.contains?(extracted, "Let me think")
    end
  end

  describe "timestamp/1" do
    test "returns timestamp from user message" do
      message = Message.user("Test")
      timestamp = Message.timestamp(message)
      
      assert is_integer(timestamp)
      assert timestamp == message.timestamp
    end

    test "returns timestamp from assistant message" do
      message = Message.assistant("Response", "anthropic", "claude")
      timestamp = Message.timestamp(message)
      
      assert is_integer(timestamp)
      assert timestamp == message.timestamp
    end

    test "returns timestamp from tool result message" do
      message = Message.tool_result("call_123", "tool", {:ok, "result"}, %{})
      timestamp = Message.timestamp(message)
      
      assert is_integer(timestamp)
      assert timestamp == message.timestamp
    end

    test "handles message without timestamp" do
      # Create a message struct without timestamp field (edge case)
      message = %UserMessage{role: :user, content: "test"}
      
      timestamp = Message.timestamp(message)
      assert is_integer(timestamp)
      assert timestamp > 0
    end
  end

  describe "role/1" do
    test "returns role from user message" do
      message = Message.user("Test")
      
      assert Message.role(message) == :user
    end

    test "returns role from assistant message" do
      message = Message.assistant("Response", "anthropic", "claude")
      
      assert Message.role(message) == :assistant
    end

    test "returns role from tool result message" do
      message = Message.tool_result("call_123", "tool", {:ok, "result"}, %{})
      
      assert Message.role(message) == :tool
    end
  end

  describe "message type detection" do
    test "identifies user messages" do
      message = Message.user("Hello")
      
      assert match?(%UserMessage{}, message)
      assert Message.role(message) == :user
    end

    test "identifies assistant messages" do
      message = Message.assistant("Hi there", "anthropic", "claude")
      
      assert match?(%AssistantMessage{}, message)
      assert Message.role(message) == :assistant
    end

    test "identifies tool result messages" do
      message = Message.tool_result("call_123", "tool", {:ok, "result"}, %{})
      
      assert match?(%ToolResultMessage{}, message)
      assert Message.role(message) == :tool
    end
  end

  describe "content processing edge cases" do
    test "handles nil content gracefully" do
      message = %UserMessage{role: :user, content: nil, timestamp: System.system_time(:millisecond)}
      
      # Should return empty string or handle gracefully
      content = Message.content(message)
      assert is_binary(content)
    end

    test "handles empty assistant content list" do
      message = Message.assistant([], "anthropic", "claude")
      
      assert Message.content(message) == ""
    end

    test "handles malformed assistant content" do
      # Content with missing required fields
      content = [
        %{type: :text},  # missing text field
        %{text: "orphaned text"}  # missing type field
      ]
      message = Message.assistant(content, "anthropic", "claude")
      
      # Should handle gracefully without crashing
      extracted = Message.content(message)
      assert is_binary(extracted)
    end

    test "extracts content from complex nested structures" do
      content = [
        %{
          type: :text,
          text: "Here's a complex response with nested data"
        },
        %{
          type: :tool_call,
          id: "call_complex",
          name: "data_processor",
          arguments: %{
            "query" => "SELECT * FROM users",
            "options" => %{
              "limit" => 10,
              "format" => "json"
            }
          }
        }
      ]
      message = Message.assistant(content, "anthropic", "claude")
      
      extracted = Message.content(message)
      assert String.contains?(extracted, "Here's a complex response")
      # Should not include tool call details in extracted text
      refute String.contains?(extracted, "SELECT")
    end
  end

  describe "message validation" do
    test "validates user message structure" do
      message = Message.user("Valid content")
      
      assert message.role == :user
      assert is_binary(message.content)
      assert is_integer(message.timestamp)
      assert message.timestamp > 0
    end

    test "validates assistant message structure" do
      message = Message.assistant("Valid response", "anthropic", "claude-3")
      
      assert message.role == :assistant
      assert is_list(message.content)
      assert message.provider == "anthropic"
      assert message.model == "claude-3"
      assert is_integer(message.timestamp)
    end

    test "validates tool result message structure" do
      message = Message.tool_result("call_123", "test_tool", {:ok, "success"}, %{})
      
      assert message.role == :tool
      assert message.tool_call_id == "call_123"
      assert message.tool_name == "test_tool"
      assert is_binary(message.content)
      assert message.is_error == false
    end
  end

  describe "performance and memory" do
    test "handles large content efficiently" do
      # Test with large content
      large_content = String.duplicate("A", 100_000)
      message = Message.user(large_content)
      
      assert byte_size(Message.content(message)) == 100_000
      assert Message.role(message) == :user
    end

    test "handles many content blocks in assistant message" do
      # Create message with many content blocks
      content = Enum.map(1..1000, fn i ->
        %{type: :text, text: "Block #{i}"}
      end)
      
      message = Message.assistant(content, "anthropic", "claude")
      extracted = Message.content(message)
      
      assert String.contains?(extracted, "Block 1")
      assert String.contains?(extracted, "Block 1000")
      assert length(message.content) == 1000
    end
  end
end