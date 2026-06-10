defmodule Expi.Agent.Turn do
  @moduledoc """
  Single turn execution logic for agent conversations.

  This module handles the execution of a single conversation turn, including
  streaming assistant responses, processing message content, extracting tool
  calls, and coordinating with the broader agent loop. Each turn represents
  one complete interaction cycle from user input to assistant response.

  ## Turn Lifecycle

  A single turn consists of several phases:
  1. **Context Preparation**: Convert agent messages to LLM format
  2. **Streaming Response**: Stream assistant response from AI model
  3. **Content Processing**: Process streaming content and updates
  4. **Tool Extraction**: Extract and queue tool calls for execution
  5. **State Updates**: Update agent state with new messages and status
  6. **Event Emission**: Emit appropriate events for monitoring

  ## Core Functions

  - **Turn Execution**: `execute_turn/2`, `process_turn_response/3`
  - **Streaming**: `handle_streaming_response/3`, `process_stream_events/3`
  - **Tool Processing**: `extract_and_queue_tools/2`, `process_tool_calls/3`
  - **State Management**: `update_turn_state/3`, `finalize_turn/2`
  - **Event Coordination**: `emit_turn_events/3`, `emit_message_events/3`

  ## Integration

  The turn module integrates with:
  - Expi.AI for streaming assistant responses
  - Message processing pipeline for format conversion
  - State management for conversation updates
  - Event system for real-time progress updates
  - Tool execution framework for tool call handling
  """

  alias Expi.Agent.Types.{AgentState, AgentEvent}
  alias Expi.Agent.{State, MessageProcessor}
  alias Expi.Types.{Context, AssistantMessage, ToolCall}
  alias Expi.AI

  require Logger

  @type turn_result :: {:ok, AgentState.t()} | {:error, any()}
  @type turn_context :: %{
          agent_state: AgentState.t(),
          llm_context: Context.t(),
          streaming_message: AssistantMessage.t() | nil,
          extracted_tools: [ToolCall.t()],
          turn_start_time: pos_integer()
        }
  @type stream_state :: %{
          partial_message: AssistantMessage.t(),
          content_buffer: String.t(),
          tool_calls_buffer: map(),
          thinking_buffer: String.t(),
          block_types: map()
        }

  @doc """
  Executes a complete conversation turn with streaming and tool processing.

  This is the main entry point for turn execution. It handles the complete
  flow from context preparation through streaming response to tool extraction
  and state updates.

  ## Parameters

  - `loop_state` - Current loop state containing agent state and configuration
  - `event_callback` - Optional callback for emitting events

  ## Examples

      # Basic turn execution
      {:ok, updated_state} = Turn.execute_turn(loop_state, nil)
      
      # With event monitoring
      {:ok, updated_state} = Turn.execute_turn(loop_state, fn event ->
        handle_turn_event(event)
      end)
      
      # Turn execution will:
      # 1. Prepare LLM context from agent messages
      # 2. Stream assistant response from AI model  
      # 3. Process streaming events and build response
      # 4. Extract tool calls and queue for execution
      # 5. Update agent state with new message and tools
      # 6. Emit appropriate lifecycle events
  """
  @spec execute_turn(map(), function() | nil) :: turn_result()
  def execute_turn(loop_state, event_callback \\ nil) do
    current_agent_state = loop_state.agent_state
    current_agent_options = loop_state.options

    Logger.debug("Executing turn", %{
      turn: Map.get(loop_state, :current_turn, 1)
    })

    # Initialize turn context
    turn_context = %{
      agent_state: current_agent_state,
      llm_context: nil,
      streaming_message: nil,
      extracted_tools: [],
      turn_start_time: System.system_time(:millisecond)
    }

    # Emit turn start event
    turn_start_event = AgentEvent.turn_start()
    emit_event_if_callback(turn_start_event, event_callback)

    case run_turn_pipeline(turn_context, current_agent_options, event_callback, 0) do
      {:ok, tools_context, final_state} ->
        Logger.debug("Turn completed", %{
          execution_time: System.system_time(:millisecond) - turn_context.turn_start_time,
          tool_calls_found: length(tools_context.extracted_tools),
          has_response: not is_nil(tools_context.streaming_message)
        })

        {:ok, final_state}

      {:error, reason} = error ->
        Logger.error("Turn execution failed", %{
          reason: inspect(reason)
        })

        error
    end
  end

  defp run_turn_pipeline(turn_context, agent_options, event_callback, retries) do
    with {:ok, llm_context} <- prepare_llm_context(turn_context.agent_state, agent_options),
         {:ok, streamed_context} <-
           stream_assistant_response(
             turn_context
             |> Map.put(:llm_context, llm_context)
             |> Map.put(:stream_fn, Map.get(agent_options, :stream_fn)),
             event_callback
           ),
         {:ok, tools_context} <- process_response_tools(streamed_context, event_callback),
         {:ok, final_state} <- finalize_turn_state(tools_context, event_callback) do
      {:ok, tools_context, final_state}
    else
      {:error, reason} = error ->
        if retries < 1 and transient_stream_error?(reason) do
          run_turn_pipeline(turn_context, agent_options, event_callback, retries + 1)
        else
          error
        end
    end
  end

  @doc """
  Processes assistant response with streaming support.

  Handles the complete streaming response from the AI model, building up
  the assistant message incrementally and processing tool calls as they
  are discovered.

  ## Examples

      {:ok, response} = Turn.process_streaming_response(
        model, 
        context, 
        event_callback
      )
  """
  @spec process_streaming_response(Expi.Types.Model.t(), Context.t(), function() | nil) ::
          {:ok, AssistantMessage.t()} | {:error, any()}
  def process_streaming_response(model, context, event_callback \\ nil) do
    process_streaming_response_with_fn(model, context, &AI.stream_simple/2, event_callback)
  end

  defp process_streaming_response_with_fn(model, context, stream_fn, event_callback)
       when is_function(stream_fn, 2) do
    case stream_fn.(model, context) do
      {:ok, stream} ->
        # Initialize streaming state
        stream_state = %{
          partial_message: create_initial_assistant_message(model),
          content_buffer: "",
          tool_calls_buffer: %{},
          thinking_buffer: "",
          block_types: %{}
        }

        # Process the stream
        final_state =
          stream
          |> Enum.reduce(stream_state, fn event, acc_state ->
            process_stream_event(event, acc_state, event_callback)
          end)

        {:ok, final_state.partial_message}

      {:error, reason} ->
        Logger.error("Failed to start streaming", %{reason: inspect(reason)})

        fallback_message = %AssistantMessage{
          role: :assistant,
          content: [%{type: :text, text: "[error] #{inspect(reason)}"}],
          api: model.api,
          provider: model.provider,
          model: model.id,
          stop_reason: :error,
          error_message: inspect(reason),
          timestamp: System.system_time(:millisecond)
        }

        {:ok, fallback_message}
    end
  end

  @doc """
  Extracts tool calls from assistant message content.

  Scans the assistant message for tool call content blocks and converts
  them to ToolCall structures for execution.

  ## Examples

      tool_calls = Turn.extract_tool_calls(assistant_message)
      
      Enum.each(tool_calls, fn tc ->
        IO.puts("Tool: " <> tc.name <> " with args: " <> inspect(tc.arguments))
      end)
  """
  @spec extract_tool_calls(AssistantMessage.t()) :: [ToolCall.t()]
  def extract_tool_calls(assistant_message) do
    assistant_message.content
    |> Enum.filter(fn block ->
      match?(%{type: :tool_call}, block)
    end)
    |> Enum.map(fn tool_call_block ->
      %ToolCall{
        id: Map.get(tool_call_block, :id, generate_tool_call_id()),
        name: Map.get(tool_call_block, :name, "unknown"),
        arguments: Map.get(tool_call_block, :arguments, %{})
      }
    end)
  end

  @doc """
  Validates turn execution prerequisites.

  Checks that all required components are properly configured before
  attempting to execute a turn.

  ## Examples

      case Turn.validate_turn_setup(agent_state, agent_options) do
        :ok -> execute_turn()
        {:error, reason} -> handle_setup_error(reason)
      end
  """
  @spec validate_turn_setup(AgentState.t(), map()) :: :ok | {:error, String.t()}
  def validate_turn_setup(agent_state, agent_options) do
    cond do
      is_nil(agent_state.model) ->
        {:error, "No model configured for turn execution"}

      State.is_streaming?(agent_state) ->
        {:error, "Cannot start turn while streaming is active"}

      State.has_error?(agent_state) ->
        {:error, "Cannot start turn while agent is in error state"}

      is_nil(agent_options) ->
        {:error, "No agent options provided"}

      true ->
        :ok
    end
  end

  @doc """
  Gets turn execution statistics and metrics.

  ## Examples

      stats = Turn.get_turn_stats(turn_context)
      IO.puts("Turn duration: " <> to_string(stats.execution_time) <> "ms")
      IO.puts("Content generated: " <> to_string(stats.content_length) <> " characters")
  """
  @spec get_turn_stats(turn_context()) :: map()
  def get_turn_stats(turn_context) do
    execution_time = System.system_time(:millisecond) - turn_context.turn_start_time

    content_length =
      if turn_context.streaming_message do
        turn_context.streaming_message.content
        |> Enum.filter(fn block -> match?(%{type: :text}, block) end)
        |> Enum.map(fn %{text: text} -> String.length(text) end)
        |> Enum.sum()
      else
        0
      end

    %{
      execution_time: execution_time,
      content_length: content_length,
      tool_calls_found: length(turn_context.extracted_tools),
      has_response: not is_nil(turn_context.streaming_message)
    }
  end

  # Private implementation functions

  @spec prepare_llm_context(AgentState.t(), struct()) :: {:ok, Context.t()} | {:error, any()}
  defp prepare_llm_context(agent_state, agent_options) do
    # Use message processor to convert agent context to LLM format
    transform_fn = agent_options.transform_context
    convert_fn = agent_options.convert_to_llm

    case MessageProcessor.process_pipeline(agent_state, transform_fn, convert_fn) do
      {:ok, llm_context} ->
        Logger.debug("LLM context prepared", %{
          message_count: length(llm_context.messages),
          has_tools: not is_nil(llm_context.tools)
        })

        {:ok, llm_context}

      {:error, reason} = error ->
        Logger.error("Failed to prepare LLM context", %{reason: inspect(reason)})
        error
    end
  end

  @spec stream_assistant_response(turn_context(), function() | nil) ::
          {:ok, turn_context()} | {:error, any()}
  defp stream_assistant_response(turn_context, event_callback) do
    model = turn_context.agent_state.model
    context = turn_context.llm_context
    stream_fn = Map.get(turn_context, :stream_fn) || Map.get(turn_context.agent_state, :stream_fn)

    case stream_with_optional_fn(model, context, stream_fn, event_callback) do
      {:ok, assistant_message} ->
        assistant_message =
          if assistant_message.content == [] do
            Logger.warning("Empty streamed assistant message; retrying stream once")

            case stream_with_optional_fn(model, context, stream_fn, event_callback) do
              {:ok, retry_message} -> retry_message
              {:error, _} -> assistant_message
            end
          else
            assistant_message
          end

        updated_context = %{turn_context | streaming_message: assistant_message}
        {:ok, updated_context}

      {:error, reason} = error ->
        Logger.error("Streaming response failed", %{reason: inspect(reason)})
        error
    end
  end

  @spec process_response_tools(turn_context(), function() | nil) ::
          {:ok, turn_context()} | {:error, any()}
  defp process_response_tools(turn_context, event_callback) do
    case turn_context.streaming_message do
      nil ->
        Logger.warning("No streaming message to process tools from")
        {:ok, turn_context}

      assistant_message ->
        # Extract tool calls from the response
        tool_calls = extract_tool_calls(assistant_message)

        if tool_calls != [] do
          Logger.debug("Extracted tool calls", %{count: Enum.count(tool_calls)})

          # Emit tool extraction events
          Enum.each(tool_calls, fn tool_call ->
            tool_event =
              AgentEvent.tool_execution_start(
                tool_call.id,
                tool_call.name,
                tool_call.arguments
              )

            emit_event_if_callback(tool_event, event_callback)
          end)
        end

        updated_context = %{turn_context | extracted_tools: tool_calls}
        {:ok, updated_context}
    end
  end

  @spec finalize_turn_state(turn_context(), function() | nil) ::
          {:ok, AgentState.t()} | {:error, any()}
  defp finalize_turn_state(turn_context, event_callback) do
    agent_state = turn_context.agent_state
    assistant_message = turn_context.streaming_message
    tool_calls = turn_context.extracted_tools

    if is_nil(assistant_message) or (assistant_message.content == [] and tool_calls == []) do
      Logger.warning(
        "Empty turn result after tool/user input; returning guarded empty turn result"
      )

      {:error, :empty_turn_result}
    else
      updated_state = State.add_message(agent_state, assistant_message)

      final_state =
        Enum.reduce(tool_calls, updated_state, fn tool_call, state ->
          State.add_pending_tool_call(state, tool_call.id)
        end)

      message_start_event = %AgentEvent{type: :message_start, message: assistant_message}
      emit_event_if_callback(message_start_event, event_callback)

      message_end_event = %AgentEvent{type: :message_end, message: assistant_message}
      emit_event_if_callback(message_end_event, event_callback)

      {:ok, final_state}
    end
  end

  @spec process_stream_event(map(), stream_state(), function() | nil) :: stream_state()
  defp process_stream_event(%{type: :start} = event, stream_state, _event_callback),
    do: handle_stream_start(event, stream_state)

  defp process_stream_event(%{type: :text_start} = event, stream_state, _event_callback),
    do: handle_text_start(event, stream_state)

  defp process_stream_event(%{type: :text_delta} = event, stream_state, event_callback),
    do: handle_text_delta(event, stream_state, event_callback)

  defp process_stream_event(%{type: :text_end} = event, stream_state, _event_callback),
    do: handle_text_end(event, stream_state)

  defp process_stream_event(%{type: :thinking_start} = event, stream_state, _event_callback),
    do: handle_thinking_start(event, stream_state)

  defp process_stream_event(%{type: :thinking_delta} = event, stream_state, _event_callback),
    do: handle_thinking_delta(event, stream_state)

  defp process_stream_event(%{type: :thinking_end}, stream_state, _event_callback),
    do: stream_state

  defp process_stream_event(%{type: :toolcall_start} = event, stream_state, _event_callback),
    do: handle_toolcall_start(event, stream_state)

  defp process_stream_event(%{type: :toolcall_delta} = event, stream_state, _event_callback),
    do: handle_toolcall_delta(event, stream_state)

  defp process_stream_event(%{type: :toolcall_end} = event, stream_state, _event_callback),
    do: handle_toolcall_end(event, stream_state)

  defp process_stream_event(%{type: :done} = event, stream_state, _event_callback),
    do: handle_stream_done(event, stream_state)

  defp process_stream_event(%{type: :error}, stream_state, _event_callback),
    do: handle_stream_error(stream_state)

  defp process_stream_event(event, stream_state, _event_callback) do
    Logger.debug("Unknown stream event type", %{type: event.type})
    stream_state
  end

  defp handle_stream_start(event, stream_state) do
    source_message = event.partial || event.message
    partial = stream_state.partial_message

    updated_message = %{
      partial
      | api: if(is_map(source_message), do: source_message.api, else: partial.api),
        provider: if(is_map(source_message), do: source_message.provider, else: partial.provider),
        model: if(is_map(source_message), do: source_message.model, else: partial.model),
        timestamp: System.system_time(:millisecond)
    }

    %{stream_state | partial_message: updated_message}
  end

  defp handle_text_start(event, stream_state) do
    index = event.content_index || 0
    %{stream_state | block_types: Map.put(stream_state.block_types, index, :text)}
  end

  defp handle_text_delta(event, stream_state, event_callback) do
    updated_buffer = stream_state.content_buffer <> event.delta
    text_content = %{type: :text, text: updated_buffer}

    updated_content =
      [
        text_content
        | Enum.reject(stream_state.partial_message.content, &match?(%{type: :text}, &1))
      ]

    updated_message = %{stream_state.partial_message | content: updated_content}
    emit_message_update(updated_message, event, event_callback)

    %{stream_state | content_buffer: updated_buffer, partial_message: updated_message}
  end

  defp emit_message_update(_updated_message, _event, nil), do: :ok

  defp emit_message_update(updated_message, event, event_callback) do
    update_event = %AgentEvent{
      type: :message_update,
      message: updated_message,
      assistant_message_event: event
    }

    emit_event_if_callback(update_event, event_callback)
  end

  defp handle_text_end(event, stream_state) do
    index = event.content_index || 0

    updated_state =
      case Map.get(stream_state.block_types, index, :text) do
        :toolcall ->
          case finalize_tool_call_from_buffer(stream_state, index) do
            {:ok, resolved} -> resolved
            :not_found -> stream_state
          end

        _ ->
          stream_state
      end

    %{updated_state | block_types: Map.delete(updated_state.block_types, index)}
  end

  defp handle_thinking_start(event, stream_state) do
    index = event.content_index || 0
    %{stream_state | block_types: Map.put(stream_state.block_types, index, :thinking)}
  end

  defp handle_thinking_delta(event, stream_state) do
    updated_thinking = stream_state.thinking_buffer <> event.delta
    thinking_content = %{type: :thinking, thinking: updated_thinking}

    updated_content =
      [
        thinking_content
        | Enum.reject(stream_state.partial_message.content, &match?(%{type: :thinking}, &1))
      ]

    updated_message = %{stream_state.partial_message | content: updated_content}
    %{stream_state | thinking_buffer: updated_thinking, partial_message: updated_message}
  end

  defp handle_toolcall_start(event, stream_state) do
    index = event.content_index || 0
    tool_data = build_tool_data(event.tool_call)

    %{
      stream_state
      | tool_calls_buffer: Map.put(stream_state.tool_calls_buffer, index, tool_data),
        block_types: Map.put(stream_state.block_types, index, :toolcall)
    }
  end

  defp build_tool_data(tool_call) when is_map(tool_call) do
    %{
      id: Map.get(tool_call, :id) || Map.get(tool_call, "id") || generate_tool_call_id(),
      name: Map.get(tool_call, :name) || Map.get(tool_call, "name") || "unknown",
      arguments: Map.get(tool_call, :arguments) || Map.get(tool_call, "arguments") || %{},
      partial_json: ""
    }
  end

  defp build_tool_data(_),
    do: %{id: generate_tool_call_id(), name: "unknown", arguments: %{}, partial_json: ""}

  defp handle_toolcall_delta(event, stream_state) do
    index = event.content_index || 0
    existing = Map.get(stream_state.tool_calls_buffer, index, build_tool_data(nil))
    delta = if is_binary(event.delta), do: event.delta, else: ""
    updated = %{existing | partial_json: existing.partial_json <> delta}

    %{stream_state | tool_calls_buffer: Map.put(stream_state.tool_calls_buffer, index, updated)}
  end

  defp handle_toolcall_end(event, stream_state) do
    if is_map(event.tool_call) do
      add_tool_call_content(stream_state, event.tool_call)
    else
      case finalize_tool_call_from_buffer(stream_state, event.content_index) do
        {:ok, updated_state} ->
          updated_state

        :not_found ->
          Logger.warning("toolcall_end event missing tool_call payload")
          stream_state
      end
    end
  end

  defp handle_stream_done(event, stream_state) do
    final_message = %{
      stream_state.partial_message
      | usage:
          if(is_map(event.message),
            do: event.message.usage,
            else: stream_state.partial_message.usage
          ),
        stop_reason: event.reason,
        timestamp: System.system_time(:millisecond)
    }

    %{stream_state | partial_message: final_message}
  end

  defp handle_stream_error(stream_state) do
    error_message = %{
      stream_state.partial_message
      | stop_reason: :error,
        error_message: "Streaming error",
        timestamp: System.system_time(:millisecond)
    }

    %{stream_state | partial_message: error_message}
  end

  defp finalize_tool_call_from_buffer(stream_state, index) when is_integer(index) do
    case Map.pop(stream_state.tool_calls_buffer, index) do
      {nil, _remaining} ->
        :not_found

      {tool_data, remaining} ->
        arguments =
          if is_binary(tool_data.partial_json) and tool_data.partial_json != "" do
            case Jason.decode(tool_data.partial_json) do
              {:ok, parsed} when is_map(parsed) -> parsed
              _ -> tool_data.arguments || %{}
            end
          else
            tool_data.arguments || %{}
          end

        tool_call = %{
          id: tool_data.id,
          name: tool_data.name,
          arguments: arguments
        }

        updated_state =
          stream_state
          |> Map.put(:tool_calls_buffer, remaining)
          |> add_tool_call_content(tool_call)

        {:ok, updated_state}
    end
  end

  defp finalize_tool_call_from_buffer(_stream_state, _index), do: :not_found

  defp add_tool_call_content(stream_state, tool_call) do
    tool_call_content = %{
      type: :tool_call,
      id: Map.get(tool_call, :id) || Map.get(tool_call, "id") || generate_tool_call_id(),
      name: Map.get(tool_call, :name) || Map.get(tool_call, "name") || "unknown",
      arguments: Map.get(tool_call, :arguments) || Map.get(tool_call, "arguments") || %{}
    }

    updated_content = [tool_call_content | stream_state.partial_message.content]
    updated_message = %{stream_state.partial_message | content: updated_content}

    %{stream_state | partial_message: updated_message}
  end

  @spec create_initial_assistant_message(Expi.Types.Model.t()) :: AssistantMessage.t()
  defp create_initial_assistant_message(model) do
    %AssistantMessage{
      role: :assistant,
      content: [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: nil,
      stop_reason: nil,
      error_message: nil,
      timestamp: System.system_time(:millisecond)
    }
  end

  @spec generate_tool_call_id() :: String.t()
  defp generate_tool_call_id do
    "call_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp stream_with_optional_fn(model, context, nil, event_callback) do
    process_streaming_response(model, context, event_callback)
  end

  defp stream_with_optional_fn(model, context, stream_fn, event_callback)
       when is_function(stream_fn, 2) do
    process_streaming_response_with_fn(model, context, stream_fn, event_callback)
  end

  defp stream_with_optional_fn(model, context, _stream_fn, event_callback) do
    process_streaming_response(model, context, event_callback)
  end

  defp transient_stream_error?(reason) do
    reason in [:timeout, :rate_limited, :connection_error, :temporary_failure]
  end

  @spec emit_event_if_callback(AgentEvent.t(), function() | nil) :: :ok
  defp emit_event_if_callback(_event, nil), do: :ok

  defp emit_event_if_callback(event, callback) when is_function(callback) do
    try do
      callback.(event)
    rescue
      error ->
        Logger.warning("Turn event callback failed", %{
          event_type: event.type,
          error: Exception.message(error)
        })
    end

    :ok
  end
end
