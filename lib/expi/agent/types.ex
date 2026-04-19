defmodule Expi.Agent.Types do
  @moduledoc """
  Core type definitions for the Expi Agent module.

  This module defines all the structs and types used throughout the Agent module,
  following the architecture specifications and extending the existing Expi.Types
  with agent-specific types.
  """

  alias Expi.Types.Model

  # Thinking level for AI reasoning
  @type thinking_level :: :off | :minimal | :low | :medium | :high | :xhigh

  # Agent state structure
  defmodule AgentState do
    @moduledoc """
    Complete state of an agent conversation.

    The AgentState struct maintains all conversation context including:
    - System prompt and model configuration
    - Thinking level for reasoning depth
    - Available tools and their configurations  
    - Complete message history
    - Current streaming status and active operations
    - Error state and recovery information
    """

    @type t :: %__MODULE__{
            system_prompt: String.t(),
            model: Model.t(),
            thinking_level: Expi.Agent.Types.thinking_level(),
            tools: [AgentTool.t()],
            messages: [AgentMessage.t()],
            is_streaming: boolean(),
            stream_message: AgentMessage.t() | nil,
            pending_tool_calls: MapSet.t(String.t()),
            error: String.t() | nil,
            created_at: pos_integer(),
            max_context_length: pos_integer() | nil,
            temperature: float() | nil,
            streaming: boolean()
          }

    defstruct system_prompt: "",
              model: nil,
              thinking_level: :off,
              tools: [],
              messages: [],
              is_streaming: false,
              stream_message: nil,
              pending_tool_calls: MapSet.new(),
              error: nil,
              created_at: nil,
              max_context_length: nil,
              temperature: nil,
              streaming: true

    @doc """
    Validates if an agent state structure is valid.
    """
    @spec valid?(t()) :: boolean()
    def valid?(%__MODULE__{model: %Model{}} = state) do
      is_binary(state.system_prompt) and
        is_list(state.tools) and
        is_list(state.messages) and
        is_boolean(state.is_streaming)
    end

    def valid?(_), do: false

    @doc """
    Checks if the agent is currently idle (not streaming, no pending tools).
    """
    @spec idle?(t()) :: boolean()
    def idle?(%__MODULE__{is_streaming: false, pending_tool_calls: pending}) do
      MapSet.size(pending) == 0
    end

    def idle?(_), do: false

    @doc """
    Checks if the agent has pending tool calls to execute.
    """
    @spec has_pending_tools?(t()) :: boolean()
    def has_pending_tools?(%__MODULE__{pending_tool_calls: pending}) do
      MapSet.size(pending) > 0
    end
  end

  # Agent tool structure with execution capabilities
  defmodule AgentTool do
    @moduledoc """
    Agent tool definition with execution capabilities and metadata.

    AgentTool extends the base Tool concept with:
    - Human-readable labels for UI display
    - Asynchronous execution with streaming updates
    - Cancellation support via abort signals
    - Rich result handling separating content from details
    """

    @type parameters_schema :: map()
    @type tool_details :: any()

    @type execute_callback :: (String.t(), map(), pid() | nil, update_callback() | nil ->
                                 {:ok, AgentToolResult.t()} | {:error, any()})

    @type update_callback :: (AgentToolResult.t() -> :ok)

    @type t :: %__MODULE__{
            type: :function,
            function: %{
              name: String.t(),
              description: String.t(),
              parameters: parameters_schema()
            },
            label: String.t(),
            execute: execute_callback()
          }

    defstruct type: :function,
              function: %{name: "", description: "", parameters: %{}},
              label: "",
              execute: nil

    @doc """
    Validates if an agent tool structure is valid.
    """
    @spec valid?(t()) :: boolean()
    def valid?(%__MODULE__{function: %{name: name}, execute: execute})
        when is_binary(name) and name != "" and is_function(execute) do
      true
    end

    def valid?(_), do: false

    @doc """
    Gets the tool name from the function spec.
    """
    @spec name(t()) :: String.t()
    def name(%__MODULE__{function: %{name: name}}), do: name
  end

  # Tool execution result
  defmodule AgentToolResult do
    @moduledoc """
    Result from agent tool execution.

    Separates content (what the LLM sees) from details (what the UI displays):
    - content: Text and image content blocks for LLM consumption
    - details: Structured data for UI display, progress tracking, metadata
    """

    @type content_block :: Expi.Types.TextContent.t() | Expi.Types.ImageContent.t()

    @type t :: %__MODULE__{
            content: [content_block()],
            details: any()
          }

    defstruct content: [], details: nil

    @doc """
    Creates a simple text result.
    """
    @spec text(String.t(), any()) :: t()
    def text(text, details \\ nil) do
      %__MODULE__{
        content: [%Expi.Types.TextContent{type: :text, text: text}],
        details: details
      }
    end

    @doc """
    Validates if a tool result is properly formatted.
    """
    @spec valid?(t()) :: boolean()
    def valid?(%__MODULE__{content: content}) when is_list(content), do: true
    def valid?(_), do: false
  end

  # Agent event system
  defmodule AgentEvent do
    @moduledoc """
    Events emitted during agent lifecycle and operations.

    Comprehensive event system covering:
    - Agent lifecycle (start, end)
    - Turn lifecycle (one assistant response + tool calls)
    - Message lifecycle (streaming events)
    - Tool execution lifecycle (start, update, end)
    """

    @type event_type ::
            :agent_start
            | :agent_end
            | :turn_start
            | :turn_end
            | :message_start
            | :message_update
            | :message_end
            | :tool_execution_start
            | :tool_execution_update
            | :tool_execution_end

    @type t :: %__MODULE__{
            type: event_type(),
            # Agent lifecycle fields
            messages: [AgentMessage.t()] | nil,
            # Turn lifecycle fields  
            message: AgentMessage.t() | nil,
            tool_results: [Expi.Types.ToolResultMessage.t()] | nil,
            # Message lifecycle fields
            assistant_message_event: Expi.Types.AssistantMessageEvent.t() | nil,
            # Tool execution fields
            tool_call_id: String.t() | nil,
            tool_name: String.t() | nil,
            args: any() | nil,
            partial_result: any() | nil,
            result: any() | nil,
            is_error: boolean() | nil
          }

    defstruct [
      :type,
      :messages,
      :message,
      :tool_results,
      :assistant_message_event,
      :tool_call_id,
      :tool_name,
      :args,
      :partial_result,
      :result,
      :is_error
    ]

    # Valid event types
    @valid_types [
      :agent_start,
      :agent_end,
      :turn_start,
      :turn_end,
      :message_start,
      :message_update,
      :message_end,
      :tool_execution_start,
      :tool_execution_update,
      :tool_execution_end
    ]

    @doc """
    Validates if an event type is supported.
    """
    @spec valid_type?(atom()) :: boolean()
    def valid_type?(type) when type in @valid_types, do: true
    def valid_type?(_), do: false

    @doc """
    Creates an agent start event.
    """
    @spec agent_start() :: t()
    def agent_start() do
      %__MODULE__{type: :agent_start}
    end

    @doc """
    Creates an agent end event.
    """
    @spec agent_end([AgentMessage.t()]) :: t()
    def agent_end(messages) do
      %__MODULE__{type: :agent_end, messages: messages}
    end

    @doc """
    Creates a turn start event.
    """
    @spec turn_start() :: t()
    def turn_start() do
      %__MODULE__{type: :turn_start}
    end

    @doc """
    Creates a turn end event.
    """
    @spec turn_end(AgentMessage.t(), [Expi.Types.ToolResultMessage.t()]) :: t()
    def turn_end(message, tool_results) do
      %__MODULE__{type: :turn_end, message: message, tool_results: tool_results}
    end

    @doc """
    Creates a tool execution start event.
    """
    @spec tool_execution_start(String.t(), String.t(), any()) :: t()
    def tool_execution_start(tool_call_id, tool_name, args) do
      %__MODULE__{
        type: :tool_execution_start,
        tool_call_id: tool_call_id,
        tool_name: tool_name,
        args: args
      }
    end

    @doc """
    Creates a tool execution update event.
    """
    @spec tool_execution_update(String.t(), String.t(), any(), any()) :: t()
    def tool_execution_update(tool_call_id, tool_name, args, partial_result) do
      %__MODULE__{
        type: :tool_execution_update,
        tool_call_id: tool_call_id,
        tool_name: tool_name,
        args: args,
        partial_result: partial_result
      }
    end

    @doc """
    Creates a tool execution end event.
    """
    @spec tool_execution_end(String.t(), String.t(), any(), boolean()) :: t()
    def tool_execution_end(tool_call_id, tool_name, result, is_error) do
      %__MODULE__{
        type: :tool_execution_end,
        tool_call_id: tool_call_id,
        tool_name: tool_name,
        result: result,
        is_error: is_error
      }
    end
  end

  # AgentMessage type alias
  @type agent_message :: Expi.Agent.Message.t()

  # Agent context for LLM requests
  defmodule AgentContext do
    @moduledoc """
    Agent context for AI model requests.

    Similar to Expi.Types.Context but uses AgentMessage types
    and agent-specific tools.
    """

    @type t :: %__MODULE__{
            system_prompt: String.t(),
            messages: [Expi.Agent.Types.agent_message()],
            tools: [AgentTool.t()] | nil
          }

    defstruct system_prompt: "", messages: [], tools: nil

    @doc """
    Validates if an agent context is valid.
    """
    @spec valid?(t()) :: boolean()
    def valid?(%__MODULE__{system_prompt: prompt, messages: messages})
        when is_binary(prompt) and is_list(messages) do
      true
    end

    def valid?(_), do: false
  end

  # Agent configuration options
  defmodule AgentOptions do
    @moduledoc """
    Configuration options for agent creation and operation.

    Provides extensive customization including:
    - Initial state overrides
    - Message conversion and transformation functions
    - Queue processing modes
    - Custom streaming functions
    - Authentication and retry configuration
    """

    @type stream_fn :: (Model.t(), Expi.Types.Context.t(), map() ->
                          {:ok, Enumerable.t()} | {:error, atom()})

    @type convert_fn :: ([Expi.Agent.Types.agent_message()] ->
                           [Expi.Types.message()]
                           | {:ok, [Expi.Types.message()]}
                           | {:error, atom()})

    @type transform_fn :: ([Expi.Agent.Types.agent_message()], pid() | nil ->
                             {:ok, [Expi.Agent.Types.agent_message()]} | {:error, atom()})

    @type auth_fn :: (String.t() -> String.t() | nil | {:ok, String.t()} | {:error, atom()})

    @type queue_mode :: :all | :one_at_a_time

    @type t :: %__MODULE__{
            initial_state: map() | nil,
            convert_to_llm: convert_fn() | nil,
            transform_context: transform_fn() | nil,
            steering_mode: queue_mode(),
            follow_up_mode: queue_mode(),
            stream_fn: stream_fn() | nil,
            session_id: String.t() | nil,
            get_api_key: auth_fn() | nil,
            max_retry_delay_ms: pos_integer()
          }

    defstruct initial_state: nil,
              convert_to_llm: nil,
              transform_context: nil,
              steering_mode: :all,
              follow_up_mode: :all,
              stream_fn: nil,
              session_id: nil,
              get_api_key: nil,
              max_retry_delay_ms: 30_000

    @doc """
    Creates default agent options.
    """
    @spec default() :: t()
    def default() do
      %__MODULE__{}
    end

    @doc """
    Validates if agent options are properly configured.
    """
    @spec valid?(t()) :: boolean()
    def valid?(%__MODULE__{steering_mode: steering, follow_up_mode: follow_up})
        when steering in [:all, :one_at_a_time] and follow_up in [:all, :one_at_a_time] do
      true
    end

    def valid?(_), do: false
  end

  # Thinking level validation
  @valid_thinking_levels [:off, :minimal, :low, :medium, :high, :xhigh]

  @doc """
  Validates if a thinking level is supported.
  """
  @spec valid_thinking_level?(atom()) :: boolean()
  def valid_thinking_level?(level) when level in @valid_thinking_levels, do: true
  def valid_thinking_level?(_), do: false

  @doc """
  All supported thinking levels.
  """
  @spec thinking_levels() :: [thinking_level()]
  def thinking_levels(), do: @valid_thinking_levels
end
