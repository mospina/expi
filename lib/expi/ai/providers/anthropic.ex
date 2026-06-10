defmodule Expi.Providers.Anthropic do
  @moduledoc """
  Anthropic Claude API provider implementation.
  Supports Claude models with reasoning/thinking capabilities.
  """

  alias Expi.AI.HttpClient
  alias Expi.AI.Auth
  alias Expi.Providers.Base

  alias Expi.Types.{
    AssistantMessage,
    Context,
    ImageContent,
    Model,
    TextContent,
    ThinkingContent,
    ToolCall,
    ToolResultMessage,
    Usage,
    UserMessage
  }

  @default_options %{
    max_tokens: 4096,
    temperature: 0.7
  }

  @doc """
  Completes a conversation using Anthropic's API.
  """
  @spec complete(Model.t(), Context.t(), map()) :: {:ok, AssistantMessage.t()} | {:error, atom()}
  def complete(model, context, options \\ %{}) do
    with :ok <- Base.validate_model(model),
         :ok <- Base.validate_context(context),
         :ok <- Base.validate_options(options),
         {:ok, payload} <- build_request_payload(model, context, options),
         {:ok, headers} <- prepare_request_headers(model),
         {:ok, response} <- make_api_request(model, payload, headers),
         {:ok, message} <- parse_response(response) do
      {:ok, message}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Builds the request payload for Anthropic's Messages API.
  """
  @spec build_request_payload(Model.t(), Context.t(), map()) :: {:ok, map()} | {:error, atom()}
  def build_request_payload(model, context, options) do
    merged_options = Base.merge_default_options(@default_options, options)

    messages = format_anthropic_messages(context.messages)

    payload = %{
      "model" => model.id,
      "messages" => messages,
      "max_tokens" => merged_options.max_tokens,
      "temperature" => merged_options.temperature
    }

    payload = maybe_add_system_prompt(payload, context.system_prompt)
    payload = maybe_add_tools(payload, context.tools)
    payload = maybe_add_reasoning(payload, merged_options)

    {:ok, payload}
  end

  @doc """
  Parses Anthropic API response into AssistantMessage.
  """
  @spec parse_response(map()) :: {:ok, AssistantMessage.t()} | {:error, atom()}
  def parse_response(%{"type" => "error", "error" => error}) do
    case error["type"] do
      "invalid_request_error" -> {:error, :bad_request}
      "authentication_error" -> {:error, :unauthorized}
      "permission_error" -> {:error, :forbidden}
      "not_found_error" -> {:error, :not_found}
      "rate_limit_error" -> {:error, :rate_limited}
      "api_error" -> {:error, :server_error}
      _ -> {:error, :unknown_error}
    end
  end

  def parse_response(%{"content" => content, "usage" => usage, "model" => model_id} = response) do
    parsed_content = parse_content_blocks(content)
    usage_struct = parse_usage(usage)
    stop_reason = parse_stop_reason(response["stop_reason"])

    message = %AssistantMessage{
      role: :assistant,
      content: parsed_content,
      api: "anthropic-messages",
      provider: "anthropic",
      model: model_id,
      usage: usage_struct,
      stop_reason: stop_reason,
      timestamp: System.system_time(:millisecond)
    }

    {:ok, message}
  end

  def parse_response(_), do: {:error, :invalid_response}

  @doc """
  Maps HTTP status codes to error atoms.
  """
  @spec map_http_error(integer()) :: atom()
  def map_http_error(400), do: :bad_request
  def map_http_error(401), do: :unauthorized
  def map_http_error(403), do: :forbidden
  def map_http_error(404), do: :not_found
  def map_http_error(429), do: :rate_limited
  def map_http_error(500), do: :server_error
  def map_http_error(503), do: :service_unavailable
  def map_http_error(529), do: :service_unavailable
  def map_http_error(_), do: :unknown_error

  @doc """
  Formats error messages for better user experience.
  """
  @spec format_error(atom(), String.t()) :: String.t()
  def format_error(:rate_limited, message), do: "Rate limit exceeded: #{message}"
  def format_error(:unauthorized, _), do: "Invalid API key or authentication failed"
  def format_error(:quota_exceeded, message), do: "Quota exceeded: #{message}"
  def format_error(:server_error, _), do: "Anthropic API server error"
  def format_error(reason, message), do: "API error (#{reason}): #{message}"

  # Private helper functions

  defp prepare_request_headers(model) do
    case Auth.get_api_key("anthropic") do
      {:ok, api_key} ->
        headers = [
          {"x-api-key", api_key},
          {"anthropic-version", "2023-06-01"}
        ]

        {:ok, Base.prepare_headers(model, headers)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp make_api_request(model, payload, headers) do
    url = "#{model.base_url}/v1/messages"
    body = Jason.encode!(payload)

    case HttpClient.post(url, body, headers) do
      {:ok, %{status: 200, body: response_body}} ->
        Base.parse_json_safely(response_body)

      {:ok, %{status: status, body: body}} ->
        case Base.parse_json_safely(body) do
          {:ok, error_response} ->
            # Pass the parsed error response for handling by parse_response
            {:ok, error_response}

          {:error, _} ->
            Base.handle_http_error(status, body)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_anthropic_messages(messages) do
    do_format_anthropic_messages(messages, []) |> Enum.reverse()
  end

  defp do_format_anthropic_messages([], acc), do: acc

  defp do_format_anthropic_messages([%ToolResultMessage{} = msg | rest], acc) do
    {tool_results, remaining} = Enum.split_while(rest, &match?(%ToolResultMessage{}, &1))
    batch = [msg | tool_results]

    content_blocks =
      Enum.map(batch, fn tool_msg ->
        %{
          "type" => "tool_result",
          "tool_use_id" => tool_msg.tool_call_id,
          "content" => Base.extract_text_content(tool_msg.content),
          "is_error" => tool_msg.is_error
        }
      end)

    do_format_anthropic_messages(remaining, [
      %{"role" => "user", "content" => content_blocks} | acc
    ])
  end

  defp do_format_anthropic_messages([message | rest], acc) do
    do_format_anthropic_messages(rest, [format_anthropic_message(message) | acc])
  end

  defp format_anthropic_message(%UserMessage{role: :user, content: content})
       when is_binary(content) do
    %{"role" => "user", "content" => content}
  end

  defp format_anthropic_message(%UserMessage{role: :user, content: content})
       when is_list(content) do
    formatted_content = Enum.map(content, &format_content_block/1)
    %{"role" => "user", "content" => formatted_content}
  end

  defp format_anthropic_message(%AssistantMessage{role: :assistant, content: content}) do
    formatted_content =
      content
      |> Enum.map(&format_assistant_content_block/1)
      |> Enum.reject(&is_nil/1)

    case formatted_content do
      [] ->
        text = Base.extract_text_content(content)
        %{"role" => "assistant", "content" => text}

      blocks ->
        %{"role" => "assistant", "content" => blocks}
    end
  end

  defp format_anthropic_message(%ToolResultMessage{role: :tool_result} = msg) do
    %{
      "role" => "user",
      "content" => [
        %{
          "type" => "tool_result",
          "tool_use_id" => msg.tool_call_id,
          "content" => Base.extract_text_content(msg.content),
          "is_error" => msg.is_error
        }
      ]
    }
  end

  defp format_assistant_content_block(%{type: :text, text: text}) when is_binary(text) do
    %{"type" => "text", "text" => text}
  end

  defp format_assistant_content_block(%TextContent{type: :text, text: text}) do
    %{"type" => "text", "text" => text}
  end

  defp format_assistant_content_block(%{type: :tool_call, id: id, name: name, arguments: args}) do
    %{
      "type" => "tool_use",
      "id" => id,
      "name" => name,
      "input" => args || %{}
    }
  end

  defp format_assistant_content_block(_), do: nil

  defp format_content_block(%TextContent{type: :text, text: text}) do
    %{"type" => "text", "text" => text}
  end

  defp format_content_block(%ImageContent{type: :image, data: data, mime_type: mime_type}) do
    %{
      "type" => "image",
      "source" => %{
        "type" => "base64",
        "media_type" => mime_type,
        "data" => data
      }
    }
  end

  defp format_content_block(content), do: content

  defp maybe_add_system_prompt(payload, nil), do: payload
  defp maybe_add_system_prompt(payload, ""), do: payload

  defp maybe_add_system_prompt(payload, system_prompt) do
    Map.put(payload, "system", system_prompt)
  end

  defp maybe_add_tools(payload, nil), do: payload
  defp maybe_add_tools(payload, []), do: payload

  defp maybe_add_tools(payload, tools) do
    formatted_tools = Enum.map(tools, &format_tool/1)
    Map.put(payload, "tools", formatted_tools)
  end

  defp format_tool(%{name: name, description: desc, input_schema: schema}) do
    %{
      "name" => name,
      "description" => desc,
      "input_schema" => normalize_schema(schema)
    }
  end

  defp format_tool(%Expi.Types.Tool{
         type: :function,
         function: %{name: name, description: desc, parameters: params}
       }) do
    %{
      "name" => name,
      "description" => desc,
      "input_schema" => normalize_schema(params)
    }
  end

  defp format_tool(%{function: %{name: name, description: desc, parameters: params}}) do
    %{
      "name" => name,
      "description" => desc,
      "input_schema" => normalize_schema(params)
    }
  end

  defp normalize_schema(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {to_string(k), normalize_schema(v)} end)
    |> Map.new()
  end

  defp normalize_schema(value) when is_list(value), do: Enum.map(value, &normalize_schema/1)
  defp normalize_schema(value) when is_atom(value), do: to_string(value)
  defp normalize_schema(value), do: value

  defp maybe_add_reasoning(payload, %{reasoning: reasoning})
       when reasoning in ["high", "medium", "low"] do
    Map.put(payload, "reasoning", reasoning)
  end

  defp maybe_add_reasoning(payload, _), do: payload

  defp parse_content_blocks(content) when is_list(content) do
    Enum.map(content, &parse_content_block/1)
  end

  defp parse_content_block(%{"type" => "text", "text" => text}) do
    %TextContent{type: :text, text: text}
  end

  defp parse_content_block(%{"type" => "thinking", "thinking" => thinking}) do
    %ThinkingContent{type: :thinking, thinking: thinking}
  end

  defp parse_content_block(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}) do
    %ToolCall{type: :tool_call, id: id, name: name, arguments: input}
  end

  defp parse_content_block(block), do: block

  defp parse_usage(%{
         "input_tokens" => input,
         "output_tokens" => output,
         "cache_creation_input_tokens" => cache_write,
         "cache_read_input_tokens" => cache_read
       }) do
    total = input + output

    %Usage{
      input: input,
      output: output,
      cache_read: cache_read,
      cache_write: cache_write,
      total_tokens: total,
      cost: calculate_usage_cost(input, output, cache_read, cache_write)
    }
  end

  defp parse_usage(%{"input_tokens" => input, "output_tokens" => output}) do
    total = input + output

    %Usage{
      input: input,
      output: output,
      cache_read: 0,
      cache_write: 0,
      total_tokens: total,
      cost: calculate_usage_cost(input, output, 0, 0)
    }
  end

  defp calculate_usage_cost(input, output, cache_read, cache_write) do
    # Using default Anthropic pricing - this would be model-specific in real implementation
    input_cost = input * 15.0 / 1_000_000
    output_cost = output * 75.0 / 1_000_000
    cache_read_cost = cache_read * 0.15 / 1_000_000
    cache_write_cost = cache_write * 18.75 / 1_000_000

    %Expi.Types.Cost{
      input: input_cost,
      output: output_cost,
      cache_read: cache_read_cost,
      cache_write: cache_write_cost
    }
  end

  @doc """
  Streams a conversation using Anthropic's API with Server-Sent Events.
  """
  @spec stream(Model.t(), Context.t(), map()) :: {:ok, Enumerable.t()} | {:error, atom()}
  def stream(model, context, options \\ %{}) do
    with :ok <- Base.validate_model(model),
         :ok <- Base.validate_context(context),
         :ok <- Base.validate_options(options),
         {:ok, payload} <- build_streaming_payload(model, context, options),
         {:ok, headers} <- prepare_streaming_headers(model),
         {:ok, url} <- build_streaming_url(model) do
      # Attempt production streaming - if it fails, return the error
      case Expi.AI.Streaming.create_production_stream(
             url,
             payload,
             headers,
             "anthropic",
             model.id
           ) do
        {:ok, event_stream} ->
          # create_production_stream already converts to AssistantMessageEvent format
          # No additional transformation needed
          {:ok, event_stream}

        {:error, reason} ->
          # Return the actual error (missing API key, network issues, etc.)
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_streaming_payload(model, context, options) do
    # Same as regular payload but with stream: true
    with {:ok, payload} <- build_request_payload(model, context, options) do
      streaming_payload = Map.put(payload, "stream", true)
      {:ok, streaming_payload}
    end
  end

  defp prepare_streaming_headers(model) do
    with {:ok, headers} <- prepare_request_headers(model) do
      # Add streaming-specific headers
      streaming_headers = [
        {"Accept", "text/event-stream"},
        {"Cache-Control", "no-cache"} | headers
      ]

      {:ok, streaming_headers}
    end
  end

  defp build_streaming_url(model) do
    base_url = model.base_url || "https://api.anthropic.com"
    url = "#{base_url}/v1/messages"
    {:ok, url}
  end

  defp parse_stop_reason("end_turn"), do: :stop
  defp parse_stop_reason("max_tokens"), do: :max_tokens
  defp parse_stop_reason("stop_sequence"), do: :stop_sequence
  defp parse_stop_reason("tool_use"), do: :tool_use
  defp parse_stop_reason(_), do: :unknown
end
