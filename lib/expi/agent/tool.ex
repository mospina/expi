defmodule Expi.Agent.Tool do
  @moduledoc """
  Agent tool definition, validation, and execution utilities.
  
  This module provides functions for creating, validating, and working with
  AgentTools. It extends the base Expi.Types.Tool concept with agent-specific
  features like execution callbacks, streaming updates, and result handling.
  """

  alias Expi.Agent.Types.{AgentTool, AgentToolResult}
  alias Expi.Types.Tool

  @doc """
  Creates a new AgentTool with validation.
  
  ## Parameters
  
  - `name` - Tool function name (must be non-empty string)
  - `description` - Human-readable description of what the tool does
  - `parameters` - JSON schema defining the tool's parameters
  - `label` - Display label for UI (defaults to name if not provided)  
  - `execute` - Function that executes the tool
  
  ## Examples
  
      # Simple text-based tool
      {:ok, search_tool} = AgentTool.new(
        "web_search",
        "Search the web for information",
        %{
          type: :object,
          properties: %{
            query: %{type: :string, description: "Search query"},
            max_results: %{type: :integer, minimum: 1, maximum: 10, default: 5}
          },
          required: ["query"]
        },
        "Web Search",
        fn tool_call_id, params, _abort_signal, _update_callback ->
          query = params["query"]
          
          content = [%Expi.Types.TextContent{
            type: :text, 
            text: "Found results for query: " <> query
          }]
          
          {:ok, %AgentToolResult{content: content, details: %{query: query}}}
        end
      )
      
      # Tool with streaming updates  
      {:ok, file_tool} = AgentTool.new(
        "process_file",
        "Process a large file with progress updates", 
        %{type: :object, properties: %{file_path: %{type: :string}}},
        "File Processor",
        fn _tool_call_id, _params, _abort_signal, _update_callback ->
          # Implementation would handle file processing with progress updates
          {:ok, %AgentToolResult{
            content: [%Expi.Types.TextContent{type: :text, text: "File processed"}],
            details: %{status: :completed}
          }}
        end
      )
      
  ## Returns
  
  - `{:ok, %AgentTool{}}` - Successfully created tool
  - `{:error, reason}` - Validation failed
  
  ## Validation Rules
  
  - Name must be a non-empty string matching /^[a-zA-Z_][a-zA-Z0-9_]*$/
  - Description must be a non-empty string
  - Parameters must be a valid JSON schema map
  - Execute function must have arity 4: (tool_call_id, params, abort_signal, update_callback)
  """
  @spec new(String.t(), String.t(), map(), String.t(), function()) :: 
        {:ok, AgentTool.t()} | {:error, atom() | String.t()}
  def new(name, description, parameters, label \\ nil, execute_fn) do
    with :ok <- validate_name(name),
         :ok <- validate_description(description),
         :ok <- validate_parameters(parameters),
         :ok <- validate_execute_function(execute_fn) do
      
      tool = %AgentTool{
        type: :function,
        function: %{
          name: name,
          description: description,
          parameters: parameters
        },
        label: label || name,
        execute: execute_fn
      }
      
      {:ok, tool}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a simple text-only tool that returns a string result.
  
  Convenience function for tools that only return text content.
  
  ## Examples
  
      {:ok, time_tool} = AgentTool.text_tool(
        "get_time",
        "Get the current time",
        %{type: :object, properties: %{}},
        fn _tool_call_id, _params, _signal, _callback ->
          {:ok, "Current time: #{DateTime.utc_now()}"}
        end
      )
  """
  @spec text_tool(String.t(), String.t(), map(), function()) :: 
        {:ok, AgentTool.t()} | {:error, atom() | String.t()}
  def text_tool(name, description, parameters, execute_fn) do
    wrapped_execute = fn tool_call_id, params, abort_signal, update_callback ->
      case execute_fn.(tool_call_id, params, abort_signal, update_callback) do
        {:ok, text} when is_binary(text) ->
          {:ok, AgentToolResult.text(text)}
        {:error, reason} -> 
          {:error, reason}
        other ->
          {:error, {:invalid_return, other}}
      end
    end
    
    new(name, description, parameters, nil, wrapped_execute)
  end

  @doc """
  Validates an AgentTool structure.
  
  ## Examples
  
      iex> AgentTool.valid?(tool)
      true
      
      iex> AgentTool.valid?(%{invalid: "structure"})
      false
  """
  @spec valid?(term()) :: boolean()
  def valid?(tool) do
    AgentTool.valid?(tool)
  end

  @doc """
  Executes an agent tool with the given parameters.
  
  Provides a safe wrapper around tool execution with proper error handling,
  timeout management, and cancellation support.
  
  ## Parameters
  
  - `tool` - The AgentTool to execute
  - `tool_call_id` - Unique identifier for this execution
  - `params` - Parameters to pass to the tool (already validated)
  - `opts` - Execution options
  
  ## Options
  
  - `timeout` - Maximum execution time in milliseconds (default: 30000)
  - `update_callback` - Function to call for streaming updates
  - `abort_signal` - Process to monitor for cancellation
  
  ## Examples
  
      # Basic execution
      {:ok, result} = AgentTool.execute(search_tool, "call_123", %{"query" => "elixir"})
      
      # With timeout and callback
      {:ok, result} = AgentTool.execute(
        file_tool, 
        "call_456", 
        %{"file_path" => "/tmp/data.csv"},
        timeout: 60_000,
        update_callback: fn partial -> IO.inspect(partial) end
      )
      
      # With cancellation
      abort_pid = spawn(fn -> Process.sleep(5000) end)
      {:ok, result} = AgentTool.execute(
        long_tool,
        "call_789",
        %{},
        abort_signal: abort_pid
      )
  """
  @spec execute(AgentTool.t(), String.t(), map(), keyword()) :: 
        {:ok, AgentToolResult.t()} | {:error, any()}
  def execute(tool, tool_call_id, params, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    update_callback = Keyword.get(opts, :update_callback)
    abort_signal = Keyword.get(opts, :abort_signal)

    task = Task.async(fn ->
      try do
        tool.execute.(tool_call_id, params, abort_signal, update_callback)
      rescue
        error ->
          {:error, {:execution_error, Exception.message(error)}}
      end
    end)

    try do
      case Task.await(task, timeout) do
        {:ok, %AgentToolResult{} = result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:invalid_result, other}}
      end
    catch
      :exit, {:timeout, _} ->
        Task.shutdown(task)
        {:error, :timeout}
    end
  end

  @doc """
  Converts an AgentTool to an Expi.Types.Tool for LLM compatibility.
  
  ## Examples
  
      iex> llm_tool = AgentTool.to_llm_tool(agent_tool)
      %Expi.Types.Tool{
        type: :function,
        function: %{name: "search", description: "...", parameters: %{...}}
      }
  """
  @spec to_llm_tool(AgentTool.t()) :: Tool.t()
  def to_llm_tool(%AgentTool{type: type, function: function}) do
    %Tool{type: type, function: function}
  end

  @doc """
  Converts a list of AgentTools to LLM-compatible tools.
  
  ## Examples
  
      iex> llm_tools = AgentTool.to_llm_tools([tool1, tool2, tool3])
      [%Tool{...}, %Tool{...}, %Tool{...}]
  """
  @spec to_llm_tools([AgentTool.t()]) :: [Tool.t()]
  def to_llm_tools(agent_tools) do
    Enum.map(agent_tools, &to_llm_tool/1)
  end

  @doc """
  Finds a tool in a list by its name.
  
  ## Examples
  
      iex> AgentTool.find_by_name([search_tool, file_tool], "web_search")
      {:ok, search_tool}
      
      iex> AgentTool.find_by_name([tool1, tool2], "nonexistent")
      {:error, :tool_not_found}
  """
  @spec find_by_name([AgentTool.t()], String.t()) :: {:ok, AgentTool.t()} | {:error, :tool_not_found}
  def find_by_name(tools, name) do
    tools
    |> Enum.find(fn tool -> AgentTool.name(tool) == name end)
    |> case do
      nil -> {:error, :tool_not_found}
      tool -> {:ok, tool}
    end
  end

  @doc """
  Validates all tools in a list.
  
  ## Examples
  
      iex> AgentTool.validate_all([tool1, tool2])
      :ok
      
      iex> AgentTool.validate_all([valid_tool, invalid_tool])
      {:error, {:invalid_tool, 1}}
  """
  @spec validate_all([AgentTool.t()]) :: :ok | {:error, {:invalid_tool, non_neg_integer()}}
  def validate_all(tools) do
    tools
    |> Enum.with_index()
    |> Enum.find(fn {tool, _index} -> not valid?(tool) end)
    |> case do
      nil -> :ok
      {_invalid_tool, index} -> {:error, {:invalid_tool, index}}
    end
  end

  @doc """
  Gets the names of all tools in a list.
  
  ## Examples
  
      iex> AgentTool.names([search_tool, file_tool])
      ["web_search", "process_file"]
  """
  @spec names([AgentTool.t()]) :: [String.t()]
  def names(tools) do
    Enum.map(tools, &AgentTool.name/1)
  end

  # Private validation functions

  @spec validate_name(String.t()) :: :ok | {:error, :invalid_name}
  defp validate_name(name) when is_binary(name) do
    if String.length(name) > 0 and Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, name) do
      :ok
    else
      {:error, :invalid_name}
    end
  end
  defp validate_name(_), do: {:error, :invalid_name}

  @spec validate_description(String.t()) :: :ok | {:error, :invalid_description}
  defp validate_description(description) when is_binary(description) do
    if String.length(description) > 0 do
      :ok
    else
      {:error, :invalid_description}
    end
  end
  defp validate_description(_), do: {:error, :invalid_description}

  @spec validate_parameters(map()) :: :ok | {:error, :invalid_parameters}
  defp validate_parameters(params) when is_map(params) do
    # Basic JSON schema validation - could be enhanced with a proper validator
    required_keys = [:type]
    if Enum.all?(required_keys, &Map.has_key?(params, &1)) do
      :ok
    else
      {:error, :invalid_parameters}
    end
  end
  defp validate_parameters(_), do: {:error, :invalid_parameters}

  @spec validate_execute_function(function()) :: :ok | {:error, :invalid_execute_function}
  defp validate_execute_function(func) when is_function(func, 4) do
    :ok
  end
  defp validate_execute_function(_), do: {:error, :invalid_execute_function}
end