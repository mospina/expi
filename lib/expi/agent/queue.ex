defmodule Expi.Agent.Queue do
  @moduledoc """
  Message queue operations for agent conversation management.

  This module provides sophisticated message queuing capabilities that enable
  complex conversation flows with support for steering messages (urgent
  interruptions) and follow-up messages (natural continuations). The queue
  system is designed to handle different processing modes and priority levels
  to create natural conversation experiences.

  ## Queue Types

  **Steering Queue**: High-priority messages that interrupt current processing
  - Delivered immediately after current tool execution completes
  - Skip remaining tool calls in the current turn
  - Used for urgent user interruptions or system messages

  **Follow-up Queue**: Normal-priority messages for natural conversation flow
  - Delivered only when the agent has no more pending work
  - Allow natural conversation continuation
  - Used for non-urgent follow-up questions or clarifications

  ## Processing Modes

  - **All Mode**: Process all queued messages in a single turn
  - **One-at-a-time Mode**: Process one message per turn for natural pacing

  ## Core Functions

  - **Queue Operations**: `create_queue/0`, `add_message/3`, `get_messages/2`, `clear_queue/2`
  - **Priority Handling**: `add_steering/2`, `add_follow_up/2`, `has_steering/1`, `has_follow_up/1`
  - **Processing**: `drain_queue/3`, `process_by_mode/3`, `merge_queues/2`
  - **State Management**: `queue_stats/1`, `queue_size/1`, `is_empty/1`
  """

  alias Expi.Agent.Message

  @type queue_type :: :steering | :follow_up
  @type processing_mode :: :all | :one_at_a_time
  @type message_queue :: %{
          steering: [Message.t()],
          follow_up: [Message.t()],
          created_at: pos_integer(),
          last_processed: pos_integer() | nil
        }
  @type queue_stats :: %{
          steering_count: non_neg_integer(),
          follow_up_count: non_neg_integer(),
          total_count: non_neg_integer(),
          oldest_timestamp: pos_integer() | nil,
          newest_timestamp: pos_integer() | nil,
          queue_age: non_neg_integer()
        }

  @doc """
  Creates a new empty message queue.

  Initializes a message queue with separate steering and follow-up queues,
  along with metadata for tracking queue lifecycle and statistics.

  ## Examples

      queue = Queue.create_queue()
      
      # Queue starts empty with timestamps
      assert Queue.is_empty?(queue)
      assert queue.created_at > 0
  """
  @spec create_queue() :: message_queue()
  def create_queue() do
    %{
      steering: [],
      follow_up: [],
      created_at: System.system_time(:millisecond),
      last_processed: nil
    }
  end

  @doc """
  Adds a message to the specified queue type.

  Messages are added to the appropriate queue based on their priority
  and processing requirements. Steering messages are prioritized for
  immediate processing, while follow-up messages wait for natural breaks.

  ## Parameters

  - `queue` - The current message queue
  - `message` - The message to add
  - `queue_type` - Either `:steering` or `:follow_up`

  ## Examples

      # Add urgent steering message
      user_interrupt = Message.user("Stop that and do this instead")
      updated_queue = Queue.add_message(queue, user_interrupt, :steering)
      
      # Add follow-up question
      follow_up_question = Message.user("Can you also explain how this works?")
      updated_queue = Queue.add_message(queue, follow_up_question, :follow_up)
      
      # System steering message
      system_msg = Message.user("[SYSTEM] Processing interrupted")
      updated_queue = Queue.add_message(queue, system_msg, :steering)
  """
  @spec add_message(message_queue(), Message.t(), queue_type()) :: message_queue()
  def add_message(queue, message, queue_type) when queue_type in [:steering, :follow_up] do
    case queue_type do
      :steering ->
        %{queue | steering: queue.steering ++ [message]}

      :follow_up ->
        %{queue | follow_up: queue.follow_up ++ [message]}
    end
  end

  @doc """
  Adds a steering message with high priority processing.

  Steering messages are designed to interrupt current processing and
  redirect the agent's attention to urgent matters.

  ## Examples

      # User interruption
      interrupt_msg = Message.user("Cancel that and help me with this urgent issue")
      updated_queue = Queue.add_steering(queue, interrupt_msg)
      
      # System alert
      alert_msg = Message.user("[ALERT] Memory usage high, please reduce complexity")
      updated_queue = Queue.add_steering(queue, alert_msg)
  """
  @spec add_steering(message_queue(), Message.t()) :: message_queue()
  def add_steering(queue, message) do
    add_message(queue, message, :steering)
  end

  @doc """
  Adds a follow-up message for natural conversation flow.

  Follow-up messages wait until the agent completes its current work
  and naturally reaches a stopping point before being processed.

  ## Examples

      # Natural follow-up question
      follow_up = Message.user("That's helpful! Can you give me an example?")
      updated_queue = Queue.add_follow_up(queue, follow_up)
      
      # Additional request
      extra_request = Message.user("Also, can you format that as a table?")
      updated_queue = Queue.add_follow_up(queue, extra_request)
  """
  @spec add_follow_up(message_queue(), Message.t()) :: message_queue()
  def add_follow_up(queue, message) do
    add_message(queue, message, :follow_up)
  end

  @doc """
  Retrieves messages from the specified queue type.

  Returns messages in the order they were added (FIFO), optionally
  limiting the number of messages returned.

  ## Parameters

  - `queue` - The message queue
  - `queue_type` - Which queue to retrieve from (`:steering` or `:follow_up`)
  - `limit` - Maximum number of messages to return (optional)

  ## Examples

      # Get all steering messages
      steering_messages = Queue.get_messages(queue, :steering)
      
      # Get up to 5 follow-up messages
      follow_ups = Queue.get_messages(queue, :follow_up, 5)
      
      # Check for any urgent messages
      if Queue.has_steering?(queue) do
        urgent = Queue.get_messages(queue, :steering, 1)
        process_urgent_messages(urgent)
      end
  """
  @spec get_messages(message_queue(), queue_type(), pos_integer() | nil) :: [Message.t()]
  def get_messages(queue, queue_type, limit \\ nil) when queue_type in [:steering, :follow_up] do
    messages =
      case queue_type do
        :steering -> queue.steering
        :follow_up -> queue.follow_up
      end

    case limit do
      nil -> messages
      n when is_integer(n) and n > 0 -> Enum.take(messages, n)
      _ -> messages
    end
  end

  @doc """
  Clears messages from the specified queue type.

  Removes all or a specified number of messages from the queue,
  typically after they have been processed.

  ## Examples

      # Clear all steering messages after processing
      cleared_queue = Queue.clear_queue(queue, :steering)
      
      # Clear first 3 follow-up messages
      partial_clear = Queue.clear_queue(queue, :follow_up, 3)
  """
  @spec clear_queue(message_queue(), queue_type(), pos_integer() | :all) :: message_queue()
  def clear_queue(queue, queue_type, count \\ :all) when queue_type in [:steering, :follow_up] do
    case {queue_type, count} do
      {:steering, :all} ->
        %{queue | steering: [], last_processed: System.system_time(:millisecond)}

      {:follow_up, :all} ->
        %{queue | follow_up: [], last_processed: System.system_time(:millisecond)}

      {:steering, n} when is_integer(n) ->
        remaining = Enum.drop(queue.steering, n)
        %{queue | steering: remaining, last_processed: System.system_time(:millisecond)}

      {:follow_up, n} when is_integer(n) ->
        remaining = Enum.drop(queue.follow_up, n)
        %{queue | follow_up: remaining, last_processed: System.system_time(:millisecond)}
    end
  end

  @doc """
  Checks if the queue has any steering messages.

  ## Examples

      if Queue.has_steering?(queue) do
        handle_urgent_interruption()
      else
        continue_normal_processing()
      end
  """
  @spec has_steering?(message_queue()) :: boolean()
  def has_steering?(queue) do
    queue.steering != []
  end

  @doc """
  Checks if the queue has any follow-up messages.

  ## Examples

      if Queue.has_follow_up?(queue) do
        prepare_for_follow_up_processing()
      else
        conversation_complete()
      end
  """
  @spec has_follow_up?(message_queue()) :: boolean()
  def has_follow_up?(queue) do
    queue.follow_up != []
  end

  @doc """
  Checks if the queue is completely empty.

  ## Examples

      if Queue.is_empty?(queue) do
        agent_idle()
      else
        process_pending_messages()
      end
  """
  @spec is_empty?(message_queue()) :: boolean()
  def is_empty?(queue) do
    queue.steering == [] and queue.follow_up == []
  end

  @doc """
  Drains messages from the queue based on processing mode.

  Extracts messages for processing while respecting the specified
  processing mode and priority rules. Steering messages are always
  processed before follow-up messages.

  ## Parameters

  - `queue` - The message queue
  - `queue_type` - Which queue to drain (`:steering` or `:follow_up`)
  - `mode` - Processing mode (`:all` or `:one_at_a_time`)

  ## Examples

      # Drain all steering messages for immediate processing
      {messages, updated_queue} = Queue.drain_queue(queue, :steering, :all)
      
      # Drain one follow-up message for natural pacing
      {messages, updated_queue} = Queue.drain_queue(queue, :follow_up, :one_at_a_time)
      
      # Process based on mode configuration
      processing_mode = get_agent_processing_mode()
      {batch, new_queue} = Queue.drain_queue(queue, :follow_up, processing_mode)
  """
  @spec drain_queue(message_queue(), queue_type(), processing_mode()) ::
          {[Message.t()], message_queue()}
  def drain_queue(queue, queue_type, mode) when queue_type in [:steering, :follow_up] do
    messages = get_messages(queue, queue_type)

    case mode do
      :all ->
        # Take all messages
        updated_queue = clear_queue(queue, queue_type)
        {messages, updated_queue}

      :one_at_a_time ->
        # Take only the first message
        case messages do
          [] ->
            {[], queue}

          [first | _rest] ->
            updated_queue = clear_queue(queue, queue_type, 1)
            {[first], updated_queue}
        end
    end
  end

  @doc """
  Processes queued messages by priority and mode.

  Implements the complete message processing logic, handling steering
  messages first (with interruption semantics) followed by follow-up
  messages (with natural flow semantics).

  ## Parameters

  - `queue` - The message queue
  - `steering_mode` - How to process steering messages (`:all` or `:one_at_a_time`)
  - `follow_up_mode` - How to process follow-up messages (`:all` or `:one_at_a_time`)

  ## Examples

      # Process all urgent messages, one follow-up at a time
      result = Queue.process_by_mode(queue, :all, :one_at_a_time)
      
      case result do
        {:steering, messages, updated_queue} ->
          # Handle urgent interruption
          process_steering_messages(messages)
          
        {:follow_up, messages, updated_queue} ->
          # Handle natural follow-up
          process_follow_up_messages(messages)
          
        {:empty, updated_queue} ->
          # No messages to process
          agent_idle()
      end
  """
  @spec process_by_mode(message_queue(), processing_mode(), processing_mode()) ::
          {:steering, [Message.t()], message_queue()}
          | {:follow_up, [Message.t()], message_queue()}
          | {:empty, message_queue()}
  def process_by_mode(queue, steering_mode, follow_up_mode) do
    cond do
      has_steering?(queue) ->
        # Process steering messages first (interruption semantics)
        {messages, updated_queue} = drain_queue(queue, :steering, steering_mode)
        {:steering, messages, updated_queue}

      has_follow_up?(queue) ->
        # Process follow-up messages (natural flow semantics)
        {messages, updated_queue} = drain_queue(queue, :follow_up, follow_up_mode)
        {:follow_up, messages, updated_queue}

      true ->
        # No messages to process
        {:empty, queue}
    end
  end

  @doc """
  Merges two message queues, maintaining priority order.

  Combines queues while preserving the ordering semantics and
  priority relationships between different message types.

  ## Examples

      # Merge queues from different sources
      combined_queue = Queue.merge_queues(primary_queue, secondary_queue)
      
      # Merge temporary queue back into main queue
      main_queue = Queue.merge_queues(main_queue, temp_queue)
  """
  @spec merge_queues(message_queue(), message_queue()) :: message_queue()
  def merge_queues(queue1, queue2) do
    %{
      steering: queue1.steering ++ queue2.steering,
      follow_up: queue1.follow_up ++ queue2.follow_up,
      created_at: min(queue1.created_at, queue2.created_at),
      last_processed: max_timestamp(queue1.last_processed, queue2.last_processed)
    }
  end

  @doc """
  Gets comprehensive statistics about the message queue.

  Provides detailed information about queue state, message counts,
  timing information, and queue health metrics.

  ## Examples

      stats = Queue.queue_stats(queue)
      
      IO.puts("Total messages: " <> to_string(stats.total_count))
      IO.puts("Steering: " <> to_string(stats.steering_count))
      IO.puts("Follow-up: " <> to_string(stats.follow_up_count))
      IO.puts("Queue age: " <> to_string(stats.queue_age) <> "ms")
      
      # Check for queue health
      if stats.total_count > 50 do
        Logger.warning("Message queue getting large", stats)
      end
  """
  @spec queue_stats(message_queue()) :: queue_stats()
  def queue_stats(queue) do
    steering_count = length(queue.steering)
    follow_up_count = length(queue.follow_up)
    total_count = steering_count + follow_up_count

    all_messages = queue.steering ++ queue.follow_up
    timestamps = Enum.map(all_messages, &Message.timestamp/1)

    {oldest_timestamp, newest_timestamp} =
      if timestamps != [] do
        {Enum.min(timestamps), Enum.max(timestamps)}
      else
        {nil, nil}
      end

    queue_age = System.system_time(:millisecond) - queue.created_at

    %{
      steering_count: steering_count,
      follow_up_count: follow_up_count,
      total_count: total_count,
      oldest_timestamp: oldest_timestamp,
      newest_timestamp: newest_timestamp,
      queue_age: queue_age
    }
  end

  @doc """
  Gets the total size of the message queue.

  ## Examples

      queue_size = Queue.queue_size(queue)
      
      if queue_size > max_queue_size do
        apply_backpressure()
      end
  """
  @spec queue_size(message_queue()) :: non_neg_integer()
  def queue_size(queue) do
    length(queue.steering) + length(queue.follow_up)
  end

  @doc """
  Filters messages in the queue based on criteria.

  Allows selective processing or removal of messages based on
  content, timestamp, or other characteristics.

  ## Examples

      # Filter old messages
      cutoff_time = System.system_time(:millisecond) - 300_000  # 5 minutes
      filtered_queue = Queue.filter_messages(queue, fn message ->
        Message.timestamp(message) > cutoff_time
      end)
      
      # Remove system messages
      user_only_queue = Queue.filter_messages(queue, fn message ->
        not String.starts_with?(Message.content(message), "[SYSTEM]")
      end)
  """
  @spec filter_messages(message_queue(), (Message.t() -> boolean())) :: message_queue()
  def filter_messages(queue, filter_fn) when is_function(filter_fn, 1) do
    filtered_steering = Enum.filter(queue.steering, filter_fn)
    filtered_follow_up = Enum.filter(queue.follow_up, filter_fn)

    %{queue | steering: filtered_steering, follow_up: filtered_follow_up}
  end

  @doc """
  Applies backpressure by limiting queue size.

  Implements queue size management by removing oldest messages
  when the queue exceeds specified limits.

  ## Examples

      # Limit total queue size
      managed_queue = Queue.apply_backpressure(queue, max_size: 100)
      
      # Limit by queue type
      managed_queue = Queue.apply_backpressure(queue,
        max_steering: 20,
        max_follow_up: 50
      )
  """
  @spec apply_backpressure(message_queue(), keyword()) :: message_queue()
  def apply_backpressure(queue, options \\ []) do
    max_size = Keyword.get(options, :max_size)
    max_steering = Keyword.get(options, :max_steering)
    max_follow_up = Keyword.get(options, :max_follow_up)

    # Apply steering queue limit
    limited_steering =
      if max_steering && length(queue.steering) > max_steering do
        Enum.take(queue.steering, -max_steering)
      else
        queue.steering
      end

    # Apply follow-up queue limit
    limited_follow_up =
      if max_follow_up && length(queue.follow_up) > max_follow_up do
        Enum.take(queue.follow_up, -max_follow_up)
      else
        queue.follow_up
      end

    # Apply total size limit
    updated_queue = %{queue | steering: limited_steering, follow_up: limited_follow_up}

    if max_size && queue_size(updated_queue) > max_size do
      # Remove oldest messages first from follow-up, then steering if necessary
      excess = queue_size(updated_queue) - max_size

      if excess <= length(limited_follow_up) do
        # Remove from follow-up only
        trimmed_follow_up = Enum.drop(limited_follow_up, excess)
        %{updated_queue | follow_up: trimmed_follow_up}
      else
        # Remove all follow-up and some steering
        steering_excess = excess - length(limited_follow_up)
        trimmed_steering = Enum.drop(limited_steering, steering_excess)
        %{updated_queue | steering: trimmed_steering, follow_up: []}
      end
    else
      updated_queue
    end
  end

  @doc """
  Creates a queue processing summary for logging and debugging.

  ## Examples

      summary = Queue.summarize_processing(queue, processed_messages, processing_time)
      Logger.info("Queue processing complete: " <> summary)
  """
  @spec summarize_processing(message_queue(), [Message.t()], non_neg_integer()) :: String.t()
  def summarize_processing(queue, processed_messages, processing_time_ms) do
    stats = queue_stats(queue)
    processed_count = length(processed_messages)

    "Processed #{processed_count} messages in #{processing_time_ms}ms. " <>
      "Remaining: #{stats.steering_count} steering, #{stats.follow_up_count} follow-up"
  end

  # Private helper functions

  @spec max_timestamp(pos_integer() | nil, pos_integer() | nil) :: pos_integer() | nil
  defp max_timestamp(nil, nil), do: nil
  defp max_timestamp(nil, t2), do: t2
  defp max_timestamp(t1, nil), do: t1
  defp max_timestamp(t1, t2), do: max(t1, t2)
end
