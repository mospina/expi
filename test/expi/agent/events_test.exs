defmodule Expi.Agent.EventsTest do
  # Events may involve process communication
  use ExUnit.Case, async: false

  alias Expi.Agent.Events
  alias Expi.Agent.Types.AgentEvent
  alias Expi.Agent.{Message, State}
  alias Expi.Types.{Model, ToolResultMessage}

  # Test fixtures
  defp mock_model do
    %Model{
      id: "claude-3-sonnet-20240229",
      provider: "anthropic",
      api: "anthropic"
    }
  end

  defp mock_agent_state do
    {:ok, state} =
      State.new(mock_model(), %{
        system_prompt: "You are helpful"
      })

    state
  end

  describe "agent_lifecycle_event/2" do
    test "creates agent start event" do
      agent_state = mock_agent_state()

      event = Events.agent_lifecycle_event(:start, agent_state)

      assert %AgentEvent{} = event
      assert event.type == :agent_start
      assert event.agent_state == agent_state
      assert is_integer(event.timestamp)
    end

    test "creates agent end event" do
      agent_state = mock_agent_state()

      event = Events.agent_lifecycle_event(:end, agent_state)

      assert event.type == :agent_end
      assert event.agent_state == agent_state
    end

    test "creates agent error event with details" do
      agent_state = mock_agent_state()
      error_details = "Network connection failed"

      event = Events.agent_lifecycle_event(:error, agent_state, error_details)

      assert event.type == :agent_error
      assert event.agent_state == agent_state
      assert event.error_details == error_details
    end
  end

  describe "turn_lifecycle_event/3" do
    test "creates turn start event" do
      event = Events.turn_lifecycle_event(:start, 1)

      assert event.type == :turn_start
      assert event.turn_number == 1
      assert is_integer(event.timestamp)
    end

    test "creates turn end event with results" do
      assistant_msg = Message.assistant("Response", "anthropic", "claude")

      tool_results = [
        %ToolResultMessage{
          role: :tool,
          tool_call_id: "call_123",
          tool_name: "calculator",
          content: "42",
          is_error: false,
          timestamp: System.system_time(:millisecond)
        }
      ]

      event =
        Events.turn_lifecycle_event(:end, 1, %{
          assistant_message: assistant_msg,
          tool_results: tool_results
        })

      assert event.type == :turn_end
      assert event.turn_number == 1
      assert event.assistant_message == assistant_msg
      assert event.tool_results == tool_results
    end
  end

  describe "message_lifecycle_event/2" do
    test "creates message start event" do
      message = Message.user("Hello")

      event = Events.message_lifecycle_event(:start, message)

      assert event.type == :message_start
      assert event.message == message
    end

    test "creates message update event with streaming data" do
      message = Message.assistant("Streaming response", "anthropic", "claude")
      stream_data = %{delta: "new text", content_index: 0}

      event = Events.message_lifecycle_event(:update, message, stream_data)

      assert event.type == :message_update
      assert event.message == message
      assert event.assistant_message_event == stream_data
    end

    test "creates message end event" do
      message = Message.assistant("Complete response", "anthropic", "claude")

      event = Events.message_lifecycle_event(:end, message)

      assert event.type == :message_end
      assert event.message == message
    end
  end

  describe "tool_execution_event/4" do
    test "creates tool start event" do
      event = Events.tool_execution_event(:start, "call_123", "calculator", %{"expr" => "2+2"})

      assert event.type == :tool_execution_start
      assert event.tool_call_id == "call_123"
      assert event.tool_name == "calculator"
      assert event.arguments == %{"expr" => "2+2"}
    end

    test "creates tool update event with partial results" do
      event =
        Events.tool_execution_event(
          :update,
          "call_456",
          "search",
          %{"query" => "test"},
          "Searching..."
        )

      assert event.type == :tool_execution_update
      assert event.tool_call_id == "call_456"
      assert event.partial_result == "Searching..."
    end

    test "creates tool end event with final result" do
      tool_result = %ToolResultMessage{
        role: :tool,
        tool_call_id: "call_789",
        tool_name: "weather",
        content: "Sunny, 75°F",
        is_error: false,
        timestamp: System.system_time(:millisecond)
      }

      event = Events.tool_execution_event(:end, "call_789", "weather", %{}, tool_result)

      assert event.type == :tool_execution_end
      assert event.tool_call_id == "call_789"
      assert event.result == tool_result
    end

    test "creates tool error event" do
      error_msg = "API key invalid"

      event = Events.tool_execution_event(:error, "call_error", "api", %{}, error_msg)

      assert event.type == :tool_execution_error
      assert event.tool_call_id == "call_error"
      assert event.error == error_msg
    end
  end

  describe "emit_event/3" do
    test "emits event to function callback" do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event_received, event})
      end

      event = Events.agent_lifecycle_event(:start, mock_agent_state())

      :ok = Events.emit_event(event, [callback])

      assert_receive {:event_received, ^event}, 1000
    end

    test "emits event to multiple callbacks" do
      test_pid = self()

      callback1 = fn event ->
        send(test_pid, {:callback1, event.type})
      end

      callback2 = fn event ->
        send(test_pid, {:callback2, event.type})
      end

      event = Events.turn_lifecycle_event(:start, 1)

      :ok = Events.emit_event(event, [callback1, callback2])

      assert_receive {:callback1, :turn_start}, 1000
      assert_receive {:callback2, :turn_start}, 1000
    end

    test "handles callback errors gracefully" do
      failing_callback = fn _event ->
        raise "Callback failed"
      end

      working_callback = fn event ->
        send(self(), {:working_callback, event.type})
      end

      event = Events.message_lifecycle_event(:start, Message.user("Test"))

      # Should not crash when callback fails
      :ok = Events.emit_event(event, [failing_callback, working_callback])

      # Working callback should still receive event
      assert_receive {:working_callback, :message_start}, 1000
    end

    test "emits events asynchronously when specified" do
      slow_callback = fn event ->
        Process.sleep(100)
        send(self(), {:slow_callback, event.type})
      end

      event = Events.agent_lifecycle_event(:start, mock_agent_state())

      start_time = System.system_time(:millisecond)
      :ok = Events.emit_event(event, [slow_callback], async: true)
      end_time = System.system_time(:millisecond)

      # Should return quickly due to async execution
      assert end_time - start_time < 50

      # But should still receive the callback
      assert_receive {:slow_callback, :agent_start}, 1000
    end

    test "emits events synchronously by default" do
      test_pid = self()

      callback = fn event ->
        Process.sleep(50)
        send(test_pid, {:sync_callback, event.type})
      end

      event = Events.message_lifecycle_event(:end, Message.user("Test"))

      start_time = System.system_time(:millisecond)
      :ok = Events.emit_event(event, [callback])
      end_time = System.system_time(:millisecond)

      # Should wait for callback completion
      assert end_time - start_time >= 45

      assert_receive {:sync_callback, :message_end}, 100
    end

    test "handles empty callback list" do
      event = Events.agent_lifecycle_event(:end, mock_agent_state())

      # Should not crash with empty callback list
      assert :ok = Events.emit_event(event, [])
    end

    test "handles nil callback list" do
      event = Events.turn_lifecycle_event(:end, 1)

      # Should handle nil gracefully
      assert :ok = Events.emit_event(event, nil)
    end
  end

  describe "event filtering and batching" do
    test "filters events by type" do
      test_pid = self()

      # Callback that only processes turn events
      filtered_callback = fn event ->
        if String.contains?(to_string(event.type), "turn") do
          send(test_pid, {:turn_event, event.type})
        end
      end

      # Emit various event types
      Events.emit_event(Events.agent_lifecycle_event(:start, mock_agent_state()), [
        filtered_callback
      ])

      Events.emit_event(Events.turn_lifecycle_event(:start, 1), [filtered_callback])

      Events.emit_event(Events.message_lifecycle_event(:start, Message.user("Test")), [
        filtered_callback
      ])

      Events.emit_event(Events.turn_lifecycle_event(:end, 1), [filtered_callback])

      # Should only receive turn events
      assert_receive {:turn_event, :turn_start}, 1000
      assert_receive {:turn_event, :turn_end}, 1000

      # Should not receive other event types
      refute_receive {:turn_event, :agent_start}, 100
      refute_receive {:turn_event, :message_start}, 100
    end

    test "handles event batching in callback" do
      test_pid = self()

      # Callback that batches events
      batching_callback = fn event ->
        # Simulate batching by collecting events for a short time
        receive do
          {:flush_batch, events} ->
            send(test_pid, {:batch_processed, length(events)})
        after
          10 ->
            send(test_pid, {:single_event, event.type})
        end
      end

      event1 = Events.message_lifecycle_event(:start, Message.user("Test1"))
      event2 = Events.message_lifecycle_event(:start, Message.user("Test2"))

      Events.emit_event(event1, [batching_callback], async: true)
      Events.emit_event(event2, [batching_callback], async: true)

      # Should receive individual events since no batching signal sent
      assert_receive {:single_event, :message_start}, 1000
      assert_receive {:single_event, :message_start}, 1000
    end
  end

  describe "event transformation" do
    test "transforms events in callback" do
      test_pid = self()

      transforming_callback = fn event ->
        # Transform event by extracting key information
        transformed = %{
          event_type: event.type,
          timestamp: event.timestamp,
          has_message: not is_nil(Map.get(event, :message, nil))
        }

        send(test_pid, {:transformed_event, transformed})
      end

      message = Message.user("Hello transformation")
      event = Events.message_lifecycle_event(:start, message)

      Events.emit_event(event, [transforming_callback])

      assert_receive {:transformed_event, transformed}, 1000
      assert transformed.event_type == :message_start
      assert transformed.has_message == true
      assert is_integer(transformed.timestamp)
    end
  end

  describe "complex event scenarios" do
    test "handles rapid event emission" do
      test_pid = self()
      counter_pid = spawn(fn -> event_counter(0) end)

      counting_callback = fn _event ->
        send(counter_pid, :increment)
      end

      # Emit many events rapidly
      for i <- 1..100 do
        event =
          Events.message_lifecycle_event(
            :update,
            Message.user("Message #{i}"),
            %{delta: "update #{i}"}
          )

        Events.emit_event(event, [counting_callback], async: true)
      end

      # Wait a bit for async processing
      Process.sleep(100)

      send(counter_pid, {:get_count, test_pid})
      assert_receive {:count, count}, 1000

      # Should have processed most or all events
      # Allow for some timing variations
      assert count >= 90
    end

    test "handles event emission during callback execution" do
      test_pid = self()

      recursive_callback = fn event ->
        # Emit another event from within callback
        if event.type == :agent_start do
          turn_event = Events.turn_lifecycle_event(:start, 1)
          Events.emit_event(turn_event, [fn e -> send(test_pid, {:nested_event, e.type}) end])
        end

        send(test_pid, {:main_event, event.type})
      end

      agent_event = Events.agent_lifecycle_event(:start, mock_agent_state())
      Events.emit_event(agent_event, [recursive_callback])

      assert_receive {:main_event, :agent_start}, 1000
      assert_receive {:nested_event, :turn_start}, 1000
    end
  end

  describe "event validation and structure" do
    test "validates event structure consistency" do
      # All events should have these basic fields
      events = [
        Events.agent_lifecycle_event(:start, mock_agent_state()),
        Events.turn_lifecycle_event(:start, 1),
        Events.message_lifecycle_event(:start, Message.user("Test")),
        Events.tool_execution_event(:start, "call_123", "tool", %{})
      ]

      Enum.each(events, fn event ->
        assert %AgentEvent{} = event
        assert is_atom(event.type)
        assert is_integer(event.timestamp)
        assert event.timestamp > 0
      end)
    end

    test "event timestamps are monotonically increasing" do
      events =
        for i <- 1..10 do
          # Ensure time progression
          Process.sleep(1)
          Events.turn_lifecycle_event(:start, i)
        end

      timestamps = Enum.map(events, & &1.timestamp)
      sorted_timestamps = Enum.sort(timestamps)

      # Timestamps should be in ascending order
      assert timestamps == sorted_timestamps
    end
  end

  # Helper function for event counting test
  defp event_counter(count) do
    receive do
      :increment ->
        event_counter(count + 1)

      {:get_count, pid} ->
        send(pid, {:count, count})
        event_counter(count)
    end
  end
end
