defmodule Expi.Agent.State do
  @moduledoc """
  Pure functional agent state management.

  This module provides functions for creating, updating, and querying agent state
  in a purely functional manner. All operations return new state instances rather
  than modifying existing state, following Elixir's immutability principles.

  ## Core Operations

  - **Creation**: `new/1`, `from_options/2`
  - **Updates**: `add_message/2`, `set_streaming/3`, `update_tools/2`
  - **Queries**: `get_messages/1`, `is_idle?/1`, `has_pending_tools?/1`
  - **Utilities**: `reset/1`, `merge_state/2`

  All functions are designed to be composable and work well with pipelines.
  """

  alias Expi.Agent.Types.{AgentState, AgentOptions, AgentTool}
  alias Expi.Agent.Message
  alias Expi.Types.Model

  @type state_update :: (AgentState.t() -> AgentState.t())
  @type validation_error :: {:error, :invalid_state | :invalid_message | :invalid_tool | atom()}

  @doc """
  Creates a new agent state with required model and optional overrides.

  ## Parameters

  - `model` - Required AI model configuration from Expi.AI.get_model/2
  - `overrides` - Optional map of state field overrides

  ## Examples

      # Basic agent state
      {:ok, model} = Expi.AI.get_model("anthropic", "claude-sonnet-3-6")
      state = AgentState.new(model)
      
      # With custom system prompt and tools
      state = AgentState.new(model, %{
        system_prompt: "You are a helpful coding assistant",
        thinking_level: :medium,
        tools: [search_tool, file_tool]
      })
      
      # With initial message history
      messages = [Message.user("Hello, can you help me with Elixir?")]
      state = AgentState.new(model, %{messages: messages})

  ## Returns

  Returns a properly initialized AgentState struct with:
  - The provided model configuration
  - Default empty message history
  - No active streaming or pending operations  
  - Thinking level set to :off by default
  - Any provided overrides applied
  """
  @spec new(Model.t(), map()) :: AgentState.t()
  def new(model, overrides \\ %{}) do
    default_state = %AgentState{
      system_prompt: "",
      model: model,
      thinking_level: :off,
      tools: [],
      messages: [],
      is_streaming: false,
      stream_message: nil,
      pending_tool_calls: MapSet.new(),
      error: nil,
      created_at: System.system_time(:millisecond),
      max_context_length: nil,
      temperature: nil,
      streaming: true
    }

    struct(default_state, overrides)
  end

  @doc """
  Creates agent state from AgentOptions and model.

  Extracts initial state overrides from AgentOptions and applies them
  to create a properly configured agent state.

  ## Examples

      options = %AgentOptions{
        initial_state: %{
          system_prompt: "You are an expert mathematician",
          thinking_level: :high
        }
      }
      
      {:ok, model} = Expi.AI.get_model("anthropic", "claude-opus-4-5")
      state = AgentState.from_options(model, options)
  """
  @spec from_options(Model.t(), AgentOptions.t()) :: AgentState.t()
  def from_options(model, %AgentOptions{initial_state: nil}) do
    new(model)
  end

  def from_options(model, %AgentOptions{initial_state: overrides}) when is_map(overrides) do
    new(model, overrides)
  end

  def from_options(model, _options) do
    new(model)
  end

  @doc """
  Resets agent state to initial condition while preserving model and tools.

  Clears message history, streaming status, and error state while keeping
  the core configuration intact.

  ## Examples

      # Clear conversation history but keep configuration
      clean_state = AgentState.reset(state)
      
      # Agent is ready for a new conversation
      assert clean_state.messages == []
      assert clean_state.is_streaming == false
      assert clean_state.error == nil
  """
  @spec reset(AgentState.t()) :: AgentState.t()
  def reset(%AgentState{} = state) do
    %AgentState{
      state
      | messages: [],
        is_streaming: false,
        stream_message: nil,
        pending_tool_calls: MapSet.new(),
        error: nil
    }
  end

  @doc """
  Validates that an agent state is properly formed.

  Checks all required fields and validates internal consistency.

  ## Examples

      case AgentState.validate(state) do
        :ok -> proceed_with_agent(state)
        {:error, reason} -> handle_invalid_state(reason)
      end
  """
  @spec validate(AgentState.t()) :: :ok | validation_error()
  def validate(%AgentState{} = state) do
    with :ok <- validate_model(state.model),
         :ok <- validate_messages(state.messages),
         :ok <- validate_tools(state.tools),
         :ok <- validate_thinking_level(state.thinking_level) do
      :ok
    else
      error -> error
    end
  end

  def validate(_), do: {:error, :invalid_state}

  # Message Management

  @doc """
  Adds a message to the agent's conversation history.

  Messages are appended in chronological order. The function validates
  the message before adding it to ensure data integrity.

  ## Examples

      # Add user message
      user_msg = Message.user("What's the weather like?")
      updated_state = AgentState.add_message(state, user_msg)
      
      # Add assistant response (typically done by the agent loop)
      assistant_msg = %AssistantMessage{...}
      updated_state = AgentState.add_message(state, assistant_msg)
      
      # Chain multiple updates
      state
      |> AgentState.add_message(user_msg)
      |> AgentState.add_message(assistant_msg)
  """
  @spec add_message(AgentState.t(), Message.t()) :: AgentState.t()
  def add_message(%AgentState{} = state, message) do
    if Message.valid?(message) do
      %AgentState{state | messages: state.messages ++ [message]}
    else
      # Log warning but don't crash - graceful degradation
      # In a real app, you might want to emit a warning event
      state
    end
  end

  @doc """
  Adds multiple messages to the conversation history.

  ## Examples

      messages = [user_msg1, assistant_msg1, user_msg2]
      updated_state = AgentState.add_messages(state, messages)
  """
  @spec add_messages(AgentState.t(), [Message.t()]) :: AgentState.t()
  def add_messages(%AgentState{} = state, messages) when is_list(messages) do
    Enum.reduce(messages, state, &add_message(&2, &1))
  end

  @doc """
  Replaces the entire message history.

  Useful for loading conversations from storage or applying transformations.

  ## Examples

      # Load conversation from storage
      stored_messages = load_messages_from_db(conversation_id)
      state = AgentState.set_messages(state, stored_messages)
      
      # Clear all messages
      state = AgentState.set_messages(state, [])
  """
  @spec set_messages(AgentState.t(), [Message.t()]) :: AgentState.t()
  def set_messages(%AgentState{} = state, messages) when is_list(messages) do
    %AgentState{state | messages: messages}
  end

  @doc """
  Gets the current message history.

  ## Examples

      messages = AgentState.get_messages(state)
      message_count = length(messages)
  """
  @spec get_messages(AgentState.t()) :: [Message.t()]
  def get_messages(%AgentState{messages: messages}), do: messages

  @doc """
  Gets the last N messages from the conversation.

  ## Examples

      # Get last 5 messages for context
      recent_messages = AgentState.get_recent_messages(state, 5)
      
      # Get just the last message
      [last_message] = AgentState.get_recent_messages(state, 1)
  """
  @spec get_recent_messages(AgentState.t(), pos_integer()) :: [Message.t()]
  def get_recent_messages(%AgentState{messages: messages}, count) when count > 0 do
    messages |> Enum.take(-count)
  end

  # Streaming State Management

  @doc """
  Sets the streaming status and optionally the current streaming message.

  ## Examples

      # Start streaming
      state = AgentState.set_streaming(state, true, partial_message)
      
      # Stop streaming
      state = AgentState.set_streaming(state, false)
      
      # Update streaming message
      state = AgentState.set_streaming(state, true, updated_message)
  """
  @spec set_streaming(AgentState.t(), boolean(), Message.t() | nil) :: AgentState.t()
  def set_streaming(%AgentState{} = state, is_streaming, stream_message \\ nil) do
    %AgentState{state | is_streaming: is_streaming, stream_message: stream_message}
  end

  @doc """
  Gets the current streaming status.

  ## Examples

      if AgentState.is_streaming?(state) do
        show_streaming_indicator()
      end
  """
  @spec is_streaming?(AgentState.t()) :: boolean()
  def is_streaming?(%AgentState{is_streaming: streaming}), do: streaming

  @doc """
  Gets the current streaming message if any.

  ## Examples

      case AgentState.get_stream_message(state) do
        nil -> :no_streaming
        message -> display_partial_message(message)
      end
  """
  @spec get_stream_message(AgentState.t()) :: Message.t() | nil
  def get_stream_message(%AgentState{stream_message: message}), do: message

  # Tool Management

  @doc """
  Updates the available tools for the agent.

  Replaces the entire tool list with validation.

  ## Examples

      new_tools = [search_tool, calculator_tool, file_tool]
      updated_state = AgentState.update_tools(state, new_tools)
      
      # Remove all tools
      updated_state = AgentState.update_tools(state, [])
  """
  @spec update_tools(AgentState.t(), [AgentTool.t()]) :: AgentState.t()
  def update_tools(%AgentState{} = state, tools) when is_list(tools) do
    %AgentState{state | tools: tools}
  end

  @doc """
  Adds a single tool to the agent's toolkit.

  ## Examples

      new_tool = create_weather_tool()
      updated_state = AgentState.add_tool(state, new_tool)
  """
  @spec add_tool(AgentState.t(), AgentTool.t()) :: AgentState.t()
  def add_tool(%AgentState{tools: tools} = state, tool) do
    %AgentState{state | tools: tools ++ [tool]}
  end

  @doc """
  Removes a tool by name from the agent's toolkit.

  ## Examples

      # Remove the web search tool
      updated_state = AgentState.remove_tool(state, "web_search")
  """
  @spec remove_tool(AgentState.t(), String.t()) :: AgentState.t()
  def remove_tool(%AgentState{tools: tools} = state, tool_name) do
    updated_tools =
      Enum.reject(tools, fn tool ->
        AgentTool.name(tool) == tool_name
      end)

    %AgentState{state | tools: updated_tools}
  end

  @doc """
  Gets the current tools available to the agent.

  ## Examples

      tools = AgentState.get_tools(state)
      tool_names = Enum.map(tools, &AgentTool.name/1)
  """
  @spec get_tools(AgentState.t()) :: [AgentTool.t()]
  def get_tools(%AgentState{tools: tools}), do: tools

  @doc """
  Finds a tool by name in the agent's toolkit.

  ## Examples

      case AgentState.find_tool(state, "web_search") do
        {:ok, tool} -> use_tool(tool)
        {:error, :not_found} -> handle_missing_tool()
      end
  """
  @spec find_tool(AgentState.t(), String.t()) :: {:ok, AgentTool.t()} | {:error, :not_found}
  def find_tool(%AgentState{tools: tools}, tool_name) do
    case Enum.find(tools, fn tool -> AgentTool.name(tool) == tool_name end) do
      nil -> {:error, :not_found}
      tool -> {:ok, tool}
    end
  end

  # Tool Call Management

  @doc """
  Adds a pending tool call to track active executions.

  ## Examples

      # Track that we're executing a tool call
      updated_state = AgentState.add_pending_tool_call(state, "call_123")
  """
  @spec add_pending_tool_call(AgentState.t(), String.t()) :: AgentState.t()
  def add_pending_tool_call(%AgentState{pending_tool_calls: pending} = state, tool_call_id) do
    %AgentState{state | pending_tool_calls: MapSet.put(pending, tool_call_id)}
  end

  @doc """
  Removes a pending tool call when execution completes.

  ## Examples

      # Mark tool call as completed
      updated_state = AgentState.remove_pending_tool_call(state, "call_123")
  """
  @spec remove_pending_tool_call(AgentState.t(), String.t()) :: AgentState.t()
  def remove_pending_tool_call(%AgentState{pending_tool_calls: pending} = state, tool_call_id) do
    %AgentState{state | pending_tool_calls: MapSet.delete(pending, tool_call_id)}
  end

  @doc """
  Checks if there are any pending tool calls.

  ## Examples

      if AgentState.has_pending_tools?(state) do
        wait_for_tools_to_complete()
      end
  """
  @spec has_pending_tools?(AgentState.t()) :: boolean()
  def has_pending_tools?(%AgentState{pending_tool_calls: pending}) do
    MapSet.size(pending) > 0
  end

  @doc """
  Gets the set of pending tool call IDs.

  ## Examples

      pending_calls = AgentState.get_pending_tool_calls(state)
      pending_count = MapSet.size(pending_calls)
  """
  @spec get_pending_tool_calls(AgentState.t()) :: MapSet.t(String.t())
  def get_pending_tool_calls(%AgentState{pending_tool_calls: pending}), do: pending

  # Configuration Management

  @doc """
  Updates the system prompt for the agent.

  ## Examples

      new_prompt = "You are an expert in functional programming"
      updated_state = AgentState.set_system_prompt(state, new_prompt)
  """
  @spec set_system_prompt(AgentState.t(), String.t()) :: AgentState.t()
  def set_system_prompt(%AgentState{} = state, prompt) when is_binary(prompt) do
    %AgentState{state | system_prompt: prompt}
  end

  @doc """
  Updates the thinking level for the agent.

  ## Examples

      # Enable high reasoning for complex problems
      updated_state = AgentState.set_thinking_level(state, :high)
      
      # Disable thinking for speed
      updated_state = AgentState.set_thinking_level(state, :off)
  """
  @spec set_thinking_level(AgentState.t(), Expi.Agent.Types.thinking_level()) :: AgentState.t()
  def set_thinking_level(%AgentState{} = state, level) do
    if level in Expi.Agent.Types.thinking_levels() do
      %AgentState{state | thinking_level: level}
    else
      # Invalid level, keep current
      state
    end
  end

  @doc """
  Sets or clears an error state.

  ## Examples

      # Set error
      error_state = AgentState.set_error(state, "Network connection failed")
      
      # Clear error
      clean_state = AgentState.set_error(state, nil)
  """
  @spec set_error(AgentState.t(), String.t() | nil) :: AgentState.t()
  def set_error(%AgentState{} = state, error_message) do
    %AgentState{state | error: error_message}
  end

  # Query Functions

  @doc """
  Checks if the agent is currently idle (not streaming, no pending operations).

  ## Examples

      if AgentState.is_idle?(state) do
        accept_new_message()
      else
        queue_message_for_later()
      end
  """
  @spec is_idle?(AgentState.t()) :: boolean()
  def is_idle?(%AgentState{} = state) do
    not state.is_streaming and MapSet.size(state.pending_tool_calls) == 0
  end

  @doc """
  Checks if the agent is in an error state.

  ## Examples

      if AgentState.has_error?(state) do
        display_error(state.error)
      end
  """
  @spec has_error?(AgentState.t()) :: boolean()
  def has_error?(%AgentState{error: nil}), do: false
  def has_error?(%AgentState{error: error}) when is_binary(error), do: true

  @doc """
  Gets the current error message if any.

  ## Examples

      case AgentState.get_error(state) do
        nil -> :no_error
        error -> log_error(error)
      end
  """
  @spec get_error(AgentState.t()) :: String.t() | nil
  def get_error(%AgentState{error: error}), do: error

  @doc """
  Counts the total number of messages in the conversation.

  ## Examples

      message_count = AgentState.message_count(state)
      
      if message_count > 100 do
        suggest_conversation_pruning()
      end
  """
  @spec message_count(AgentState.t()) :: non_neg_integer()
  def message_count(%AgentState{messages: messages}), do: length(messages)

  @doc """
  Merges updates from another state while preserving core identity.

  Useful for applying updates while maintaining model and tool configuration.

  ## Examples

      # Apply updates from agent loop
      updated_state = AgentState.merge_state(original_state, loop_state)
  """
  @spec merge_state(AgentState.t(), AgentState.t()) :: AgentState.t()
  def merge_state(%AgentState{} = base, %AgentState{} = updates) do
    %AgentState{
      base
      | messages: updates.messages,
        is_streaming: updates.is_streaming,
        stream_message: updates.stream_message,
        pending_tool_calls: updates.pending_tool_calls,
        error: updates.error
    }
  end

  # Private validation helpers

  @spec validate_model(Model.t() | nil) :: :ok | validation_error()
  defp validate_model(%Model{}), do: :ok
  defp validate_model(_), do: {:error, :invalid_model}

  @spec validate_messages([Message.t()]) :: :ok | validation_error()
  defp validate_messages(messages) when is_list(messages) do
    case Message.validate_all(messages) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_message}
    end
  end

  defp validate_messages(_), do: {:error, :invalid_messages}

  @spec validate_tools([AgentTool.t()]) :: :ok | validation_error()
  defp validate_tools(tools) when is_list(tools) do
    case Expi.Agent.Tool.validate_all(tools) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_tool}
    end
  end

  defp validate_tools(_), do: {:error, :invalid_tools}

  @spec validate_thinking_level(atom()) :: :ok | validation_error()
  defp validate_thinking_level(level) do
    if Expi.Agent.Types.valid_thinking_level?(level) do
      :ok
    else
      {:error, :invalid_thinking_level}
    end
  end
end
