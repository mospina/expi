defmodule Expi.Types do
  @moduledoc """
  Core type definitions for the Expi AI module.

  This module defines all the structs and types used throughout the AI module,
  following the architecture specifications from docs/architecture-analysis.md.
  """

  # Cost tracking
  defmodule Cost do
    @moduledoc """
    Represents token costs for input, output, cache operations.
    """
    @type t :: %__MODULE__{
            input: float(),
            output: float(),
            cache_read: float(),
            cache_write: float()
          }

    defstruct [:input, :output, :cache_read, :cache_write]

    @doc """
    Calculate total cost across all operations.
    """
    @spec total(t()) :: float()
    def total(%__MODULE__{} = cost) do
      cost.input + cost.output + cost.cache_read + cost.cache_write
    end
  end

  # Usage tracking
  defmodule Usage do
    @moduledoc """
    Tracks token usage and associated costs for AI requests.
    """
    @type t :: %__MODULE__{
            input: non_neg_integer(),
            output: non_neg_integer(),
            cache_read: non_neg_integer(),
            cache_write: non_neg_integer(),
            total_tokens: non_neg_integer(),
            cost: Cost.t()
          }

    defstruct [:input, :output, :cache_read, :cache_write, :total_tokens, :cost]
  end

  # Content types
  defmodule TextContent do
    @moduledoc """
    Text content in messages.
    """
    @type t :: %__MODULE__{
            type: :text,
            text: String.t(),
            text_signature: String.t() | nil
          }

    defstruct type: :text, text: "", text_signature: nil
  end

  defmodule ThinkingContent do
    @moduledoc """
    Thinking/reasoning content from AI models.
    """
    @type t :: %__MODULE__{
            type: :thinking,
            thinking: String.t(),
            thinking_signature: String.t() | nil,
            redacted: boolean()
          }

    defstruct type: :thinking, thinking: "", thinking_signature: nil, redacted: false
  end

  defmodule ImageContent do
    @moduledoc """
    Image content in messages.
    """
    @type t :: %__MODULE__{
            type: :image,
            data: String.t(),
            mime_type: String.t()
          }

    defstruct type: :image, data: "", mime_type: ""
  end

  defmodule Tool do
    @moduledoc """
    Tool definition for function calling.
    """
    @type function_spec :: %{
            name: String.t(),
            description: String.t(),
            parameters: map()
          }

    @type t :: %__MODULE__{
            type: :function,
            function: function_spec()
          }

    defstruct type: :function, function: %{}
  end

  defmodule ToolCall do
    @moduledoc """
    Tool call content from AI models.
    """
    @type t :: %__MODULE__{
            type: :tool_call,
            id: String.t(),
            name: String.t(),
            arguments: map(),
            thought_signature: String.t() | nil
          }

    defstruct type: :tool_call, id: "", name: "", arguments: %{}, thought_signature: nil
  end

  # Model definition
  defmodule Model do
    @moduledoc """
    AI model configuration and metadata.
    """
    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            api: String.t(),
            provider: String.t(),
            base_url: String.t(),
            reasoning: boolean(),
            input: [String.t()],
            cost: Cost.t(),
            context_window: pos_integer(),
            max_tokens: pos_integer(),
            headers: map(),
            compat: map()
          }

    defstruct [
      :id,
      :name,
      :api,
      :provider,
      :base_url,
      :reasoning,
      :input,
      :cost,
      :context_window,
      :max_tokens,
      :headers,
      :compat
    ]

    @doc """
    Validates if a model ID is in the correct format.
    """
    @spec valid_model_id?(String.t() | nil) :: boolean()
    def valid_model_id?(nil), do: false
    def valid_model_id?(""), do: false
    def valid_model_id?(id) when is_binary(id), do: String.length(id) > 0

    @doc """
    Validates if a provider name is valid.
    """
    @spec valid_provider?(String.t() | nil) :: boolean()
    def valid_provider?(nil), do: false
    def valid_provider?(""), do: false

    def valid_provider?(provider) when is_binary(provider) do
      provider in ["anthropic", "openai", "google", "ollama"]
    end
  end

  # Message types
  defmodule UserMessage do
    @moduledoc """
    User message in a conversation.
    """
    @type content :: String.t() | [TextContent.t() | ImageContent.t()]

    @type t :: %__MODULE__{
            role: :user,
            content: content(),
            timestamp: pos_integer()
          }

    defstruct role: :user, content: "", timestamp: 0
  end

  defmodule AssistantMessage do
    @moduledoc """
    Assistant message in a conversation.
    """
    @type content :: [TextContent.t() | ThinkingContent.t() | ToolCall.t()]
    @type stop_reason :: :stop | :length | :tool_use | :error | :aborted | nil

    @type t :: %__MODULE__{
            role: :assistant,
            content: content(),
            api: String.t(),
            provider: String.t(),
            model: String.t(),
            usage: Usage.t() | nil,
            stop_reason: stop_reason(),
            error_message: String.t() | nil,
            timestamp: pos_integer()
          }

    defstruct role: :assistant,
              content: [],
              api: "",
              provider: "",
              model: "",
              usage: nil,
              stop_reason: nil,
              error_message: nil,
              timestamp: 0
  end

  defmodule ToolResultMessage do
    @moduledoc """
    Tool execution result message.
    """
    @type content :: [TextContent.t() | ImageContent.t()]

    @type t :: %__MODULE__{
            role: :tool_result,
            tool_call_id: String.t(),
            tool_name: String.t(),
            content: content(),
            details: any(),
            is_error: boolean(),
            timestamp: pos_integer()
          }

    defstruct role: :tool_result,
              tool_call_id: "",
              tool_name: "",
              content: [],
              details: nil,
              is_error: false,
              timestamp: 0
  end

  # Context for AI requests
  defmodule Context do
    @moduledoc """
    Context for AI model requests, containing system prompt, messages, and tools.
    """
    @type message :: UserMessage.t() | AssistantMessage.t() | ToolResultMessage.t()

    @type t :: %__MODULE__{
            system_prompt: String.t() | nil,
            messages: [message()],
            tools: [Tool.t()] | nil
          }

    defstruct system_prompt: nil, messages: [], tools: nil

    @doc """
    Validates if a context structure is valid.
    """
    @spec valid?(t()) :: boolean()
    def valid?(%__MODULE__{messages: messages}) when is_list(messages), do: true
    def valid?(_), do: false
  end

  # Event types for streaming
  defmodule AssistantMessageEvent do
    @moduledoc """
    Events emitted during streaming AI responses.

    Supports 12 different event types:
    - Lifecycle: start, done, error
    - Text: text_start, text_delta, text_end
    - Thinking: thinking_start, thinking_delta, thinking_end
    - Tool calls: toolcall_start, toolcall_delta, toolcall_end
    """
    @type event_type ::
            :start
            | :text_start
            | :text_delta
            | :text_end
            | :thinking_start
            | :thinking_delta
            | :thinking_end
            | :toolcall_start
            | :toolcall_delta
            | :toolcall_end
            | :done
            | :error

    @type stop_reason :: :stop | :length | :tool_use | :error | :aborted

    @type t :: %__MODULE__{
            type: event_type(),
            content_index: non_neg_integer() | nil,
            delta: String.t() | nil,
            content: String.t() | nil,
            tool_call: ToolCall.t() | nil,
            partial: AssistantMessage.t() | nil,
            reason: stop_reason() | nil,
            message: AssistantMessage.t() | nil,
            error: AssistantMessage.t() | nil
          }

    defstruct [
      :type,
      :content_index,
      :delta,
      :content,
      :tool_call,
      :partial,
      :reason,
      :message,
      :error
    ]

    @valid_types [
      :start,
      :text_start,
      :text_delta,
      :text_end,
      :thinking_start,
      :thinking_delta,
      :thinking_end,
      :toolcall_start,
      :toolcall_delta,
      :toolcall_end,
      :done,
      :error
    ]

    @doc """
    Validates if an event type is supported.
    """
    @spec valid_type?(atom()) :: boolean()
    def valid_type?(type) when type in @valid_types, do: true
    def valid_type?(_), do: false
  end
end
