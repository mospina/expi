defmodule Expi.Agent.Loop do
  @moduledoc """
  Core agent loop orchestration for conversation management.

  This module implements the sophisticated two-level loop system that enables
  complex conversation flows with proper handling of tool execution, steering
  messages, and follow-up processing. The loop coordinates between AI model
  streaming, tool execution, and state management to provide seamless agent
  operation.

  ## Loop Architecture

  The agent loop uses a two-level architecture:

  **Outer Loop**: Follow-up message processing
  - Processes messages that wait until the agent naturally stops
  - Handles conversation continuation and natural flow
  - Manages conversation completion and cleanup

  **Inner Loop**: Tool calls and steering
  - Manages current assistant response streaming
  - Executes tool calls concurrently or sequentially
  - Handles steering messages (urgent interruptions)
  - Coordinates state updates and event emission

  ## Core Functions

  - **Main Loop**: `run_agent_loop/3`, `process_conversation/2`
  - **Turn Management**: `execute_turn/3`, `process_assistant_response/3`
  - **Tool Coordination**: `handle_tool_calls/3`, `process_tool_results/3`
  - **Message Handling**: `process_pending_messages/3`, `handle_steering/3`
  - **State Management**: `update_loop_state/2`, `finalize_turn/3`

  ## Integration Points

  The loop integrates with all agent subsystems:
  - State management for conversation context
  - Message processing for LLM format conversion
  - Tool execution for concurrent tool processing
  - Event system for real-time progress updates
  - Callback system for external integrations
  """

  alias Expi.Agent.Types.{AgentState, AgentEvent, AgentOptions}
  alias Expi.Agent.{State, ToolExecutor, Events, Turn}
  alias Expi.Types.{AssistantMessage, ToolCall}

  require Logger

  @type loop_result :: {:ok, AgentState.t()} | {:error, any()}
  @type loop_options :: [
          max_turns: pos_integer() | :unlimited,
          timeout: pos_integer(),
          event_callback: function() | nil,
          steering_check_interval: pos_integer(),
          follow_up_check_interval: pos_integer()
        ]
  @type message_queue :: %{
          steering: [Expi.Agent.Message.t()],
          follow_up: [Expi.Agent.Message.t()]
        }
  @type loop_state :: %{
          agent_state: AgentState.t(),
          message_queue: message_queue(),
          current_turn: non_neg_integer(),
          loop_start_time: pos_integer(),
          options: AgentOptions.t(),
          empty_turn_count: non_neg_integer(),
          max_consecutive_empty_turns: non_neg_integer(),
          tool_calls_executed: non_neg_integer(),
          stop_reason: atom() | nil,
          status: :running | :completed | :stopped_incomplete | :error | :aborted
        }

  # 5 minutes
  @default_timeout 300_000
  # 100ms
  @default_steering_interval 100
  # 500ms
  @default_follow_up_interval 500

  @doc """
  Runs the main agent loop with full conversation orchestration.

  This is the primary entry point for agent operation. It manages the complete
  conversation flow including message processing, tool execution, and state
  management while handling interruptions and follow-up messages.

  ## Parameters

  - `initial_state` - Starting agent state with model and configuration
  - `agent_options` - Agent configuration options
  - `loop_options` - Loop-specific configuration options

  ## Options

  - `max_turns` - Maximum number of conversation turns (:unlimited or integer)
  - `timeout` - Maximum total execution time in milliseconds
  - `event_callback` - Function to call for each agent event
  - `steering_check_interval` - How often to check for steering messages (ms)
  - `follow_up_check_interval` - How often to check for follow-up messages (ms)

  ## Examples

      # Basic agent loop
      {:ok, final_state} = AgentLoop.run_agent_loop(
        initial_state,
        agent_options
      )
      
      # With custom configuration
      {:ok, final_state} = AgentLoop.run_agent_loop(
        initial_state,
        agent_options,
        max_turns: 10,
        timeout: 600_000,
        event_callback: fn agent_event ->
          IO.puts("Agent event: " <> to_string(agent_event.type))
        end
      )
      
      # Unlimited turns with real-time monitoring
      {:ok, final_state} = AgentLoop.run_agent_loop(
        initial_state,
        agent_options,
        max_turns: :unlimited,
        steering_check_interval: 50,  # Very responsive
        event_callback: &handle_agent_event/1
      )
  """
  @spec run_agent_loop(AgentState.t(), AgentOptions.t(), loop_options()) :: loop_result()
  def run_agent_loop(initial_state, agent_options, options \\ []) do
    max_turns = Keyword.get(options, :max_turns, :unlimited)
    timeout = Keyword.get(options, :timeout, @default_timeout)
    event_callback = Keyword.get(options, :event_callback)

    max_empty_turns = Keyword.get(options, :max_consecutive_empty_turns, 1)

    # Initialize loop state
    loop_state = %{
      agent_state: initial_state,
      message_queue: %{
        steering: Map.get(initial_state, :steering_queue, []),
        follow_up: Map.get(initial_state, :follow_up_queue, [])
      },
      current_turn: 0,
      loop_start_time: System.system_time(:millisecond),
      options: agent_options,
      empty_turn_count: 0,
      max_consecutive_empty_turns: max_empty_turns,
      tool_calls_executed: 0,
      stop_reason: nil,
      status: :running
    }

    Logger.info("Starting agent loop", %{
      max_turns: max_turns,
      timeout: timeout,
      agent_id: Map.get(initial_state, :agent_id, "unknown")
    })

    # Emit agent start event
    start_event = Events.agent_lifecycle_event(:start, initial_state)
    emit_event_if_callback(start_event, event_callback)

    try do
      # Run the main conversation loop with timeout
      task =
        Task.async(fn ->
          process_conversation(loop_state, max_turns, event_callback)
        end)

      case Task.await(task, timeout) do
        {:ok, final_loop_state} ->
          outcome = build_loop_outcome(final_loop_state)
          final_state = Map.put(final_loop_state.agent_state, :loop_outcome, outcome)

          # Emit agent end event
          end_event = Expi.Agent.Types.AgentEvent.agent_end(final_state.messages, outcome)
          emit_event_if_callback(end_event, event_callback)

          Logger.info("Agent loop completed", %{
            turns_completed: final_loop_state.current_turn,
            total_messages: length(final_state.messages)
          })

          {:ok, final_state}

        {:error, reason} = error ->
          # Emit error event
          error_event =
            Events.agent_lifecycle_event(:error, loop_state.agent_state, inspect(reason))

          emit_event_if_callback(error_event, event_callback)

          error
      end
    rescue
      error ->
        Logger.error("Agent loop crashed", %{
          error: Exception.message(error),
          stacktrace: Exception.format_stacktrace(__STACKTRACE__)
        })

        {:error, {:loop_crashed, Exception.message(error)}}
    catch
      :exit, {:timeout, _} ->
        Logger.warning("Agent loop timed out", %{
          timeout: timeout,
          elapsed: System.system_time(:millisecond) - loop_state.loop_start_time
        })

        {:error, :loop_timeout}
    end
  end

  @doc """
  Processes a single conversation turn with full tool execution.

  Handles one complete assistant response including streaming, tool calls,
  and result processing. This is the core turn processing logic.

  ## Examples

      {:ok, updated_state} = AgentLoop.process_single_turn(
        agent_state,
        agent_options,
        event_callback: &handle_events/1
      )
  """
  @spec process_single_turn(AgentState.t(), AgentOptions.t(), keyword()) ::
          {:ok, AgentState.t()} | {:error, any()}
  def process_single_turn(agent_state, agent_options, options \\ []) do
    event_callback = Keyword.get(options, :event_callback)

    # Create minimal loop state for single turn
    loop_state = %{
      agent_state: agent_state,
      message_queue: %{
        steering: Map.get(agent_state, :steering_queue, []),
        follow_up: Map.get(agent_state, :follow_up_queue, [])
      },
      current_turn: 1,
      loop_start_time: System.system_time(:millisecond),
      options: agent_options,
      empty_turn_count: 0,
      max_consecutive_empty_turns: 1,
      tool_calls_executed: 0,
      stop_reason: nil,
      status: :running
    }

    Turn.execute_turn(loop_state, event_callback)
  end

  @doc """
  Adds a steering message to interrupt current processing.

  Steering messages are delivered immediately after the current tool execution
  completes, potentially skipping remaining tool calls in the current turn.

  ## Examples

      # Add urgent user interruption
      updated_state = AgentLoop.add_steering_message(state, user_message)
      
      # Add system steering message
      system_msg = Message.user("[SYSTEM] Processing interrupted by user")
      updated_state = AgentLoop.add_steering_message(state, system_msg)
  """
  @spec add_steering_message(AgentState.t(), Expi.Agent.Message.t()) :: AgentState.t()
  def add_steering_message(agent_state, message) do
    Logger.debug("Steering message added", %{
      message_type: Expi.Agent.Message.message_type(message)
    })

    State.enqueue_steering(agent_state, message)
  end

  @doc """
  Adds a follow-up message to be processed after current work completes.

  Follow-up messages wait until the agent has naturally completed its current
  work and has no more pending operations.

  ## Examples

      # Add follow-up question
      follow_up = Message.user("Can you also check the latest updates?")
      updated_state = AgentLoop.add_follow_up_message(state, follow_up)
  """
  @spec add_follow_up_message(AgentState.t(), Expi.Agent.Message.t()) :: AgentState.t()
  def add_follow_up_message(agent_state, message) do
    Logger.debug("Follow-up message added", %{
      message_type: Expi.Agent.Message.message_type(message)
    })

    State.enqueue_follow_up(agent_state, message)
  end

  @doc """
  Checks if the agent should continue processing.

  Determines whether the agent should continue with more turns based on
  pending messages, tool calls, and continuation conditions.

  ## Examples

      if AgentLoop.should_continue?(loop_state) do
        continue_processing()
      else
        finalize_conversation()
      end
  """
  @spec should_continue?(loop_state()) :: boolean()
  def should_continue?(loop_state) do
    if loop_state.status in [:error, :aborted, :stopped_incomplete] do
      false
    else
      has_pending_tools = State.has_pending_tools?(loop_state.agent_state)
      has_steering = loop_state.message_queue.steering != []
      has_follow_up = loop_state.message_queue.follow_up != []
      is_streaming = State.is_streaming?(loop_state.agent_state)
      needs_assistant_turn = last_message_requires_response?(loop_state.agent_state)

      has_pending_tools or has_steering or has_follow_up or is_streaming or needs_assistant_turn
    end
  end

  @doc """
  Gets comprehensive loop statistics for monitoring.

  ## Examples

      stats = AgentLoop.get_loop_stats(loop_state)
      IO.puts("Current turn: " <> to_string(stats.current_turn))
      IO.puts("Elapsed time: " <> to_string(stats.elapsed_time) <> "ms")
      IO.puts("Messages processed: " <> to_string(stats.message_count))
  """
  @spec get_loop_stats(loop_state()) :: map()
  def get_loop_stats(loop_state) do
    elapsed_time = System.system_time(:millisecond) - loop_state.loop_start_time

    %{
      current_turn: loop_state.current_turn,
      elapsed_time: elapsed_time,
      message_count: length(loop_state.agent_state.messages),
      pending_tool_calls: MapSet.size(State.get_pending_tool_calls(loop_state.agent_state)),
      steering_queue_size: length(loop_state.message_queue.steering),
      follow_up_queue_size: length(loop_state.message_queue.follow_up),
      is_streaming: State.is_streaming?(loop_state.agent_state),
      has_error: State.has_error?(loop_state.agent_state)
    }
  end

  @doc """
  Validates loop configuration and state before starting.

  ## Examples

      case AgentLoop.validate_loop_setup(agent_state, agent_options) do
        :ok -> start_loop()
        {:error, reason} -> handle_setup_error(reason)
      end
  """
  @spec validate_loop_setup(AgentState.t(), AgentOptions.t()) ::
          :ok | {:error, String.t()}
  def validate_loop_setup(agent_state, agent_options) do
    cond do
      State.validate(agent_state) != :ok ->
        {:error, "Invalid agent state"}

      not AgentOptions.valid?(agent_options) ->
        {:error, "Invalid agent options"}

      is_nil(agent_state.model) ->
        {:error, "No model specified in agent state"}

      true ->
        :ok
    end
  end

  # Private implementation functions

  @spec process_conversation(loop_state(), pos_integer() | :unlimited, function() | nil) ::
          {:ok, loop_state()} | {:error, any()}
  defp process_conversation(loop_state, max_turns, event_callback) do
    # Outer loop: Follow-up message processing
    outer_loop(loop_state, max_turns, event_callback)
  end

  @spec outer_loop(loop_state(), pos_integer() | :unlimited, function() | nil) ::
          {:ok, loop_state()} | {:error, any()}
  defp outer_loop(loop_state, max_turns, event_callback) do
    cond do
      turn_limit_reached?(loop_state, max_turns) ->
        Logger.debug("Turn limit reached", %{max_turns: max_turns})
        {:ok, loop_state}

      no_remaining_work?(loop_state) ->
        Logger.debug("No more work to do")
        {:ok, loop_state}

      true ->
        continue_outer_loop(loop_state, max_turns, event_callback)
    end
  end

  defp turn_limit_reached?(loop_state, max_turns) do
    max_turns != :unlimited and loop_state.current_turn >= max_turns
  end

  defp no_remaining_work?(loop_state) do
    not should_continue?(loop_state) and Enum.empty?(loop_state.message_queue.follow_up)
  end

  defp continue_outer_loop(loop_state, max_turns, event_callback) do
    case inner_loop(loop_state, event_callback) do
      {:ok, updated_loop_state} ->
        route_post_turn(updated_loop_state, max_turns, event_callback)

      {:error, reason} = error ->
        Logger.error("Inner loop failed", %{reason: inspect(reason)})
        error
    end
  end

  defp route_post_turn(updated_loop_state, max_turns, event_callback) do
    case process_follow_up_messages(updated_loop_state) do
      {new_loop_state, true} ->
        outer_loop(new_loop_state, max_turns, event_callback)

      {final_loop_state, false} ->
        if should_continue?(final_loop_state) do
          outer_loop(final_loop_state, max_turns, event_callback)
        else
          {:ok, final_loop_state}
        end
    end
  end

  @spec inner_loop(loop_state(), function() | nil) ::
          {:ok, loop_state()} | {:error, any()}
  defp inner_loop(loop_state, event_callback) do
    # Inner loop: Process current turn with tool calls and steering
    with {:ok, turn_state} <- prepare_turn(loop_state),
         {:ok, response_state} <- process_assistant_turn(turn_state, event_callback),
         {:ok, tools_state} <- handle_turn_tool_calls(response_state, event_callback),
         {:ok, final_state} <- finalize_turn_processing(tools_state, event_callback) do
      {:ok, final_state}
    else
      {:empty_turn, updated_loop_state} ->
        {:ok, updated_loop_state}

      {:error, reason} = error ->
        Logger.error("Turn processing failed", %{
          reason: inspect(reason),
          turn: loop_state.current_turn
        })

        error
    end
  end

  @spec prepare_turn(loop_state()) :: {:ok, loop_state()} | {:error, any()}
  defp prepare_turn(loop_state) do
    # Increment turn counter
    updated_loop_state = %{loop_state | current_turn: loop_state.current_turn + 1}

    Logger.debug("Preparing turn", %{
      turn: updated_loop_state.current_turn,
      message_count: length(loop_state.agent_state.messages)
    })

    {:ok, updated_loop_state}
  end

  @spec process_assistant_turn(loop_state(), function() | nil) ::
          {:ok, loop_state()} | {:error, any()}
  defp process_assistant_turn(loop_state, event_callback) do
    case Turn.execute_turn(loop_state, event_callback) do
      {:ok, updated_agent_state} ->
        updated_loop_state = %{loop_state | agent_state: updated_agent_state, empty_turn_count: 0}

        case List.last(State.get_messages(updated_agent_state)) do
          %{role: :assistant, stop_reason: :aborted} ->
            {:ok, %{updated_loop_state | status: :aborted, stop_reason: :aborted}}

          %{role: :assistant, stop_reason: :error} ->
            {:ok, %{updated_loop_state | status: :error, stop_reason: :provider_error}}

          _ ->
            {:ok, updated_loop_state}
        end

      {:error, :empty_turn_result} ->
        next_empty_count = loop_state.empty_turn_count + 1

        if next_empty_count > loop_state.max_consecutive_empty_turns do
          {:empty_turn,
           %{
             loop_state
             | empty_turn_count: next_empty_count,
               status: :stopped_incomplete,
               stop_reason: :stopped_empty_after_tools
           }}
        else
          {:empty_turn, %{loop_state | empty_turn_count: next_empty_count}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec handle_turn_tool_calls(loop_state(), function() | nil) ::
          {:ok, loop_state()} | {:error, any()}
  defp handle_turn_tool_calls(loop_state, event_callback) do
    if loop_state.status in [:error, :aborted, :stopped_incomplete] do
      {:ok, loop_state}
    else
      # Check if there are pending tool calls to execute
      pending_tools = State.get_pending_tool_calls(loop_state.agent_state)

      if MapSet.size(pending_tools) > 0 do
        Logger.debug("Processing tool calls", %{
          tool_count: MapSet.size(pending_tools),
          turn: loop_state.current_turn
        })

        # Execute tools and update state
        case execute_pending_tools(loop_state, event_callback) do
          {:ok, updated_loop_state} ->
            {:ok, updated_loop_state}

          {:error, reason} = error ->
            Logger.error("Tool execution failed", %{reason: inspect(reason)})
            error
        end
      else
        # No tools to execute
        {:ok, loop_state}
      end
    end
  end

  @spec finalize_turn_processing(loop_state(), function() | nil) ::
          {:ok, loop_state()}
  defp finalize_turn_processing(loop_state, event_callback) do
    # Process any steering messages that arrived during the turn
    {:ok, updated_loop_state} = process_steering_messages(loop_state, event_callback)

    # Turn is complete
    Logger.debug("Turn completed", %{
      turn: loop_state.current_turn,
      final_message_count: length(updated_loop_state.agent_state.messages)
    })

    {:ok, updated_loop_state}
  end

  @spec process_follow_up_messages(loop_state()) :: {loop_state(), boolean()}
  defp process_follow_up_messages(loop_state) do
    mode = Map.get(loop_state.options, :follow_up_mode, :one_at_a_time)

    case loop_state.message_queue.follow_up do
      [] ->
        {loop_state, false}

      follow_up_messages ->
        {batch, remaining} = take_by_mode(follow_up_messages, mode)

        Logger.debug("Processing follow-up messages", %{
          count: length(batch),
          remaining: length(remaining),
          mode: mode
        })

        updated_agent_state =
          loop_state.agent_state
          |> State.add_messages(batch)
          |> Map.put(:follow_up_queue, remaining)

        updated_queue = %{loop_state.message_queue | follow_up: remaining}

        updated_loop_state = %{
          loop_state
          | agent_state: updated_agent_state,
            message_queue: updated_queue
        }

        {updated_loop_state, true}
    end
  end

  defp last_message_requires_response?(agent_state) do
    case State.get_messages(agent_state) do
      [] ->
        false

      messages ->
        case List.last(messages) do
          %{role: :user} -> true
          %{role: :tool_result} -> true
          _ -> false
        end
    end
  end

  @spec process_steering_messages(loop_state(), function() | nil) ::
          {:ok, loop_state()} | {:error, any()}
  defp process_steering_messages(loop_state, _event_callback) do
    mode = Map.get(loop_state.options, :steering_mode, :all)

    case loop_state.message_queue.steering do
      [] ->
        {:ok, loop_state}

      steering_messages ->
        {batch, remaining} = take_by_mode(steering_messages, mode)

        Logger.debug("Processing steering messages", %{
          count: length(batch),
          remaining: length(remaining),
          mode: mode
        })

        updated_agent_state =
          loop_state.agent_state
          |> State.add_messages(batch)
          |> Map.put(:steering_queue, remaining)

        updated_queue = %{loop_state.message_queue | steering: remaining}

        updated_loop_state = %{
          loop_state
          | agent_state: updated_agent_state,
            message_queue: updated_queue
        }

        {:ok, updated_loop_state}
    end
  end

  @spec execute_pending_tools(loop_state(), function() | nil) ::
          {:ok, loop_state()} | {:error, any()}
  defp execute_pending_tools(loop_state, event_callback) do
    messages = State.get_messages(loop_state.agent_state)

    case get_latest_assistant_message_with_tools(messages) do
      {:ok, assistant_message} ->
        run_tool_execution(loop_state, assistant_message, event_callback)

      {:error, reason} = error ->
        Logger.error("Could not find assistant message with tools", %{reason: reason})
        error
    end
  end

  defp run_tool_execution(loop_state, assistant_message, event_callback) do
    tool_calls = extract_tool_calls(assistant_message)
    available_tools = State.get_tools(loop_state.agent_state)
    tool_callback = if(event_callback, do: fn event -> event_callback.(event) end, else: nil)

    tool_strategy = Map.get(loop_state.options, :tool_execution_strategy, :sequential)
    tool_timeout = Map.get(loop_state.options, :tool_timeout)
    max_concurrent = Map.get(loop_state.options, :tool_max_concurrent)

    case tool_strategy do
      :sequential ->
        execute_tools_sequentially(
          loop_state,
          tool_calls,
          available_tools,
          tool_timeout,
          tool_callback
        )

      _ ->
        execute_tools_concurrently(
          loop_state,
          tool_calls,
          available_tools,
          tool_timeout,
          max_concurrent,
          tool_callback,
          tool_strategy
        )
    end
  end

  defp execute_tools_sequentially(
         loop_state,
         tool_calls,
         available_tools,
         tool_timeout,
         tool_callback
       ) do
    {results, _remaining, executed_count} =
      execute_tools_with_steering_interrupt(
        tool_calls,
        available_tools,
        tool_timeout,
        tool_callback,
        loop_state.agent_state
      )

    {:ok, apply_tool_results(loop_state, tool_calls, results, executed_count)}
  end

  defp execute_tools_concurrently(
         loop_state,
         tool_calls,
         available_tools,
         tool_timeout,
         max_concurrent,
         tool_callback,
         tool_strategy
       ) do
    tool_exec_opts =
      [on_complete: tool_callback, strategy: tool_strategy]
      |> maybe_put_opt(:timeout, tool_timeout)
      |> maybe_put_opt(:max_concurrent, max_concurrent)

    case ToolExecutor.execute_tools_concurrent(tool_calls, available_tools, tool_exec_opts) do
      {:ok, tool_results} ->
        {:ok, apply_tool_results(loop_state, tool_calls, tool_results, length(tool_calls))}

      {:error, reason} = error ->
        Logger.error("Tool execution failed", %{reason: inspect(reason)})
        error
    end
  end

  defp apply_tool_results(loop_state, tool_calls, results, executed_count) do
    updated_agent_state = State.add_messages(loop_state.agent_state, results)

    cleared_agent_state =
      Enum.reduce(tool_calls, updated_agent_state, fn tool_call, state ->
        State.remove_pending_tool_call(state, tool_call.id)
      end)

    %{
      loop_state
      | agent_state: cleared_agent_state,
        tool_calls_executed: loop_state.tool_calls_executed + executed_count
    }
  end

  @spec get_latest_assistant_message_with_tools([Expi.Agent.Message.t()]) ::
          {:ok, AssistantMessage.t()} | {:error, :not_found}
  defp get_latest_assistant_message_with_tools(messages) do
    # Find the most recent assistant message that has tool calls
    assistant_message =
      messages
      # Start from most recent
      |> Enum.reverse()
      |> Enum.find(fn message ->
        case Expi.Agent.Message.to_llm_message(message) do
          %AssistantMessage{content: content} ->
            Enum.any?(content, fn block ->
              match?(%{type: :tool_call}, block)
            end)

          _ ->
            false
        end
      end)

    case assistant_message do
      nil ->
        {:error, :not_found}

      message ->
        case Expi.Agent.Message.to_llm_message(message) do
          %AssistantMessage{} = llm_message -> {:ok, llm_message}
          _ -> {:error, :not_assistant_message}
        end
    end
  end

  @spec extract_tool_calls(AssistantMessage.t()) :: [ToolCall.t()]
  defp extract_tool_calls(assistant_message) do
    assistant_message.content
    |> Enum.filter(fn block -> match?(%{type: :tool_call}, block) end)
    |> Enum.map(fn %{type: :tool_call} = tool_call_block ->
      %ToolCall{
        id: tool_call_block.id,
        name: tool_call_block.name,
        arguments: tool_call_block.arguments
      }
    end)
  end

  defp take_by_mode(messages, :one_at_a_time) do
    case messages do
      [] -> {[], []}
      [first | rest] -> {[first], rest}
    end
  end

  defp take_by_mode(messages, _mode), do: {messages, []}

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp execute_tools_with_steering_interrupt(
         tool_calls,
         available_tools,
         tool_timeout,
         tool_callback,
         agent_state
       ) do
    tool_map =
      available_tools
      |> Enum.map(fn tool -> {Expi.Agent.Types.AgentTool.name(tool), tool} end)
      |> Map.new()

    Enum.reduce_while(Enum.with_index(tool_calls), {[], tool_calls, 0}, fn {tool_call, idx},
                                                                           {acc, _remaining,
                                                                            executed} ->
      if should_interrupt_for_steering?(agent_state, idx) do
        skipped = tool_calls |> Enum.drop(idx) |> Enum.map(&skipped_tool_result/1)
        {:halt, {acc ++ skipped, [], executed}}
      else
        result = execute_one_tool_call(tool_call, tool_map, tool_timeout, tool_callback)
        {:cont, {acc ++ [result], Enum.drop(tool_calls, idx + 1), executed + 1}}
      end
    end)
  end

  defp should_interrupt_for_steering?(agent_state, idx) do
    steering_queue = Map.get(agent_state, :steering_queue, [])
    idx > 0 and not Enum.empty?(steering_queue)
  end

  defp execute_one_tool_call(tool_call, tool_map, tool_timeout, tool_callback) do
    case Map.get(tool_map, tool_call.name) do
      nil ->
        skipped_tool_result(tool_call)

      tool ->
        exec_opts = [] |> maybe_put_opt(:timeout, tool_timeout) |> Keyword.put(:on_update, nil)
        {:ok, tool_result} = ToolExecutor.execute_single_tool(tool_call, tool, exec_opts)
        maybe_emit_tool_callback(tool_callback, tool_result)
        tool_result
    end
  end

  defp maybe_emit_tool_callback(callback, tool_result) when is_function(callback),
    do: callback.(tool_result)

  defp maybe_emit_tool_callback(_callback, _tool_result), do: :ok

  defp skipped_tool_result(tool_call) do
    %Expi.Types.ToolResultMessage{
      role: :tool_result,
      tool_call_id: tool_call.id,
      tool_name: tool_call.name,
      content: [
        %Expi.Types.TextContent{type: :text, text: "Skipped due to queued user message."}
      ],
      details: %{skipped: true, reason: :steering_interrupt},
      is_error: true,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp build_loop_outcome(loop_state) do
    status =
      case loop_state.status do
        :running -> :completed
        other -> other
      end

    %{
      status: status,
      stop_reason: loop_state.stop_reason || :completed,
      turn_count: loop_state.current_turn,
      tool_calls_executed: loop_state.tool_calls_executed,
      empty_turn_count: loop_state.empty_turn_count,
      metadata: %{}
    }
  end

  @spec emit_event_if_callback(AgentEvent.t(), function() | nil) :: :ok
  defp emit_event_if_callback(_event, nil), do: :ok

  defp emit_event_if_callback(event, callback) when is_function(callback) do
    try do
      callback.(event)
    rescue
      error ->
        Logger.warning("Event callback failed", %{
          event_type: event.type,
          error: Exception.message(error)
        })
    end

    :ok
  end
end
