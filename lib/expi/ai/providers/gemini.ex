defmodule Expi.Providers.Gemini do
  @moduledoc """
  Google Gemini API provider implementation.
  Supports Gemini models including multi-modal capabilities.
  """

  alias Expi.AI.{Auth, HttpClient}
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
    max_tokens: 8192,
    temperature: 0.7
  }

  @default_safety_settings [
    %{
      "category" => "HARM_CATEGORY_HARASSMENT", 
      "threshold" => "BLOCK_MEDIUM_AND_ABOVE"
    },
    %{
      "category" => "HARM_CATEGORY_HATE_SPEECH",
      "threshold" => "BLOCK_MEDIUM_AND_ABOVE"
    },
    %{
      "category" => "HARM_CATEGORY_SEXUALLY_EXPLICIT",
      "threshold" => "BLOCK_MEDIUM_AND_ABOVE"
    },
    %{
      "category" => "HARM_CATEGORY_DANGEROUS_CONTENT",
      "threshold" => "BLOCK_MEDIUM_AND_ABOVE"
    }
  ]

  @doc """
  Completes a conversation using Google's Gemini API.
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
  Builds the request payload for Google's Generative AI API.
  """
  @spec build_request_payload(Model.t(), Context.t(), map()) :: {:ok, map()} | {:error, atom()}
  def build_request_payload(_model, context, options) do
    merged_options = Base.merge_default_options(@default_options, options)
    
    contents = format_gemini_messages(context.messages, context.system_prompt)

    generation_config = %{
      "maxOutputTokens" => merged_options.max_tokens,
      "temperature" => merged_options.temperature
    }

    payload = %{
      "contents" => contents,
      "generationConfig" => generation_config
    }

    payload = maybe_add_safety_settings(payload, merged_options)
    payload = maybe_add_tools(payload, context.tools)

    {:ok, payload}
  end

  @doc """
  Parses Google Gemini API response into AssistantMessage.
  """
  @spec parse_response(map()) :: {:ok, AssistantMessage.t()} | {:error, atom()}
  def parse_response(%{"error" => %{"code" => code, "message" => _message}}) do
    case code do
      400 -> {:error, :bad_request}
      401 -> {:error, :unauthorized}
      403 -> {:error, :forbidden}
      404 -> {:error, :not_found}
      429 -> {:error, :quota_exceeded}
      500 -> {:error, :server_error}
      503 -> {:error, :service_unavailable}
      _ -> {:error, :unknown_error}
    end
  end

  def parse_response(%{"candidates" => []}) do
    {:error, :no_candidates}
  end

  def parse_response(%{"candidates" => [%{"finishReason" => "SAFETY"}]}) do
    {:error, :content_filtered}
  end

  def parse_response(%{"candidates" => [candidate | _], "usageMetadata" => usage_metadata}) do
    case candidate do
      %{"content" => content, "finishReason" => finish_reason} ->
        parsed_content = parse_gemini_content(content)
        usage_struct = parse_gemini_usage(usage_metadata)
        stop_reason = parse_gemini_stop_reason(finish_reason)

        message = %AssistantMessage{
          role: :assistant,
          content: parsed_content,
          api: "google-generative-ai",
          provider: "google",
          model: "gemini-pro", # Would be extracted from request context in real implementation
          usage: usage_struct,
          stop_reason: stop_reason,
          timestamp: System.system_time(:millisecond)
        }

        {:ok, message}

      _ ->
        {:error, :invalid_response}
    end
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
  def map_http_error(429), do: :quota_exceeded
  def map_http_error(500), do: :server_error
  def map_http_error(503), do: :service_unavailable
  def map_http_error(_), do: :unknown_error

  @doc """
  Formats error messages for better user experience.
  """
  @spec format_error(atom(), String.t()) :: String.t()
  def format_error(:quota_exceeded, message), do: "API quota exceeded: #{message}"
  def format_error(:content_filtered, _), do: "Content was filtered by safety settings"
  def format_error(:unauthorized, _), do: "Invalid API key or authentication failed"
  def format_error(:no_candidates, _), do: "No response candidates generated"
  def format_error(reason, message), do: "API error (#{reason}): #{message}"

  # Private helper functions

  defp prepare_request_headers(model) do
    case Auth.get_api_key("google") do
      {:ok, api_key} ->
        headers = [{"x-goog-api-key", api_key}]
        {:ok, Base.prepare_headers(model, headers)}
      {:error, reason} -> 
        {:error, reason}
    end
  end

  defp make_api_request(model, payload, headers) do
    url = "#{model.base_url}/v1/models/gemini-pro:generateContent"
    body = Jason.encode!(payload)

    case HttpClient.post(url, body, headers) do
      {:ok, %{status: 200, body: response_body}} ->
        Base.parse_json_safely(response_body)
      {:ok, %{status: status, body: body}} ->
        case Base.parse_json_safely(body) do
          {:ok, error_response} -> {:error, {status, error_response}}
          {:error, _} -> Base.handle_http_error(status, body)
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_gemini_messages(messages, system_prompt) do
    formatted_messages = Enum.map(messages, &format_gemini_message/1)
    
    # Add system instruction if present
    if system_prompt do
      system_content = %{
        "role" => "user",
        "parts" => [%{"text" => "System: #{system_prompt}"}]
      }
      [system_content | formatted_messages]
    else
      formatted_messages
    end
  end

  defp format_gemini_message(%UserMessage{role: :user, content: content}) when is_binary(content) do
    %{
      "role" => "user",
      "parts" => [%{"text" => content}]
    }
  end

  defp format_gemini_message(%UserMessage{role: :user, content: content}) when is_list(content) do
    parts = Enum.map(content, &format_gemini_part/1)
    %{
      "role" => "user", 
      "parts" => parts
    }
  end

  defp format_gemini_message(%AssistantMessage{role: :assistant, content: content}) do
    text = Base.extract_text_content(content)
    %{
      "role" => "model",
      "parts" => [%{"text" => text}]
    }
  end

  defp format_gemini_part(%TextContent{type: :text, text: text}) do
    %{"text" => text}
  end

  defp format_gemini_part(%ImageContent{type: :image, data: data, mime_type: mime_type}) do
    %{
      "inlineData" => %{
        "mimeType" => mime_type,
        "data" => data
      }
    }
  end

  defp format_gemini_part(part), do: part

  defp maybe_add_safety_settings(payload, %{safety_settings: settings}) do
    Map.put(payload, "safetySettings", settings)
  end
  defp maybe_add_safety_settings(payload, _) do
    Map.put(payload, "safetySettings", @default_safety_settings)
  end

  defp maybe_add_tools(payload, nil), do: payload
  defp maybe_add_tools(payload, []), do: payload
  defp maybe_add_tools(payload, tools) do
    function_declarations = Enum.map(tools, &format_gemini_tool/1)
    
    tools_spec = %{
      "functionDeclarations" => function_declarations
    }
    
    Map.put(payload, "tools", [tools_spec])
  end

  defp format_gemini_tool(%{name: name, description: desc, parameters: params}) do
    %{
      "name" => name,
      "description" => desc,
      "parameters" => params
    }
  end

  defp parse_gemini_content(%{"parts" => parts}) do
    Enum.map(parts, &parse_gemini_part/1)
  end

  defp parse_gemini_part(%{"text" => text}) do
    %TextContent{type: :text, text: text}
  end

  defp parse_gemini_part(%{"functionCall" => %{"name" => name, "args" => args}}) do
    %ToolCall{type: :tool_call, id: generate_tool_call_id(), name: name, arguments: args}
  end

  defp parse_gemini_part(part), do: part

  defp parse_gemini_usage(%{
    "promptTokenCount" => input,
    "candidatesTokenCount" => output,
    "totalTokenCount" => total
  }) do
    %Usage{
      input: input,
      output: output,
      cache_read: 0,
      cache_write: 0,
      total_tokens: total,
      cost: calculate_gemini_cost(input, output)
    }
  end

  defp calculate_gemini_cost(input, output) do
    # Using default Gemini pricing
    input_cost = input * 0.5 / 1_000_000
    output_cost = output * 1.5 / 1_000_000

    %Expi.Types.Cost{
      input: input_cost,
      output: output_cost,
      cache_read: 0.0,
      cache_write: 0.0
    }
  end

  defp parse_gemini_stop_reason("STOP"), do: :stop
  defp parse_gemini_stop_reason("MAX_TOKENS"), do: :max_tokens
  defp parse_gemini_stop_reason("SAFETY"), do: :content_filter
  defp parse_gemini_stop_reason("RECITATION"), do: :content_filter
  defp parse_gemini_stop_reason("FUNCTION_CALL"), do: :tool_use
  defp parse_gemini_stop_reason(_), do: :unknown

  @doc """
  Streams a conversation using Google's Gemini API with Server-Sent Events.
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
      case Expi.AI.Streaming.create_production_stream(url, body, headers, "google", model.id) do
        {:ok, raw_stream} ->
          # Transform Gemini SSE events to standardized events
          transformed_stream = 
            raw_stream
            |> Stream.map(fn event -> transform_gemini_event(event, payload) end)
            |> Stream.filter(fn event -> not is_nil(event) end)
          
          {:ok, transformed_stream}
        
        {:error, reason} ->
          # Return the actual error (missing API key, network issues, etc.)
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_streaming_payload(model, context, options) do
    # Same as regular payload but with streamGenerationConfig
    with {:ok, payload} <- build_request_payload(model, context, options) do
      streaming_config = %{
        "generationConfig" => Map.merge(
          Map.get(payload, "generationConfig", %{}),
          %{"stream" => true}
        )
      }
      streaming_payload = Map.merge(payload, streaming_config)
      {:ok, streaming_payload}
    end
  end

  defp prepare_streaming_headers(model) do
    with {:ok, headers} <- prepare_request_headers(model) do
      # Add streaming-specific headers for Gemini
      streaming_headers = [
        {"Accept", "text/event-stream"},
        {"Cache-Control", "no-cache"} | headers
      ]
      {:ok, streaming_headers}
    end
  end

  defp build_streaming_url(model) do
    base_url = model.base_url || "https://generativelanguage.googleapis.com"
    case Expi.AI.Auth.get_api_key("google") do
      {:ok, api_key} ->
        url = "#{base_url}/v1beta/models/#{model.id}:streamGenerateContent?key=#{api_key}"
        {:ok, url}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transform_gemini_event(sse_event, _payload) do
    # Parse Gemini-specific SSE event format and convert to standardized AssistantMessageEvent
    Expi.AI.Streaming.standardize_event(sse_event, "google")
  end

  defp generate_tool_call_id do
    "call_#{:rand.uniform(100_000_000)}"
  end
end