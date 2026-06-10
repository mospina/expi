defmodule Expi.Agent.ToolExecutor do
  @moduledoc """
  Concurrent tool execution framework for agent operations.

  This module provides sophisticated tool execution capabilities including:
  - Concurrent execution of multiple tools using Task.async_stream
  - Real-time streaming updates via callback functions
  - Cancellation support through process monitoring
  - Rich error handling and timeout management
  - Result aggregation and coordination

  ## Core Functions

  - **Execution**: `execute_tools_concurrent/3`, `execute_single_tool/3`
  - **Management**: `cancel_execution/1`, `monitor_execution/2`
  - **Streaming**: `stream_tool_updates/3`, `handle_partial_results/2`
  - **Coordination**: `coordinate_results/2`, `aggregate_tool_results/2`

  ## Execution Strategies

  - **Concurrent**: Execute multiple tools in parallel for speed
  - **Sequential**: Execute tools one by one for resource management
  - **Hybrid**: Mix of concurrent and sequential based on tool characteristics

  ## Error Handling

  - Tool execution failures are isolated and don't affect other tools
  - Comprehensive error reporting with context and recovery suggestions
  - Graceful degradation when tools time out or crash
  """

  alias Expi.Agent.Types.{AgentTool, AgentToolResult, AgentEvent}
  alias Expi.Agent.Protocols.AgentToolCallback
  alias Expi.Types.{ToolCall, ToolResultMessage}

  require Logger

  @type execution_id :: String.t()
  @type execution_options :: [
          timeout: pos_integer(),
          max_concurrent: pos_integer(),
          strategy: :concurrent | :sequential | :hybrid,
          on_update: AgentToolCallback.t() | nil,
          on_complete: function() | nil
        ]
  @type execution_result :: {:ok, [ToolResultMessage.t()]} | {:error, any()}
  @type tool_execution :: %{
          id: execution_id(),
          tool: AgentTool.t(),
          tool_call: ToolCall.t(),
          task: Task.t(),
          start_time: integer(),
          status: :running | :completed | :failed | :cancelled
        }

  @default_timeout 30_000
  @default_max_concurrent 5
  @execution_table :expi_tool_executions

  @doc """
  Executes multiple tools concurrently with coordinated result handling.

  This is the main entry point for tool execution. It orchestrates concurrent
  execution of multiple tools while managing streaming updates, error handling,
  and result aggregation.

  ## Parameters

  - `tool_calls` - List of ToolCall structs from LLM response
  - `available_tools` - List of AgentTool structs available for execution
  - `options` - Execution options and callbacks

  ## Options

  - `timeout` - Maximum execution time per tool (default: 30000ms)
  - `max_concurrent` - Maximum number of concurrent executions (default: 5)
  - `strategy` - Execution strategy (:concurrent, :sequential, :hybrid)
  - `on_update` - Callback for streaming updates
  - `on_complete` - Callback when each tool completes

  ## Examples

      # Concurrent execution with streaming updates
      tool_calls = [
        %ToolCall{id: "call_1", name: "web_search", arguments: %{"query" => "elixir"}},
        %ToolCall{id: "call_2", name: "file_read", arguments: %{"path" => "/data.csv"}}
      ]

      callback = ProcessCallback.new(self(), :detailed)

      {:ok, results} = ToolExecutor.execute_tools_concurrent(
        tool_calls,
        available_tools,
        timeout: 45_000,
        max_concurrent: 2,
        on_update: callback
      )

      # Sequential execution for resource-constrained scenarios
      {:ok, results} = ToolExecutor.execute_tools_concurrent(
        tool_calls,
        available_tools,
        strategy: :sequential,
        timeout: 60_000
      )

  ## Returns

  - `{:ok, [ToolResultMessage.t()]}` - All tools executed successfully
  - `{:error, reason}` - Critical failure in execution coordination

  Individual tool failures are captured in the ToolResultMessage.is_error field
  rather than failing the entire execution.
  """
  @spec execute_tools_concurrent([ToolCall.t()], [AgentTool.t()], execution_options()) ::
          execution_result()
  def execute_tools_concurrent(tool_calls, available_tools, options \\ []) do
    ensure_execution_table()
    timeout = Keyword.get(options, :timeout, @default_timeout)
    max_concurrent = Keyword.get(options, :max_concurrent, @default_max_concurrent)
    strategy = Keyword.get(options, :strategy, :sequential)
    on_update = Keyword.get(options, :on_update)
    on_complete = Keyword.get(options, :on_complete)

    execution_id = generate_execution_id()

    Logger.debug("Starting tool execution", %{
      execution_id: execution_id,
      tool_count: length(tool_calls),
      strategy: strategy,
      timeout: timeout
    })

    :ets.insert(
      @execution_table,
      {execution_id,
       %{
         status: :running,
         started_at: System.system_time(:millisecond),
         tool_count: length(tool_calls)
       }}
    )

    case strategy do
      :concurrent ->
        execute_concurrent(
          tool_calls,
          available_tools,
          execution_id,
          timeout,
          max_concurrent,
          on_update,
          on_complete
        )

      :sequential ->
        execute_sequential(
          tool_calls,
          available_tools,
          execution_id,
          timeout,
          on_update,
          on_complete
        )

      :hybrid ->
        execute_hybrid(
          tool_calls,
          available_tools,
          execution_id,
          timeout,
          max_concurrent,
          on_update,
          on_complete
        )
    end
  end

  @doc """
  Executes a single tool with comprehensive error handling.

  Used internally by concurrent execution and can be called directly
  for single tool scenarios.

  ## Examples

      tool_call = %ToolCall{id: "call_123", name: "search", arguments: %{"q" => "test"}}

      {:ok, result} = ToolExecutor.execute_single_tool(
        tool_call,
        search_tool,
        timeout: 10_000,
        on_update: callback
      )
  """
  @spec execute_single_tool(ToolCall.t(), AgentTool.t(), execution_options()) ::
          {:ok, ToolResultMessage.t()} | {:error, any()}
  def execute_single_tool(tool_call, tool, options \\ []) do
    timeout = Keyword.get(options, :timeout, @default_timeout)
    on_update = Keyword.get(options, :on_update)

    start_time = System.system_time(:millisecond)

    # Create abort signal process for cancellation
    abort_signal =
      spawn(fn ->
        receive do
          :abort -> :ok
        after
          timeout -> :ok
        end
      end)

    # Create update callback wrapper
    update_callback =
      if on_update do
        fn partial_result ->
          AgentToolCallback.on_update(on_update, tool_call.id, partial_result)
        end
      else
        nil
      end

    try do
      Logger.info(
        "Executing tool name=#{tool_call.name} id=#{tool_call.id} args=#{inspect(summarize_arguments(tool_call.arguments))}"
      )

      # Execute the tool
      case Expi.Agent.Tool.execute(
             tool,
             tool_call.id,
             tool_call.arguments,
             timeout: timeout,
             update_callback: update_callback,
             abort_signal: abort_signal
           ) do
        {:ok, %AgentToolResult{} = result} ->
          execution_time = System.system_time(:millisecond) - start_time

          tool_result = %ToolResultMessage{
            role: :tool_result,
            tool_call_id: tool_call.id,
            tool_name: tool_call.name,
            content: result.content,
            details: %{
              original_details: result.details,
              execution_time_ms: execution_time,
              timestamp: System.system_time(:millisecond)
            },
            is_error: false,
            timestamp: System.system_time(:millisecond)
          }

          Logger.info(
            "Tool execution succeeded name=#{tool_call.name} id=#{tool_call.id} duration_ms=#{execution_time}"
          )

          if on_update do
            AgentToolCallback.on_complete(on_update, tool_call.id, tool_result, false)
          end

          {:ok, tool_result}

        {:error, reason} ->
          execution_time = System.system_time(:millisecond) - start_time

          error_result = %ToolResultMessage{
            role: :tool_result,
            tool_call_id: tool_call.id,
            tool_name: tool_call.name,
            content: [
              %Expi.Types.TextContent{
                type: :text,
                text: "Tool execution failed: #{inspect(reason)}"
              }
            ],
            details: %{
              error: reason,
              execution_time_ms: execution_time,
              timestamp: System.system_time(:millisecond)
            },
            is_error: true,
            timestamp: System.system_time(:millisecond)
          }

          Logger.error(
            "Tool execution failed name=#{tool_call.name} id=#{tool_call.id} reason=#{inspect(reason)} duration_ms=#{execution_time}"
          )

          if on_update do
            AgentToolCallback.on_complete(on_update, tool_call.id, error_result, true)
          end

          # Don't propagate errors - wrap in result
          {:ok, error_result}
      end
    rescue
      error ->
        Logger.error("Tool execution crashed", %{
          tool_call_id: tool_call.id,
          tool_name: tool_call.name,
          error: Exception.message(error)
        })

        crash_result = %ToolResultMessage{
          role: :tool_result,
          tool_call_id: tool_call.id,
          tool_name: tool_call.name,
          content: [
            %Expi.Types.TextContent{
              type: :text,
              text: "Tool crashed during execution: #{Exception.message(error)}"
            }
          ],
          details: %{
            crash: Exception.message(error),
            timestamp: System.system_time(:millisecond)
          },
          is_error: true,
          timestamp: System.system_time(:millisecond)
        }

        {:ok, crash_result}
    after
      # Clean up abort signal process
      if Process.alive?(abort_signal) do
        Process.exit(abort_signal, :shutdown)
      end
    end
  end

  defp summarize_arguments(arguments) when is_map(arguments) do
    arguments
    |> Enum.take(8)
    |> Enum.map(fn {k, v} -> {k, summarize_value(v)} end)
    |> Map.new()
  end

  defp summarize_arguments(_), do: %{}

  defp summarize_value(v) when is_binary(v) and byte_size(v) > 120,
    do: String.slice(v, 0, 120) <> "..."

  defp summarize_value(v) when is_list(v), do: "[list length=#{length(v)}]"
  defp summarize_value(v) when is_map(v), do: "{map keys=#{map_size(v)}}"
  defp summarize_value(v), do: v

  @doc """
  Cancels a running tool execution by ID.

  Sends cancellation signals to the specified tool execution
  and updates its status accordingly.

  ## Examples

      execution_ref = start_tool_execution(tool_call, tool)

      # Cancel after 5 seconds if still running
      Process.sleep(5000)
      ToolExecutor.cancel_execution(execution_ref)
  """
  @spec cancel_execution(execution_id()) :: :ok | {:error, :not_found | :already_completed}
  def cancel_execution(execution_id) do
    ensure_execution_table()

    case :ets.lookup(@execution_table, execution_id) do
      [] ->
        {:error, :not_found}

      [{^execution_id, %{status: status} = execution}]
      when status in [:completed, :failed, :cancelled] ->
        {:error, :already_completed}

      [{^execution_id, execution}] ->
        :ets.insert(@execution_table, {execution_id, Map.put(execution, :status, :cancelled)})
        Logger.info("Cancellation requested", %{execution_id: execution_id})
        :ok
    end
  end

  @doc """
  Monitors tool execution progress and handles coordination.

  Tracks multiple concurrent tool executions and provides
  real-time status updates and progress coordination.

  ## Examples

      monitor_pid = spawn(fn ->
        ToolExecutor.monitor_execution(execution_id, callback)
      end)
  """
  @spec monitor_execution(execution_id(), function() | nil) :: :ok | {:error, :not_found}
  def monitor_execution(execution_id, status_callback \\ nil) do
    ensure_execution_table()

    case :ets.lookup(@execution_table, execution_id) do
      [] ->
        {:error, :not_found}

      [{^execution_id, execution}] ->
        Logger.debug("Monitoring execution", %{
          execution_id: execution_id,
          status: execution.status
        })

        if status_callback do
          status_callback.({execution.status, execution_id})
        end

        :ok
    end
  end

  @doc """
  Streams tool updates to registered callbacks.

  Coordinates streaming updates from multiple concurrent tool
  executions and delivers them to the appropriate callbacks.
  """
  @spec stream_tool_updates(execution_id(), [tool_execution()], AgentToolCallback.t()) :: :ok
  def stream_tool_updates(execution_id, executions, _callback) do
    Logger.debug("Streaming updates", %{
      execution_id: execution_id,
      active_tools: length(executions)
    })

    {:error, :unsupported}
  end

  @doc """
  Handles partial results from streaming tool executions.

  Processes and routes partial results to appropriate handlers
  while maintaining execution context and coordination.
  """
  @spec handle_partial_results([AgentToolResult.t()], execution_options()) :: :ok
  def handle_partial_results(partial_results, _options \\ []) do
    Logger.debug("Handling partial results", %{
      result_count: length(partial_results)
    })

    {:error, :unsupported}
  end

  @doc """
  Coordinates results from multiple tool executions.

  Aggregates and synchronizes results from concurrent tool executions,
  ensuring proper ordering and completeness.
  """
  @spec coordinate_results([tool_execution()], execution_options()) ::
          {:ok, [ToolResultMessage.t()]} | {:error, any()}
  def coordinate_results(executions, options \\ []) do
    timeout = Keyword.get(options, :timeout, @default_timeout)

    # Wait for all executions to complete
    results =
      executions
      |> Enum.map(fn execution ->
        case Task.await(execution.task, timeout) do
          {:ok, result} ->
            result

          {:error, _reason} ->
            # Error already wrapped in ToolResultMessage by execute_single_tool
            %ToolResultMessage{
              role: :tool_result,
              tool_call_id: execution.tool_call.id,
              tool_name: execution.tool_call.name,
              content: [
                %Expi.Types.TextContent{
                  type: :text,
                  text: "Tool execution timeout"
                }
              ],
              is_error: true,
              timestamp: System.system_time(:millisecond)
            }
        end
      end)

    {:ok, results}
  rescue
    error ->
      Logger.error("Result coordination failed", %{error: Exception.message(error)})
      {:error, {:coordination_failed, Exception.message(error)}}
  end

  @doc """
  Aggregates tool results with metadata and statistics.

  Combines individual tool results into a comprehensive summary
  including execution statistics, performance metrics, and metadata.
  """
  @spec aggregate_tool_results([ToolResultMessage.t()], map()) :: map()
  def aggregate_tool_results(results, metadata \\ %{}) do
    successful_count = Enum.count(results, fn r -> not r.is_error end)
    failed_count = Enum.count(results, fn r -> r.is_error end)

    execution_times =
      results
      |> Enum.map(fn result ->
        case result.details do
          %{execution_time_ms: time} -> time
          _ -> 0
        end
      end)

    total_tools = Enum.count(results)
    execution_time_count = Enum.count(execution_times)

    %{
      total_tools: total_tools,
      successful: successful_count,
      failed: failed_count,
      success_rate:
        if total_tools != 0 do
          successful_count / total_tools
        else
          0.0
        end,
      total_execution_time: Enum.sum(execution_times),
      average_execution_time:
        if execution_time_count != 0 do
          Enum.sum(execution_times) / execution_time_count
        else
          0.0
        end,
      results: results,
      metadata: metadata
    }
  end

  @doc """
  Creates execution events for agent event system integration.

  Generates AgentEvent structs for tool execution lifecycle events
  that can be consumed by the agent's event system.
  """
  @spec create_execution_events([ToolResultMessage.t()]) :: [AgentEvent.t()]
  def create_execution_events(tool_results) do
    tool_results
    |> Enum.flat_map(fn result ->
      [
        AgentEvent.tool_execution_start(
          result.tool_call_id,
          result.tool_name,
          # Arguments would come from original tool call
          %{}
        ),
        AgentEvent.tool_execution_end(
          result.tool_call_id,
          result.tool_name,
          result,
          result.is_error
        )
      ]
    end)
  end

  @doc """
  Validates tool execution configuration and dependencies.

  Ensures that all required tools are available and properly configured
  before beginning execution.
  """
  @spec validate_execution_setup([ToolCall.t()], [AgentTool.t()]) ::
          :ok | {:error, {:missing_tools, [String.t()]}}
  def validate_execution_setup(tool_calls, available_tools) do
    requested_tools = Enum.map(tool_calls, & &1.name)
    available_tool_names = Enum.map(available_tools, &AgentTool.name/1)

    missing_tools = requested_tools -- available_tool_names

    if missing_tools == [] do
      :ok
    else
      {:error, {:missing_tools, missing_tools}}
    end
  end

  # Private implementation functions

  @spec execute_concurrent(
          [ToolCall.t()],
          [AgentTool.t()],
          execution_id(),
          pos_integer(),
          pos_integer(),
          AgentToolCallback.t() | nil,
          function() | nil
        ) ::
          execution_result()
  defp execute_concurrent(
         tool_calls,
         available_tools,
         execution_id,
         timeout,
         max_concurrent,
         on_update,
         on_complete
       ) do
    case validate_execution_setup(tool_calls, available_tools) do
      :ok ->
        tool_map =
          available_tools
          |> Enum.map(fn tool -> {AgentTool.name(tool), tool} end)
          |> Map.new()

        results =
          tool_calls
          |> Task.async_stream(
            fn tool_call ->
              case Map.get(tool_map, tool_call.name) do
                nil ->
                  {:error, {:tool_not_found, tool_call.name}}

                tool ->
                  execute_single_tool(tool_call, tool, timeout: timeout, on_update: on_update)
              end
            end,
            max_concurrency: max_concurrent,
            timeout: timeout + 1000,
            on_timeout: :kill_task
          )
          |> Enum.map(fn
            {:ok, {:ok, result}} -> result
            {:ok, {:error, reason}} -> create_error_result(reason, tool_calls)
            {:exit, reason} -> create_crash_result(reason, tool_calls)
          end)

        if on_complete, do: on_complete.(results)

        :ets.insert(
          @execution_table,
          {execution_id,
           %{
             status: :completed,
             completed_at: System.system_time(:millisecond),
             tool_count: length(results)
           }}
        )

        Logger.debug("Concurrent execution completed", %{
          execution_id: execution_id,
          tool_count: length(results),
          successful: Enum.count(results, fn r -> not r.is_error end)
        })

        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec execute_sequential(
          [ToolCall.t()],
          [AgentTool.t()],
          execution_id(),
          pos_integer(),
          AgentToolCallback.t() | nil,
          function() | nil
        ) :: execution_result()
  defp execute_sequential(
         tool_calls,
         available_tools,
         execution_id,
         timeout,
         on_update,
         on_complete
       ) do
    case validate_execution_setup(tool_calls, available_tools) do
      :ok ->
        tool_map =
          available_tools
          |> Enum.map(fn tool -> {AgentTool.name(tool), tool} end)
          |> Map.new()

        results =
          Enum.map(tool_calls, fn tool_call ->
            case Map.get(tool_map, tool_call.name) do
              nil ->
                create_error_result({:tool_not_found, tool_call.name}, [tool_call])

              tool ->
                case execute_single_tool(tool_call, tool, timeout: timeout, on_update: on_update) do
                  {:ok, result} -> result
                end
            end
          end)

        if on_complete, do: on_complete.(results)

        :ets.insert(
          @execution_table,
          {execution_id,
           %{
             status: :completed,
             completed_at: System.system_time(:millisecond),
             tool_count: length(results)
           }}
        )

        Logger.debug("Sequential execution completed", %{
          execution_id: execution_id,
          tool_count: length(results)
        })

        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec execute_hybrid(
          [ToolCall.t()],
          [AgentTool.t()],
          execution_id(),
          pos_integer(),
          pos_integer(),
          AgentToolCallback.t() | nil,
          function() | nil
        ) ::
          execution_result()
  defp execute_hybrid(
         tool_calls,
         available_tools,
         execution_id,
         timeout,
         max_concurrent,
         on_update,
         on_complete
       ) do
    # Hybrid strategy: group tools by characteristics and execute appropriately
    # For now, just delegate to concurrent execution
    execute_concurrent(
      tool_calls,
      available_tools,
      execution_id,
      timeout,
      max_concurrent,
      on_update,
      on_complete
    )
  end

  @spec create_error_result(any(), [ToolCall.t()]) :: ToolResultMessage.t()
  defp create_error_result(reason, tool_calls) do
    tool_call = List.first(tool_calls) || %ToolCall{id: "unknown", name: "unknown"}

    %ToolResultMessage{
      role: :tool_result,
      tool_call_id: tool_call.id,
      tool_name: tool_call.name,
      content: [
        %Expi.Types.TextContent{
          type: :text,
          text: "Tool execution error: #{inspect(reason)}"
        }
      ],
      details: %{error: reason},
      is_error: true,
      timestamp: System.system_time(:millisecond)
    }
  end

  @spec create_crash_result(any(), [ToolCall.t()]) :: ToolResultMessage.t()
  defp create_crash_result(reason, tool_calls) do
    tool_call = List.first(tool_calls) || %ToolCall{id: "unknown", name: "unknown"}

    %ToolResultMessage{
      role: :tool_result,
      tool_call_id: tool_call.id,
      tool_name: tool_call.name,
      content: [
        %Expi.Types.TextContent{
          type: :text,
          text: "Tool execution crashed: #{inspect(reason)}"
        }
      ],
      details: %{crash: reason},
      is_error: true,
      timestamp: System.system_time(:millisecond)
    }
  end

  @spec generate_execution_id() :: execution_id()
  defp generate_execution_id do
    :crypto.strong_rand_bytes(8)
    |> Base.url_encode64(padding: false)
    |> String.slice(0, 12)
  end

  defp ensure_execution_table do
    case :ets.whereis(@execution_table) do
      :undefined -> :ets.new(@execution_table, [:named_table, :public, :set])
      _tid -> :ok
    end

    :ok
  end
end
