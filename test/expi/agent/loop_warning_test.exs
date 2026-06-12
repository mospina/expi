defmodule Expi.Agent.LoopWarningTest do
  use ExUnit.Case, async: true

  alias Expi.Agent.{Loop, Message, State}
  alias Expi.AI

  test "should_continue? respects pending tools and queue state" do
    {:ok, model} = AI.get_model("anthropic", "claude-opus-4-5")
    agent_state = State.new(model)

    base_loop_state = %{
      agent_state: agent_state,
      message_queue: %{steering: [], follow_up: []},
      current_turn: 1,
      loop_start_time: System.system_time(:millisecond),
      status: :running
    }

    refute Loop.should_continue?(base_loop_state)

    steering_loop_state = %{
      base_loop_state
      | message_queue: %{steering: [Message.user("steer now")], follow_up: []}
    }

    assert Loop.should_continue?(steering_loop_state)

    follow_up_loop_state = %{
      base_loop_state
      | message_queue: %{steering: [], follow_up: [Message.user("follow up")]}
    }

    assert Loop.should_continue?(follow_up_loop_state)

    pending_tool_loop_state = %{
      base_loop_state
      | agent_state: State.add_pending_tool_call(agent_state, "call_1")
    }

    assert Loop.should_continue?(pending_tool_loop_state)

    errored_loop_state = %{
      base_loop_state
      | status: :error,
        message_queue: %{steering: [Message.user("steer")], follow_up: []}
    }

    refute Loop.should_continue?(errored_loop_state)
  end
end
