defmodule Expi.Agent.Steering do
  @moduledoc """
  Steering and follow-up message logic for agent conversations.

  This module implements the sophisticated logic for handling steering messages
  (urgent interruptions) and follow-up messages (natural continuations) in
  agent conversations. It provides the decision-making logic that determines
  when and how to process different types of messages based on agent state,
  conversation context, and processing priorities.

  ## Steering Messages

  Steering messages are high-priority interruptions that redirect the agent's
  attention to urgent matters. They are processed immediately after the current
  tool execution completes, interrupting any remaining work in the current turn.

  **Characteristics:**
  - Immediate processing priority
  - Interrupt current conversation flow
  - Skip remaining tool calls in current turn
  - Used for user corrections, urgent requests, or system alerts

  ## Follow-up Messages

  Follow-up messages are natural conversation continuations that wait for
  appropriate stopping points. They maintain conversation flow without
  interrupting ongoing work.

  **Characteristics:**
  - Process only at natural conversation breaks
  - Wait for current turn and all tool executions to complete
  - Maintain natural conversation pacing
  - Used for additional questions, clarifications, or related requests

  ## Core Functions

  - **Decision Logic**: `should_process_steering/2`, `should_process_follow_up/2`
  - **Processing Control**: `apply_steering_logic/3`, `apply_follow_up_logic/3`
  - **State Analysis**: `analyze_agent_readiness/1`, `get_processing_priority/2`
  - **Integration**: `coordinate_with_loop/3`, `update_processing_state/3`
  """

  alias Expi.Agent.Types.{AgentState, AgentEvent}
  alias Expi.Agent.{State, Queue, Message, Events}

  require Logger

  @type steering_decision :: :process_now | :process_after_tools | :defer | :ignore
  @type follow_up_decision :: :process_now | :defer_until_complete | :defer | :ignore
  @type processing_context :: %{
          agent_state: AgentState.t(),
          current_turn_active: boolean(),
          tools_executing: boolean(),
          pending_tool_count: non_neg_integer(),
          last_message_timestamp: pos_integer() | nil,
          conversation_idle_time: non_neg_integer()
        }

  @type steering_options :: [
          interrupt_tools: boolean(),
          max_steering_per_turn: pos_integer(),
          steering_timeout_ms: pos_integer(),
          priority_threshold: atom()
        ]

  @type follow_up_options :: [
          min_idle_time_ms: pos_integer(),
          max_follow_ups_per_turn: pos_integer(),
          natural_break_detection: boolean(),
          follow_up_timeout_ms: pos_integer()
        ]

  @doc """
  Determines if steering messages should be processed based on agent state.

  Analyzes the current agent state, conversation context, and message
  characteristics to decide when steering messages should interrupt
  current processing.

  ## Parameters

  - `agent_state` - Current agent state
  - `steering_messages` - List of pending steering messages
  - `options` - Processing options and thresholds

  ## Examples

      case Steering.should_process_steering(agent_state, steering_msgs, opts) do
        :process_now ->
          # Interrupt immediately
          handle_urgent_steering(steering_msgs)

        :process_after_tools ->
          # Wait for current tools to complete
          queue_steering_after_tools(steering_msgs)

        :defer ->
          # Wait for better timing
          defer_steering_processing(steering_msgs)

        :ignore ->
          # Skip processing (e.g., duplicate or invalid messages)
          log_ignored_steering(steering_msgs)
      end
  """
  @spec should_process_steering(AgentState.t(), [Message.t()], steering_options()) ::
          steering_decision()
  def should_process_steering(_agent_state, [], _options), do: :ignore

  def should_process_steering(agent_state, steering_messages, options) do
    context = build_processing_context(agent_state)
    interrupt_tools = Keyword.get(options, :interrupt_tools, false)
    max_per_turn = Keyword.get(options, :max_steering_per_turn, 5)

    cond do
      too_many_steering_messages?(steering_messages, max_per_turn) ->
        :defer

      not context.current_turn_active and not context.tools_executing ->
        :process_now

      context.tools_executing and interrupt_tools ->
        Logger.debug("Interrupting tool execution for steering")
        :process_now

      context.tools_executing ->
        :process_after_tools

      context.current_turn_active ->
        if has_urgent_steering?(steering_messages), do: :process_now, else: :process_after_tools

      true ->
        :process_now
    end
  end

  defp too_many_steering_messages?(steering_messages, max_per_turn) do
    count = length(steering_messages)

    if count > max_per_turn do
      Logger.warning("Too many steering messages in turn", %{count: count, max: max_per_turn})
      true
    else
      false
    end
  end

  @doc """
  Determines if follow-up messages should be processed.

  Evaluates conversation state and timing to determine the appropriate
  moment for processing follow-up messages without disrupting natural
  conversation flow.

  ## Parameters

  - `agent_state` - Current agent state
  - `follow_up_messages` - List of pending follow-up messages
  - `options` - Processing options and timing thresholds

  ## Examples

      case Steering.should_process_follow_up(agent_state, follow_ups, opts) do
        :process_now ->
          # Natural break detected, process follow-ups
          handle_follow_up_messages(follow_ups)

        :defer_until_complete ->
          # Wait for all current work to complete
          wait_for_conversation_completion()

        :defer ->
          # Wait for better timing
          schedule_follow_up_check()

        :ignore ->
          # Skip processing (e.g., too old or redundant)
          cleanup_old_follow_ups(follow_ups)
      end
  """
  @spec should_process_follow_up(AgentState.t(), [Message.t()], follow_up_options()) ::
          follow_up_decision()
  def should_process_follow_up(_agent_state, [], _options), do: :ignore

  def should_process_follow_up(agent_state, follow_up_messages, options) do
    context = build_processing_context(agent_state)
    min_idle_time = Keyword.get(options, :min_idle_time_ms, 1000)
    max_per_turn = Keyword.get(options, :max_follow_ups_per_turn, 3)
    natural_break_detection = Keyword.get(options, :natural_break_detection, true)

    cond do
      too_many_follow_ups?(follow_up_messages, max_per_turn) ->
        :defer

      context.current_turn_active or context.tools_executing ->
        :defer_until_complete

      context.conversation_idle_time < min_idle_time ->
        log_min_idle_wait(context.conversation_idle_time, min_idle_time)
        :defer

      natural_break_detection and not at_natural_break?(agent_state) ->
        :defer

      has_expired_follow_ups?(follow_up_messages) ->
        Logger.debug("Some follow-up messages have expired")
        :ignore

      true ->
        :process_now
    end
  end

  defp too_many_follow_ups?(follow_up_messages, max_per_turn) do
    count = length(follow_up_messages)

    if count > max_per_turn do
      Logger.debug("Limiting follow-up messages per turn", %{count: count, max: max_per_turn})
      true
    else
      false
    end
  end

  defp log_min_idle_wait(current_idle, min_idle_time) do
    Logger.debug("Waiting for minimum idle time", %{
      current_idle: current_idle,
      min_required: min_idle_time
    })
  end

  @doc """
  Applies steering logic to determine message processing approach.

  Implements the complete steering decision logic, including timing,
  priority analysis, and integration with the agent loop system.

  ## Examples

      {decision, processed_messages, updated_queue} =
        Steering.apply_steering_logic(agent_state, message_queue, options)

      case decision do
        {:interrupt, messages} ->
          interrupt_current_processing()
          process_steering_immediately(messages)

        {:queue_after_tools, messages} ->
          wait_for_tools()
          schedule_steering_processing(messages)

        {:defer, reason} ->
          log_steering_deferral(reason)
          continue_current_processing()
      end
  """
  @spec apply_steering_logic(AgentState.t(), Queue.message_queue(), steering_options()) ::
          {{:interrupt, [Message.t()]} | {:queue_after_tools, [Message.t()]} | {:defer, atom()},
           Queue.message_queue()}
  def apply_steering_logic(agent_state, message_queue, options \\ []) do
    steering_messages = Queue.get_messages(message_queue, :steering)

    case should_process_steering(agent_state, steering_messages, options) do
      :process_now ->
        # Process steering immediately - interrupt current flow
        processing_mode = determine_steering_processing_mode(steering_messages, options)
        {messages, updated_queue} = Queue.drain_queue(message_queue, :steering, processing_mode)

        Logger.info("Processing steering messages immediately", %{
          count: length(messages),
          mode: processing_mode
        })

        {{:interrupt, messages}, updated_queue}

      :process_after_tools ->
        # Queue for processing after current tools complete
        processing_mode = determine_steering_processing_mode(steering_messages, options)
        {messages, updated_queue} = Queue.drain_queue(message_queue, :steering, processing_mode)

        Logger.info("Queueing steering messages after tools", %{
          count: length(messages),
          pending_tools: count_pending_tools(agent_state)
        })

        {{:queue_after_tools, messages}, updated_queue}

      :defer ->
        # Keep messages in queue for later processing
        Logger.debug("Deferring steering messages", %{
          count: length(steering_messages),
          reason: "timing_not_optimal"
        })

        {{:defer, :timing_not_optimal}, message_queue}

      :ignore ->
        # Clear ignored messages
        updated_queue = Queue.clear_queue(message_queue, :steering)

        Logger.debug("Ignoring steering messages", %{
          count: length(steering_messages),
          reason: "invalid_or_duplicate"
        })

        {{:defer, :ignored}, updated_queue}
    end
  end

  @doc """
  Applies follow-up logic to determine natural processing timing.

  Implements the complete follow-up decision logic, ensuring messages
  are processed at natural conversation breaks without disrupting flow.

  ## Examples

      {decision, processed_messages, updated_queue} =
        Steering.apply_follow_up_logic(agent_state, message_queue, options)

      case decision do
        {:process_natural, messages} ->
          process_follow_up_naturally(messages)

        {:wait_for_break, estimated_time} ->
          schedule_follow_up_check(estimated_time)

        {:defer_conversation_active, nil} ->
          continue_monitoring_conversation()
      end
  """
  @spec apply_follow_up_logic(AgentState.t(), Queue.message_queue(), follow_up_options()) ::
          {{:process_natural, [Message.t()]}
           | {:wait_for_break, pos_integer()}
           | {:defer_conversation_active, nil}, Queue.message_queue()}
  def apply_follow_up_logic(agent_state, message_queue, options \\ []) do
    follow_up_messages = Queue.get_messages(message_queue, :follow_up)

    case should_process_follow_up(agent_state, follow_up_messages, options) do
      :process_now ->
        # Process follow-ups at natural break
        processing_mode = determine_follow_up_processing_mode(follow_up_messages, options)
        {messages, updated_queue} = Queue.drain_queue(message_queue, :follow_up, processing_mode)

        Logger.info("Processing follow-up messages at natural break", %{
          count: length(messages),
          mode: processing_mode,
          idle_time: build_processing_context(agent_state).conversation_idle_time
        })

        {{:process_natural, messages}, updated_queue}

      :defer_until_complete ->
        # Wait for conversation to reach natural stopping point
        estimated_wait = estimate_completion_time(agent_state)

        Logger.debug("Waiting for conversation completion", %{
          follow_up_count: length(follow_up_messages),
          estimated_wait_ms: estimated_wait
        })

        {{:wait_for_break, estimated_wait}, message_queue}

      :defer ->
        # Continue waiting for better timing
        Logger.debug("Deferring follow-up processing", %{
          count: length(follow_up_messages),
          reason: "waiting_for_natural_break"
        })

        {{:defer_conversation_active, nil}, message_queue}

      :ignore ->
        # Remove expired or invalid follow-ups
        cleaned_queue = clean_expired_follow_ups(message_queue)
        removed_count = length(follow_up_messages) - Queue.queue_size(cleaned_queue)

        if removed_count > 0 do
          Logger.debug("Removed expired follow-up messages", %{count: removed_count})
        end

        {{:defer_conversation_active, nil}, cleaned_queue}
    end
  end

  @doc """
  Analyzes agent readiness for different types of message processing.

  Provides comprehensive analysis of agent state to support decision
  making for both steering and follow-up message processing.

  ## Examples

      readiness = Steering.analyze_agent_readiness(agent_state)

      IO.puts("Can interrupt: " <> to_string(readiness.can_interrupt))
      IO.puts("At natural break: " <> to_string(readiness.at_natural_break))
      IO.puts("Processing capacity: " <> to_string(readiness.processing_capacity))
  """
  @spec analyze_agent_readiness(AgentState.t()) :: %{
          can_interrupt: boolean(),
          at_natural_break: boolean(),
          processing_capacity: float(),
          current_workload: non_neg_integer(),
          idle_time: non_neg_integer(),
          last_activity: pos_integer() | nil
        }
  def analyze_agent_readiness(agent_state) do
    context = build_processing_context(agent_state)

    %{
      can_interrupt: not context.current_turn_active and not context.tools_executing,
      at_natural_break: at_natural_break?(agent_state),
      processing_capacity: calculate_processing_capacity(agent_state),
      current_workload: context.pending_tool_count,
      idle_time: context.conversation_idle_time,
      last_activity: context.last_message_timestamp
    }
  end

  @doc """
  Gets processing priority for different message types.

  Determines the relative priority of different message types based on
  context, urgency, and conversation state.

  ## Examples

      priority_info = Steering.get_processing_priority(steering_msgs, follow_up_msgs)

      case priority_info.recommendation do
        :process_steering_first -> handle_steering_priority()
        :process_follow_up_first -> handle_follow_up_priority()
        :process_together -> handle_batch_processing()
        :defer_all -> wait_for_better_timing()
      end
  """
  @spec get_processing_priority([Message.t()], [Message.t()]) :: %{
          steering_priority: non_neg_integer(),
          follow_up_priority: non_neg_integer(),
          recommendation:
            :process_steering_first | :process_follow_up_first | :process_together | :defer_all,
          reasoning: String.t()
        }
  def get_processing_priority(steering_messages, follow_up_messages) do
    steering_priority = calculate_message_priority(steering_messages, :steering)
    follow_up_priority = calculate_message_priority(follow_up_messages, :follow_up)

    {recommendation, reasoning} =
      cond do
        steering_messages != [] and follow_up_messages == [] ->
          {:process_steering_first, "Only steering messages present"}

        steering_messages == [] and follow_up_messages != [] ->
          {:process_follow_up_first, "Only follow-up messages present"}

        steering_priority > follow_up_priority ->
          {:process_steering_first, "Steering messages have higher priority"}

        follow_up_priority > steering_priority ->
          {:process_follow_up_first, "Follow-up messages have higher priority"}

        steering_messages != [] and follow_up_messages != [] ->
          {:process_steering_first, "Default to steering priority when both present"}

        true ->
          {:defer_all, "No messages to process"}
      end

    %{
      steering_priority: steering_priority,
      follow_up_priority: follow_up_priority,
      recommendation: recommendation,
      reasoning: reasoning
    }
  end

  @doc """
  Coordinates message processing with the agent loop system.

  Provides integration between message queue processing decisions and
  the main agent loop, ensuring proper coordination and state management.

  ## Examples

      coordination_result = Steering.coordinate_with_loop(
        agent_state,
        message_queue,
        loop_options
      )

      case coordination_result.action do
        :interrupt_loop -> interrupt_and_process()
        :queue_for_next_turn -> schedule_next_turn_processing()
        :continue_loop -> maintain_current_processing()
      end
  """
  @spec coordinate_with_loop(AgentState.t(), Queue.message_queue(), keyword()) :: %{
          action: :interrupt_loop | :queue_for_next_turn | :continue_loop,
          messages_to_process: [Message.t()],
          updated_queue: Queue.message_queue(),
          processing_mode: Queue.processing_mode(),
          estimated_processing_time: pos_integer()
        }
  def coordinate_with_loop(agent_state, message_queue, options \\ []) do
    steering_opts = Keyword.get(options, :steering, [])
    follow_up_opts = Keyword.get(options, :follow_up, [])

    # Analyze both steering and follow-up logic
    {steering_decision, steering_queue} =
      apply_steering_logic(agent_state, message_queue, steering_opts)

    {follow_up_decision, final_queue} =
      apply_follow_up_logic(agent_state, steering_queue, follow_up_opts)

    # Determine coordinated action
    {action, messages, mode, estimated_time} =
      case {steering_decision, follow_up_decision} do
        {{:interrupt, steering_msgs}, _} ->
          # Steering interruption takes precedence
          {:interrupt_loop, steering_msgs, :one_at_a_time,
           estimate_processing_time(steering_msgs)}

        {{:queue_after_tools, steering_msgs}, _} ->
          # Queue steering for after current tools
          {:queue_for_next_turn, steering_msgs, :all, estimate_processing_time(steering_msgs)}

        {_, {:process_natural, follow_up_msgs}} ->
          # Process follow-ups at natural break
          {:queue_for_next_turn, follow_up_msgs, :one_at_a_time,
           estimate_processing_time(follow_up_msgs)}

        _ ->
          # Continue current processing
          {:continue_loop, [], :one_at_a_time, 0}
      end

    %{
      action: action,
      messages_to_process: messages,
      updated_queue: final_queue,
      processing_mode: mode,
      estimated_processing_time: estimated_time
    }
  end

  @doc """
  Updates processing state based on steering and follow-up decisions.

  Manages the state transitions and updates required when processing
  steering and follow-up messages, ensuring proper coordination with
  the overall agent lifecycle.

  ## Examples

      updated_state = Steering.update_processing_state(
        agent_state,
        coordination_result,
        processing_events
      )

      # State reflects message processing decisions
      assert State.has_pending_steering?(updated_state) == false
      assert State.get_follow_up_count(updated_state) == expected_count
  """
  @spec update_processing_state(AgentState.t(), map(), [AgentEvent.t()]) :: AgentState.t()
  def update_processing_state(agent_state, coordination_result, events \\ []) do
    messages_to_add = coordination_result.messages_to_process

    # Add messages to agent state
    updated_state =
      if messages_to_add != [] do
        State.add_messages(agent_state, messages_to_add)
      else
        agent_state
      end

    # Update processing state based on coordination action
    final_state =
      case coordination_result.action do
        :interrupt_loop ->
          # Processing was interrupted - no additional state changes needed for now
          updated_state

        :queue_for_next_turn ->
          # Messages queued for next turn - no additional state changes needed for now
          updated_state

        :continue_loop ->
          # No special state changes needed
          updated_state
      end

    # Emit coordination events if provided
    if events != [] do
      Enum.each(events, fn event ->
        Events.emit_event(event, [], async: true)
      end)
    end

    final_state
  end

  # Private helper functions

  @spec build_processing_context(AgentState.t()) :: processing_context()
  defp build_processing_context(agent_state) do
    current_time = System.system_time(:millisecond)
    last_message_time = get_last_message_timestamp(agent_state)

    idle_time =
      if last_message_time do
        current_time - last_message_time
      else
        current_time
      end

    %{
      agent_state: agent_state,
      current_turn_active: State.is_streaming?(agent_state),
      tools_executing: has_executing_tools?(agent_state),
      pending_tool_count: count_pending_tools(agent_state),
      last_message_timestamp: last_message_time,
      conversation_idle_time: idle_time
    }
  end

  @spec has_urgent_steering?([Message.t()]) :: boolean()
  defp has_urgent_steering?(messages) do
    Enum.any?(messages, fn message ->
      content = Message.content(message)

      String.contains?(content, ["[URGENT]", "[STOP]", "[INTERRUPT]"]) or
        String.starts_with?(content, "!")
    end)
  end

  @spec at_natural_break?(AgentState.t()) :: boolean()
  defp at_natural_break?(agent_state) do
    # Agent is at a natural break if:
    # 1. Not currently streaming a response
    # 2. No tools are executing
    # 3. Last message was completed (not partial)
    not State.is_streaming?(agent_state) and
      not has_executing_tools?(agent_state) and
      last_message_complete?(agent_state)
  end

  @spec has_expired_follow_ups?([Message.t()]) :: boolean()
  defp has_expired_follow_ups?(messages) do
    # 10 minutes
    expiry_time = System.system_time(:millisecond) - 600_000

    Enum.any?(messages, fn message ->
      Message.timestamp(message) < expiry_time
    end)
  end

  @spec determine_steering_processing_mode([Message.t()], steering_options()) ::
          Queue.processing_mode()
  defp determine_steering_processing_mode(messages, options) do
    max_per_batch = Keyword.get(options, :max_steering_per_turn, 5)

    if length(messages) <= max_per_batch and has_urgent_steering?(messages) do
      # Process all urgent messages at once
      :all
    else
      # Process gradually for non-urgent
      :one_at_a_time
    end
  end

  @spec determine_follow_up_processing_mode([Message.t()], follow_up_options()) ::
          Queue.processing_mode()
  defp determine_follow_up_processing_mode(_messages, _options) do
    # Follow-ups are always processed one at a time for natural flow
    :one_at_a_time
  end

  @spec calculate_processing_capacity(AgentState.t()) :: float()
  defp calculate_processing_capacity(agent_state) do
    # Simple capacity calculation based on current workload
    pending_tools = count_pending_tools(agent_state)
    message_count = length(agent_state.messages)

    # Capacity decreases with more pending work
    base_capacity = 1.0
    tool_impact = pending_tools * 0.1
    message_impact = message_count * 0.01

    max(0.0, base_capacity - tool_impact - message_impact)
  end

  @spec calculate_message_priority([Message.t()], atom()) :: non_neg_integer()
  defp calculate_message_priority(messages, message_type) do
    base_priority =
      case message_type do
        :steering -> 100
        :follow_up -> 50
      end

    # Increase priority based on message count and urgency
    count_bonus = length(messages) * 5
    urgency_bonus = if has_urgent_steering?(messages), do: 50, else: 0

    base_priority + count_bonus + urgency_bonus
  end

  @spec estimate_completion_time(AgentState.t()) :: pos_integer()
  defp estimate_completion_time(agent_state) do
    pending_tools = count_pending_tools(agent_state)
    streaming = State.is_streaming?(agent_state)

    # Rough estimates
    # 2 seconds per tool
    tool_time = pending_tools * 2000
    # 5 seconds for streaming
    streaming_time = if streaming, do: 5000, else: 0

    tool_time + streaming_time
  end

  @spec estimate_processing_time([Message.t()]) :: pos_integer()
  defp estimate_processing_time(messages) do
    # Rough estimate: 1 second per message plus base processing time
    base_time = 1000
    message_time = length(messages) * 1000

    base_time + message_time
  end

  @spec clean_expired_follow_ups(Queue.message_queue()) :: Queue.message_queue()
  defp clean_expired_follow_ups(message_queue) do
    # 10 minutes
    expiry_time = System.system_time(:millisecond) - 600_000

    Queue.filter_messages(message_queue, fn message ->
      Message.timestamp(message) >= expiry_time
    end)
  end

  @spec get_last_message_timestamp(AgentState.t()) :: pos_integer() | nil
  defp get_last_message_timestamp(agent_state) do
    messages = State.get_messages(agent_state)

    case List.last(messages) do
      nil -> nil
      last_message -> Message.timestamp(last_message)
    end
  end

  @spec has_executing_tools?(AgentState.t()) :: boolean()
  defp has_executing_tools?(agent_state) do
    count_pending_tools(agent_state) > 0
  end

  @spec count_pending_tools(AgentState.t()) :: non_neg_integer()
  defp count_pending_tools(agent_state) do
    agent_state
    |> State.get_pending_tool_calls()
    |> MapSet.size()
  end

  @spec last_message_complete?(AgentState.t()) :: boolean()
  defp last_message_complete?(agent_state) do
    # Check if the last message in the conversation is complete
    # (not partial or streaming)
    not State.is_streaming?(agent_state)
  end
end
