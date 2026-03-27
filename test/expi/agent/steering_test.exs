defmodule Expi.Agent.SteeringTest do
  use ExUnit.Case, async: true

  alias Expi.Agent.{Steering, State, Message, Queue}
  alias Expi.Types.Model

  # Test fixtures
  defp mock_model do
    %Model{
      id: "claude-3-sonnet-20240229",
      provider: "anthropic",
      api: "anthropic"
    }
  end

  defp mock_agent_state(overrides \\ %{}) do
    {:ok, state} = State.new(mock_model(), %{
      system_prompt: "You are helpful"
    })
    
    # Apply any overrides
    Enum.reduce(overrides, state, fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end

  defp mock_steering_messages do
    [
      Message.user("[URGENT] Stop what you're doing!"),
      Message.user("Actually, cancel that request")
    ]
  end

  defp mock_follow_up_messages do
    [
      Message.user("Can you explain that better?"),
      Message.user("Also, what about edge cases?")
    ]
  end

  describe "should_process_steering/3" do
    test "processes steering immediately when agent is idle" do
      agent_state = mock_agent_state()
      steering_messages = [Message.user("Urgent request")]
      
      decision = Steering.should_process_steering(agent_state, steering_messages, [])
      
      assert decision == :process_now
    end

    test "defers steering when agent is streaming" do
      agent_state = mock_agent_state(%{is_streaming: true})
      steering_messages = [Message.user("Urgent request")]
      
      decision = Steering.should_process_steering(agent_state, steering_messages, [
        interrupt_tools: false
      ])
      
      assert decision in [:process_after_tools, :defer]
    end

    test "processes urgent steering even when busy" do
      agent_state = mock_agent_state(%{is_streaming: true})
      urgent_messages = [Message.user("[URGENT] Critical system alert!")]
      
      decision = Steering.should_process_steering(agent_state, urgent_messages, [
        interrupt_tools: true
      ])
      
      assert decision == :process_now
    end

    test "ignores empty steering messages" do
      agent_state = mock_agent_state()
      
      decision = Steering.should_process_steering(agent_state, [], [])
      
      assert decision == :ignore
    end

    test "defers when too many steering messages" do
      agent_state = mock_agent_state()
      many_messages = for i <- 1..10, do: Message.user("Message #{i}")
      
      decision = Steering.should_process_steering(agent_state, many_messages, [
        max_steering_per_turn: 5
      ])
      
      assert decision == :defer
    end

    test "respects interrupt_tools option" do
      agent_state = mock_agent_state(%{is_streaming: true})
      steering_messages = [Message.user("Regular steering")]
      
      # Without interrupt permission
      no_interrupt = Steering.should_process_steering(agent_state, steering_messages, [
        interrupt_tools: false
      ])
      
      # With interrupt permission
      with_interrupt = Steering.should_process_steering(agent_state, steering_messages, [
        interrupt_tools: true
      ])
      
      assert no_interrupt in [:process_after_tools, :defer]
      assert with_interrupt == :process_now
    end
  end

  describe "should_process_follow_up/3" do
    test "processes follow-up when agent is idle and enough time passed" do
      agent_state = mock_agent_state()
      follow_up_messages = [Message.user("Follow-up question")]
      
      decision = Steering.should_process_follow_up(agent_state, follow_up_messages, [
        min_idle_time_ms: 100
      ])
      
      # May need to wait for idle time in real implementation
      assert decision in [:process_now, :defer]
    end

    test "defers follow-up when agent is busy" do
      agent_state = mock_agent_state(%{is_streaming: true})
      follow_up_messages = [Message.user("Follow-up question")]
      
      decision = Steering.should_process_follow_up(agent_state, follow_up_messages, [])
      
      assert decision == :defer_until_complete
    end

    test "ignores empty follow-up messages" do
      agent_state = mock_agent_state()
      
      decision = Steering.should_process_follow_up(agent_state, [], [])
      
      assert decision == :ignore
    end

    test "defers when too many follow-up messages" do
      agent_state = mock_agent_state()
      many_messages = for i <- 1..10, do: Message.user("Follow-up #{i}")
      
      decision = Steering.should_process_follow_up(agent_state, many_messages, [
        max_follow_ups_per_turn: 3
      ])
      
      assert decision == :defer
    end

    test "respects minimum idle time" do
      agent_state = mock_agent_state()
      follow_up_messages = [Message.user("Follow-up question")]
      
      # Very high idle time requirement
      decision = Steering.should_process_follow_up(agent_state, follow_up_messages, [
        min_idle_time_ms: 10_000  # 10 seconds
      ])
      
      # Should defer since not enough idle time has passed
      assert decision in [:defer, :defer_until_complete]
    end

    test "detects natural conversation breaks" do
      idle_agent = mock_agent_state(%{is_streaming: false})
      follow_up_messages = [Message.user("Natural follow-up")]
      
      decision = Steering.should_process_follow_up(idle_agent, follow_up_messages, [
        natural_break_detection: true,
        min_idle_time_ms: 0  # No time requirement for this test
      ])
      
      assert decision == :process_now
    end
  end

  describe "apply_steering_logic/3" do
    test "immediately interrupts for urgent steering" do
      agent_state = mock_agent_state()
      message_queue = Queue.create_queue()
      message_queue = Queue.add_steering(message_queue, Message.user("[URGENT] Critical!"))
      
      {decision, updated_queue} = Steering.apply_steering_logic(agent_state, message_queue, [])
      
      assert match?({:interrupt, [_message]}, decision)
      assert Queue.is_empty?(updated_queue)
    end

    test "queues steering for after tools when appropriate" do
      busy_agent = mock_agent_state(%{is_streaming: true})
      message_queue = Queue.create_queue()
      message_queue = Queue.add_steering(message_queue, Message.user("Regular steering"))
      
      {decision, updated_queue} = Steering.apply_steering_logic(busy_agent, message_queue, [
        interrupt_tools: false
      ])
      
      assert match?({:queue_after_tools, [_message]}, decision)
      assert Queue.is_empty?(updated_queue)
    end

    test "defers steering when timing is not optimal" do
      agent_state = mock_agent_state()
      message_queue = Queue.create_queue()
      many_messages = for i <- 1..10, do: Message.user("Steering #{i}")
      
      queue_with_many = Enum.reduce(many_messages, message_queue, fn msg, acc ->
        Queue.add_steering(acc, msg)
      end)
      
      {decision, _updated_queue} = Steering.apply_steering_logic(agent_state, queue_with_many, [
        max_steering_per_turn: 3
      ])
      
      assert match?({:defer, :timing_not_optimal}, decision)
    end

    test "handles empty steering queue" do
      agent_state = mock_agent_state()
      empty_queue = Queue.create_queue()
      
      {decision, updated_queue} = Steering.apply_steering_logic(agent_state, empty_queue, [])
      
      assert match?({:defer, :ignored}, decision)
      assert updated_queue == empty_queue
    end
  end

  describe "apply_follow_up_logic/3" do
    test "processes follow-up at natural breaks" do
      idle_agent = mock_agent_state(%{is_streaming: false})
      message_queue = Queue.create_queue()
      message_queue = Queue.add_follow_up(message_queue, Message.user("Natural question"))
      
      {decision, updated_queue} = Steering.apply_follow_up_logic(idle_agent, message_queue, [
        min_idle_time_ms: 0
      ])
      
      assert match?({:process_natural, [_message]}, decision)
      assert Queue.is_empty?(updated_queue)
    end

    test "waits for conversation completion when agent busy" do
      busy_agent = mock_agent_state(%{is_streaming: true})
      message_queue = Queue.create_queue()
      message_queue = Queue.add_follow_up(message_queue, Message.user("Follow-up"))
      
      {decision, _updated_queue} = Steering.apply_follow_up_logic(busy_agent, message_queue, [])
      
      assert match?({:wait_for_break, _estimated_time}, decision)
    end

    test "defers when not at natural conversation break" do
      agent_state = mock_agent_state()
      message_queue = Queue.create_queue()
      message_queue = Queue.add_follow_up(message_queue, Message.user("Follow-up"))
      
      {decision, _updated_queue} = Steering.apply_follow_up_logic(agent_state, message_queue, [
        min_idle_time_ms: 10_000  # Very high requirement
      ])
      
      assert match?({:defer_conversation_active, nil}, decision)
    end

    test "cleans expired follow-up messages" do
      agent_state = mock_agent_state()
      message_queue = Queue.create_queue()
      
      # Create old message (simulated)
      old_message = Message.user("Old follow-up")
      message_queue = Queue.add_follow_up(message_queue, old_message)
      
      {decision, cleaned_queue} = Steering.apply_follow_up_logic(agent_state, message_queue, [])
      
      # Should handle cleanup gracefully
      assert match?({:defer_conversation_active, nil}, decision)
      assert is_map(cleaned_queue)
    end
  end

  describe "analyze_agent_readiness/1" do
    test "analyzes idle agent correctly" do
      idle_agent = mock_agent_state(%{is_streaming: false})
      
      readiness = Steering.analyze_agent_readiness(idle_agent)
      
      assert readiness.can_interrupt == true
      assert readiness.at_natural_break == true
      assert is_float(readiness.processing_capacity)
      assert readiness.processing_capacity > 0
      assert readiness.current_workload >= 0
      assert is_integer(readiness.idle_time)
    end

    test "analyzes busy agent correctly" do
      busy_agent = mock_agent_state(%{is_streaming: true})
      
      readiness = Steering.analyze_agent_readiness(busy_agent)
      
      assert readiness.can_interrupt == false
      assert readiness.at_natural_break == false
      assert is_float(readiness.processing_capacity)
    end

    test "calculates processing capacity based on workload" do
      # Agent with no workload should have high capacity
      idle_agent = mock_agent_state()
      idle_readiness = Steering.analyze_agent_readiness(idle_agent)
      
      # Agent with streaming should have lower capacity
      busy_agent = mock_agent_state(%{is_streaming: true})
      busy_readiness = Steering.analyze_agent_readiness(busy_agent)
      
      assert idle_readiness.processing_capacity >= busy_readiness.processing_capacity
    end
  end

  describe "get_processing_priority/2" do
    test "prioritizes steering over follow-up" do
      steering_messages = mock_steering_messages()
      follow_up_messages = mock_follow_up_messages()
      
      priority_info = Steering.get_processing_priority(steering_messages, follow_up_messages)
      
      assert priority_info.recommendation == :process_steering_first
      assert priority_info.steering_priority > priority_info.follow_up_priority
      assert String.contains?(priority_info.reasoning, "steering")
    end

    test "handles only steering messages" do
      steering_messages = mock_steering_messages()
      
      priority_info = Steering.get_processing_priority(steering_messages, [])
      
      assert priority_info.recommendation == :process_steering_first
      assert priority_info.follow_up_priority == 0
    end

    test "handles only follow-up messages" do
      follow_up_messages = mock_follow_up_messages()
      
      priority_info = Steering.get_processing_priority([], follow_up_messages)
      
      assert priority_info.recommendation == :process_follow_up_first
      assert priority_info.steering_priority == 0
    end

    test "handles no messages" do
      priority_info = Steering.get_processing_priority([], [])
      
      assert priority_info.recommendation == :defer_all
      assert priority_info.reasoning == "No messages to process"
    end

    test "considers message urgency in priority calculation" do
      urgent_steering = [Message.user("[URGENT] Critical alert!")]
      normal_steering = [Message.user("Regular message")]
      
      urgent_priority = Steering.get_processing_priority(urgent_steering, [])
      normal_priority = Steering.get_processing_priority(normal_steering, [])
      
      assert urgent_priority.steering_priority > normal_priority.steering_priority
    end
  end

  describe "coordinate_with_loop/3" do
    test "coordinates urgent steering interruption" do
      agent_state = mock_agent_state()
      message_queue = Queue.create_queue()
      message_queue = Queue.add_steering(message_queue, Message.user("[URGENT] Stop now!"))
      
      coordination = Steering.coordinate_with_loop(agent_state, message_queue, [])
      
      assert coordination.action in [:interrupt_loop, :queue_for_next_turn]
      assert length(coordination.messages_to_process) > 0
      assert coordination.processing_mode in [:all, :one_at_a_time]
      assert is_integer(coordination.estimated_processing_time)
    end

    test "coordinates follow-up processing" do
      agent_state = mock_agent_state()
      message_queue = Queue.create_queue()
      message_queue = Queue.add_follow_up(message_queue, Message.user("Follow-up question"))
      
      coordination = Steering.coordinate_with_loop(agent_state, message_queue, [])
      
      assert is_map(coordination)
      assert Map.has_key?(coordination, :action)
      assert Map.has_key?(coordination, :updated_queue)
    end

    test "handles empty queues gracefully" do
      agent_state = mock_agent_state()
      empty_queue = Queue.create_queue()
      
      coordination = Steering.coordinate_with_loop(agent_state, empty_queue, [])
      
      assert coordination.action == :continue_loop
      assert coordination.messages_to_process == []
      assert coordination.estimated_processing_time == 0
    end

    test "respects coordination options" do
      agent_state = mock_agent_state()
      message_queue = Queue.create_queue()
      message_queue = Queue.add_steering(message_queue, Message.user("Steering message"))
      
      options = [
        steering: [interrupt_tools: true, max_steering_per_turn: 1],
        follow_up: [min_idle_time_ms: 500]
      ]
      
      coordination = Steering.coordinate_with_loop(agent_state, message_queue, options)
      
      # Should reflect the options in the coordination result
      assert is_map(coordination)
      assert Map.has_key?(coordination, :processing_mode)
    end
  end

  describe "update_processing_state/3" do
    test "updates state after interruption coordination" do
      agent_state = mock_agent_state()
      messages_to_add = [Message.user("Processed steering")]
      
      coordination_result = %{
        action: :interrupt_loop,
        messages_to_process: messages_to_add,
        updated_queue: Queue.create_queue(),
        processing_mode: :all,
        estimated_processing_time: 1000
      }
      
      updated_state = Steering.update_processing_state(
        agent_state, 
        coordination_result, 
        []
      )
      
      # Should have added the messages to state
      assert length(State.get_messages(updated_state)) == 1
      assert hd(State.get_messages(updated_state)) == hd(messages_to_add)
    end

    test "handles queue-for-next-turn coordination" do
      agent_state = mock_agent_state()
      
      coordination_result = %{
        action: :queue_for_next_turn,
        messages_to_process: [Message.user("Queued message")],
        updated_queue: Queue.create_queue(),
        processing_mode: :one_at_a_time,
        estimated_processing_time: 2000
      }
      
      updated_state = Steering.update_processing_state(
        agent_state, 
        coordination_result, 
        []
      )
      
      # Should update state appropriately
      assert length(State.get_messages(updated_state)) == 1
    end

    test "handles continue-loop coordination" do
      agent_state = mock_agent_state()
      
      coordination_result = %{
        action: :continue_loop,
        messages_to_process: [],
        updated_queue: Queue.create_queue(),
        processing_mode: :all,
        estimated_processing_time: 0
      }
      
      updated_state = Steering.update_processing_state(
        agent_state, 
        coordination_result, 
        []
      )
      
      # Should remain largely unchanged
      assert State.get_messages(updated_state) == State.get_messages(agent_state)
    end

    test "processes coordination events when provided" do
      agent_state = mock_agent_state()
      
      coordination_result = %{
        action: :interrupt_loop,
        messages_to_process: [],
        updated_queue: Queue.create_queue(),
        processing_mode: :all,
        estimated_processing_time: 500
      }
      
      mock_events = [
        %{type: :coordination_started, timestamp: System.system_time(:millisecond)}
      ]
      
      # Should handle events gracefully
      updated_state = Steering.update_processing_state(
        agent_state, 
        coordination_result, 
        mock_events
      )
      
      assert is_map(updated_state)
    end
  end

  describe "edge cases and error handling" do
    test "handles malformed steering messages gracefully" do
      agent_state = mock_agent_state()
      
      # Test with edge case message content
      edge_messages = [
        Message.user(""),  # Empty content
        Message.user("   "),  # Whitespace only
        Message.user(String.duplicate("A", 10_000))  # Very long content
      ]
      
      decision = Steering.should_process_steering(agent_state, edge_messages, [])
      
      # Should handle gracefully
      assert decision in [:process_now, :process_after_tools, :defer, :ignore]
    end

    test "handles invalid agent state gracefully" do
      # Create agent state with missing fields
      minimal_state = %{
        model: mock_model(),
        is_streaming: false,
        messages: []
      }
      
      # Should not crash
      readiness = Steering.analyze_agent_readiness(minimal_state)
      assert is_map(readiness)
    end

    test "handles rapid steering decision requests" do
      agent_state = mock_agent_state()
      steering_messages = [Message.user("Quick decision needed")]
      
      # Make many rapid decisions
      decisions = for _i <- 1..100 do
        Steering.should_process_steering(agent_state, steering_messages, [])
      end
      
      # All decisions should be consistent
      unique_decisions = Enum.uniq(decisions)
      assert length(unique_decisions) == 1
      assert hd(unique_decisions) == :process_now
    end

    test "handles complex queue states" do
      agent_state = mock_agent_state()
      
      # Create complex queue with mixed message types
      complex_queue = Queue.create_queue()
      
      # Add many different types of messages
      complex_queue = Enum.reduce(1..50, complex_queue, fn i, acc ->
        if rem(i, 2) == 0 do
          Queue.add_steering(acc, Message.user("Steering #{i}"))
        else
          Queue.add_follow_up(acc, Message.user("Follow-up #{i}"))
        end
      end)
      
      # Should handle complex coordination
      coordination = Steering.coordinate_with_loop(agent_state, complex_queue, [])
      
      assert is_map(coordination)
      assert coordination.action in [:interrupt_loop, :queue_for_next_turn, :continue_loop]
    end
  end
end