defmodule Expi.Providers.Ollama do
  @moduledoc """
  Ollama local API provider implementation.
  Supports local LLM models through OpenAI-compatible API.
  """

  alias Expi.AI.HttpClient
  alias Expi.Providers.Base
  alias Expi.Types.{
    AssistantMessage,
    Context,
    ImageContent,
    Model,
    TextContent,
    ToolCall,
    Usage,
    UserMessage
  }

  @default_options %{
    max_tokens: 2048,
    temperature: 0.7
  }

  @doc """
  Completes a conversation using Ollama's OpenAI-compatible API.
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
  Builds the request payload for Ollama's chat completions API.
  """
  @spec build_request_payload(Model.t(), Context.t(), map()) :: {:ok, map()} | {:error, atom()}
  def build_request_payload(model, context, options) do
    merged_options = Base.merge_default_options(@default_options, options)
    
    messages = format_ollama_messages(context.messages, context.system_prompt)

    payload = %{
      "model" => model.id,
      "messages" => messages,
      "max_tokens" => merged_options.max_tokens,
      "temperature" => merged_options.temperature,
      "stream" => false
    }

    payload = maybe_add_tools(payload, context.tools)

    {:ok, payload}
  end

  @doc """
  Parses Ollama API response into AssistantMessage.
  """
  @spec parse_response(map()) :: {:ok, AssistantMessage.t()} | {:error, atom()}
  def parse_response(%{"error" => %{"message" => _message, "type" => type}}) do
    case type do
      "invalid_request_error" -> {:error, :bad_request}
      "model_not_found" -> {:error, :model_not_found}
      "insufficient_quota" -> {:error, :quota_exceeded}
      _ -> {:error, :server_error}
    end
  end

  def parse_response(%{
    "choices" => [choice | _],
    "usage" => usage,
    "model" => model_id
  }) do
    message = choice["message"]
    finish_reason = Map.get(choice, "finish_reason")
    
    parsed_content = parse_ollama_message(message)
    usage_struct = parse_ollama_usage(usage)
    stop_reason = parse_ollama_finish_reason(finish_reason)

    response = %AssistantMessage{
      role: :assistant,
      content: parsed_content,
      api: "openai-completions",
      provider: "ollama",
      model: model_id,
      usage: usage_struct,
      stop_reason: stop_reason,
      timestamp: System.system_time(:millisecond)
    }

    {:ok, response}
  end

  def parse_response(%{"choices" => []}), do: {:error, :no_choices}
  def parse_response(_), do: {:error, :invalid_response}

  @doc """
  Checks if Ollama service is healthy and accessible.
  """
  @spec health_check(String.t()) :: {:ok, map()} | {:error, atom()}
  def health_check(base_url) do
    url = "#{base_url}/api/tags"
    headers = [{"Content-Type", "application/json"}]

    case HttpClient.get(url, headers) do
      {:ok, %{status: 200, body: body}} ->
        case Base.parse_json_safely(body) do
          {:ok, response} -> {:ok, response}
          {:error, reason} -> {:error, reason}
        end
      {:ok, %{status: status}} ->
        {:error, map_http_error(status)}
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Checks if a specific model is available in Ollama.
  """
  @spec model_available?(String.t(), String.t()) :: {:ok, boolean()} | {:error, atom()}
  def model_available?(base_url, model_name) do
    case health_check(base_url) do
      {:ok, %{"models" => models}} ->
        available = Enum.any?(models, fn model ->
          Map.get(model, "name") == model_name
        end)
        {:ok, available}
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Maps HTTP status codes to error atoms.
  """
  @spec map_http_error(integer()) :: atom()
  def map_http_error(400), do: :bad_request
  def map_http_error(401), do: :unauthorized
  def map_http_error(403), do: :forbidden
  def map_http_error(404), do: :model_not_found
  def map_http_error(429), do: :rate_limited
  def map_http_error(500), do: :server_error
  def map_http_error(503), do: :service_unavailable
  def map_http_error(_), do: :unknown_error

  @doc """
  Formats error messages for better user experience.
  """
  @spec format_error(atom(), String.t()) :: String.t()
  def format_error(:connection_refused, _), do: "Cannot connect to Ollama service. Is it running?"
  def format_error(:model_not_found, model), do: "Model '#{model}' not found in Ollama"
  def format_error(:service_unavailable, _), do: "Ollama service is temporarily unavailable"
  def format_error(reason, message), do: "Ollama error (#{reason}): #{message}"

  # Private helper functions

  defp prepare_request_headers(model) do
    headers = []  # Ollama typically doesn't require authentication for local usage
    {:ok, Base.prepare_headers(model, headers)}
  end

  defp make_api_request(model, payload, headers) do
    url = "#{model.base_url}/api/chat"
    body = Jason.encode!(payload)

    case HttpClient.post(url, body, headers) do
      {:ok, %{status: 200, body: response_body}} ->
        Base.parse_json_safely(response_body)
      {:ok, %{status: status, body: body}} ->
        case Base.parse_json_safely(body) do
          {:ok, error_response} -> {:error, {status, error_response}}
          {:error, _} -> Base.handle_http_error(status, body)
        end
      {:error, :econnrefused} ->
        {:error, :connection_refused}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_ollama_messages(messages, system_prompt) do
    # Add system message if present
    system_messages = if system_prompt do
      [%{"role" => "system", "content" => system_prompt}]
    else
      []
    end

    formatted_messages = Enum.map(messages, &format_ollama_message/1)
    system_messages ++ formatted_messages
  end

  defp format_ollama_message(%UserMessage{role: :user, content: content}) when is_binary(content) do
    %{"role" => "user", "content" => content}
  end

  defp format_ollama_message(%UserMessage{role: :user, content: content}) when is_list(content) do
    # For multi-modal content, extract text parts
    text_content = content
    |> Enum.filter(&is_text_content?/1)
    |> Enum.map(& &1.text)
    |> Enum.join(" ")

    %{"role" => "user", "content" => text_content}
  end

  defp format_ollama_message(%AssistantMessage{role: :assistant, content: content}) do
    text = Base.extract_text_content(content)
    %{"role" => "assistant", "content" => text}
  end

  defp is_text_content?(%TextContent{type: :text}), do: true
  defp is_text_content?(_), do: false

  defp maybe_add_tools(payload, nil), do: payload
  defp maybe_add_tools(payload, []), do: payload
  defp maybe_add_tools(payload, tools) do
    # Ollama/OpenAI format for tools
    formatted_tools = Enum.map(tools, &format_ollama_tool/1)
    Map.put(payload, "tools", formatted_tools)
  end

  defp format_ollama_tool(%{name: name, description: desc, parameters: params}) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => desc,
        "parameters" => params
      }
    }
  end

  # Handle pre-formatted tool (already in OpenAI format)
  defp format_ollama_tool(%{type: "function", function: function}) do
    %{
      "type" => "function",
      "function" => function
    }
  end

  defp parse_ollama_message(%{"content" => content, "tool_calls" => tool_calls}) when is_nil(content) or content == "" do
    # If no text content, just return tool calls
    Enum.map(tool_calls, &parse_tool_call/1)
  end

  defp parse_ollama_message(%{"content" => content, "tool_calls" => tool_calls}) do
    # If there's both text and tool calls, include both
    text_content = [%TextContent{type: :text, text: content}]
    tool_call_content = Enum.map(tool_calls, &parse_tool_call/1)
    text_content ++ tool_call_content
  end

  defp parse_ollama_message(%{"content" => content}) do
    [%TextContent{type: :text, text: content || ""}]
  end

  defp parse_tool_call(%{"id" => id, "function" => %{"name" => name, "arguments" => args}}) do
    parsed_args = case Jason.decode(args) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end

    %ToolCall{type: :tool_call, id: id, name: name, arguments: parsed_args}
  end

  defp parse_ollama_usage(%{
    "prompt_tokens" => input,
    "completion_tokens" => output,
    "total_tokens" => total
  }) do
    %Usage{
      input: input,
      output: output,
      cache_read: 0,
      cache_write: 0,
      total_tokens: total,
      cost: calculate_ollama_cost(input, output)
    }
  end

  defp calculate_ollama_cost(_input, _output) do
    # Ollama is free for local usage
    %Expi.Types.Cost{
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0
    }
  end

  @doc """
  Streams a conversation using Ollama's OpenAI-compatible API with Server-Sent Events.
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
      body = Jason.encode!(payload)
      case Expi.AI.Streaming.create_production_stream(url, body, headers, "ollama", model.id) do
        {:ok, raw_stream} ->
          # Transform Ollama SSE events to standardized events
          transformed_stream = 
            raw_stream
            |> Stream.map(fn event -> transform_ollama_event(event, payload) end)
            |> Stream.filter(fn event -> not is_nil(event) end)
          
          {:ok, transformed_stream}
        
        {:error, reason} ->
          # Return the actual error (connection refused, missing API key, network issues, etc.)
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_streaming_payload(model, context, options) do
    # Same as regular payload but with stream: true (OpenAI-compatible)
    with {:ok, payload} <- build_request_payload(model, context, options) do
      streaming_payload = Map.put(payload, "stream", true)
      {:ok, streaming_payload}
    end
  end

  defp prepare_streaming_headers(model) do
    with {:ok, headers} <- prepare_request_headers(model) do
      # Add streaming-specific headers for Ollama
      streaming_headers = [
        {"Accept", "text/event-stream"},
        {"Cache-Control", "no-cache"} | headers
      ]
      {:ok, streaming_headers}
    end
  end

  defp build_streaming_url(_model) do
    ollama_endpoint = Expi.AI.Auth.get_ollama_endpoint()
    url = "#{ollama_endpoint}/v1/chat/completions"
    {:ok, url}
  end

  defp transform_ollama_event(sse_event, _payload) do
    # Parse Ollama-specific SSE event format and convert to standardized AssistantMessageEvent
    Expi.AI.Streaming.standardize_event(sse_event, "ollama")
  end

  defp parse_ollama_finish_reason("stop"), do: :stop
  defp parse_ollama_finish_reason("length"), do: :length
  defp parse_ollama_finish_reason("tool_calls"), do: :tool_use
  defp parse_ollama_finish_reason("content_filter"), do: :content_filter
  defp parse_ollama_finish_reason(nil), do: :stop  # Default when no finish_reason provided
  defp parse_ollama_finish_reason(_), do: :unknown
end