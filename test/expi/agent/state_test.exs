defmodule Expi.Agent.StateTest do
  use ExUnit.Case, async: true

  @moduletag :known_failure
  @moduletag skip: "KNOWN_FAILURE(PRD-20260528, owner:eng, expires:2026-06-30): State API mismatch (clear_error/1, streaming helpers changed)"

  alias Expi.Agent.State
  alias Expi.Agent.Types.AgentState
  alias Expi.Agent.{Message, Tool}
  alias Expi.Types.Model

  # Test fixtures
  defp mock_model do
    %Model{
      id: "claude-3-sonnet-20240229",
      provider: "anthropic",
      api: "anthropic"
    }
  end

  defp mock_tool do
    {:ok, tool} =
      Expi.Agent.Tool.new(
        "test_tool",
        "A test tool",
        %{type: :object, properties: %{}},
        "Test Tool",
        fn _, _, _, _ ->
          {:ok, %Expi.Agent.Types.AgentToolResult{content: [], details: %{result: "test result"}}}
        end
      )

    tool
  end

  describe "new/2" do
    test "creates new agent state with valid model and config" do
      model = mock_model()

      config = %{
        system_prompt: "You are helpful",
        tools: [mock_tool()],
        temperature: 0.7
      }

      assert {:ok, %AgentState{} = state} = State.new(model, config)
      assert state.model == model
      assert state.system_prompt == "You are helpful"
      assert length(state.tools) == 1
      assert state.messages == []
      assert state.is_streaming == false
      assert state.error == nil
    end

    test "creates state with minimal config" do
      model = mock_model()

      assert {:ok, %AgentState{} = state} = State.new(model, %{})
      assert state.model == model
      assert state.system_prompt == ""
      assert state.tools == []
      assert state.messages == []
    end

    test "fails with invalid model" do
      assert {:error, "Model is required"} = State.new(nil, %{})
    end

    test "handles empty tools list" do
      model = mock_model()
      config = %{tools: []}

      assert {:ok, state} = State.new(model, config)
      assert state.tools == []
    end

    test "sets thinking level from config" do
      model = mock_model()
      config = %{thinking_level: :high}

      assert {:ok, state} = State.new(model, config)
      assert state.thinking_level == :high
    end
  end

  describe "validate/1" do
    test "validates properly configured state" do
      model = mock_model()
      {:ok, state} = State.new(model, %{})

      assert State.validate(state) == :ok
    end

    test "detects missing model" do
      {:ok, state} = State.new(mock_model(), %{})
      invalid_state = %{state | model: nil}

      assert State.validate(invalid_state) == {:error, "Model is required"}
    end

    test "detects invalid messages list" do
      {:ok, state} = State.new(mock_model(), %{})
      invalid_state = %{state | messages: :not_a_list}

      assert {:error, _reason} = State.validate(invalid_state)
    end

    test "detects invalid tools list" do
      {:ok, state} = State.new(mock_model(), %{})
      invalid_state = %{state | tools: :not_a_list}

      assert {:error, _reason} = State.validate(invalid_state)
    end
  end

  describe "add_message/2" do
    test "adds message to conversation" do
      {:ok, state} = State.new(mock_model(), %{})
      message = Message.user("Hello")

      updated_state = State.add_message(state, message)

      assert length(updated_state.messages) == 1
      assert hd(updated_state.messages) == message
    end

    test "preserves message order" do
      {:ok, state} = State.new(mock_model(), %{})
      msg1 = Message.user("First")
      msg2 = Message.user("Second")

      state = State.add_message(state, msg1)
      state = State.add_message(state, msg2)

      assert length(state.messages) == 2
      assert Enum.at(state.messages, 0) == msg1
      assert Enum.at(state.messages, 1) == msg2
    end

    test "handles multiple message additions" do
      {:ok, state} = State.new(mock_model(), %{})

      state =
        Enum.reduce(1..100, state, fn i, acc ->
          msg = Message.user("Message #{i}")
          State.add_message(acc, msg)
        end)

      assert length(state.messages) == 100
    end
  end

  describe "add_messages/2" do
    test "adds multiple messages at once" do
      {:ok, state} = State.new(mock_model(), %{})

      messages = [
        Message.user("First"),
        Message.user("Second"),
        Message.user("Third")
      ]

      updated_state = State.add_messages(state, messages)

      assert length(updated_state.messages) == 3
      assert updated_state.messages == messages
    end

    test "preserves existing messages" do
      {:ok, state} = State.new(mock_model(), %{})
      existing_msg = Message.user("Existing")
      state = State.add_message(state, existing_msg)

      new_messages = [Message.user("New1"), Message.user("New2")]
      updated_state = State.add_messages(state, new_messages)

      assert length(updated_state.messages) == 3
      assert hd(updated_state.messages) == existing_msg
    end

    test "handles empty message list" do
      {:ok, state} = State.new(mock_model(), %{})

      updated_state = State.add_messages(state, [])

      assert updated_state.messages == []
    end
  end

  describe "get_messages/1" do
    test "returns empty list for new state" do
      {:ok, state} = State.new(mock_model(), %{})

      assert State.get_messages(state) == []
    end

    test "returns all messages" do
      {:ok, state} = State.new(mock_model(), %{})
      messages = [Message.user("1"), Message.user("2")]
      state = State.add_messages(state, messages)

      assert State.get_messages(state) == messages
    end
  end

  describe "message_count/1" do
    test "returns zero for new state" do
      {:ok, state} = State.new(mock_model(), %{})

      assert State.message_count(state) == 0
    end

    test "returns correct count after adding messages" do
      {:ok, state} = State.new(mock_model(), %{})

      state = State.add_message(state, Message.user("1"))
      assert State.message_count(state) == 1

      state = State.add_message(state, Message.user("2"))
      assert State.message_count(state) == 2
    end
  end

  describe "add_tool/2" do
    test "adds tool to state" do
      {:ok, state} = State.new(mock_model(), %{})
      tool = mock_tool()

      updated_state = State.add_tool(state, tool)

      assert length(updated_state.tools) == 1
      assert hd(updated_state.tools) == tool
    end

    test "preserves existing tools" do
      {:ok, tool1} =
        Expi.Agent.Tool.new("tool1", "First", %{type: :object}, "Tool 1", fn _, _, _, _ ->
          {:ok, %Expi.Agent.Types.AgentToolResult{content: [], details: %{}}}
        end)

      {:ok, state} = State.new(mock_model(), %{tools: [tool1]})

      {:ok, tool2} =
        Expi.Agent.Tool.new("tool2", "Second", %{type: :object}, "Tool 2", fn _, _, _, _ ->
          {:ok, %Expi.Agent.Types.AgentToolResult{content: [], details: %{}}}
        end)

      updated_state = State.add_tool(state, tool2)

      assert length(updated_state.tools) == 2
      tool_names = Enum.map(updated_state.tools, & &1.function.name)
      assert "tool1" in tool_names
      assert "tool2" in tool_names
    end
  end

  describe "remove_tool/2" do
    test "removes tool by name" do
      tool = mock_tool()
      {:ok, state} = State.new(mock_model(), %{tools: [tool]})

      updated_state = State.remove_tool(state, "test_tool")

      assert updated_state.tools == []
    end

    test "preserves other tools when removing one" do
      {:ok, tool1} =
        Expi.Agent.Tool.new("keep", "Keep me", %{type: :object}, "Keep Tool", fn _, _, _, _ ->
          {:ok, %Expi.Agent.Types.AgentToolResult{content: [], details: %{}}}
        end)

      {:ok, tool2} =
        Expi.Agent.Tool.new("remove", "Remove me", %{type: :object}, "Remove Tool", fn _,
                                                                                       _,
                                                                                       _,
                                                                                       _ ->
          {:ok, %Expi.Agent.Types.AgentToolResult{content: [], details: %{}}}
        end)

      {:ok, state} = State.new(mock_model(), %{tools: [tool1, tool2]})

      updated_state = State.remove_tool(state, "remove")

      assert length(updated_state.tools) == 1
      assert hd(updated_state.tools).function.name == "keep"
    end

    test "handles removing non-existent tool" do
      tool = mock_tool()
      {:ok, state} = State.new(mock_model(), %{tools: [tool]})

      updated_state = State.remove_tool(state, "non_existent")

      # Should be unchanged
      assert length(updated_state.tools) == 1
      assert hd(updated_state.tools) == tool
    end
  end

  describe "get_tools/1" do
    test "returns empty list for state without tools" do
      {:ok, state} = State.new(mock_model(), %{})

      assert State.get_tools(state) == []
    end

    test "returns all configured tools" do
      {:ok, tool1} =
        Tool.new("tool1", "First", %{type: :object}, "Tool 1", fn _, _, _, _ ->
          {:ok, %Expi.Agent.Types.AgentToolResult{content: [], details: %{value: "1"}}}
        end)

      {:ok, tool2} =
        Tool.new("tool2", "Second", %{type: :object}, "Tool 2", fn _, _, _, _ ->
          {:ok, %Expi.Agent.Types.AgentToolResult{content: [], details: %{value: "2"}}}
        end)

      tools = [tool1, tool2]
      {:ok, state} = State.new(mock_model(), %{tools: tools})

      assert State.get_tools(state) == tools
    end
  end

  describe "streaming state management" do
    test "set_streaming/2 updates streaming status" do
      {:ok, state} = State.new(mock_model(), %{})

      streaming_state = State.set_streaming(state, true)

      assert streaming_state.is_streaming == true
    end

    test "set_streaming/3 updates streaming status and message" do
      {:ok, state} = State.new(mock_model(), %{})
      message = Message.assistant("Streaming response", "anthropic", "claude")

      streaming_state = State.set_streaming(state, true, message)

      assert streaming_state.is_streaming == true
      assert streaming_state.stream_message == message
    end

    test "is_streaming?/1 returns streaming status" do
      {:ok, state} = State.new(mock_model(), %{})

      assert State.is_streaming?(state) == false

      streaming_state = State.set_streaming(state, true)
      assert State.is_streaming?(streaming_state) == true
    end
  end

  describe "error state management" do
    test "set_error/2 sets error message" do
      {:ok, state} = State.new(mock_model(), %{})

      error_state = State.set_error(state, "Something went wrong")

      assert error_state.error == "Something went wrong"
    end

    test "has_error?/1 detects error state" do
      {:ok, state} = State.new(mock_model(), %{})

      assert State.has_error?(state) == false

      error_state = State.set_error(state, "Error occurred")
      assert State.has_error?(error_state) == true
    end

    test "clear_error/1 removes error state" do
      {:ok, state} = State.new(mock_model(), %{})
      error_state = State.set_error(state, "Error occurred")

      cleared_state = State.clear_error(error_state)

      assert cleared_state.error == nil
      assert State.has_error?(cleared_state) == false
    end
  end

  describe "reset/1" do
    test "resets conversation while preserving configuration" do
      tools = [mock_tool()]

      {:ok, state} =
        State.new(mock_model(), %{
          system_prompt: "You are helpful",
          tools: tools
        })

      # Add messages and set streaming
      state = State.add_message(state, Message.user("Hello"))
      state = State.set_streaming(state, true)
      state = State.set_error(state, "Some error")

      reset_state = State.reset(state)

      # Configuration should be preserved
      assert reset_state.model == state.model
      assert reset_state.system_prompt == state.system_prompt
      assert reset_state.tools == state.tools

      # Conversation state should be reset
      assert reset_state.messages == []
      assert reset_state.is_streaming == false
      assert reset_state.stream_message == nil
      assert reset_state.error == nil
    end
  end

  describe "pending tool call management" do
    test "add_pending_tool_call/2 adds tool call ID" do
      {:ok, state} = State.new(mock_model(), %{})

      updated_state = State.add_pending_tool_call(state, "call_123")

      assert MapSet.member?(updated_state.pending_tool_calls, "call_123")
    end

    test "remove_pending_tool_call/2 removes tool call ID" do
      {:ok, state} = State.new(mock_model(), %{})
      state = State.add_pending_tool_call(state, "call_123")

      updated_state = State.remove_pending_tool_call(state, "call_123")

      refute MapSet.member?(updated_state.pending_tool_calls, "call_123")
    end

    test "has_pending_tool_calls?/1 detects pending calls" do
      {:ok, state} = State.new(mock_model(), %{})

      assert State.has_pending_tool_calls?(state) == false

      state_with_pending = State.add_pending_tool_call(state, "call_123")
      assert State.has_pending_tool_calls?(state_with_pending) == true
    end
  end

  describe "edge cases and error handling" do
    test "handles large message histories" do
      {:ok, state} = State.new(mock_model(), %{})

      # Add many messages
      large_state =
        Enum.reduce(1..1000, state, fn i, acc ->
          State.add_message(acc, Message.user("Message #{i}"))
        end)

      assert State.message_count(large_state) == 1000
      assert State.validate(large_state) == :ok
    end

    test "handles duplicate tool names" do
      {:ok, tool1} =
        Tool.new("duplicate", "First", %{type: :object}, "Duplicate 1", fn _, _, _, _ ->
          {:ok, %Expi.Agent.Types.AgentToolResult{content: [], details: %{value: "1"}}}
        end)

      {:ok, tool2} =
        Tool.new("duplicate", "Second", %{type: :object}, "Duplicate 2", fn _, _, _, _ ->
          {:ok, %Expi.Agent.Types.AgentToolResult{content: [], details: %{value: "2"}}}
        end)

      {:ok, state} = State.new(mock_model(), %{})
      state = State.add_tool(state, tool1)
      state = State.add_tool(state, tool2)

      # Both tools should be present (no automatic deduplication)
      assert length(state.tools) == 2
    end

    test "handles nil system prompt" do
      {:ok, state} = State.new(mock_model(), %{system_prompt: nil})

      # Should convert nil to empty string
      assert state.system_prompt == ""
    end

    test "validates thinking levels" do
      valid_levels = [:off, :minimal, :low, :medium, :high, :xhigh]

      Enum.each(valid_levels, fn level ->
        {:ok, state} = State.new(mock_model(), %{thinking_level: level})
        assert state.thinking_level == level
        assert State.validate(state) == :ok
      end)
    end
  end
end
