defmodule Expi.AI.Telemetry do
  @moduledoc """
  Telemetry integration for monitoring AI module metrics.
  Tracks request/response times, token usage, costs, and error rates.
  """

  require Logger

  @doc """
  Emit telemetry events for HTTP request metrics.
  """
  @spec emit_request_start(String.t(), String.t(), map()) :: :ok
  def emit_request_start(provider, model_id, metadata \\ %{}) do
    :telemetry.execute(
      [:expi, :request, :start],
      %{system_time: System.system_time()},
      %{provider: provider, model_id: model_id}
      |> Map.merge(metadata)
    )
  end

  @doc """
  Emit telemetry events for completed HTTP requests.
  """
  @spec emit_request_stop(String.t(), String.t(), integer(), map()) :: :ok
  def emit_request_stop(provider, model_id, duration_ms, metadata \\ %{}) do
    :telemetry.execute(
      [:expi, :request, :stop],
      %{duration: duration_ms},
      %{provider: provider, model_id: model_id}
      |> Map.merge(metadata)
    )
  end

  @doc """
  Emit telemetry events for request errors.
  """
  @spec emit_request_error(String.t(), String.t(), atom(), integer(), map()) :: :ok
  def emit_request_error(provider, model_id, error_type, duration_ms, metadata \\ %{}) do
    :telemetry.execute(
      [:expi, :request, :error],
      %{duration: duration_ms},
      %{provider: provider, model_id: model_id, error_type: error_type}
      |> Map.merge(metadata)
    )
  end

  @doc """
  Emit telemetry events for token usage tracking.
  """
  @spec emit_token_usage(String.t(), String.t(), integer(), integer(), map()) :: :ok
  def emit_token_usage(provider, model_id, input_tokens, output_tokens, metadata \\ %{}) do
    :telemetry.execute(
      [:expi, :tokens, :usage],
      %{input_tokens: input_tokens, output_tokens: output_tokens, total_tokens: input_tokens + output_tokens},
      %{provider: provider, model_id: model_id}
      |> Map.merge(metadata)
    )
  end

  @doc """
  Emit telemetry events for cost tracking.
  """
  @spec emit_cost_tracking(String.t(), String.t(), float(), float(), float(), map()) :: :ok
  def emit_cost_tracking(provider, model_id, input_cost, output_cost, total_cost, metadata \\ %{}) do
    :telemetry.execute(
      [:expi, :cost, :tracking],
      %{input_cost: input_cost, output_cost: output_cost, total_cost: total_cost},
      %{provider: provider, model_id: model_id}
      |> Map.merge(metadata)
    )
  end

  @doc """
  Emit telemetry events for streaming metrics.
  """
  @spec emit_stream_event(String.t(), String.t(), atom(), map()) :: :ok
  def emit_stream_event(provider, model_id, event_type, metadata \\ %{}) do
    :telemetry.execute(
      [:expi, :stream, :event],
      %{count: 1},
      %{provider: provider, model_id: model_id, event_type: event_type}
      |> Map.merge(metadata)
    )
  end

  @doc """
  Emit streaming session duration metrics.
  """
  @spec emit_stream_session(String.t(), String.t(), integer(), integer(), map()) :: :ok
  def emit_stream_session(provider, model_id, duration_ms, event_count, metadata \\ %{}) do
    :telemetry.execute(
      [:expi, :stream, :session],
      %{duration: duration_ms, event_count: event_count},
      %{provider: provider, model_id: model_id}
      |> Map.merge(metadata)
    )
  end

  # Collector functions called by telemetry_poller

  @doc """
  Collect HTTP connection pool metrics.
  """
  def collect_http_metrics do
    try do
      # Get Hackney pool stats if available
      pool_stats = :hackney_pool.get_stats(:ai_pool)
      
      :telemetry.execute(
        [:expi, :http, :pool_stats],
        %{
          in_use_count: Keyword.get(pool_stats, :in_use_count, 0),
          free_count: Keyword.get(pool_stats, :free_count, 0),
          queue_count: Keyword.get(pool_stats, :queue_count, 0)
        },
        %{pool: :ai_pool}
      )
    rescue
      _ -> :ok  # Ignore errors if pool stats not available
    end
  end

  @doc """
  Collect aggregated token usage metrics from ETS or other storage.
  """
  def collect_token_metrics do
    # This would typically read from an ETS table or other storage
    # For now, emit a heartbeat to indicate the collector is running
    :telemetry.execute(
      [:expi, :metrics, :heartbeat],
      %{timestamp: System.system_time()},
      %{collector: :token_metrics}
    )
  end

  @doc """
  Collect cost metrics and totals.
  """
  def collect_cost_metrics do
    # This would typically aggregate cost data from storage
    # For now, emit a heartbeat to indicate the collector is running
    :telemetry.execute(
      [:expi, :metrics, :heartbeat],
      %{timestamp: System.system_time()},
      %{collector: :cost_metrics}
    )
  end

  # Utility functions for timing operations

  @doc """
  Execute a function while timing it and emitting telemetry events.
  """
  @spec time_operation(String.t(), String.t(), (() -> any()), map()) :: any()
  def time_operation(provider, model_id, fun, metadata \\ %{}) do
    emit_request_start(provider, model_id, metadata)
    start_time = System.monotonic_time(:millisecond)
    
    try do
      result = fun.()
      duration = System.monotonic_time(:millisecond) - start_time
      emit_request_stop(provider, model_id, duration, metadata)
      result
    rescue
      error ->
        duration = System.monotonic_time(:millisecond) - start_time
        error_type = error.__struct__ |> to_string() |> String.replace("Elixir.", "")
        emit_request_error(provider, model_id, String.to_atom(error_type), duration, metadata)
        reraise error, __STACKTRACE__
    end
  end

  @doc """
  Time an operation and return both result and duration.
  """
  @spec time_operation_with_duration((() -> any())) :: {any(), integer()}
  def time_operation_with_duration(fun) do
    start_time = System.monotonic_time(:millisecond)
    result = fun.()
    duration = System.monotonic_time(:millisecond) - start_time
    {result, duration}
  end

  # Helper functions for setting up telemetry handlers

  @doc """
  Attach default telemetry handlers for logging and monitoring.
  """
  @spec attach_default_handlers() :: :ok
  def attach_default_handlers do
    events = [
      [:expi, :request, :start],
      [:expi, :request, :stop], 
      [:expi, :request, :error],
      [:expi, :tokens, :usage],
      [:expi, :cost, :tracking],
      [:expi, :stream, :event],
      [:expi, :stream, :session]
    ]

    :telemetry.attach_many(
      "expi-ai-logger",
      events,
      &handle_telemetry_event/4,
      %{log_level: :info}
    )

    Logger.info("Expi telemetry handlers attached")
  end

  @doc """
  Detach all telemetry handlers.
  """
  @spec detach_handlers() :: :ok
  def detach_handlers do
    :telemetry.detach("expi-ai-logger")
    Logger.info("Expi telemetry handlers detached")
  end

  # Private telemetry handler function

  defp handle_telemetry_event([:expi, :request, :stop], measurements, metadata, _config) do
    Logger.info("Request completed", 
      provider: metadata.provider,
      model_id: metadata.model_id,
      duration_ms: measurements.duration
    )
  end

  defp handle_telemetry_event([:expi, :request, :error], measurements, metadata, _config) do
    Logger.warning("Request failed",
      provider: metadata.provider,
      model_id: metadata.model_id,
      error_type: metadata.error_type,
      duration_ms: measurements.duration
    )
  end

  defp handle_telemetry_event([:expi, :tokens, :usage], measurements, metadata, _config) do
    Logger.debug("Token usage",
      provider: metadata.provider,
      model_id: metadata.model_id,
      input_tokens: measurements.input_tokens,
      output_tokens: measurements.output_tokens,
      total_tokens: measurements.total_tokens
    )
  end

  defp handle_telemetry_event([:expi, :cost, :tracking], measurements, metadata, _config) do
    Logger.info("Cost tracking",
      provider: metadata.provider,
      model_id: metadata.model_id,
      total_cost: measurements.total_cost
    )
  end

  defp handle_telemetry_event(_event, _measurements, _metadata, _config) do
    # Ignore other events
    :ok
  end
end