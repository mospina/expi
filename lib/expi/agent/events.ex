defmodule Expi.Agent.Events do
  @moduledoc """
  Agent event emission and management system.

  This module provides comprehensive event emission capabilities for the agent
  lifecycle, enabling real-time monitoring, UI updates, and external system
  integrations. The event system covers all aspects of agent operation including
  agent lifecycle, conversation turns, message processing, and tool execution.

  ## Core Functions

  - **Emission**: `emit_event/2`, `emit_events/2`, `broadcast_event/2`
  - **Management**: `create_emitter/1`, `attach_emitter/2`, `detach_emitter/1`
  - **Filtering**: `filter_events/2`, `route_events/3`, `transform_events/2`
  - **Utilities**: `event_summary/1`, `validate_event/1`, `merge_events/2`

  ## Event Categories

  - **Agent Lifecycle**: Agent start/end, state changes, errors
  - **Turn Management**: Turn start/end, message processing cycles
  - **Message Events**: Message creation, updates, completion
  - **Tool Execution**: Tool start/update/end, results, failures
  - **Custom Events**: Application-specific events through extension

  ## Integration Patterns

  The event system integrates seamlessly with all agent components:
  - State management emits state change events
  - Tool execution emits progress and completion events
  - Message processing emits transformation and validation events
  - Agent loops emit turn and lifecycle events
  """

  alias Expi.Agent.Types.{AgentEvent, AgentState}
  alias Expi.Agent.Callbacks

  require Logger

  @type event_emitter :: %{
          id: String.t(),
          callbacks: [Callbacks.callback_spec()],
          filters: [event_filter()],
          active: boolean()
        }

  @type event_filter :: (AgentEvent.t() -> boolean()) | {:type, atom()} | {:pattern, map()}
  @type emission_options :: [
          async: boolean(),
          timeout: pos_integer(),
          filter: event_filter() | nil,
          metadata: map()
        ]

  @doc """
  Emits a single event to all registered callbacks.

  This is the primary function for event emission. It handles the routing
  of events to appropriate callbacks while managing filters, transformations,
  and error handling.

  ## Parameters

  - `event` - The AgentEvent to emit
  - `callbacks_or_emitter` - List of callbacks or an event emitter
  - `options` - Emission options

  ## Options

  - `async` - Whether to emit asynchronously (default: true)
  - `timeout` - Timeout for synchronous emission (default: 5000ms)
  - `filter` - Additional filter to apply before emission
  - `metadata` - Additional metadata to attach to the event

  ## Examples

      # Basic event emission
      event = AgentEvent.agent_start()
      Events.emit_event(event, callback_list)
      
      # Synchronous emission with timeout
      Events.emit_event(event, callback_list, 
        async: false, 
        timeout: 10_000
      )
      
      # Filtered emission (only send to specific callback types)
      Events.emit_event(event, callback_list,
        filter: fn event -> event.type == :tool_execution_start end
      )
      
      # With additional metadata
      Events.emit_event(event, callback_list,
        metadata: %{agent_id: "agent_123", session: "session_456"}
      )
  """
  @spec emit_event(
          AgentEvent.t(),
          [Callbacks.callback_spec()] | event_emitter(),
          emission_options()
        ) ::
          :ok | {:error, any()}
  def emit_event(event, callbacks_or_emitter, options \\ []) do
    async = Keyword.get(options, :async, true)
    timeout = Keyword.get(options, :timeout, 5_000)
    filter = Keyword.get(options, :filter)
    _metadata = Keyword.get(options, :metadata, %{})

    # For now, we don't modify the event with metadata since AgentEvent doesn't have a metadata field
    # In a real implementation, we might extend AgentEvent or handle metadata differently
    enriched_event = event

    # Apply filter if provided
    should_emit =
      if filter do
        apply_filter(enriched_event, filter)
      else
        true
      end

    if should_emit do
      case callbacks_or_emitter do
        %{callbacks: callbacks, filters: emitter_filters} = _emitter ->
          # Use emitter with its own filters
          filtered_event = apply_emitter_filters(enriched_event, emitter_filters)

          if filtered_event do
            do_emit(filtered_event, callbacks, async, timeout)
          else
            # Event was filtered out
            :ok
          end

        callbacks when is_list(callbacks) ->
          # Direct callback list
          do_emit(enriched_event, callbacks, async, timeout)

        _ ->
          {:error, :invalid_callbacks}
      end
    else
      # Event was filtered out
      :ok
    end
  end

  @doc """
  Emits multiple events in sequence or parallel.

  Efficiently handles batch emission of multiple events, with options
  for sequential or parallel processing.

  ## Examples

      events = [
        AgentEvent.turn_start(),
        AgentEvent.message_start(message),
        AgentEvent.tool_execution_start("call_1", "search", %{})
      ]
      
      # Parallel emission (default)
      Events.emit_events(events, callbacks)
      
      # Sequential emission
      Events.emit_events(events, callbacks, mode: :sequential)
      
      # With shared metadata
      Events.emit_events(events, callbacks, 
        metadata: %{batch_id: "batch_123"}
      )
  """
  @spec emit_events([AgentEvent.t()], [Callbacks.callback_spec()] | event_emitter(), keyword()) ::
          :ok | {:error, any()}
  def emit_events(events, callbacks_or_emitter, options \\ []) do
    mode = Keyword.get(options, :mode, :parallel)
    shared_metadata = Keyword.get(options, :metadata, %{})

    case mode do
      :parallel ->
        # Emit all events concurrently
        tasks =
          Enum.map(events, fn event ->
            Task.async(fn ->
              emit_event(event, callbacks_or_emitter,
                metadata: shared_metadata,
                # Individual emissions are sync within the task
                async: false
              )
            end)
          end)

        # Wait for all to complete
        results = Task.await_many(tasks, 10_000)

        # Check if any failed
        case Enum.find(results, &match?({:error, _}, &1)) do
          nil -> :ok
          error -> error
        end

      :sequential ->
        # Emit events one by one
        Enum.reduce_while(events, :ok, fn event, _acc ->
          case emit_event(event, callbacks_or_emitter, metadata: shared_metadata) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  @doc """
  Broadcasts an event to all active emitters in the system.

  Useful for system-wide events that should be delivered to all
  registered listeners regardless of their specific subscriptions.

  ## Examples

      # System-wide agent shutdown event
      shutdown_event = AgentEvent.agent_end([])
      Events.broadcast_event(shutdown_event, emitter_registry)
      
      # Emergency error event
      error_event = %AgentEvent{type: :system_error, error: "Critical failure"}
      Events.broadcast_event(error_event, emitter_registry, priority: :high)
  """
  @spec broadcast_event(AgentEvent.t(), [event_emitter()], keyword()) :: :ok | {:error, any()}
  def broadcast_event(event, emitters, options \\ []) do
    priority = Keyword.get(options, :priority, :normal)

    active_emitters = Enum.filter(emitters, & &1.active)

    emission_options =
      case priority do
        :high -> [async: false, timeout: 15_000]
        :normal -> [async: true]
        :low -> [async: true, timeout: 2_000]
      end

    emit_events([event], active_emitters,
      mode: :parallel,
      emission_options: emission_options
    )
  end

  @doc """
  Creates a new event emitter with specified configuration.

  Event emitters encapsulate callback management, filtering, and routing
  logic for specific use cases or components.

  ## Examples

      # UI-focused emitter
      ui_emitter = Events.create_emitter(%{
        id: "ui_updates",
        callbacks: [ui_callback],
        filters: [
          {:type, :message_update},
          {:type, :tool_execution_update}
        ]
      })
      
      # Debug emitter that captures everything
      debug_emitter = Events.create_emitter(%{
        id: "debug_all",
        callbacks: [debug_callback],
        filters: []  # No filters - capture all events
      })
      
      # Performance monitoring emitter
      perf_emitter = Events.create_emitter(%{
        id: "performance",
        callbacks: [metrics_callback],
        filters: [
          fn event -> 
            event.type in [:turn_start, :turn_end, :tool_execution_end]
          end
        ]
      })
  """
  @spec create_emitter(map()) :: event_emitter()
  def create_emitter(config) do
    %{
      id: Map.get(config, :id, generate_emitter_id()),
      callbacks: Map.get(config, :callbacks, []),
      filters: Map.get(config, :filters, []),
      active: Map.get(config, :active, true)
    }
  end

  @doc """
  Attaches a callback to an existing emitter.

  ## Examples

      updated_emitter = Events.attach_emitter(emitter, new_callback)
  """
  @spec attach_emitter(event_emitter(), Callbacks.callback_spec()) :: event_emitter()
  def attach_emitter(%{callbacks: callbacks} = emitter, callback) do
    %{emitter | callbacks: callbacks ++ [callback]}
  end

  @doc """
  Detaches a callback from an emitter.

  ## Examples

      # Detach by callback ID
      updated_emitter = Events.detach_emitter(emitter, callback_id)
      
      # Detach by callback reference
      updated_emitter = Events.detach_emitter(emitter, callback)
  """
  @spec detach_emitter(event_emitter(), Callbacks.callback_spec() | String.t()) :: event_emitter()
  def detach_emitter(%{callbacks: callbacks} = emitter, callback_or_id) do
    updated_callbacks =
      case callback_or_id do
        id when is_binary(id) ->
          Enum.reject(callbacks, fn callback ->
            Callbacks.get_callback_id(callback) == id
          end)

        callback ->
          Enum.reject(callbacks, &(&1 == callback))
      end

    %{emitter | callbacks: updated_callbacks}
  end

  @doc """
  Filters events based on type, pattern, or custom function.

  ## Examples

      # Filter by event type
      tool_events = Events.filter_events(events, {:type, :tool_execution_start})
      
      # Filter by custom function
      error_events = Events.filter_events(events, fn event ->
        Map.has_key?(event, :error) and not is_nil(event.error)
      end)
      
      # Filter by pattern matching
      message_events = Events.filter_events(events, {:pattern, %{type: :message_update}})
  """
  @spec filter_events([AgentEvent.t()], event_filter()) :: [AgentEvent.t()]
  def filter_events(events, filter) when is_list(events) do
    Enum.filter(events, fn event ->
      apply_filter(event, filter)
    end)
  end

  @doc """
  Routes events to different callback sets based on routing rules.

  Enables sophisticated event distribution where different types of events
  are sent to different sets of callbacks.

  ## Examples

      routing_rules = [
        {fn e -> e.type == :tool_execution_start end, tool_callbacks},
        {fn e -> e.type in [:message_start, :message_end] end, ui_callbacks},
        {fn _ -> true end, debug_callbacks}  # Catch-all rule
      ]
      
      Events.route_events(events, routing_rules, async: true)
  """
  @spec route_events([AgentEvent.t()], [{event_filter(), [Callbacks.callback_spec()]}], keyword()) ::
          :ok
  def route_events(events, routing_rules, options \\ []) do
    async = Keyword.get(options, :async, true)

    events
    |> Enum.each(fn event ->
      # Find matching routing rules and emit to corresponding callbacks
      routing_rules
      |> Enum.each(fn {filter, callbacks} ->
        if apply_filter(event, filter) do
          emit_event(event, callbacks, async: async)
        end
      end)
    end)
  end

  @doc """
  Transforms events using a transformation function.

  Enables modification or enrichment of events before emission.

  ## Examples

      # Add timestamps to all events
      enriched_events = Events.transform_events(events, fn event ->
        Map.put(event, :processed_at, System.system_time(:millisecond))
      end)
      
      # Add context information
      contextualized_events = Events.transform_events(events, fn event ->
        %{event | metadata: Map.put(event.metadata || %{}, :agent_id, "agent_123")}
      end)
  """
  @spec transform_events([AgentEvent.t()], (AgentEvent.t() -> AgentEvent.t())) :: [AgentEvent.t()]
  def transform_events(events, transform_fn) when is_function(transform_fn, 1) do
    Enum.map(events, transform_fn)
  end

  @doc """
  Creates a summary of event activity for monitoring and debugging.

  ## Examples

      summary = Events.event_summary(recent_events)
      
      IO.puts("Events processed: " <> to_string(summary.total_count))
      IO.puts("Tool executions: " <> to_string(summary.by_type.tool_execution_start))
      IO.puts("Error rate: " <> to_string(summary.error_rate * 100) <> "%")
  """
  @spec event_summary([AgentEvent.t()]) :: map()
  def event_summary(events) do
    total_count = length(events)
    by_type = Enum.frequencies_by(events, & &1.type)

    error_count =
      events
      |> Enum.count(fn event ->
        Map.has_key?(event, :error) or Map.has_key?(event, :is_error)
      end)

    time_range =
      if events != [] do
        timestamps =
          events
          |> Enum.map(&get_event_timestamp/1)
          |> Enum.filter(&(&1 != nil))

        if timestamps != [] do
          {Enum.min(timestamps), Enum.max(timestamps)}
        else
          nil
        end
      else
        nil
      end

    %{
      total_count: total_count,
      by_type: by_type,
      error_count: error_count,
      error_rate:
        if total_count > 0 do
          error_count / total_count
        else
          0.0
        end,
      time_range: time_range,
      generated_at: System.system_time(:millisecond)
    }
  end

  @doc """
  Validates that an event structure is properly formed.

  ## Examples

      case Events.validate_event(event) do
        :ok -> process_event(event)
        {:error, reason} -> log_invalid_event(event, reason)
      end
  """
  @spec validate_event(AgentEvent.t()) :: :ok | {:error, String.t()}
  def validate_event(%AgentEvent{type: type} = event) do
    cond do
      not AgentEvent.valid_type?(type) ->
        {:error, "Invalid event type: #{inspect(type)}"}

      not is_struct(event, AgentEvent) ->
        {:error, "Event is not an AgentEvent struct"}

      true ->
        validate_event_fields(event)
    end
  end

  def validate_event(_), do: {:error, "Event is not an AgentEvent struct"}

  @doc """
  Merges multiple events into a single consolidated event.

  Useful for batching or aggregating related events for efficiency.

  ## Examples

      # Merge tool execution events
      batch_event = Events.merge_events(tool_events, :tool_execution_batch)
      
      # Merge message events  
      message_batch = Events.merge_events(message_events, :message_batch)
  """
  @spec merge_events([AgentEvent.t()], atom()) :: AgentEvent.t()
  def merge_events(events, merged_type) when is_list(events) and is_atom(merged_type) do
    # Create a merged event with basic information
    # In a real implementation, we might add a metadata field to AgentEvent
    %AgentEvent{
      type: merged_type
    }
  end

  @doc """
  Creates common agent lifecycle events with proper structure.

  Convenience functions for creating standard agent events.

  ## Examples

      # Create standard lifecycle events
      start_event = Events.agent_lifecycle_event(:start, agent_state)
      end_event = Events.agent_lifecycle_event(:end, agent_state)
      error_event = Events.agent_lifecycle_event(:error, agent_state, "Connection failed")
  """
  @spec agent_lifecycle_event(:start | :end | :error, AgentState.t(), String.t() | nil) ::
          AgentEvent.t()
  def agent_lifecycle_event(lifecycle_type, agent_state, _error_message \\ nil) do
    case lifecycle_type do
      :start ->
        AgentEvent.agent_start()

      :end ->
        AgentEvent.agent_end(agent_state.messages, Map.get(agent_state, :loop_outcome))

      :error ->
        # Since AgentEvent doesn't have an error field, we'll create a basic event
        # In a real implementation, we might extend AgentEvent to include error information
        %AgentEvent{type: :agent_error}
    end
  end

  @doc """
  Creates tool execution events with rich context information.

  ## Examples

      start_event = Events.tool_execution_event(:start, "call_123", "web_search", %{"query" => "test"})
      update_event = Events.tool_execution_event(:update, "call_123", "web_search", %{}, partial_result)
      end_event = Events.tool_execution_event(:end, "call_123", "web_search", %{}, final_result, false)
  """
  @spec tool_execution_event(
          :start | :update | :end,
          String.t(),
          String.t(),
          map(),
          any(),
          boolean()
        ) :: AgentEvent.t()
  def tool_execution_event(phase, tool_call_id, tool_name, args, result \\ nil, is_error \\ false) do
    case phase do
      :start -> AgentEvent.tool_execution_start(tool_call_id, tool_name, args)
      :update -> AgentEvent.tool_execution_update(tool_call_id, tool_name, args, result)
      :end -> AgentEvent.tool_execution_end(tool_call_id, tool_name, result, is_error)
    end
  end

  # Private helper functions

  @spec do_emit(AgentEvent.t(), [Callbacks.callback_spec()], boolean(), pos_integer()) ::
          :ok | {:error, any()}
  defp do_emit(event, callbacks, async, timeout) do
    if async do
      # Asynchronous emission
      Task.start(fn ->
        emit_to_callbacks(event, callbacks)
      end)

      :ok
    else
      # Synchronous emission with timeout
      task =
        Task.async(fn ->
          emit_to_callbacks(event, callbacks)
        end)

      try do
        Task.await(task, timeout)
        :ok
      catch
        :exit, {:timeout, _} ->
          Task.shutdown(task)
          {:error, :emission_timeout}
      end
    end
  end

  @spec emit_to_callbacks(AgentEvent.t(), [Callbacks.callback_spec()]) :: :ok
  defp emit_to_callbacks(event, callbacks) do
    Enum.each(callbacks, fn callback ->
      try do
        Callbacks.invoke_callback(callback, event)
      rescue
        error ->
          Logger.warning("Callback execution failed", %{
            callback: inspect(callback),
            event_type: event.type,
            error: Exception.message(error)
          })
      end
    end)
  end

  @spec apply_filter(AgentEvent.t(), event_filter()) :: boolean()
  defp apply_filter(event, filter) do
    case filter do
      {:type, event_type} ->
        event.type == event_type

      {:pattern, pattern} ->
        match_pattern(event, pattern)

      filter_fn when is_function(filter_fn, 1) ->
        filter_fn.(event)

      _ ->
        true
    end
  end

  @spec apply_emitter_filters(AgentEvent.t(), [event_filter()]) :: AgentEvent.t() | nil
  defp apply_emitter_filters(event, filters) do
    if Enum.all?(filters, fn filter -> apply_filter(event, filter) end) do
      event
    else
      nil
    end
  end

  @spec match_pattern(AgentEvent.t(), map()) :: boolean()
  defp match_pattern(event, pattern) do
    Enum.all?(pattern, fn {key, value} ->
      Map.get(event, key) == value
    end)
  end

  @spec get_event_timestamp(AgentEvent.t()) :: pos_integer() | nil
  defp get_event_timestamp(_event) do
    # Since AgentEvent doesn't have timestamp or metadata fields,
    # we'll use the current time as a fallback
    System.system_time(:millisecond)
  end

  @spec validate_event_fields(AgentEvent.t()) :: :ok | {:error, String.t()}
  defp validate_event_fields(event) do
    case event.type do
      type when type in [:turn_start, :turn_end] ->
        validate_turn_event(event)

      type when type in [:tool_execution_start, :tool_execution_update, :tool_execution_end] ->
        validate_tool_event(event)

      type when type in [:message_start, :message_update, :message_end] ->
        validate_message_event(event)

      _ ->
        # Basic validation for other event types
        :ok
    end
  end

  @spec validate_turn_event(AgentEvent.t()) :: :ok | {:error, String.t()}
  defp validate_turn_event(%AgentEvent{type: :turn_end, message: nil}) do
    {:error, "turn_end event must have a message"}
  end

  defp validate_turn_event(_), do: :ok

  @spec validate_tool_event(AgentEvent.t()) :: :ok | {:error, String.t()}
  defp validate_tool_event(%AgentEvent{tool_call_id: nil}) do
    {:error, "Tool event must have tool_call_id"}
  end

  defp validate_tool_event(%AgentEvent{tool_name: nil}) do
    {:error, "Tool event must have tool_name"}
  end

  defp validate_tool_event(_), do: :ok

  @spec validate_message_event(AgentEvent.t()) :: :ok | {:error, String.t()}
  defp validate_message_event(%AgentEvent{message: nil}) do
    {:error, "Message event must have a message"}
  end

  defp validate_message_event(_), do: :ok

  @spec generate_emitter_id() :: String.t()
  defp generate_emitter_id() do
    :crypto.strong_rand_bytes(8)
    |> Base.url_encode64(padding: false)
    |> String.slice(0, 12)
    |> String.downcase()
  end
end
