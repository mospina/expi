defmodule Expi.Agent.QueueWarningTest do
  use ExUnit.Case, async: true

  alias Expi.Agent.{Message, Queue}

  test "queue emptiness helpers reflect steering and follow-up contents" do
    empty_queue = Queue.create_queue()

    refute Queue.has_steering?(empty_queue)
    refute Queue.has_follow_up?(empty_queue)
    assert Queue.is_empty?(empty_queue)

    steering_queue = Queue.add_steering(empty_queue, Message.user("steering"))

    assert Queue.has_steering?(steering_queue)
    refute Queue.has_follow_up?(steering_queue)
    refute Queue.is_empty?(steering_queue)

    follow_up_queue = Queue.add_follow_up(empty_queue, Message.user("follow up"))

    refute Queue.has_steering?(follow_up_queue)
    assert Queue.has_follow_up?(follow_up_queue)
    refute Queue.is_empty?(follow_up_queue)
  end
end
