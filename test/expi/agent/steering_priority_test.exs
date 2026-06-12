defmodule Expi.Agent.SteeringPriorityTest do
  use ExUnit.Case, async: true

  alias Expi.Agent.Steering
  alias Expi.Types.UserMessage

  test "returns defer_all when no messages are present" do
    assert %{recommendation: :defer_all, reasoning: "No messages to process"} =
             Steering.get_processing_priority([], [])
  end

  test "prefers steering when only steering messages are present" do
    assert %{recommendation: :process_steering_first} =
             Steering.get_processing_priority([message("steering")], [])
  end

  test "prefers follow-up when only follow-up messages are present" do
    assert %{recommendation: :process_follow_up_first} =
             Steering.get_processing_priority([], [message("follow up")])
  end

  test "prefers steering when steering has higher priority" do
    steering = [message("[URGENT] steering")]
    follow_up = [message("follow up")]

    assert %{recommendation: :process_steering_first} =
             Steering.get_processing_priority(steering, follow_up)
  end

  test "prefers follow-up when follow-up has higher priority" do
    steering = [message("steering")]
    follow_up = for index <- 1..12, do: message("follow up #{index}")

    assert %{recommendation: :process_follow_up_first} =
             Steering.get_processing_priority(steering, follow_up)
  end

  test "defaults to steering when both are present and priorities are tied" do
    steering = [message("steering")]
    follow_up = for index <- 1..11, do: message("follow up #{index}")

    assert %{
             recommendation: :process_steering_first,
             reasoning: "Default to steering priority when both present"
           } =
             Steering.get_processing_priority(steering, follow_up)
  end

  defp message(text) do
    %UserMessage{content: text, timestamp: System.system_time(:millisecond)}
  end
end
