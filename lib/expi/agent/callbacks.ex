defmodule Expi.Agent.Callbacks do
  @moduledoc """
  Agent callback registration and management system.

  This module provides comprehensive callback management for the agent event
  system, including registration, invocation, filtering, and lifecycle management.
  It supports multiple callback types and patterns for flexible integration
  with different application architectures.

  ## Core Functions

  - **Registration**: `register_callback/2`, `unregister_callback/1`, `list_callbacks/1`
  - **Invocation**: `invoke_callback/2`, `invoke_callbacks/2`, `batch_invoke/3`
  - **Management**: `create_registry/0`, `cleanup_registry/1`, `get_callback_stats/1`
  - **Utilities**: `validate_callback/1`, `filter_callbacks/2`, `callback_health_check/1`

  ## Callback Types

  - **Function Callbacks**: Simple functions that receive events
  - **Process Callbacks**: Send messages to registered processes
  - **Module Callbacks**: Call specific module functions with events
  - **Custom Callbacks**: User-defined callback implementations

  ## Registry Management

  Callbacks are organized in registries that provide:
  - Thread-safe registration and deregistration
  - Callback lifecycle management
  - Health monitoring and automatic cleanup
  - Performance monitoring and statistics
  """

  alias Expi.Agent.Types.AgentEvent

  require Logger

  @type callback_spec ::
          function_callback() | process_callback() | module_callback() | custom_callback()
  @type callback_id :: String.t()
  @type callback_registry :: %{
          callbacks: %{callback_id() => callback_spec()},
          stats: %{callback_id() => callback_stats()},
          created_at: pos_integer(),
          last_cleanup: pos_integer()
        }

  @type function_callback :: %{
          type: :function,
          id: callback_id(),
          function: (AgentEvent.t() -> any()),
          metadata: map()
        }

  @type process_callback :: %{
          type: :process,
          id: callback_id(),
          pid: pid(),
          message_format: :simple | :detailed | :custom,
          message_transformer: (AgentEvent.t() -> any()) | nil,
          metadata: map()
        }

  @type module_callback :: %{
          type: :module,
          id: callback_id(),
          module: atom(),
          function: atom(),
          args: [any()],
          metadata: map()
        }

  @type custom_callback :: %{
          type: :custom,
          id: callback_id(),
          handler: any(),
          invoke_function: (any(), AgentEvent.t() -> any()),
          metadata: map()
        }

  @type callback_stats :: %{
          invocation_count: non_neg_integer(),
          total_execution_time: non_neg_integer(),
          average_execution_time: float(),
          last_invoked: pos_integer() | nil,
          error_count: non_neg_integer(),
          last_error: String.t() | nil
        }

  @type invocation_options :: [
          timeout: pos_integer(),
          async: boolean(),
          retry_count: non_neg_integer(),
          on_error: :ignore | :log | :raise | function()
        ]

  @stats_table :expi_callback_stats

  @doc """
  Creates a new callback registry.

  A callback registry manages a collection of callbacks with lifecycle
  management, statistics tracking, and health monitoring.

  ## Examples

      registry = Callbacks.create_registry()
      
      # Register callbacks
      {:ok, callback_id} = Callbacks.register_callback(registry, function_callback)
      
      # Invoke all callbacks
      Callbacks.invoke_callbacks(registry, event)
  """
  @spec create_registry() :: callback_registry()
  def create_registry do
    %{
      callbacks: %{},
      stats: %{},
      created_at: System.system_time(:millisecond),
      last_cleanup: System.system_time(:millisecond)
    }
  end

  @doc """
  Registers a callback in the registry.

  ## Parameters

  - `registry` - The callback registry
  - `callback_spec` - The callback specification to register

  ## Examples

      # Function callback
      function_callback = %{
        type: :function,
        id: "ui_updater",
        function: fn event -> update_ui(event) end,
        metadata: %{component: "main_ui"}
      }
      
      {:ok, registry, callback_id} = Callbacks.register_callback(registry, function_callback)
      
      # Process callback
      process_callback = %{
        type: :process,
        id: "event_logger",
        pid: logger_pid,
        message_format: :detailed,
        metadata: %{log_level: :info}
      }
      
      {:ok, registry, callback_id} = Callbacks.register_callback(registry, process_callback)
      
      # Module callback
      module_callback = %{
        type: :module,
        id: "metrics_collector",
        module: MyApp.Metrics,
        function: :record_agent_event,
        args: [],
        metadata: %{namespace: "agent_events"}
      }
      
      {:ok, registry, callback_id} = Callbacks.register_callback(registry, module_callback)
  """
  @spec register_callback(callback_registry(), map()) ::
          {:ok, callback_registry(), callback_id()} | {:error, any()}
  def register_callback(registry, callback_spec) do
    ensure_stats_table()

    case validate_callback(callback_spec) do
      :ok ->
        callback_id = Map.get(callback_spec, :id, generate_callback_id())

        # Create full callback spec with generated ID if needed
        full_callback = Map.put(callback_spec, :id, callback_id)

        # Initialize stats
        stats = %{
          invocation_count: 0,
          total_execution_time: 0,
          average_execution_time: 0.0,
          last_invoked: nil,
          error_count: 0,
          last_error: nil
        }

        updated_registry =
          registry
          |> put_in([:callbacks, callback_id], full_callback)
          |> put_in([:stats, callback_id], stats)

        :ets.insert(@stats_table, {callback_id, stats})

        Logger.debug("Callback registered", %{
          callback_id: callback_id,
          callback_type: callback_spec.type
        })

        {:ok, updated_registry, callback_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Unregisters a callback from the registry.

  ## Examples

      {:ok, updated_registry} = Callbacks.unregister_callback(registry, callback_id)
  """
  @spec unregister_callback(callback_registry(), callback_id()) ::
          {:ok, callback_registry()} | {:error, :not_found}
  def unregister_callback(registry, callback_id) do
    case Map.get(registry.callbacks, callback_id) do
      nil ->
        {:error, :not_found}

      _callback ->
        updated_registry =
          registry
          |> update_in([:callbacks], &Map.delete(&1, callback_id))
          |> update_in([:stats], &Map.delete(&1, callback_id))

        :ets.delete(@stats_table, callback_id)

        Logger.debug("Callback unregistered", %{callback_id: callback_id})

        {:ok, updated_registry}
    end
  end

  @doc """
  Lists all callbacks in the registry with optional filtering.

  ## Examples

      # List all callbacks
      all_callbacks = Callbacks.list_callbacks(registry)
      
      # List only function callbacks
      function_callbacks = Callbacks.list_callbacks(registry, type: :function)
      
      # List callbacks with specific metadata
      ui_callbacks = Callbacks.list_callbacks(registry, 
        metadata_filter: fn meta -> Map.get(meta, :component) == "ui" end
      )
  """
  @spec list_callbacks(callback_registry(), keyword()) :: [callback_spec()]
  def list_callbacks(registry, filters \\ []) do
    type_filter = Keyword.get(filters, :type)
    metadata_filter = Keyword.get(filters, :metadata_filter)

    registry.callbacks
    |> Map.values()
    |> Enum.filter(fn callback ->
      type_match =
        if type_filter do
          callback.type == type_filter
        else
          true
        end

      metadata_match =
        if metadata_filter do
          metadata_filter.(callback.metadata || %{})
        else
          true
        end

      type_match and metadata_match
    end)
  end

  @doc """
  Invokes a single callback with an event.

  ## Examples

      # Basic invocation
      result = Callbacks.invoke_callback(callback, event)
      
      # With timeout and error handling
      result = Callbacks.invoke_callback(callback, event,
        timeout: 10_000,
        on_error: :log
      )
      
      # Asynchronous invocation
      Callbacks.invoke_callback(callback, event, async: true)
  """
  @spec invoke_callback(callback_spec(), AgentEvent.t(), invocation_options()) :: any()
  def invoke_callback(callback, event, options \\ []) do
    timeout = Keyword.get(options, :timeout, 5_000)
    async = Keyword.get(options, :async, false)
    on_error = Keyword.get(options, :on_error, :log)

    invocation = fn ->
      start_time = System.monotonic_time(:millisecond)

      try do
        result = do_invoke_callback(callback, event)
        execution_time = System.monotonic_time(:millisecond) - start_time
        update_stats(get_callback_id(callback), execution_time, nil)

        Logger.debug("Callback invoked successfully", %{
          callback_id: get_callback_id(callback),
          event_type: event.type,
          execution_time: execution_time
        })

        result
      rescue
        error ->
          execution_time = System.monotonic_time(:millisecond) - start_time
          error_message = Exception.message(error)

          update_stats(get_callback_id(callback), execution_time, error_message)

          Logger.error("Callback invocation failed", %{
            callback_id: get_callback_id(callback),
            event_type: event.type,
            execution_time: execution_time,
            error: error_message
          })

          case on_error do
            :ignore -> nil
            # Already logged
            :log -> nil
            :raise -> reraise error, __STACKTRACE__
            handler when is_function(handler) -> handler.(error, callback, event)
          end
      end
    end

    if async do
      Task.start(invocation)
      :ok
    else
      Task.async(invocation)
      |> Task.await(timeout)
    end
  end

  @doc """
  Invokes all callbacks in a registry with an event.

  ## Examples

      # Invoke all callbacks
      results = Callbacks.invoke_callbacks(registry, event)
      
      # Invoke with filtering
      results = Callbacks.invoke_callbacks(registry, event,
        filter: fn callback -> callback.type == :function end
      )
      
      # Parallel invocation with timeout
      results = Callbacks.invoke_callbacks(registry, event,
        mode: :parallel,
        timeout: 15_000
      )
  """
  @spec invoke_callbacks(callback_registry(), AgentEvent.t(), keyword()) ::
          [any()] | {:error, any()}
  def invoke_callbacks(registry, event, options \\ []) do
    mode = Keyword.get(options, :mode, :sequential)
    filter = Keyword.get(options, :filter)
    timeout = Keyword.get(options, :timeout, 30_000)

    callbacks =
      if filter do
        registry.callbacks
        |> Map.values()
        |> Enum.filter(filter)
      else
        Map.values(registry.callbacks)
      end

    case mode do
      :sequential ->
        Enum.map(callbacks, fn callback ->
          invoke_callback(callback, event, options)
        end)

      :parallel ->
        callbacks
        |> Task.async_stream(
          fn callback ->
            invoke_callback(callback, event, Keyword.put(options, :async, false))
          end,
          timeout: timeout,
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, reason} -> {:error, reason}
        end)
    end
  end

  @doc """
  Batch invokes callbacks with multiple events efficiently.

  ## Examples

      events = [event1, event2, event3]
      
      # Sequential batch processing
      results = Callbacks.batch_invoke(registry, events, mode: :sequential)
      
      # Parallel batch processing
      results = Callbacks.batch_invoke(registry, events, 
        mode: :parallel,
        batch_size: 10
      )
  """
  @spec batch_invoke(callback_registry(), [AgentEvent.t()], keyword()) ::
          [[any()]] | {:error, any()}
  def batch_invoke(registry, events, options \\ []) do
    mode = Keyword.get(options, :mode, :sequential)
    batch_size = Keyword.get(options, :batch_size, 50)

    case mode do
      :sequential ->
        Enum.map(events, fn event ->
          invoke_callbacks(registry, event, options)
        end)

      :parallel ->
        events
        |> Enum.chunk_every(batch_size)
        |> Task.async_stream(
          fn event_batch ->
            Enum.map(event_batch, fn event ->
              invoke_callbacks(registry, event, Keyword.put(options, :mode, :sequential))
            end)
          end,
          timeout: 60_000,
          max_concurrency: System.schedulers_online()
        )
        |> Enum.flat_map(fn
          {:ok, results} -> results
          {:exit, _reason} -> []
        end)
    end
  end

  @doc """
  Gets statistics for a specific callback.

  ## Examples

      stats = Callbacks.get_callback_stats(registry, callback_id)
      
      IO.puts("Invocations: " <> to_string(stats.invocation_count))
      IO.puts("Average time: " <> to_string(stats.average_execution_time) <> "ms")
      IO.puts("Error rate: " <> to_string(stats.error_count / stats.invocation_count * 100) <> "%")
  """
  @spec get_callback_stats(callback_registry(), callback_id()) ::
          {:ok, callback_stats()} | {:error, :not_found}
  def get_callback_stats(registry, callback_id) do
    ensure_stats_table()

    case :ets.lookup(@stats_table, callback_id) do
      [{^callback_id, stats}] ->
        {:ok, stats}

      [] ->
        case Map.get(registry.stats, callback_id) do
          nil -> {:error, :not_found}
          stats -> {:ok, stats}
        end
    end
  end

  @doc """
  Gets comprehensive statistics for all callbacks in the registry.

  ## Examples

      summary = Callbacks.get_registry_stats(registry)
      
      IO.puts("Total callbacks: " <> to_string(summary.total_callbacks))
      IO.puts("Total invocations: " <> to_string(summary.total_invocations))
      IO.puts("Overall error rate: " <> to_string(summary.error_rate * 100) <> "%")
  """
  @spec get_registry_stats(callback_registry()) :: map()
  def get_registry_stats(registry) do
    stats = Map.values(registry.stats)

    total_callbacks = length(stats)
    total_invocations = Enum.sum(Enum.map(stats, & &1.invocation_count))
    total_errors = Enum.sum(Enum.map(stats, & &1.error_count))
    total_execution_time = Enum.sum(Enum.map(stats, & &1.total_execution_time))

    %{
      total_callbacks: total_callbacks,
      total_invocations: total_invocations,
      total_errors: total_errors,
      error_rate:
        if total_invocations > 0 do
          total_errors / total_invocations
        else
          0.0
        end,
      average_execution_time:
        if total_invocations > 0 do
          total_execution_time / total_invocations
        else
          0.0
        end,
      registry_age: System.system_time(:millisecond) - registry.created_at,
      last_cleanup: registry.last_cleanup
    }
  end

  @doc """
  Validates a callback specification.

  ## Examples

      case Callbacks.validate_callback(callback_spec) do
        :ok -> register_callback(callback_spec)
        {:error, reason} -> handle_invalid_callback(reason)
      end
  """
  @spec validate_callback(map()) :: :ok | {:error, String.t()}
  def validate_callback(callback_spec) do
    case callback_spec.type do
      :function ->
        validate_function_callback(callback_spec)

      :process ->
        validate_process_callback(callback_spec)

      :module ->
        validate_module_callback(callback_spec)

      :custom ->
        validate_custom_callback(callback_spec)

      _ ->
        {:error, "Unknown callback type: #{inspect(callback_spec.type)}"}
    end
  end

  @doc """
  Filters callbacks based on criteria.

  ## Examples

      # Filter by type
      function_callbacks = Callbacks.filter_callbacks(callbacks, type: :function)
      
      # Filter by custom criteria
      active_callbacks = Callbacks.filter_callbacks(callbacks, fn callback ->
        case callback.type do
          :process -> Process.alive?(callback.pid)
          _ -> true
        end
      end)
  """
  @spec filter_callbacks([callback_spec()], keyword() | function()) :: [callback_spec()]
  def filter_callbacks(callbacks, filter) when is_function(filter) do
    Enum.filter(callbacks, filter)
  end

  def filter_callbacks(callbacks, criteria) when is_list(criteria) do
    Enum.filter(callbacks, fn callback ->
      Enum.all?(criteria, fn {key, value} ->
        Map.get(callback, key) == value
      end)
    end)
  end

  @doc """
  Performs a health check on callbacks, removing dead processes and invalid callbacks.

  ## Examples

      {:ok, cleaned_registry, removed_count} = Callbacks.callback_health_check(registry)
      
      if removed_count > 0 do
        Logger.info("Removed " <> to_string(removed_count) <> " dead callbacks")
      end
  """
  @spec callback_health_check(callback_registry()) ::
          {:ok, callback_registry(), non_neg_integer()}
  def callback_health_check(registry) do
    {valid_callbacks, removed_count} =
      Enum.reduce(registry.callbacks, {%{}, 0}, fn {id, callback}, {acc, count} ->
        case is_callback_healthy?(callback) do
          true ->
            {Map.put(acc, id, callback), count}

          false ->
            Logger.debug("Removing unhealthy callback", %{callback_id: id, type: callback.type})
            {acc, count + 1}
        end
      end)

    # Remove stats for removed callbacks
    valid_stats = Map.take(registry.stats, Map.keys(valid_callbacks))

    cleaned_registry = %{
      registry
      | callbacks: valid_callbacks,
        stats: valid_stats,
        last_cleanup: System.system_time(:millisecond)
    }

    {:ok, cleaned_registry, removed_count}
  end

  @doc """
  Cleans up the registry by removing old statistics and performing maintenance.

  ## Examples

      cleaned_registry = Callbacks.cleanup_registry(registry, max_age_ms: 3600_000)
  """
  @spec cleanup_registry(callback_registry(), keyword()) :: callback_registry()
  def cleanup_registry(registry, options \\ []) do
    # 24 hours default
    _max_age_ms = Keyword.get(options, :max_age_ms, 86_400_000)

    # Perform health check
    {:ok, health_checked_registry, _removed} = callback_health_check(registry)

    # Additional cleanup logic would go here
    # For now, just update the cleanup timestamp
    %{health_checked_registry | last_cleanup: System.system_time(:millisecond)}
  end

  @doc """
  Gets the callback ID from a callback specification.

  ## Examples

      callback_id = Callbacks.get_callback_id(callback)
  """
  @spec get_callback_id(callback_spec()) :: callback_id()
  def get_callback_id(callback) do
    Map.get(callback, :id, "unknown")
  end

  @doc """
  Creates callback specifications for common use cases.

  ## Examples

      # Function callback
      ui_callback = Callbacks.create_function_callback("ui_updates", &update_ui/1)
      
      # Process callback
      logger_callback = Callbacks.create_process_callback("logger", logger_pid)
      
      # Module callback
      metrics_callback = Callbacks.create_module_callback("metrics", MyApp.Metrics, :record_event)
  """
  @spec create_function_callback(String.t(), function(), map()) :: function_callback()
  def create_function_callback(id, function, metadata \\ %{}) do
    %{
      type: :function,
      id: id,
      function: function,
      metadata: metadata
    }
  end

  @spec create_process_callback(String.t(), pid(), atom(), map()) :: process_callback()
  def create_process_callback(id, pid, message_format \\ :simple, metadata \\ %{}) do
    %{
      type: :process,
      id: id,
      pid: pid,
      message_format: message_format,
      message_transformer: nil,
      metadata: metadata
    }
  end

  @spec create_module_callback(String.t(), atom(), atom(), [any()], map()) :: module_callback()
  def create_module_callback(id, module, function, args \\ [], metadata \\ %{}) do
    %{
      type: :module,
      id: id,
      module: module,
      function: function,
      args: args,
      metadata: metadata
    }
  end

  # Private implementation functions

  @spec do_invoke_callback(callback_spec(), AgentEvent.t()) :: any()
  defp do_invoke_callback(%{type: :function, function: func}, event) do
    func.(event)
  end

  defp do_invoke_callback(%{type: :process, pid: pid, message_format: format} = callback, event) do
    message =
      case format do
        :simple ->
          {:agent_event, event.type}

        :detailed ->
          {:agent_event, event}

        :custom ->
          if callback.message_transformer do
            callback.message_transformer.(event)
          else
            {:agent_event, event}
          end
      end

    send(pid, message)
    :ok
  end

  defp do_invoke_callback(%{type: :module, module: mod, function: func, args: args}, event) do
    apply(mod, func, [event | args])
  end

  defp do_invoke_callback(%{type: :custom, handler: handler, invoke_function: invoke_fn}, event) do
    invoke_fn.(handler, event)
  end

  @spec validate_function_callback(map()) :: :ok | {:error, String.t()}
  defp validate_function_callback(callback) do
    cond do
      not is_function(callback.function) ->
        {:error, "Function callback must have a callable function"}

      not is_function(callback.function, 1) ->
        {:error, "Function callback must accept exactly 1 argument (the event)"}

      true ->
        :ok
    end
  end

  @spec validate_process_callback(map()) :: :ok | {:error, String.t()}
  defp validate_process_callback(callback) do
    cond do
      not is_pid(callback.pid) ->
        {:error, "Process callback must have a valid PID"}

      not Process.alive?(callback.pid) ->
        {:error, "Process callback PID is not alive"}

      callback.message_format not in [:simple, :detailed, :custom] ->
        {:error, "Invalid message format for process callback"}

      callback.message_format == :custom and is_nil(callback.message_transformer) ->
        {:error, "Custom message format requires message_transformer function"}

      true ->
        :ok
    end
  end

  @spec validate_module_callback(map()) :: :ok | {:error, String.t()}
  defp validate_module_callback(callback) do
    cond do
      not is_atom(callback.module) ->
        {:error, "Module callback must specify a valid module atom"}

      not is_atom(callback.function) ->
        {:error, "Module callback must specify a valid function atom"}

      not function_exported?(callback.module, callback.function, length(callback.args) + 1) ->
        {:error, "Module callback function does not exist or has wrong arity"}

      true ->
        :ok
    end
  end

  @spec validate_custom_callback(map()) :: :ok | {:error, String.t()}
  defp validate_custom_callback(callback) do
    cond do
      is_nil(callback.handler) ->
        {:error, "Custom callback must have a handler"}

      not is_function(callback.invoke_function, 2) ->
        {:error, "Custom callback must have invoke_function with arity 2"}

      true ->
        :ok
    end
  end

  @spec is_callback_healthy?(callback_spec()) :: boolean()
  defp is_callback_healthy?(%{type: :process, pid: pid}) do
    Process.alive?(pid)
  end

  defp is_callback_healthy?(%{type: :module, module: mod, function: func, args: args}) do
    function_exported?(mod, func, length(args) + 1)
  end

  defp is_callback_healthy?(%{type: :function, function: func}) do
    is_function(func, 1)
  end

  defp is_callback_healthy?(%{type: :custom, invoke_function: func}) do
    is_function(func, 2)
  end

  defp is_callback_healthy?(_), do: false

  @spec generate_callback_id() :: String.t()
  defp generate_callback_id do
    :crypto.strong_rand_bytes(8)
    |> Base.url_encode64(padding: false)
    |> String.slice(0, 12)
    |> String.downcase()
  end

  defp ensure_stats_table do
    case :ets.whereis(@stats_table) do
      :undefined -> :ets.new(@stats_table, [:named_table, :public, :set])
      _tid -> :ok
    end

    :ok
  end

  defp update_stats(callback_id, execution_time, error_message) do
    ensure_stats_table()

    current =
      case :ets.lookup(@stats_table, callback_id) do
        [{^callback_id, stats}] ->
          stats

        [] ->
          %{
            invocation_count: 0,
            total_execution_time: 0,
            average_execution_time: 0.0,
            last_invoked: nil,
            error_count: 0,
            last_error: nil
          }
      end

    invocation_count = current.invocation_count + 1
    total_execution_time = current.total_execution_time + execution_time
    error_count = if error_message, do: current.error_count + 1, else: current.error_count

    updated = %{
      current
      | invocation_count: invocation_count,
        total_execution_time: total_execution_time,
        average_execution_time: total_execution_time / invocation_count,
        last_invoked: System.system_time(:millisecond),
        error_count: error_count,
        last_error: error_message || current.last_error
    }

    :ets.insert(@stats_table, {callback_id, updated})
    :ok
  end
end
