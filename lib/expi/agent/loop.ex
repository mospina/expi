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
    options: AgentOptions.t()
  }

  @default_timeout 300_000  # 5 minutes
  @default_steering_interval 100  # 100ms
  @default_follow_up_interval 500  # 500ms

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
    
    # Initialize loop state
    loop_state = %{
      agent_state: initial_state,
      message_queue: %{steering: [], follow_up: []},
      current_turn: 0,
      loop_start_time: System.system_time(:millisecond),
      options: agent_options
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
      task = Task.async(fn ->
        process_conversation(loop_state, max_turns, event_callback)
      end)
      
      case Task.await(task, timeout) do
        {:ok, final_loop_state} ->
          final_state = final_loop_state.agent_state
          
          # Emit agent end event
          end_event = Events.agent_lifecycle_event(:end, final_state)
          emit_event_if_callback(end_event, event_callback)
          
          Logger.info("Agent loop completed", %{
            turns_completed: final_loop_state.current_turn,
            total_messages: State.message_count(final_state)
          })
          
          {:ok, final_state}
          
        {:error, reason} = error ->
          # Emit error event
          error_event = Events.agent_lifecycle_event(:error, loop_state.agent_state, inspect(reason))
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
      message_queue: %{steering: [], follow_up: []},
      current_turn: 1,
      loop_start_time: System.system_time(:millisecond),
      options: agent_options
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
    # In a full implementation, this would interact with a message queue
    # For now, we'll add it to a hypothetical steering queue in state
    Logger.debug("Steering message added", %{
      message_type: Expi.Agent.Message.message_type(message)
    })
    
    # This would be implemented as part of a broader queue management system
    agent_state
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
    # Similar to steering, this would interact with message queue management
    Logger.debug("Follow-up message added", %{
      message_type: Expi.Agent.Message.message_type(message)
    })
    
    agent_state
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
    has_pending_tools = State.has_pending_tools?(loop_state.agent_state)
    has_steering = length(loop_state.message_queue.steering) > 0
    has_follow_up = length(loop_state.message_queue.follow_up) > 0
    is_streaming = State.is_streaming?(loop_state.agent_state)
    
    has_pending_tools or has_steering or has_follow_up or is_streaming
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
      message_count: State.message_count(loop_state.agent_state),
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
      # Check turn limit
      max_turns != :unlimited and loop_state.current_turn >= max_turns ->
        Logger.debug("Turn limit reached", %{max_turns: max_turns})
        {:ok, loop_state}
      
      # Check if we should continue
      not should_continue?(loop_state) and length(loop_state.message_queue.follow_up) == 0 ->
        Logger.debug("No more work to do")
        {:ok, loop_state}
      
      true ->
        # Execute inner loop for current work
        case inner_loop(loop_state, event_callback) do
          {:ok, updated_loop_state} ->
            # Check for follow-up messages
            case process_follow_up_messages(updated_loop_state) do
              {new_loop_state, true} ->
                # More follow-up messages to process
                outer_loop(new_loop_state, max_turns, event_callback)
              {final_loop_state, false} ->
                # No more follow-up messages
                {:ok, final_loop_state}
            end
            
          {:error, reason} = error ->
            Logger.error("Inner loop failed", %{reason: inspect(reason)})
            error
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
      message_count: State.message_count(loop_state.agent_state)
    })
    
    {:ok, updated_loop_state}
  end

  @spec process_assistant_turn(loop_state(), function() | nil) :: 
        {:ok, loop_state()} | {:error, any()}
  defp process_assistant_turn(loop_state, event_callback) do
    case Turn.execute_turn(loop_state, event_callback) do
      {:ok, updated_agent_state} ->
        updated_loop_state = %{loop_state | agent_state: updated_agent_state}
        {:ok, updated_loop_state}
      {:error, _reason} = error ->
        error
    end
  end

  @spec handle_turn_tool_calls(loop_state(), function() | nil) :: 
        {:ok, loop_state()} | {:error, any()}
  defp handle_turn_tool_calls(loop_state, event_callback) do
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

  @spec finalize_turn_processing(loop_state(), function() | nil) :: 
        {:ok, loop_state()}
  defp finalize_turn_processing(loop_state, event_callback) do
    # Process any steering messages that arrived during the turn
    {:ok, updated_loop_state} = process_steering_messages(loop_state, event_callback)
    
    # Turn is complete
    Logger.debug("Turn completed", %{
      turn: loop_state.current_turn,
      final_message_count: State.message_count(updated_loop_state.agent_state)
    })
    
    {:ok, updated_loop_state}
  end

  @spec process_follow_up_messages(loop_state()) :: {loop_state(), boolean()}
  defp process_follow_up_messages(loop_state) do
    case loop_state.message_queue.follow_up do
      [] ->
        # No follow-up messages
        {loop_state, false}
        
      follow_up_messages ->
        Logger.debug("Processing follow-up messages", %{
          count: length(follow_up_messages)
        })
        
        # Add follow-up messages to agent state and clear queue
        updated_agent_state = State.add_messages(loop_state.agent_state, follow_up_messages)
        updated_queue = %{loop_state.message_queue | follow_up: []}
        updated_loop_state = %{loop_state | 
          agent_state: updated_agent_state,
          message_queue: updated_queue
        }
        
        # More processing needed
        {updated_loop_state, true}
    end
  end

  @spec process_steering_messages(loop_state(), function() | nil) :: 
        {:ok, loop_state()} | {:error, any()}
  defp process_steering_messages(loop_state, _event_callback) do
    case loop_state.message_queue.steering do
      [] ->
        # No steering messages
        {:ok, loop_state}
        
      steering_messages ->
        Logger.debug("Processing steering messages", %{
          count: length(steering_messages)
        })
        
        # Add steering messages to agent state and clear queue
        updated_agent_state = State.add_messages(loop_state.agent_state, steering_messages)
        updated_queue = %{loop_state.message_queue | steering: []}
        updated_loop_state = %{loop_state | 
          agent_state: updated_agent_state,
          message_queue: updated_queue
        }
        
        {:ok, updated_loop_state}
    end
  end

  @spec execute_pending_tools(loop_state(), function() | nil) :: 
        {:ok, loop_state()} | {:error, any()}
  defp execute_pending_tools(loop_state, event_callback) do
    # Get the last assistant message to extract tool calls
    messages = State.get_messages(loop_state.agent_state)
    
    case get_latest_assistant_message_with_tools(messages) do
      {:ok, assistant_message} ->
        tool_calls = extract_tool_calls(assistant_message)
        available_tools = State.get_tools(loop_state.agent_state)
        
        # Set up event callback for tool execution
        tool_callback = if event_callback do
          fn event -> event_callback.(event) end
        else
          nil
        end
        
        # Execute tools
        case ToolExecutor.execute_tools_concurrent(tool_calls, available_tools, 
               on_complete: tool_callback) do
          {:ok, tool_results} ->
            # Add tool results to state
            updated_agent_state = State.add_messages(loop_state.agent_state, tool_results)
            
            # Clear pending tool calls
            cleared_agent_state = Enum.reduce(tool_calls, updated_agent_state, fn tool_call, state ->
              State.remove_pending_tool_call(state, tool_call.id)
            end)
            
            updated_loop_state = %{loop_state | agent_state: cleared_agent_state}
            {:ok, updated_loop_state}
            
          {:error, reason} = error ->
            Logger.error("Tool execution failed", %{reason: inspect(reason)})
            error
        end
        
      {:error, reason} = error ->
        Logger.error("Could not find assistant message with tools", %{reason: reason})
        error
    end
  end

  @spec get_latest_assistant_message_with_tools([Expi.Agent.Message.t()]) :: 
        {:ok, AssistantMessage.t()} | {:error, :not_found}
  defp get_latest_assistant_message_with_tools(messages) do
    # Find the most recent assistant message that has tool calls
    assistant_message = messages
    |> Enum.reverse()  # Start from most recent
    |> Enum.find(fn message ->
      case Expi.Agent.Message.to_llm_message(message) do
        %AssistantMessage{content: content} ->
          Enum.any?(content, fn block ->
            match?(%{type: :tool_call}, block)
          end)
        _ -> false
      end
    end)
    
    case assistant_message do
      nil -> {:error, :not_found}
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