defmodule Expi.Agent.Config do
  @moduledoc """
  Agent configuration management and validation.

  This module provides functions for creating, validating, and working with
  agent configuration options. It handles default values, validation rules,
  and configuration merging for flexible agent setup.

  ## Core Functions

  - **Creation**: `new/1`, `default/0`, `from_keywords/1`
  - **Validation**: `validate/1`, `validate_functions/1`
  - **Merging**: `merge/2`, `apply_defaults/1`
  - **Utilities**: `get_stream_fn/1`, `get_auth_fn/1`
  """

  alias Expi.Agent.Types.AgentOptions

  alias Expi.Agent.Message

  @type config_error :: {:error, :invalid_config | :invalid_function | atom()}

  @doc """
  Creates a new agent configuration with validation.

  ## Parameters

  - `options` - Map or keyword list of configuration options

  ## Examples

      # Basic configuration
      {:ok, config} = AgentConfig.new(%{
        session_id: "user_123",
        steering_mode: :one_at_a_time
      })

      # Advanced configuration with custom functions
      {:ok, config} = AgentConfig.new(%{
        convert_to_llm: fn messages ->
          # Custom message conversion logic
          filtered = Enum.filter(messages, &should_send_to_llm?/1)
          {:ok, Message.filter_for_llm(filtered)}
        end,
        get_api_key: fn provider ->
          # Custom auth logic
          case MyAuth.get_key(provider) do
            {:ok, key} -> key
            _ -> nil
          end
        end,
        max_retry_delay_ms: 60_000
      })

  ## Returns

  - `{:ok, %AgentOptions{}}` - Valid configuration
  - `{:error, reason}` - Invalid configuration
  """
  @spec new(map() | keyword()) :: {:ok, AgentOptions.t()} | config_error()
  def new(options) when is_list(options) do
    options |> Map.new() |> new()
  end

  def new(options) when is_map(options) do
    config = struct(AgentOptions.default(), options)

    case validate(config) do
      :ok -> {:ok, config}
      {:error, reason} -> {:error, reason}
    end
  end

  def new(_), do: {:error, :invalid_config}

  @doc """
  Creates default agent configuration.

  Provides sensible defaults for all configuration options.

  ## Examples

      config = AgentConfig.default()

      # All defaults are set:
      assert config.steering_mode == :all
      assert config.follow_up_mode == :all
      assert config.max_retry_delay_ms == 30_000
  """
  @spec default() :: AgentOptions.t()
  def default do
    AgentOptions.default()
  end

  @doc """
  Creates configuration from keyword list with defaults applied.

  Convenience function for common use cases.

  ## Examples

      config = AgentConfig.from_keywords([
        session_id: "chat_456",
        steering_mode: :one_at_a_time,
        max_retry_delay_ms: 45_000
      ])
  """
  @spec from_keywords(keyword()) :: AgentOptions.t()
  def from_keywords(keywords) do
    case new(keywords) do
      {:ok, config} -> config
      # Fallback to defaults on error
      {:error, _reason} -> default()
    end
  end

  @doc """
  Validates an agent configuration structure.

  Checks all fields for proper types and values, including custom functions.

  ## Examples

      case AgentConfig.validate(config) do
        :ok -> start_agent(config)
        {:error, reason} -> handle_config_error(reason)
      end
  """
  @spec validate(AgentOptions.t()) :: :ok | config_error()
  def validate(%AgentOptions{} = config) do
    with :ok <- validate_basic_fields(config),
         :ok <- validate_functions(config),
         :ok <- validate_modes(config) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(_), do: {:error, :invalid_config}

  @doc """
  Validates that custom functions in the configuration are properly formed.

  Checks function arities and basic structure without executing them.

  ## Examples

      case AgentConfig.validate_functions(config) do
        :ok -> proceed_with_config(config)
        {:error, :invalid_function} -> fix_function_config()
      end
  """
  @spec validate_functions(AgentOptions.t()) :: :ok | config_error()
  def validate_functions(%AgentOptions{} = config) do
    with :ok <- validate_convert_function(config.convert_to_llm),
         :ok <- validate_transform_function(config.transform_context),
         :ok <- validate_stream_function(config.stream_fn),
         :ok <- validate_auth_function(config.get_api_key) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Merges two configurations, with the second taking precedence.

  Useful for applying user overrides to default configurations.

  ## Examples

      base_config = AgentConfig.default()
      user_overrides = %AgentOptions{session_id: "user_789", steering_mode: :one_at_a_time}

      final_config = AgentConfig.merge(base_config, user_overrides)

      assert final_config.session_id == "user_789"
      assert final_config.steering_mode == :one_at_a_time
      assert final_config.follow_up_mode == :all  # From base config
  """
  @spec merge(AgentOptions.t(), AgentOptions.t()) :: AgentOptions.t()
  def merge(%AgentOptions{} = base, %AgentOptions{} = override) do
    # Merge non-nil fields from override into base
    override_map =
      override
      |> Map.from_struct()
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    struct(base, override_map)
  end

  @doc """
  Applies default values to any nil fields in the configuration.

  ## Examples

      partial_config = %AgentOptions{session_id: "abc123"}
      complete_config = AgentConfig.apply_defaults(partial_config)

      # All nil fields now have default values
      assert complete_config.steering_mode == :all
      assert complete_config.max_retry_delay_ms == 30_000
  """
  @spec apply_defaults(AgentOptions.t()) :: AgentOptions.t()
  def apply_defaults(%AgentOptions{} = config) do
    defaults = default()
    merge(defaults, config)
  end

  @doc """
  Gets the stream function from configuration or returns default.

  Provides the function used to stream responses from AI models.

  ## Examples

      stream_fn = AgentConfig.get_stream_fn(config)

      # Use the stream function
      case stream_fn.(model, context, options) do
        {:ok, stream} -> handle_stream(stream)
        {:error, reason} -> handle_stream_error(reason)
      end
  """
  @spec get_stream_fn(AgentOptions.t()) :: function()
  def get_stream_fn(%AgentOptions{stream_fn: nil}) do
    # Default stream function uses Expi.AI.stream_simple
    fn model, context, options ->
      Expi.AI.stream_simple(model, context, options)
    end
  end

  def get_stream_fn(%AgentOptions{stream_fn: stream_fn}) when is_function(stream_fn) do
    stream_fn
  end

  @doc """
  Gets the authentication function from configuration or returns default.

  ## Examples

      auth_fn = AgentConfig.get_auth_fn(config)

      case auth_fn.("anthropic") do
        key when is_binary(key) -> use_api_key(key)
        nil -> handle_missing_key()
      end
  """
  @spec get_auth_fn(AgentOptions.t()) :: function()
  def get_auth_fn(%AgentOptions{get_api_key: nil}) do
    # Default auth function - no custom auth logic
    fn _provider -> nil end
  end

  def get_auth_fn(%AgentOptions{get_api_key: auth_fn}) when is_function(auth_fn) do
    auth_fn
  end

  @doc """
  Gets the message conversion function from configuration.

  ## Examples

      convert_fn = AgentConfig.get_convert_fn(config)

      case convert_fn.(agent_messages) do
        {:ok, llm_messages} -> send_to_llm(llm_messages)
        {:error, reason} -> handle_conversion_error(reason)
      end
  """
  @spec get_convert_fn(AgentOptions.t()) :: function()
  def get_convert_fn(%AgentOptions{convert_to_llm: nil}) do
    # Default conversion function
    fn messages ->
      {:ok, Message.filter_for_llm(messages)}
    end
  end

  def get_convert_fn(%AgentOptions{convert_to_llm: convert_fn}) when is_function(convert_fn) do
    convert_fn
  end

  @doc """
  Gets the context transformation function from configuration.

  ## Examples

      transform_fn = AgentConfig.get_transform_fn(config)

      case transform_fn.(messages, abort_signal) do
        {:ok, transformed} -> proceed_with_messages(transformed)
        {:error, reason} -> handle_transform_error(reason)
      end
  """
  @spec get_transform_fn(AgentOptions.t()) :: function()
  def get_transform_fn(%AgentOptions{transform_context: nil}) do
    # Default transform function - no transformation
    fn messages, _abort_signal -> {:ok, messages} end
  end

  def get_transform_fn(%AgentOptions{transform_context: transform_fn})
      when is_function(transform_fn) do
    transform_fn
  end

  @doc """
  Creates a configuration for testing with safe defaults.

  Disables network calls and provides mock functions for testing.

  ## Examples

      test_config = AgentConfig.for_testing(%{
        session_id: "test_session"
      })

      # Safe for unit tests - no external dependencies
  """
  @spec for_testing(map()) :: AgentOptions.t()
  def for_testing(overrides \\ %{}) do
    test_defaults = %{
      stream_fn: fn _model, _context, _options ->
        # Mock stream for testing
        {:ok,
         Stream.map(1..3, fn i ->
           %{type: :text_delta, delta: "Test response #{i}"}
         end)}
      end,
      get_api_key: fn _provider -> "test_key" end,
      # Faster for tests
      max_retry_delay_ms: 1000
    }

    final_options = Map.merge(test_defaults, overrides)
    {:ok, config} = new(final_options)
    config
  end

  @doc """
  Checks if a configuration has custom functions defined.

  Useful for determining if special handling is needed.

  ## Examples

      if AgentConfig.has_custom_functions?(config) do
        enable_advanced_mode()
      end
  """
  @spec has_custom_functions?(AgentOptions.t()) :: boolean()
  def has_custom_functions?(%AgentOptions{} = config) do
    not is_nil(config.convert_to_llm) or
      not is_nil(config.transform_context) or
      not is_nil(config.stream_fn) or
      not is_nil(config.get_api_key)
  end

  @doc """
  Gets a summary of the configuration for logging/debugging.

  ## Examples

      summary_text = AgentConfig.summary(config)
      Logger.info("Agent config: " <> summary_text)
  """
  @spec summary(AgentOptions.t()) :: String.t()
  def summary(%AgentOptions{} = config) do
    custom_functions =
      [
        config.convert_to_llm && "convert",
        config.transform_context && "transform",
        config.stream_fn && "stream",
        config.get_api_key && "auth"
      ]
      |> Enum.filter(& &1)
      |> Enum.join(", ")

    function_part = if custom_functions != "", do: ", custom: [#{custom_functions}]", else: ""

    "steering: #{config.steering_mode}, follow_up: #{config.follow_up_mode}, " <>
      "retry_delay: #{config.max_retry_delay_ms}ms" <> function_part
  end

  # Private validation functions

  @spec validate_basic_fields(AgentOptions.t()) :: :ok | config_error()
  defp validate_basic_fields(%AgentOptions{} = config) do
    cond do
      not is_nil(config.session_id) and not is_binary(config.session_id) ->
        {:error, :invalid_session_id}

      not is_integer(config.max_retry_delay_ms) or config.max_retry_delay_ms < 0 ->
        {:error, :invalid_retry_delay}

      not is_nil(config.initial_state) and not is_map(config.initial_state) ->
        {:error, :invalid_initial_state}

      true ->
        :ok
    end
  end

  @spec validate_modes(AgentOptions.t()) :: :ok | config_error()
  defp validate_modes(%AgentOptions{steering_mode: steering, follow_up_mode: follow_up}) do
    valid_modes = [:all, :one_at_a_time]

    cond do
      steering not in valid_modes -> {:error, :invalid_steering_mode}
      follow_up not in valid_modes -> {:error, :invalid_follow_up_mode}
      true -> :ok
    end
  end

  @spec validate_convert_function(function() | nil) :: :ok | config_error()
  defp validate_convert_function(nil), do: :ok
  defp validate_convert_function(func) when is_function(func, 1), do: :ok
  defp validate_convert_function(_), do: {:error, :invalid_convert_function}

  @spec validate_transform_function(function() | nil) :: :ok | config_error()
  defp validate_transform_function(nil), do: :ok
  defp validate_transform_function(func) when is_function(func, 2), do: :ok
  defp validate_transform_function(_), do: {:error, :invalid_transform_function}

  @spec validate_stream_function(function() | nil) :: :ok | config_error()
  defp validate_stream_function(nil), do: :ok
  defp validate_stream_function(func) when is_function(func, 3), do: :ok
  defp validate_stream_function(_), do: {:error, :invalid_stream_function}

  @spec validate_auth_function(function() | nil) :: :ok | config_error()
  defp validate_auth_function(nil), do: :ok
  defp validate_auth_function(func) when is_function(func, 1), do: :ok
  defp validate_auth_function(_), do: {:error, :invalid_auth_function}
end
