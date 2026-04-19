defmodule Expi.AgentTest do
  use ExUnit.Case, async: true
  doctest Expi.Agent

  alias Expi.Agent
  alias Expi.Agent.{Message}
  alias Expi.Agent.Types.AgentTool
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
        "calculator",
        "Performs mathematical calculations",
        %{
          type: :object,
          properties: %{
            expression: %{type: :string, description: "Mathematical expression"}
          },
          required: ["expression"]
        },
        "Calculator",
        fn _tool_call_id, params, _abort_signal, _update_callback ->
          expr = params["expression"]

          try do
            # Simple expression evaluation for testing
            {result, _} = Code.eval_string(expr)

            {:ok,
             %Expi.Agent.Types.AgentToolResult{
               content: [%Expi.Types.TextContent{type: :text, text: to_string(result)}],
               details: %{expression: expr, result: result}
             }}
          rescue
            _ -> {:error, "Invalid expression"}
          end
        end
      )

    tool
  end

  describe "create/2" do
    test "creates agent with valid model and config" do
      model = mock_model()
      config = %{system_prompt: "You are a helpful assistant"}

      assert {:ok, agent} = Agent.create(model, config)
      assert agent.model == model
      assert agent.system_prompt == "You are a helpful assistant"
      assert agent.messages == []
      assert agent.tools == []
      assert agent.is_streaming == false
    end

    test "creates agent with tools" do
      model = mock_model()
      tool = mock_tool()
      config = %{tools: [tool]}

      assert {:ok, agent} = Agent.create(model, config)
      assert length(agent.tools) == 1
      assert hd(agent.tools).function.name == "calculator"
    end

    test "creates agent with empty config" do
      model = mock_model()

      assert {:ok, agent} = Agent.create(model, %{})
      assert agent.model == model
      assert agent.system_prompt == ""
      assert agent.messages == []
    end
  end

  describe "validate/1 and valid?/1" do
    test "validates properly configured agent" do
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{})

      assert Agent.validate(agent) == :ok
      assert Agent.valid?(agent) == true
    end

    test "detects invalid agent state" do
      # Create invalid agent by setting model to nil
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{})
      invalid_agent = %{agent | model: nil}

      assert {:error, _reason} = Agent.validate(invalid_agent)
      assert Agent.valid?(invalid_agent) == false
    end
  end

  describe "reset/1" do
    test "resets agent conversation while preserving config" do
      model = mock_model()
      tool = mock_tool()

      config = %{
        system_prompt: "You are a helpful assistant",
        tools: [tool]
      }

      {:ok, agent} = Agent.create(model, config)
      {:ok, agent_with_message} = Agent.send_message(agent, "Hello")

      # Agent should have messages
      assert length(Agent.get_messages(agent_with_message)) == 1

      # Reset should clear messages but preserve config
      reset_agent = Agent.reset(agent_with_message)
      assert length(Agent.get_messages(reset_agent)) == 0
      assert reset_agent.model == model
      assert reset_agent.system_prompt == "You are a helpful assistant"
      assert length(reset_agent.tools) == 1
    end
  end

  describe "clone/1" do
    test "creates deep copy of agent" do
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{system_prompt: "Original"})
      {:ok, agent_with_message} = Agent.send_message(agent, "Hello")

      # Small delay to ensure different timestamps
      Process.sleep(1)
      cloned_agent = Agent.clone(agent_with_message)

      # Should have same config and messages
      assert cloned_agent.model == agent_with_message.model
      assert cloned_agent.system_prompt == agent_with_message.system_prompt

      assert length(Agent.get_messages(cloned_agent)) ==
               length(Agent.get_messages(agent_with_message))

      # But should be independent instances
      refute cloned_agent == agent_with_message

      # Streaming and error state should be reset
      assert cloned_agent.is_streaming == false
      assert cloned_agent.stream_message == nil
      assert cloned_agent.error == nil
    end
  end

  describe "send_message/2" do
    test "adds user message to conversation" do
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{})

      assert {:ok, updated_agent} = Agent.send_message(agent, "Hello, how are you?")

      messages = Agent.get_messages(updated_agent)
      assert length(messages) == 1
      assert hd(messages).role == :user
      assert Message.content(hd(messages)) == "Hello, how are you?"
    end

    test "preserves message order" do
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{})

      {:ok, agent} = Agent.send_message(agent, "First message")
      {:ok, agent} = Agent.send_message(agent, "Second message")

      messages = Agent.get_messages(agent)
      assert length(messages) == 2
      assert Message.content(Enum.at(messages, 0)) == "First message"
      assert Message.content(Enum.at(messages, 1)) == "Second message"
    end
  end

  describe "add_steering/2" do
    test "adds steering message with high priority" do
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{})

      assert {:ok, updated_agent} = Agent.add_steering(agent, "STOP! This is urgent!")

      messages = Agent.get_messages(updated_agent)
      assert length(messages) == 1
      assert hd(messages).role == :user
      assert Message.content(hd(messages)) == "STOP! This is urgent!"
    end
  end

  describe "add_follow_up/2" do
    test "adds follow-up message for natural continuation" do
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{})

      assert {:ok, updated_agent} = Agent.add_follow_up(agent, "Can you also explain that?")

      messages = Agent.get_messages(updated_agent)
      assert length(messages) == 1
      assert hd(messages).role == :user
      assert Message.content(hd(messages)) == "Can you also explain that?"
    end
  end

  describe "tool management" do
    test "add_tool/2 adds tool to agent" do
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{})
      tool = mock_tool()

      updated_agent = Agent.add_tool(agent, tool)
      tools = Agent.get_tools(updated_agent)

      assert length(tools) == 1
      assert Expi.Agent.Tool.names(tools) == ["calculator"]
    end

    test "remove_tool/2 removes tool by name" do
      model = mock_model()
      tool = mock_tool()
      {:ok, agent} = Agent.create(model, %{tools: [tool]})

      updated_agent = Agent.remove_tool(agent, "calculator")
      tools = Agent.get_tools(updated_agent)

      assert length(tools) == 0
    end

    test "add multiple tools" do
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{})

      {:ok, tool1} =
        Expi.Agent.Tool.new("search", "Search", %{type: :object}, "Search Tool", fn _, _, _, _ ->
          {:ok, %Expi.Agent.Types.AgentToolResult{content: [], details: %{}}}
        end)

      {:ok, tool2} =
        Expi.Agent.Tool.new("calc", "Calculate", %{type: :object}, "Calculator", fn _, _, _, _ ->
          {:ok, %Expi.Agent.Types.AgentToolResult{content: [], details: %{}}}
        end)

      agent = Agent.add_tool(agent, tool1)
      agent = Agent.add_tool(agent, tool2)

      tools = Agent.get_tools(agent)
      assert length(tools) == 2
      tool_names = Expi.Agent.Tool.names(tools)
      assert "search" in tool_names
      assert "calc" in tool_names
    end
  end

  describe "get_messages/1" do
    test "returns empty list for new agent" do
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{})

      assert Agent.get_messages(agent) == []
    end

    test "returns messages in chronological order" do
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{})

      {:ok, agent} = Agent.send_message(agent, "First")
      {:ok, agent} = Agent.send_message(agent, "Second")

      messages = Agent.get_messages(agent)
      assert length(messages) == 2
      assert Message.content(hd(messages)) == "First"
      assert Message.content(List.last(messages)) == "Second"
    end
  end

  describe "get_tools/1" do
    test "returns empty list for agent without tools" do
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{})

      assert Agent.get_tools(agent) == []
    end

    test "returns configured tools" do
      model = mock_model()
      tool = mock_tool()
      {:ok, agent} = Agent.create(model, %{tools: [tool]})

      tools = Agent.get_tools(agent)
      assert length(tools) == 1
      assert hd(tools).function.name == "calculator"
    end
  end

  describe "get_stats/1" do
    test "returns comprehensive agent statistics" do
      model = mock_model()
      tool = mock_tool()

      {:ok, agent} =
        Agent.create(model, %{
          system_prompt: "You are helpful",
          tools: [tool]
        })

      {:ok, agent} = Agent.send_message(agent, "Hello")

      stats = Agent.get_stats(agent)

      assert stats.message_count == 1
      assert stats.tool_count == 1
      assert stats.model == "claude-3-sonnet-20240229"
      assert stats.provider == "anthropic"
      assert stats.is_streaming == false
      assert stats.has_error == false
      assert stats.system_prompt_length == String.length("You are helpful")
      assert %DateTime{} = stats.created_at
    end

    test "includes last activity timestamp when messages exist" do
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{})
      {:ok, agent} = Agent.send_message(agent, "Hello")

      stats = Agent.get_stats(agent)
      assert %DateTime{} = stats.last_activity
    end

    test "has nil last activity for agent without messages" do
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{})

      stats = Agent.get_stats(agent)
      assert stats.last_activity == nil
    end
  end

  describe "get_config/1" do
    test "returns agent configuration" do
      model = mock_model()

      {:ok, agent} =
        Agent.create(model, %{
          system_prompt: "Test prompt",
          max_context_length: 100_000,
          temperature: 0.7
        })

      config = Agent.get_config(agent)

      assert config.model == model
      assert config.system_prompt == "Test prompt"
    end
  end

  describe "execute_pending_tools/2" do
    test "returns empty results when no tool calls pending" do
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{})

      assert {:ok, updated_agent, results} = Agent.execute_pending_tools(agent)
      assert updated_agent == agent
      assert results == []
    end

    test "handles tool execution timeout" do
      model = mock_model()

      {:ok, slow_tool} =
        Expi.Agent.Tool.new(
          "slow",
          "Slow tool",
          %{type: :object, properties: %{}},
          "Slow Tool",
          fn _, _, _, _ ->
            Process.sleep(5000)
            {:ok, %Expi.Agent.Types.AgentToolResult{content: [], details: %{result: "done"}}}
          end
        )

      {:ok, agent} = Agent.create(model, %{tools: [slow_tool]})

      # Should not hang with short timeout
      assert {:ok, _agent, _results} = Agent.execute_pending_tools(agent, %{timeout: 100})
    end
  end

  describe "process_turn/2" do
    test "processes single turn without hanging" do
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{})
      {:ok, agent} = Agent.send_message(agent, "Hello")

      # This should not hang - it's a basic functionality test
      # In a full implementation this would interact with the AI model
      assert {:ok, _updated_agent, turn_data} = Agent.process_turn(agent, %{timeout: 1000})
      assert is_map(turn_data)
    end
  end

  describe "stream_response/2" do
    test "handles streaming without callback" do
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{})
      {:ok, agent} = Agent.send_message(agent, "Hello")

      # Should not crash without callback
      assert {:ok, _updated_agent, _response} = Agent.stream_response(agent)
    end

    test "calls streaming callback when provided" do
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{})
      {:ok, agent} = Agent.send_message(agent, "Hello")

      test_pid = self()

      callback = fn event ->
        send(test_pid, {:stream_event, event})
      end

      {:ok, _agent, _response} = Agent.stream_response(agent, callback)

      # Should receive callback event
      assert_receive {:stream_event, %{type: :done}}, 2000
    end
  end

  describe "apply_transforms/2" do
    test "applies message transformation function" do
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{})
      {:ok, agent} = Agent.send_message(agent, "Message 1")
      {:ok, agent} = Agent.send_message(agent, "Message 2")
      {:ok, agent} = Agent.send_message(agent, "Message 3")

      # Transform to keep only last 2 messages
      transform_fn = fn messages, _context ->
        recent_messages = Enum.take(messages, -2)
        {:ok, recent_messages}
      end

      assert {:ok, transformed_agent} =
               Agent.apply_transforms(agent, %{
                 transform_context: transform_fn
               })

      messages = Agent.get_messages(transformed_agent)
      assert length(messages) == 2
      assert Message.content(hd(messages)) == "Message 2"
      assert Message.content(List.last(messages)) == "Message 3"
    end

    test "handles transform function errors" do
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{})

      failing_transform = fn _messages, _context ->
        {:error, "Transform failed"}
      end

      assert {:error, "Transform failed"} =
               Agent.apply_transforms(agent, %{
                 transform_context: failing_transform
               })
    end
  end

  describe "error handling" do
    test "gracefully handles invalid configurations" do
      # Test with nil model
      assert_raise BadMapError, fn ->
        Agent.create(nil, %{})
      end
    end

    test "handles empty messages gracefully" do
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{})

      # Empty string should still work
      assert {:ok, _updated_agent} = Agent.send_message(agent, "")
    end
  end

  describe "integration tests" do
    test "complete workflow with tools" do
      model = mock_model()
      tool = mock_tool()

      # Create agent with tool
      {:ok, agent} =
        Agent.create(model, %{
          system_prompt: "You are a calculator assistant",
          tools: [tool]
        })

      # Add user message
      {:ok, agent} = Agent.send_message(agent, "Calculate 2 + 2")

      # Verify agent state
      assert Agent.valid?(agent)
      assert length(Agent.get_messages(agent)) == 1
      assert length(Agent.get_tools(agent)) == 1

      # Get statistics
      stats = Agent.get_stats(agent)
      assert stats.message_count == 1
      assert stats.tool_count == 1
    end

    test "message ordering across different types" do
      model = mock_model()
      {:ok, agent} = Agent.create(model, %{})

      {:ok, agent} = Agent.send_message(agent, "Regular message")
      {:ok, agent} = Agent.add_steering(agent, "Urgent interruption")
      {:ok, agent} = Agent.add_follow_up(agent, "Follow-up question")

      messages = Agent.get_messages(agent)
      assert length(messages) == 3
      assert Message.content(Enum.at(messages, 0)) == "Regular message"
      assert Message.content(Enum.at(messages, 1)) == "Urgent interruption"
      assert Message.content(Enum.at(messages, 2)) == "Follow-up question"
    end

    test "agent cloning preserves functionality" do
      model = mock_model()
      tool = mock_tool()
      {:ok, agent} = Agent.create(model, %{tools: [tool]})
      {:ok, agent} = Agent.send_message(agent, "Original message")

      cloned_agent = Agent.clone(agent)
      {:ok, cloned_agent} = Agent.send_message(cloned_agent, "Cloned message")

      # Original should be unchanged
      assert length(Agent.get_messages(agent)) == 1

      # Clone should have both messages
      assert length(Agent.get_messages(cloned_agent)) == 2

      # Both should have same tools
      assert length(Agent.get_tools(agent)) == length(Agent.get_tools(cloned_agent))
    end
  end
end
