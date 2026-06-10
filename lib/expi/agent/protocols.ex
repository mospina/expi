defmodule Expi.Agent.Protocols do
  @moduledoc """
  Protocol definitions for the Expi Agent module.

  This module defines protocols that enable extensible message types
  and other agent behaviors while maintaining type safety and
  consistent behavior across different message implementations.
  """

  # Protocol for agent messages, enabling extensible message types.
  #
  # The AgentMessage protocol allows applications to define custom
  # message types while ensuring they can be properly converted to
  # LLM-compatible messages and handled by the agent system.
  defprotocol AgentMessage do
    @doc """
    Converts an agent message to an LLM-compatible message.

    Returns the equivalent Expi.Types message that should be sent
    to the LLM, or nil if this message type should not be sent
    to the LLM (e.g., UI-only notifications).

    ## Examples

        # User message converts directly
        iex> user_msg = %Expi.Types.UserMessage{content: "Hello"}
        iex> AgentMessage.to_llm_message(user_msg)
        %Expi.Types.UserMessage{content: "Hello"}

        # Notification message is filtered out
        iex> notification = %MyApp.NotificationMessage{content: "File saved"}
        iex> AgentMessage.to_llm_message(notification)
        nil
    """
    @spec to_llm_message(t()) :: Expi.Types.message() | nil
    def to_llm_message(message)

    @doc """
    Returns the message type identifier.

    Used for categorization, filtering, and UI rendering decisions.
    Standard types: :user, :assistant, :tool_result
    Custom types: :notification, :artifact, :status, etc.
    """
    @spec message_type(t()) :: atom()
    def message_type(message)

    @doc """
    Returns the message timestamp.

    Used for chronological ordering and conversation history.
    Should return milliseconds since epoch.
    """
    @spec timestamp(t()) :: pos_integer()
    def timestamp(message)

    @doc """
    Extracts the main content from the message.

    Returns the primary textual content for display and processing.
    For complex content types, should return a readable summary.
    """
    @spec content(t()) :: String.t() | [map()] | any()
    def content(message)

    @doc """
    Validates if the message structure is valid.

    Checks that required fields are present and properly formatted.
    Used to ensure data integrity throughout the agent system.
    """
    @spec valid?(t()) :: boolean()
    def valid?(message)
  end

  # Implementation for UserMessage
  defimpl AgentMessage, for: Expi.Types.UserMessage do
    def to_llm_message(message), do: message
    def message_type(_), do: :user
    def timestamp(message), do: message.timestamp
    def content(message), do: message.content

    def valid?(message) do
      is_atom(message.role) and
        message.role == :user and
        is_integer(message.timestamp) and
        message.timestamp > 0 and
        (is_binary(message.content) or is_list(message.content))
    end
  end

  # Implementation for AssistantMessage
  defimpl AgentMessage, for: Expi.Types.AssistantMessage do
    def to_llm_message(message), do: message
    def message_type(_), do: :assistant
    def timestamp(message), do: message.timestamp

    def content(message) do
      # Extract text content from content blocks
      message.content
      |> Enum.filter(fn block ->
        match?(%{type: :text}, block)
      end)
      |> Enum.map(fn %{text: text} -> text end)
      |> Enum.join(" ")
    end

    def valid?(message) do
      is_atom(message.role) and
        message.role == :assistant and
        is_list(message.content) and
        is_integer(message.timestamp) and
        message.timestamp > 0
    end
  end

  # Implementation for ToolResultMessage
  defimpl AgentMessage, for: Expi.Types.ToolResultMessage do
    def to_llm_message(message), do: message
    def message_type(_), do: :tool_result
    def timestamp(message), do: message.timestamp

    def content(message) do
      # Extract text from content blocks
      message.content
      |> Enum.filter(fn block ->
        match?(%{type: :text}, block)
      end)
      |> Enum.map(fn %{text: text} -> text end)
      |> Enum.join(" ")
    end

    def valid?(message) do
      is_atom(message.role) and
        message.role == :tool_result and
        is_binary(message.tool_call_id) and
        is_binary(message.tool_name) and
        is_list(message.content) and
        is_boolean(message.is_error) and
        is_integer(message.timestamp) and
        message.timestamp > 0
    end
  end

  # Protocol for agent tool callbacks.
  # Enables different callback implementations for tool execution
  # updates, allowing flexibility in how partial results are handled
  # during long-running tool operations.
  defprotocol AgentToolCallback do
    @doc """
    Called when a tool produces a partial result during execution.

    This allows tools to provide incremental updates during long-running
    operations, enabling real-time progress display in UIs.

    ## Parameters

    - `callback` - The callback implementation
    - `tool_call_id` - Unique identifier for this tool call
    - `partial_result` - Partial result data from the tool

    ## Returns

    - `:ok` - Update processed successfully
    - `{:error, reason}` - Update processing failed
    """
    @spec on_update(t(), String.t(), Expi.Agent.Types.AgentToolResult.t()) ::
            :ok | {:error, any()}
    def on_update(callback, tool_call_id, partial_result)

    @doc """
    Called when a tool execution completes (success or error).

    Provides final cleanup and result processing for tool executions.

    ## Parameters

    - `callback` - The callback implementation
    - `tool_call_id` - Unique identifier for this tool call
    - `final_result` - Final result or error from the tool
    - `is_error` - Whether the execution resulted in an error
    """
    @spec on_complete(t(), String.t(), any(), boolean()) :: :ok
    def on_complete(callback, tool_call_id, final_result, is_error)
  end

  defmodule ProcessCallback do
    @moduledoc """
    Simple callback implementation that sends messages to a process.

    Useful for GenServer-based architectures where tool updates
    need to be sent as messages to a controlling process.
    """

    @type t :: %__MODULE__{
            pid: pid(),
            message_format: :simple | :detailed
          }

    defstruct pid: nil, message_format: :simple

    @doc """
    Creates a new process callback.
    """
    @spec new(pid(), :simple | :detailed) :: t()
    def new(pid, format \\ :simple) do
      %__MODULE__{pid: pid, message_format: format}
    end
  end

  defimpl AgentToolCallback, for: ProcessCallback do
    def on_update(callback, tool_call_id, partial_result) do
      message =
        case callback.message_format do
          :simple ->
            {:tool_update, tool_call_id, partial_result}

          :detailed ->
            {:tool_update,
             %{
               tool_call_id: tool_call_id,
               partial_result: partial_result,
               timestamp: System.system_time(:millisecond)
             }}
        end

      send(callback.pid, message)
      :ok
    end

    def on_complete(callback, tool_call_id, final_result, is_error) do
      message =
        case callback.message_format do
          :simple ->
            {:tool_complete, tool_call_id, final_result, is_error}

          :detailed ->
            {:tool_complete,
             %{
               tool_call_id: tool_call_id,
               final_result: final_result,
               is_error: is_error,
               timestamp: System.system_time(:millisecond)
             }}
        end

      send(callback.pid, message)
      :ok
    end
  end

  defmodule FunctionCallback do
    @moduledoc """
    Function-based callback implementation.

    Allows simple function-based callbacks for tool updates,
    useful for lightweight integrations and testing.
    """

    @type update_fn :: (String.t(), Expi.Agent.Types.AgentToolResult.t() ->
                          :ok | {:error, any()})
    @type complete_fn :: (String.t(), any(), boolean() -> :ok)

    @type t :: %__MODULE__{
            on_update: update_fn() | nil,
            on_complete: complete_fn() | nil
          }

    defstruct on_update: nil, on_complete: nil

    @doc """
    Creates a new function callback.
    """
    @spec new(update_fn() | nil, complete_fn() | nil) :: t()
    def new(update_fn \\ nil, complete_fn \\ nil) do
      %__MODULE__{on_update: update_fn, on_complete: complete_fn}
    end
  end

  defimpl AgentToolCallback, for: FunctionCallback do
    def on_update(callback, tool_call_id, partial_result) do
      if callback.on_update do
        callback.on_update.(tool_call_id, partial_result)
      else
        :ok
      end
    end

    def on_complete(callback, tool_call_id, final_result, is_error) do
      if callback.on_complete do
        callback.on_complete.(tool_call_id, final_result, is_error)
      end

      :ok
    end
  end
end
