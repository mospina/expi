defmodule Expi.Agent.Message do
  @moduledoc """
  AgentMessage type definition and utilities.
  
  This module defines the AgentMessage type as a union of all supported
  message types and provides utilities for working with agent messages.
  """

  alias Expi.Types.{UserMessage, AssistantMessage, ToolResultMessage}
  alias Expi.Agent.Protocols.AgentMessage, as: AgentMessageProtocol

  @typedoc """
  Agent message type - union of all supported message types.
  
  Core message types from Expi.Types:
  - UserMessage - Messages from users
  - AssistantMessage - Messages from AI assistants
  - ToolResultMessage - Results from tool executions
  
  Applications can extend this by implementing the AgentMessage protocol
  for custom message types (notifications, artifacts, status messages, etc.).
  """
  @type t :: UserMessage.t() | AssistantMessage.t() | ToolResultMessage.t() | term()

  @doc """
  Converts an agent message to an LLM-compatible message.
  
  Uses the AgentMessage protocol to handle conversion. Returns nil
  for message types that should not be sent to the LLM.
  
  ## Examples
  
      iex> user_msg = %UserMessage{content: "Hello", timestamp: 123}
      iex> AgentMessage.to_llm_message(user_msg)
      %UserMessage{content: "Hello", timestamp: 123}
  """
  @spec to_llm_message(t()) :: Expi.Types.message() | nil
  def to_llm_message(message) do
    AgentMessageProtocol.to_llm_message(message)
  end

  @doc """
  Gets the message type identifier.
  
  ## Examples
  
      iex> user_msg = %UserMessage{role: :user}
      iex> AgentMessage.message_type(user_msg)
      :user
  """
  @spec message_type(t()) :: atom()
  def message_type(message) do
    AgentMessageProtocol.message_type(message)
  end

  @doc """
  Gets the message timestamp.
  
  ## Examples
  
      iex> user_msg = %UserMessage{timestamp: 1234567890}
      iex> AgentMessage.timestamp(user_msg)
      1234567890
  """
  @spec timestamp(t()) :: pos_integer()
  def timestamp(message) do
    AgentMessageProtocol.timestamp(message)
  end

  @doc """
  Extracts content from the message.
  
  ## Examples
  
      iex> user_msg = %UserMessage{content: "Hello world"}
      iex> AgentMessage.content(user_msg)
      "Hello world"
  """
  @spec content(t()) :: String.t() | [map()] | any()
  def content(message) do
    AgentMessageProtocol.content(message)
  end

  @doc """
  Validates if a message is properly formatted.
  
  ## Examples
  
      iex> user_msg = %UserMessage{role: :user, content: "Hello", timestamp: 123}
      iex> AgentMessage.valid?(user_msg)
      true
  """
  @spec valid?(t()) :: boolean()
  def valid?(message) do
    AgentMessageProtocol.valid?(message)
  end

  @doc """
  Filters a list of agent messages to only those that should be sent to the LLM.
  
  ## Examples
  
      iex> messages = [user_msg, notification, assistant_msg]
      iex> AgentMessage.filter_for_llm(messages)
      [user_msg, assistant_msg]  # notification filtered out
  """
  @spec filter_for_llm([t()]) :: [Expi.Types.message()]
  def filter_for_llm(messages) do
    messages
    |> Enum.map(&to_llm_message/1)
    |> Enum.filter(& &1 != nil)
  end

  @doc """
  Sorts messages by timestamp in ascending order.
  
  ## Examples
  
      iex> AgentMessage.sort_by_timestamp([msg3, msg1, msg2])
      [msg1, msg2, msg3]  # sorted by timestamp
  """
  @spec sort_by_timestamp([t()]) :: [t()]
  def sort_by_timestamp(messages) do
    Enum.sort_by(messages, &timestamp/1)
  end

  @doc """
  Groups messages by their type.
  
  Returns a map with message types as keys and lists of messages as values.
  
  ## Examples
  
      iex> messages = [user_msg, assistant_msg, user_msg2]
      iex> AgentMessage.group_by_type(messages)
      %{user: [user_msg, user_msg2], assistant: [assistant_msg]}
  """
  @spec group_by_type([t()]) :: %{atom() => [t()]}
  def group_by_type(messages) do
    Enum.group_by(messages, &message_type/1)
  end

  @doc """
  Validates that all messages in a list are properly formatted.
  
  ## Examples
  
      iex> AgentMessage.validate_all([valid_msg1, valid_msg2])
      :ok
      
      iex> AgentMessage.validate_all([valid_msg, invalid_msg])
      {:error, {:invalid_message, 1, "Details about what's invalid"}}
  """
  @spec validate_all([t()]) :: :ok | {:error, {:invalid_message, non_neg_integer(), String.t()}}
  def validate_all(messages) do
    messages
    |> Enum.with_index()
    |> Enum.find(fn {message, _index} -> not valid?(message) end)
    |> case do
      nil -> 
        :ok
      {invalid_message, index} -> 
        {:error, {:invalid_message, index, "Message at index #{index} is invalid: #{inspect(invalid_message)}"}}
    end
  end

  @doc """
  Creates a new user message with the current timestamp.
  
  ## Examples
  
      iex> AgentMessage.user("Hello there")
      %UserMessage{role: :user, content: "Hello there", timestamp: current_time}
  """
  @spec user(String.t() | [map()]) :: UserMessage.t()
  def user(content) do
    %UserMessage{
      role: :user,
      content: content,
      timestamp: System.system_time(:millisecond)
    }
  end

  @doc """
  Creates a new tool result message.
  
  ## Examples
  
      iex> content = [%Expi.Types.TextContent{type: :text, text: "Result"}]
      iex> AgentMessage.tool_result("call_123", "search", content)
      %ToolResultMessage{...}
  """
  @spec tool_result(String.t(), String.t(), [map()], any(), boolean()) :: ToolResultMessage.t()
  def tool_result(tool_call_id, tool_name, content, details \\ nil, is_error \\ false) do
    %ToolResultMessage{
      role: :tool_result,
      tool_call_id: tool_call_id,
      tool_name: tool_name,
      content: content,
      details: details,
      is_error: is_error,
      timestamp: System.system_time(:millisecond)
    }
  end
end