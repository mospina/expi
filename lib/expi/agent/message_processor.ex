defmodule Expi.Agent.MessageProcessor do
  @moduledoc """
  Message processing pipeline for agent conversations.

  This module provides functions for converting between agent message formats
  and LLM-compatible formats, applying transformations, and managing the
  message processing pipeline. It serves as the bridge between the agent's
  internal message representation and the AI model's expected input format.

  ## Core Functions

  - **Conversion**: `convert_to_llm/1`, `convert_messages/2`
  - **Processing**: `process_pipeline/3`, `apply_transformations/3`
  - **Validation**: `validate_pipeline/1`, `validate_messages/1`
  - **Utilities**: `estimate_tokens/1`, `summarize_pipeline/1`

  ## Pipeline Flow

  1. **Input**: Agent messages with potential custom types
  2. **Transform**: Apply context transformations (pruning, injection)
  3. **Convert**: Convert to LLM-compatible message format
  4. **Validate**: Ensure the output is valid for the AI model
  5. **Output**: Clean message list ready for AI processing
  """

  alias Expi.Agent.Types.{AgentState, AgentContext}
  alias Expi.Agent.{Message, State}
  alias Expi.Types.{Context, UserMessage, AssistantMessage, ToolResultMessage}

  @type conversion_result :: {:ok, [Expi.Types.message()]} | {:error, atom() | String.t()}
  @type pipeline_result :: {:ok, Context.t()} | {:error, atom() | String.t()}
  @type transform_error :: {:error, :transform_failed | :invalid_messages | atom()}

  @doc """
  Converts a list of agent messages to LLM-compatible messages.

  Uses the AgentMessage protocol to handle different message types,
  filtering out messages that should not be sent to the LLM (like
  notifications or UI-only messages).

  ## Parameters

  - `agent_messages` - List of agent messages to convert

  ## Examples

      agent_messages = [
        Message.user("Hello there"),
        %NotificationMessage{content: "File saved"},  # Will be filtered out
        %AssistantMessage{content: [%{type: :text, text: "Hi!"}]}
      ]
      
      {:ok, llm_messages} = MessageProcessor.convert_to_llm(agent_messages)
      # Only user and assistant messages are included
      
  ## Returns

  - `{:ok, [message()]}` - Successfully converted messages
  - `{:error, reason}` - Conversion failed
  """
  @spec convert_to_llm([Message.t()]) :: conversion_result()
  def convert_to_llm(agent_messages) when is_list(agent_messages) do
    try do
      llm_messages =
        agent_messages
        |> Enum.map(&Message.to_llm_message/1)
        |> Enum.filter(&(&1 != nil))
        |> Enum.map(&validate_llm_message/1)

      case Enum.find(llm_messages, &match?({:error, _}, &1)) do
        nil ->
          valid_messages = Enum.map(llm_messages, fn {:ok, msg} -> msg end)
          {:ok, valid_messages}

        {:error, reason} ->
          {:error, {:conversion_failed, reason}}
      end
    rescue
      error ->
        {:error, {:conversion_exception, Exception.message(error)}}
    end
  end

  def convert_to_llm(_), do: {:error, :invalid_input}

  @doc """
  Converts agent messages using a custom conversion function.

  Applies a user-provided conversion function with error handling
  and validation of the result.

  ## Examples

      # Custom conversion that adds metadata
      custom_convert = fn messages ->
        processed = Enum.map(messages, &add_metadata/1)
        Message.filter_for_llm(processed)
      end
      
      {:ok, llm_messages} = MessageProcessor.convert_messages(
        agent_messages, 
        custom_convert
      )
  """
  @spec convert_messages([Message.t()], function()) :: conversion_result()
  def convert_messages(agent_messages, convert_fn) when is_function(convert_fn, 1) do
    try do
      case convert_fn.(agent_messages) do
        messages when is_list(messages) ->
          validate_llm_messages(messages)

        {:ok, messages} when is_list(messages) ->
          validate_llm_messages(messages)

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error, {:invalid_conversion_result, other}}
      end
    rescue
      error ->
        {:error, {:conversion_function_error, Exception.message(error)}}
    end
  end

  def convert_messages(_, _), do: {:error, :invalid_conversion_function}

  @doc """
  Processes a complete message pipeline from agent state to LLM context.

  This is the main pipeline function that handles the complete flow:
  1. Extract messages from agent state
  2. Apply context transformations if provided
  3. Convert to LLM-compatible format
  4. Create final context with system prompt and tools

  ## Parameters

  - `agent_state` - Current agent state with messages and configuration
  - `transform_fn` - Optional transformation function (can be nil)
  - `convert_fn` - Optional conversion function (uses default if nil)

  ## Examples

      # Basic pipeline with default functions
      {:ok, context} = MessageProcessor.process_pipeline(state, nil, nil)
      
      # Custom transformation and conversion
      transform_fn = fn messages, _abort_signal ->
        # Prune old messages if conversation is too long
        if length(messages) > 50 do
          {:ok, Enum.take(messages, -30)}
        else
          {:ok, messages}
        end
      end
      
      {:ok, context} = MessageProcessor.process_pipeline(
        state, 
        transform_fn, 
        &custom_convert/1
      )
      
      # Use the context with AI model
      {:ok, response} = Expi.AI.complete_simple(model, context)
  """
  @spec process_pipeline(AgentState.t(), function() | nil, function() | nil) :: pipeline_result()
  def process_pipeline(%AgentState{} = state, transform_fn \\ nil, convert_fn \\ nil) do
    with {:ok, messages} <- extract_messages(state),
         {:ok, transformed} <- apply_transformation(messages, transform_fn),
         {:ok, llm_messages} <- apply_conversion(transformed, convert_fn),
         {:ok, context} <- build_context(state, llm_messages) do
      {:ok, context}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Applies context transformations to a list of messages.

  Executes the provided transformation function with proper error handling
  and validation of the result.

  ## Parameters

  - `messages` - Agent messages to transform
  - `transform_fn` - Transformation function (receives messages and abort signal)
  - `abort_signal` - Optional abort signal for cancellation

  ## Examples

      # Prune messages by age
      age_prune = fn messages, _signal ->
        cutoff = System.system_time(:millisecond) - 86_400_000  # 24 hours
        recent = Enum.filter(messages, fn msg ->
          Message.timestamp(msg) > cutoff
        end)
        {:ok, recent}
      end
      
      {:ok, recent_messages} = MessageProcessor.apply_transformations(
        all_messages, 
        age_prune,
        nil
      )
  """
  @spec apply_transformations([Message.t()], function() | nil, pid() | nil) ::
          {:ok, [Message.t()]} | transform_error()
  def apply_transformations(messages, transform_fn, abort_signal \\ nil)

  def apply_transformations(messages, nil, _abort_signal) do
    # No transformation function provided - return messages as-is
    {:ok, messages}
  end

  def apply_transformations(messages, transform_fn, abort_signal)
      when is_function(transform_fn, 2) do
    try do
      case transform_fn.(messages, abort_signal) do
        {:ok, transformed} when is_list(transformed) ->
          case Message.validate_all(transformed) do
            :ok -> {:ok, transformed}
            {:error, _reason} -> {:error, :invalid_transformed_messages}
          end

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error, {:invalid_transform_result, other}}
      end
    rescue
      error ->
        {:error, {:transform_exception, Exception.message(error)}}
    end
  end

  def apply_transformations(_, _, _), do: {:error, :invalid_transform_function}

  @doc """
  Validates a complete message processing pipeline configuration.

  Checks that all functions are properly configured and compatible
  with the expected input/output formats.

  ## Examples

      pipeline = %{
        transform_fn: &prune_old_messages/2,
        convert_fn: &custom_convert/1
      }
      
      case MessageProcessor.validate_pipeline(pipeline) do
        :ok -> run_pipeline(pipeline)
        {:error, reason} -> fix_pipeline(reason)
      end
  """
  @spec validate_pipeline(map()) :: :ok | {:error, atom()}
  def validate_pipeline(%{} = config) do
    with :ok <- validate_transform_function(config[:transform_fn]),
         :ok <- validate_convert_function(config[:convert_fn]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_pipeline(_), do: {:error, :invalid_pipeline_config}

  @doc """
  Estimates the token count for a list of messages.

  Provides a rough estimate of token usage for context planning.
  Uses a simple heuristic based on character count and message structure.

  ## Examples

      messages = [user_msg, assistant_msg, tool_result]
      estimated_tokens = MessageProcessor.estimate_tokens(messages)
      
      if estimated_tokens > 8000 do
        prune_old_messages(messages)
      end
  """
  @spec estimate_tokens([Message.t()]) :: non_neg_integer()
  def estimate_tokens(messages) when is_list(messages) do
    messages
    |> Enum.map(&estimate_message_tokens/1)
    |> Enum.sum()
    |> Kernel.+(estimate_overhead_tokens(messages))
  end

  def estimate_tokens(_), do: 0

  @doc """
  Creates a summary of the message processing pipeline for debugging.

  ## Examples

      summary = MessageProcessor.summarize_pipeline(messages, transform_fn, convert_fn)
      Logger.debug("Pipeline: " <> summary)
  """
  @spec summarize_pipeline([Message.t()], function() | nil, function() | nil) :: String.t()
  def summarize_pipeline(messages, transform_fn, convert_fn) do
    message_count = length(messages)
    message_types = messages |> Enum.map(&Message.message_type/1) |> Enum.frequencies()
    estimated_tokens = estimate_tokens(messages)

    transform_info = if transform_fn, do: "custom", else: "none"
    convert_info = if convert_fn, do: "custom", else: "default"

    "Messages: #{message_count} (#{format_type_summary(message_types)}), " <>
      "Tokens: ~#{estimated_tokens}, Transform: #{transform_info}, Convert: #{convert_info}"
  end

  @doc """
  Builds an agent context from current state and tools.

  Creates an AgentContext suitable for further processing,
  combining the current state information into a unified structure.

  ## Examples

      agent_context = MessageProcessor.build_agent_context(state)
      {:ok, llm_context} = MessageProcessor.agent_context_to_llm(agent_context)
  """
  @spec build_agent_context(AgentState.t()) :: AgentContext.t()
  def build_agent_context(%AgentState{} = state) do
    %AgentContext{
      system_prompt: state.system_prompt,
      messages: State.get_messages(state),
      tools: State.get_tools(state)
    }
  end

  @doc """
  Converts an agent context to LLM-compatible context.

  Transforms an AgentContext into an Expi.Types.Context that can
  be passed directly to AI models.

  ## Examples

      agent_context = build_agent_context(state)
      
      case MessageProcessor.agent_context_to_llm(agent_context) do
        {:ok, llm_context} -> 
          Expi.AI.complete_simple(model, llm_context)
        {:error, reason} -> 
          handle_conversion_error(reason)
      end
  """
  @spec agent_context_to_llm(AgentContext.t()) :: pipeline_result()
  def agent_context_to_llm(%AgentContext{} = agent_context) do
    with {:ok, llm_messages} <- convert_to_llm(agent_context.messages),
         {:ok, llm_tools} <- convert_tools_to_llm(agent_context.tools) do
      context = %Context{
        system_prompt: agent_context.system_prompt,
        messages: llm_messages,
        tools: llm_tools
      }

      {:ok, context}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Prunes old messages from a conversation to stay within token limits.

  A common transformation function that removes older messages while
  preserving important context and recent conversation flow.

  ## Parameters

  - `messages` - Messages to prune
  - `max_tokens` - Maximum token budget to stay within
  - `preserve_count` - Number of recent messages to always keep

  ## Examples

      # Keep conversation under 4000 tokens, preserve last 10 messages
      {:ok, pruned} = MessageProcessor.prune_by_tokens(
        messages, 
        4000, 
        preserve_count: 10
      )
  """
  @spec prune_by_tokens([Message.t()], pos_integer(), keyword()) ::
          {:ok, [Message.t()]} | {:error, atom()}
  def prune_by_tokens(messages, max_tokens, opts \\ []) do
    preserve_count = Keyword.get(opts, :preserve_count, 5)

    if length(messages) <= preserve_count do
      {:ok, messages}
    else
      # Always preserve recent messages
      {to_preserve, candidates} = Enum.split(messages, -preserve_count)
      preserved_tokens = estimate_tokens(to_preserve)

      if preserved_tokens >= max_tokens do
        # Even preserved messages exceed limit - keep minimal set
        minimal_count = max(1, div(preserve_count, 2))
        {:ok, Enum.take(messages, -minimal_count)}
      else
        # Add older messages while staying under budget
        budget_remaining = max_tokens - preserved_tokens
        selected_older = select_messages_within_budget(candidates, budget_remaining)
        {:ok, selected_older ++ to_preserve}
      end
    end
  end

  @doc """
  Filters messages by type, keeping only specified message types.

  ## Examples

      # Keep only user and assistant messages, filter out notifications
      {:ok, filtered} = MessageProcessor.filter_by_type(
        messages, 
        [:user, :assistant]
      )
  """
  @spec filter_by_type([Message.t()], [atom()]) :: {:ok, [Message.t()]}
  def filter_by_type(messages, allowed_types) when is_list(allowed_types) do
    filtered =
      Enum.filter(messages, fn message ->
        Message.message_type(message) in allowed_types
      end)

    {:ok, filtered}
  end

  # Private helper functions

  @spec extract_messages(AgentState.t()) :: {:ok, [Message.t()]}
  defp extract_messages(%AgentState{} = state) do
    {:ok, State.get_messages(state)}
  end

  @spec apply_transformation([Message.t()], function() | nil) ::
          {:ok, [Message.t()]} | transform_error()
  defp apply_transformation(messages, transform_fn) do
    apply_transformations(messages, transform_fn, nil)
  end

  @spec apply_conversion([Message.t()], function() | nil) :: conversion_result()
  defp apply_conversion(messages, nil) do
    convert_to_llm(messages)
  end

  defp apply_conversion(messages, convert_fn) when is_function(convert_fn, 1) do
    convert_messages(messages, convert_fn)
  end

  defp apply_conversion(_, _) do
    {:error, :invalid_convert_function}
  end

  @spec build_context(AgentState.t(), [Expi.Types.message()]) :: pipeline_result()
  defp build_context(%AgentState{} = state, llm_messages) do
    with {:ok, llm_tools} <- convert_tools_to_llm(State.get_tools(state)) do
      context = %Context{
        system_prompt: state.system_prompt,
        messages: llm_messages,
        tools: llm_tools
      }

      {:ok, context}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec convert_tools_to_llm([Expi.Agent.Types.AgentTool.t()]) ::
          {:ok, [Expi.Types.Tool.t()] | nil} | {:error, atom()}
  defp convert_tools_to_llm([]) do
    {:ok, nil}
  end

  defp convert_tools_to_llm(agent_tools) do
    llm_tools = Expi.Agent.Tool.to_llm_tools(agent_tools)
    {:ok, llm_tools}
  end

  @spec validate_llm_message(any()) :: {:ok, Expi.Types.message()} | {:error, atom()}
  defp validate_llm_message(%UserMessage{} = msg), do: {:ok, msg}
  defp validate_llm_message(%AssistantMessage{} = msg), do: {:ok, msg}
  defp validate_llm_message(%ToolResultMessage{} = msg), do: {:ok, msg}
  defp validate_llm_message(_), do: {:error, :invalid_llm_message_type}

  @spec validate_llm_messages([any()]) :: conversion_result()
  defp validate_llm_messages(messages) when is_list(messages) do
    validated = Enum.map(messages, &validate_llm_message/1)

    case Enum.find(validated, &match?({:error, _}, &1)) do
      nil ->
        valid_messages = Enum.map(validated, fn {:ok, msg} -> msg end)
        {:ok, valid_messages}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_llm_messages(_), do: {:error, :invalid_message_list}

  @spec validate_transform_function(function() | nil) :: :ok | {:error, atom()}
  defp validate_transform_function(nil), do: :ok
  defp validate_transform_function(func) when is_function(func, 2), do: :ok
  defp validate_transform_function(_), do: {:error, :invalid_transform_function}

  @spec validate_convert_function(function() | nil) :: :ok | {:error, atom()}
  defp validate_convert_function(nil), do: :ok
  defp validate_convert_function(func) when is_function(func, 1), do: :ok
  defp validate_convert_function(_), do: {:error, :invalid_convert_function}

  @spec estimate_message_tokens(Message.t()) :: non_neg_integer()
  defp estimate_message_tokens(message) do
    content = Message.content(message)
    base_tokens = estimate_content_tokens(content)

    # Add overhead for message structure
    message_type = Message.message_type(message)

    overhead =
      case message_type do
        :user -> 10
        :assistant -> 15
        :tool_result -> 20
        _ -> 5
      end

    base_tokens + overhead
  end

  @spec estimate_content_tokens(any()) :: non_neg_integer()
  defp estimate_content_tokens(content) when is_binary(content) do
    # Rough estimate: 4 characters per token for text
    div(String.length(content) + 3, 4)
  end

  defp estimate_content_tokens(content) when is_list(content) do
    content
    |> Enum.map(&estimate_content_block_tokens/1)
    |> Enum.sum()
  end

  # Default estimate
  defp estimate_content_tokens(_), do: 10

  @spec estimate_content_block_tokens(map()) :: non_neg_integer()
  defp estimate_content_block_tokens(%{type: :text, text: text}) do
    div(String.length(text) + 3, 4)
  end

  defp estimate_content_block_tokens(%{type: :image}) do
    # Images consume significant tokens
    200
  end

  defp estimate_content_block_tokens(%{type: :tool_call}) do
    # Tool calls have moderate overhead
    50
  end

  defp estimate_content_block_tokens(_), do: 20

  @spec estimate_overhead_tokens([Message.t()]) :: non_neg_integer()
  defp estimate_overhead_tokens(messages) do
    # System prompt overhead, conversation structure, etc.
    base_overhead = 50
    message_count_factor = length(messages) * 2
    base_overhead + message_count_factor
  end

  @spec select_messages_within_budget([Message.t()], non_neg_integer()) :: [Message.t()]
  defp select_messages_within_budget(messages, budget) do
    {selected, _remaining_budget} =
      Enum.reduce(messages, {[], budget}, fn message, {acc, remaining} ->
        msg_tokens = estimate_message_tokens(message)

        if msg_tokens <= remaining do
          {[message | acc], remaining - msg_tokens}
        else
          {acc, remaining}
        end
      end)

    Enum.reverse(selected)
  end

  @spec format_type_summary(map()) :: String.t()
  defp format_type_summary(type_frequencies) do
    type_frequencies
    |> Enum.map(fn {type, count} -> "#{type}:#{count}" end)
    |> Enum.join(",")
  end
end
