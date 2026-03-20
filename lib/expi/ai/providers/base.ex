defmodule Expi.Providers.Base do
  @moduledoc """
  Base provider functionality shared across all AI providers.
  Provides common validation, formatting, and utility functions.
  """

  alias Expi.Types.{
    AssistantMessage,
    Context,
    Cost,
    ImageContent,
    Model,
    TextContent,
    Usage,
    UserMessage
  }

  @doc """
  Validates context structure and content.
  """
  @spec validate_context(Context.t() | nil) :: :ok | {:error, atom()}
  def validate_context(nil), do: {:error, :invalid_context}
  def validate_context(%Context{messages: nil}), do: {:error, :invalid_messages}
  def validate_context(%Context{messages: []}), do: {:error, :empty_messages}
  def validate_context(%Context{}), do: :ok

  @doc """
  Validates model structure and required fields.
  """
  @spec validate_model(Model.t() | nil) :: :ok | {:error, atom()}
  def validate_model(nil), do: {:error, :invalid_model}
  def validate_model(%Model{id: id}) when id == "" or is_nil(id), do: {:error, :invalid_model_id}
  def validate_model(%Model{base_url: url}) when url == "" or is_nil(url), do: {:error, :invalid_base_url}
  def validate_model(%Model{provider: provider}) when provider == "" or is_nil(provider), do: {:error, :invalid_provider}
  def validate_model(%Model{}), do: :ok

  @doc """
  Validates completion options.
  """
  @spec validate_options(map() | nil) :: :ok | {:error, atom()}
  def validate_options(nil), do: :ok
  def validate_options(options) when is_map(options) do
    with :ok <- validate_temperature(Map.get(options, :temperature)),
         :ok <- validate_max_tokens(Map.get(options, :max_tokens)) do
      :ok
    end
  end

  defp validate_temperature(nil), do: :ok
  defp validate_temperature(temp) when is_number(temp) and temp >= 0.0 and temp <= 2.0, do: :ok
  defp validate_temperature(_), do: {:error, :invalid_temperature}

  defp validate_max_tokens(nil), do: :ok
  defp validate_max_tokens(tokens) when is_integer(tokens) and tokens > 0, do: :ok
  defp validate_max_tokens(_), do: {:error, :invalid_max_tokens}

  @doc """
  Prepares HTTP headers by combining model headers with custom headers.
  """
  @spec prepare_headers(Model.t(), list()) :: list()
  def prepare_headers(%Model{headers: model_headers}, custom_headers) do
    default_headers = [{"Content-Type", "application/json"}]
    
    model_header_list = Map.to_list(model_headers || %{})
    
    # Combine all headers, with custom taking precedence
    (default_headers ++ model_header_list ++ custom_headers)
    |> Enum.reverse()
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.reverse()
  end

  @doc """
  Calculates cost based on model pricing and usage.
  """
  @spec calculate_cost(Model.t(), map()) :: map()
  def calculate_cost(%Model{cost: cost}, usage) do
    input_tokens = Map.get(usage, :input, 0)
    output_tokens = Map.get(usage, :output, 0)
    cache_read_tokens = Map.get(usage, :cache_read, 0)
    cache_write_tokens = Map.get(usage, :cache_write, 0)

    input_cost = input_tokens * cost.input / 1_000_000
    output_cost = output_tokens * cost.output / 1_000_000
    cache_read_cost = cache_read_tokens * cost.cache_read / 1_000_000
    cache_write_cost = cache_write_tokens * cost.cache_write / 1_000_000

    total_cost = input_cost + output_cost + cache_read_cost + cache_write_cost

    %{
      input: input_cost,
      output: output_cost,
      cache_read: cache_read_cost,
      cache_write: cache_write_cost,
      total: total_cost
    }
  end

  @doc """
  Formats messages for API consumption.
  """
  @spec format_messages(list()) :: list()
  def format_messages(messages) do
    Enum.map(messages, &format_single_message/1)
  end

  defp format_single_message(%UserMessage{role: :user, content: content}) when is_binary(content) do
    %{"role" => "user", "content" => content}
  end

  defp format_single_message(%UserMessage{role: :user, content: content}) when is_list(content) do
    %{"role" => "user", "content" => content}
  end

  defp format_single_message(%AssistantMessage{role: :assistant, content: content}) do
    text = extract_text_content(content)
    %{"role" => "assistant", "content" => text}
  end

  @doc """
  Maps HTTP status codes to error atoms.
  """
  @spec handle_http_error(integer(), String.t()) :: {:error, atom()}
  def handle_http_error(400, _), do: {:error, :bad_request}
  def handle_http_error(401, _), do: {:error, :unauthorized}
  def handle_http_error(403, _), do: {:error, :forbidden}
  def handle_http_error(404, _), do: {:error, :not_found}
  def handle_http_error(429, _), do: {:error, :rate_limited}
  def handle_http_error(500, _), do: {:error, :server_error}
  def handle_http_error(503, _), do: {:error, :service_unavailable}
  def handle_http_error(_, _), do: {:error, :unknown_http_error}

  @doc """
  Safely parses JSON strings.
  """
  @spec parse_json_safely(String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def parse_json_safely(nil), do: {:error, :empty_response}
  def parse_json_safely(""), do: {:error, :empty_response}
  def parse_json_safely(data) when is_binary(data) do
    Jason.decode(data)
    |> case do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:error, :invalid_json}
    end
  end
  def parse_json_safely(_), do: {:error, :invalid_input}

  @doc """
  Merges default options with custom options.
  """
  @spec merge_default_options(map(), map() | nil) :: map()
  def merge_default_options(defaults, nil), do: defaults
  def merge_default_options(defaults, custom) do
    Map.merge(defaults, custom)
  end

  @doc """
  Extracts text content from content list.
  """
  @spec extract_text_content(list()) :: String.t()
  def extract_text_content(content) when is_list(content) do
    content
    |> Enum.filter(&is_text_content?/1)
    |> Enum.map(& &1.text)
    |> Enum.join("")
  end
  def extract_text_content([]), do: ""

  defp is_text_content?(%TextContent{type: :text}), do: true
  defp is_text_content?(_), do: false

  @doc """
  Creates a usage struct with cost calculation.
  """
  @spec create_usage(Model.t(), integer(), integer(), integer()) :: Usage.t()
  def create_usage(model, input_tokens, output_tokens, total_tokens) do
    usage_map = %{
      input: input_tokens,
      output: output_tokens,
      cache_read: 0,
      cache_write: 0
    }

    cost_map = calculate_cost(model, usage_map)
    cost_struct = struct(Cost, cost_map)

    %Usage{
      input: input_tokens,
      output: output_tokens,
      cache_read: 0,
      cache_write: 0,
      total_tokens: total_tokens,
      cost: cost_struct
    }
  end

  @doc """
  Retries a function with exponential backoff.
  """
  @spec retry_with_backoff(function(), integer(), integer()) :: {:ok, any()} | {:error, any()}
  def retry_with_backoff(func, max_retries, base_delay_ms) do
    do_retry(func, max_retries, base_delay_ms, 0)
  end

  defp do_retry(func, max_retries, _delay, attempt) when attempt >= max_retries do
    try do
      func.()
    rescue
      error -> {:error, error}
    end
  end

  defp do_retry(func, max_retries, base_delay_ms, attempt) do
    try do
      case func.() do
        {:ok, result} -> {:ok, result}
        {:error, _} = error when attempt + 1 >= max_retries -> error
        {:error, _} ->
          delay = base_delay_ms * :math.pow(2, attempt)
          Process.sleep(trunc(delay))
          do_retry(func, max_retries, base_delay_ms, attempt + 1)
      end
    rescue
      _error ->
        if attempt + 1 >= max_retries do
          {:error, :max_retries_exceeded}
        else
          delay = base_delay_ms * :math.pow(2, attempt)
          Process.sleep(trunc(delay))
          do_retry(func, max_retries, base_delay_ms, attempt + 1)
        end
    end
  end
end