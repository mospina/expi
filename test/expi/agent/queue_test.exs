defmodule Expi.Agent.QueueTest do
  use ExUnit.Case, async: true

  alias Expi.Agent.{Queue, Message}

  describe "create_queue/0" do
    test "creates empty queue with proper structure" do
      queue = Queue.create_queue()

      assert queue.steering == []
      assert queue.follow_up == []
      assert is_integer(queue.created_at)
      assert queue.created_at > 0
      assert queue.last_processed == nil
    end

    test "creates queue with recent timestamp" do
      before_time = System.system_time(:millisecond)
      queue = Queue.create_queue()
      after_time = System.system_time(:millisecond)

      assert queue.created_at >= before_time
      assert queue.created_at <= after_time
    end
  end

  describe "add_message/3" do
    test "adds message to steering queue" do
      queue = Queue.create_queue()
      message = Message.user("Urgent interruption!")

      updated_queue = Queue.add_message(queue, message, :steering)

      assert length(updated_queue.steering) == 1
      assert hd(updated_queue.steering) == message
      assert updated_queue.follow_up == []
    end

    test "adds message to follow-up queue" do
      queue = Queue.create_queue()
      message = Message.user("Follow-up question")

      updated_queue = Queue.add_message(queue, message, :follow_up)

      assert length(updated_queue.follow_up) == 1
      assert hd(updated_queue.follow_up) == message
      assert updated_queue.steering == []
    end

    test "preserves message order in steering queue" do
      queue = Queue.create_queue()
      msg1 = Message.user("First urgent")
      msg2 = Message.user("Second urgent")

      queue = Queue.add_message(queue, msg1, :steering)
      queue = Queue.add_message(queue, msg2, :steering)

      assert length(queue.steering) == 2
      assert Enum.at(queue.steering, 0) == msg1
      assert Enum.at(queue.steering, 1) == msg2
    end

    test "preserves message order in follow-up queue" do
      queue = Queue.create_queue()
      msg1 = Message.user("First follow-up")
      msg2 = Message.user("Second follow-up")

      queue = Queue.add_message(queue, msg1, :follow_up)
      queue = Queue.add_message(queue, msg2, :follow_up)

      assert length(queue.follow_up) == 2
      assert Enum.at(queue.follow_up, 0) == msg1
      assert Enum.at(queue.follow_up, 1) == msg2
    end
  end

  describe "add_steering/2" do
    test "adds steering message with shorthand function" do
      queue = Queue.create_queue()
      message = Message.user("Stop everything!")

      updated_queue = Queue.add_steering(queue, message)

      assert length(updated_queue.steering) == 1
      assert hd(updated_queue.steering) == message
    end
  end

  describe "add_follow_up/2" do
    test "adds follow-up message with shorthand function" do
      queue = Queue.create_queue()
      message = Message.user("Can you explain more?")

      updated_queue = Queue.add_follow_up(queue, message)

      assert length(updated_queue.follow_up) == 1
      assert hd(updated_queue.follow_up) == message
    end
  end

  describe "get_messages/2" do
    test "gets all steering messages" do
      queue = Queue.create_queue()
      msg1 = Message.user("Urgent 1")
      msg2 = Message.user("Urgent 2")

      queue = Queue.add_steering(queue, msg1)
      queue = Queue.add_steering(queue, msg2)

      messages = Queue.get_messages(queue, :steering)
      assert length(messages) == 2
      assert messages == [msg1, msg2]
    end

    test "gets all follow-up messages" do
      queue = Queue.create_queue()
      msg1 = Message.user("Follow-up 1")
      msg2 = Message.user("Follow-up 2")

      queue = Queue.add_follow_up(queue, msg1)
      queue = Queue.add_follow_up(queue, msg2)

      messages = Queue.get_messages(queue, :follow_up)
      assert length(messages) == 2
      assert messages == [msg1, msg2]
    end

    test "gets limited number of messages" do
      queue = Queue.create_queue()
      messages = for i <- 1..5, do: Message.user("Message #{i}")

      queue =
        Enum.reduce(messages, queue, fn msg, acc ->
          Queue.add_steering(acc, msg)
        end)

      limited_messages = Queue.get_messages(queue, :steering, 3)
      assert length(limited_messages) == 3
      assert limited_messages == Enum.take(messages, 3)
    end

    test "returns empty list for empty queue" do
      queue = Queue.create_queue()

      assert Queue.get_messages(queue, :steering) == []
      assert Queue.get_messages(queue, :follow_up) == []
    end
  end

  describe "clear_queue/2" do
    test "clears all steering messages" do
      queue = Queue.create_queue()
      queue = Queue.add_steering(queue, Message.user("Urgent"))
      queue = Queue.add_steering(queue, Message.user("Very urgent"))

      cleared_queue = Queue.clear_queue(queue, :steering)

      assert cleared_queue.steering == []
      assert is_integer(cleared_queue.last_processed)
    end

    test "clears all follow-up messages" do
      queue = Queue.create_queue()
      queue = Queue.add_follow_up(queue, Message.user("Question 1"))
      queue = Queue.add_follow_up(queue, Message.user("Question 2"))

      cleared_queue = Queue.clear_queue(queue, :follow_up)

      assert cleared_queue.follow_up == []
      assert is_integer(cleared_queue.last_processed)
    end

    test "clears specific number of messages" do
      queue = Queue.create_queue()
      messages = for i <- 1..5, do: Message.user("Message #{i}")

      queue =
        Enum.reduce(messages, queue, fn msg, acc ->
          Queue.add_steering(acc, msg)
        end)

      partial_clear = Queue.clear_queue(queue, :steering, 2)

      assert length(partial_clear.steering) == 3
      # Should have remaining messages
      assert Enum.at(partial_clear.steering, 0) == Enum.at(messages, 2)
    end

    test "preserves other queue when clearing one" do
      queue = Queue.create_queue()
      steering_msg = Message.user("Steering")
      follow_up_msg = Message.user("Follow-up")

      queue = Queue.add_steering(queue, steering_msg)
      queue = Queue.add_follow_up(queue, follow_up_msg)

      cleared_queue = Queue.clear_queue(queue, :steering)

      assert cleared_queue.steering == []
      assert length(cleared_queue.follow_up) == 1
      assert hd(cleared_queue.follow_up) == follow_up_msg
    end
  end

  describe "has_steering?/1" do
    test "returns false for empty steering queue" do
      queue = Queue.create_queue()

      assert Queue.has_steering?(queue) == false
    end

    test "returns true when steering messages present" do
      queue = Queue.create_queue()
      queue = Queue.add_steering(queue, Message.user("Urgent"))

      assert Queue.has_steering?(queue) == true
    end
  end

  describe "has_follow_up?/1" do
    test "returns false for empty follow-up queue" do
      queue = Queue.create_queue()

      assert Queue.has_follow_up?(queue) == false
    end

    test "returns true when follow-up messages present" do
      queue = Queue.create_queue()
      queue = Queue.add_follow_up(queue, Message.user("Question"))

      assert Queue.has_follow_up?(queue) == true
    end
  end

  describe "is_empty?/1" do
    test "returns true for completely empty queue" do
      queue = Queue.create_queue()

      assert Queue.is_empty?(queue) == true
    end

    test "returns false when steering messages present" do
      queue = Queue.create_queue()
      queue = Queue.add_steering(queue, Message.user("Urgent"))

      assert Queue.is_empty?(queue) == false
    end

    test "returns false when follow-up messages present" do
      queue = Queue.create_queue()
      queue = Queue.add_follow_up(queue, Message.user("Question"))

      assert Queue.is_empty?(queue) == false
    end

    test "returns false when both queues have messages" do
      queue = Queue.create_queue()
      queue = Queue.add_steering(queue, Message.user("Urgent"))
      queue = Queue.add_follow_up(queue, Message.user("Question"))

      assert Queue.is_empty?(queue) == false
    end
  end

  describe "drain_queue/3" do
    test "drains all messages in :all mode" do
      queue = Queue.create_queue()

      messages = [
        Message.user("First"),
        Message.user("Second"),
        Message.user("Third")
      ]

      queue =
        Enum.reduce(messages, queue, fn msg, acc ->
          Queue.add_steering(acc, msg)
        end)

      {drained_messages, updated_queue} = Queue.drain_queue(queue, :steering, :all)

      assert drained_messages == messages
      assert updated_queue.steering == []
      assert is_integer(updated_queue.last_processed)
    end

    test "drains one message in :one_at_a_time mode" do
      queue = Queue.create_queue()
      msg1 = Message.user("First")
      msg2 = Message.user("Second")

      queue = Queue.add_steering(queue, msg1)
      queue = Queue.add_steering(queue, msg2)

      {drained_messages, updated_queue} = Queue.drain_queue(queue, :steering, :one_at_a_time)

      assert drained_messages == [msg1]
      assert updated_queue.steering == [msg2]
      assert is_integer(updated_queue.last_processed)
    end

    test "handles empty queue gracefully" do
      queue = Queue.create_queue()

      {drained_messages, updated_queue} = Queue.drain_queue(queue, :steering, :all)

      assert drained_messages == []
      # Should be unchanged
      assert updated_queue == queue
    end
  end

  describe "process_by_mode/3" do
    test "processes steering messages first" do
      queue = Queue.create_queue()
      steering_msg = Message.user("Urgent")
      follow_up_msg = Message.user("Question")

      queue = Queue.add_steering(queue, steering_msg)
      queue = Queue.add_follow_up(queue, follow_up_msg)

      result = Queue.process_by_mode(queue, :all, :all)

      assert match?({:steering, [^steering_msg], _updated_queue}, result)
    end

    test "processes follow-up messages when no steering" do
      queue = Queue.create_queue()
      follow_up_msg = Message.user("Question")

      queue = Queue.add_follow_up(queue, follow_up_msg)

      result = Queue.process_by_mode(queue, :all, :all)

      assert match?({:follow_up, [^follow_up_msg], _updated_queue}, result)
    end

    test "returns empty when no messages" do
      queue = Queue.create_queue()

      result = Queue.process_by_mode(queue, :all, :all)

      assert match?({:empty, ^queue}, result)
    end

    test "respects processing modes" do
      queue = Queue.create_queue()
      msg1 = Message.user("First")
      msg2 = Message.user("Second")

      queue = Queue.add_steering(queue, msg1)
      queue = Queue.add_steering(queue, msg2)

      # Test :one_at_a_time mode
      result = Queue.process_by_mode(queue, :one_at_a_time, :all)

      assert match?({:steering, [^msg1], _updated_queue}, result)
    end
  end

  describe "merge_queues/2" do
    test "merges two queues correctly" do
      queue1 = Queue.create_queue()
      queue1 = Queue.add_steering(queue1, Message.user("Steering 1"))
      queue1 = Queue.add_follow_up(queue1, Message.user("Follow-up 1"))

      queue2 = Queue.create_queue()
      queue2 = Queue.add_steering(queue2, Message.user("Steering 2"))
      queue2 = Queue.add_follow_up(queue2, Message.user("Follow-up 2"))

      merged_queue = Queue.merge_queues(queue1, queue2)

      assert length(merged_queue.steering) == 2
      assert length(merged_queue.follow_up) == 2
      assert merged_queue.created_at == min(queue1.created_at, queue2.created_at)
    end

    test "handles empty queues in merge" do
      queue1 = Queue.create_queue()
      queue1 = Queue.add_steering(queue1, Message.user("Message"))

      queue2 = Queue.create_queue()

      merged_queue = Queue.merge_queues(queue1, queue2)

      assert length(merged_queue.steering) == 1
      assert merged_queue.follow_up == []
    end
  end

  describe "queue_stats/1" do
    test "returns correct statistics for empty queue" do
      queue = Queue.create_queue()

      stats = Queue.queue_stats(queue)

      assert stats.steering_count == 0
      assert stats.follow_up_count == 0
      assert stats.total_count == 0
      assert stats.oldest_timestamp == nil
      assert stats.newest_timestamp == nil
      assert is_integer(stats.queue_age)
      assert stats.queue_age >= 0
    end

    test "returns correct statistics for populated queue" do
      queue = Queue.create_queue()

      # Add some messages
      queue = Queue.add_steering(queue, Message.user("Steering 1"))
      queue = Queue.add_steering(queue, Message.user("Steering 2"))
      queue = Queue.add_follow_up(queue, Message.user("Follow-up 1"))

      stats = Queue.queue_stats(queue)

      assert stats.steering_count == 2
      assert stats.follow_up_count == 1
      assert stats.total_count == 3
      assert is_integer(stats.oldest_timestamp)
      assert is_integer(stats.newest_timestamp)
      assert stats.oldest_timestamp <= stats.newest_timestamp
    end
  end

  describe "queue_size/1" do
    test "returns zero for empty queue" do
      queue = Queue.create_queue()

      assert Queue.queue_size(queue) == 0
    end

    test "returns correct total size" do
      queue = Queue.create_queue()

      queue = Queue.add_steering(queue, Message.user("Steering 1"))
      queue = Queue.add_steering(queue, Message.user("Steering 2"))
      queue = Queue.add_follow_up(queue, Message.user("Follow-up 1"))

      assert Queue.queue_size(queue) == 3
    end
  end

  describe "filter_messages/2" do
    test "filters messages based on predicate" do
      queue = Queue.create_queue()

      old_msg = Message.user("Old message")
      urgent_msg = Message.user("[URGENT] Important!")
      normal_msg = Message.user("Normal message")

      queue = Queue.add_steering(queue, old_msg)
      queue = Queue.add_steering(queue, urgent_msg)
      queue = Queue.add_follow_up(queue, normal_msg)

      # Filter to keep only urgent messages
      filtered_queue =
        Queue.filter_messages(queue, fn message ->
          String.contains?(Message.content(message), "[URGENT]")
        end)

      assert length(filtered_queue.steering) == 1
      assert hd(filtered_queue.steering) == urgent_msg
      # Normal message filtered out
      assert filtered_queue.follow_up == []
    end

    test "handles empty queue in filtering" do
      queue = Queue.create_queue()

      filtered_queue = Queue.filter_messages(queue, fn _msg -> true end)

      assert Queue.is_empty?(filtered_queue)
    end
  end

  describe "apply_backpressure/2" do
    test "limits queue size when exceeding maximum" do
      queue = Queue.create_queue()

      # Add many messages
      large_queue =
        Enum.reduce(1..100, queue, fn i, acc ->
          Queue.add_steering(acc, Message.user("Message #{i}"))
        end)

      limited_queue = Queue.apply_backpressure(large_queue, max_size: 50)

      assert Queue.queue_size(limited_queue) <= 50
    end

    test "limits steering queue specifically" do
      queue = Queue.create_queue()

      # Add many steering messages
      queue_with_many =
        Enum.reduce(1..20, queue, fn i, acc ->
          Queue.add_steering(acc, Message.user("Steering #{i}"))
        end)

      limited_queue = Queue.apply_backpressure(queue_with_many, max_steering: 5)

      assert length(limited_queue.steering) <= 5
    end

    test "preserves newest messages when applying backpressure" do
      queue = Queue.create_queue()

      # Add messages with identifiable content
      queue = Queue.add_steering(queue, Message.user("Old message 1"))
      queue = Queue.add_steering(queue, Message.user("Old message 2"))
      queue = Queue.add_steering(queue, Message.user("Recent message 1"))
      queue = Queue.add_steering(queue, Message.user("Recent message 2"))

      limited_queue = Queue.apply_backpressure(queue, max_steering: 2)

      assert length(limited_queue.steering) == 2
      # Should keep the most recent messages
      recent_contents = Enum.map(limited_queue.steering, &Message.content/1)
      assert "Recent message 1" in recent_contents
      assert "Recent message 2" in recent_contents
    end
  end

  describe "summarize_processing/3" do
    test "creates processing summary" do
      queue = Queue.create_queue()
      queue = Queue.add_steering(queue, Message.user("Remaining steering"))
      queue = Queue.add_follow_up(queue, Message.user("Remaining follow-up"))

      processed_messages = [
        Message.user("Processed 1"),
        Message.user("Processed 2")
      ]

      summary = Queue.summarize_processing(queue, processed_messages, 150)

      assert is_binary(summary)
      assert String.contains?(summary, "Processed 2 messages")
      assert String.contains?(summary, "150ms")
      assert String.contains?(summary, "1 steering")
      assert String.contains?(summary, "1 follow-up")
    end
  end

  describe "edge cases and error handling" do
    test "handles concurrent access patterns" do
      queue = Queue.create_queue()

      # Simulate concurrent additions (though not truly concurrent in this test)
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            Queue.add_steering(queue, Message.user("Concurrent #{i}"))
          end)
        end

      results = Task.await_many(tasks)

      # Each task should return a valid queue
      Enum.each(results, fn result_queue ->
        assert is_map(result_queue)
        assert length(result_queue.steering) == 1
      end)
    end

    test "handles very large message content" do
      queue = Queue.create_queue()
      large_content = String.duplicate("A", 100_000)
      large_message = Message.user(large_content)

      updated_queue = Queue.add_steering(queue, large_message)

      assert length(updated_queue.steering) == 1
      retrieved_messages = Queue.get_messages(updated_queue, :steering)
      assert Message.content(hd(retrieved_messages)) == large_content
    end

    test "preserves queue integrity after many operations" do
      queue = Queue.create_queue()

      # Perform many mixed operations
      final_queue =
        Enum.reduce(1..50, queue, fn i, acc ->
          acc
          |> Queue.add_steering(Message.user("Steering #{i}"))
          |> Queue.add_follow_up(Message.user("Follow-up #{i}"))
        end)

      # Drain some messages
      {_drained, final_queue} = Queue.drain_queue(final_queue, :steering, :all)

      # Queue should still be valid
      stats = Queue.queue_stats(final_queue)
      assert stats.steering_count == 0
      assert stats.follow_up_count == 50
      assert stats.total_count == 50
    end
  end
end
