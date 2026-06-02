defmodule Expi.AI.Streaming do
  @moduledoc """
  Streaming support for AI providers.
  Handles Server-Sent Events (SSE) and real-time response processing.
  """

  require Logger

  alias Expi.Types.{
    AssistantMessage,
    AssistantMessageEvent,
    Context,
    Model,
    TextContent,
    ThinkingContent,
    ToolCall
  }

  @doc """
  Creates a stream of events from a provider's streaming response.
  """
  @spec stream_events(Model.t(), Context.t(), map()) :: {:ok, Enumerable.t()} | {:error, atom()}
  def stream_events(%Model{provider: "anthropic"} = model, context, options) do
    Expi.Providers.Anthropic.stream(model, context, options)
  end

  def stream_events(%Model{provider: "google"} = model, context, options) do
    Expi.Providers.Gemini.stream(model, context, options)
  end

  def stream_events(%Model{provider: "ollama"} = model, context, options) do
    Expi.Providers.Ollama.stream(model, context, options)
  end

  def stream_events(%Model{provider: provider}, _context, _options) do
    {:error, {:unsupported_provider, provider}}
  end

  def stream_events(nil, _context, _options) do
    {:error, :invalid_model}
  end

  def stream_events(_model, nil, _options) do
    {:error, :invalid_context}
  end

  @doc """
  Creates a production streaming enumerable from HTTP SSE stream.
  """
  @spec create_production_stream(String.t(), map() | String.t(), list(), String.t(), String.t()) ::
          {:ok, Enumerable.t()} | {:error, atom()}
  def create_production_stream(url, body, headers, provider, model_id) do
    case Expi.AI.HttpClient.stream_post(url, body, headers) do
      {:ok, http_stream} ->
        event_stream =
          http_stream
          |> accumulate_sse_chunks()
          |> Stream.flat_map(&parse_sse_chunk/1)
          |> Stream.filter(fn event -> event != :skip and not is_nil(event) end)
          |> Stream.map(fn sse_event -> standardize_event(sse_event, provider) end)
          |> Stream.filter(fn event -> not is_nil(event) end)
          |> add_telemetry_tracking(provider, model_id)

        {:ok, event_stream}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Accumulates HTTP chunks into complete SSE events.

  HTTP streaming can send partial chunks, but SSE events need complete
  data blocks ending with double newlines.
  """
  @spec accumulate_sse_chunks(Enumerable.t()) :: Enumerable.t()
  def accumulate_sse_chunks(http_stream) do
    http_stream
    |> Stream.transform("", fn chunk, buffer ->
      # Accumulate chunks in buffer
      new_buffer = buffer <> chunk

      # Split on double newlines to find complete events
      parts = String.split(new_buffer, "\n\n")

      case parts do
        [incomplete] ->
          # No complete events yet, keep accumulating
          {[], incomplete}

        parts_list when length(parts_list) > 1 ->
          # Last part might be incomplete, others are complete events
          {remaining_buffer, complete_parts} = List.pop_at(parts_list, -1)

          # Add back double newlines to complete events (except empty ones)
          complete_events =
            complete_parts
            |> Enum.reject(&(String.trim(&1) == ""))
            |> Enum.map(&(&1 <> "\n\n"))

          {complete_events, remaining_buffer || ""}
      end
    end)
  end

  @doc """
  Creates a fallback stream for testing when production streaming is not available.
  """
  @spec create_fallback_stream(String.t(), String.t()) :: {:ok, Enumerable.t()}
  def create_fallback_stream(provider, model_id) do
    # Generate realistic sample streaming events for testing
    sample_events = [
      %AssistantMessageEvent{
        type: :start,
        content_index: 0,
        delta: nil,
        message: %AssistantMessage{
          role: :assistant,
          content: [],
          api: "streaming",
          provider: provider,
          model: model_id,
          usage: %Expi.Types.Usage{
            input: 0,
            output: 0,
            cache_read: 0,
            cache_write: 0,
            total_tokens: 0,
            cost: %Expi.Types.Cost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0}
          },
          stop_reason: nil,
          error_message: nil,
          timestamp: System.system_time(:millisecond)
        }
      },
      %AssistantMessageEvent{
        type: :text_start,
        content_index: 0,
        delta: nil,
        message: nil
      },
      %AssistantMessageEvent{
        type: :text_delta,
        content_index: 0,
        delta: "Hello! I'm an AI assistant. How can I help you today?",
        message: nil
      },
      %AssistantMessageEvent{
        type: :text_end,
        content_index: 0,
        delta: nil,
        message: nil
      },
      %AssistantMessageEvent{
        type: :done,
        content_index: 0,
        delta: nil,
        reason: :stop,
        message: %AssistantMessage{
          role: :assistant,
          content: [
            %TextContent{
              type: :text,
              text: "Hello! I'm an AI assistant. How can I help you today?"
            }
          ],
          api: "streaming",
          provider: provider,
          model: model_id,
          usage: %Expi.Types.Usage{
            input: 20,
            output: 15,
            cache_read: 0,
            cache_write: 0,
            total_tokens: 35,
            cost: %Expi.Types.Cost{input: 0.001, output: 0.002, cache_read: 0.0, cache_write: 0.0}
          },
          stop_reason: :stop,
          error_message: nil,
          timestamp: System.system_time(:millisecond)
        }
      }
    ]

    {:ok, Stream.cycle(sample_events) |> Stream.take(length(sample_events))}
  end

  @doc """
  Parses Server-Sent Events (SSE) stream data.
  """
  @spec parse_sse_chunk(String.t()) :: list(map())
  def parse_sse_chunk(chunk) when is_binary(chunk) do
    chunk
    |> String.split("\n\n")
    |> Enum.filter(&(String.trim(&1) != ""))
    |> Enum.map(&parse_single_sse_event/1)
    |> Enum.filter(& &1)
  end

  defp parse_single_sse_event(event_string) do
    lines = String.split(event_string, "\n")

    event_data =
      %{}
      |> parse_sse_lines(lines)

    case event_data do
      %{"data" => data} when data != "[DONE]" ->
        case Jason.decode(data) do
          {:ok, parsed} -> parsed
          {:error, _} -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_sse_lines(acc, []), do: acc

  defp parse_sse_lines(acc, [line | rest]) do
    case String.split(line, ": ", parts: 2) do
      ["data", value] -> parse_sse_lines(Map.put(acc, "data", value), rest)
      ["event", value] -> parse_sse_lines(Map.put(acc, "event", value), rest)
      ["id", value] -> parse_sse_lines(Map.put(acc, "id", value), rest)
      _ -> parse_sse_lines(acc, rest)
    end
  end

  @doc """
  Converts provider-specific streaming events to standardized AssistantMessageEvent format.
  """
  @spec standardize_event(map(), String.t()) :: AssistantMessageEvent.t() | nil
  def standardize_event(event_data, "anthropic") do
    log_anthropic_event(event_data)
    standardize_anthropic_event(event_data)
  end

  defp standardize_anthropic_event(%{"type" => "message_start"}) do
    %AssistantMessageEvent{type: :start}
  end

  defp standardize_anthropic_event(%{"type" => "content_block_start", "content_block" => block} = data) do
    index = Map.get(data, "index")

    case block["type"] do
      "text" -> %AssistantMessageEvent{type: :text_start, content_index: index}
      "thinking" -> %AssistantMessageEvent{type: :thinking_start, content_index: index}
      "tool_use" ->
        %AssistantMessageEvent{
          type: :toolcall_start,
          content_index: index,
          tool_call: %ToolCall{
            type: :tool_call,
            id: block["id"] || "",
            name: block["name"] || "",
            arguments: block["input"] || %{}
          }
        }
    end
  end

  defp standardize_anthropic_event(%{"type" => "content_block_delta", "delta" => delta, "index" => index}) do
    case delta["type"] do
      "text_delta" -> %AssistantMessageEvent{type: :text_delta, content_index: index, delta: delta["text"]}
      "thinking_delta" -> %AssistantMessageEvent{type: :thinking_delta, content_index: index, delta: delta["thinking"]}
      "input_json_delta" -> %AssistantMessageEvent{type: :toolcall_delta, content_index: index, delta: delta["partial_json"]}
      _ -> nil
    end
  end

  defp standardize_anthropic_event(%{"type" => "content_block_stop", "index" => index} = stop_event) do
    case get_in(stop_event, ["content_block", "type"]) do
      "thinking" -> %AssistantMessageEvent{type: :thinking_end, content_index: index}
      "tool_use" -> %AssistantMessageEvent{type: :toolcall_end, content_index: index}
      _ -> %AssistantMessageEvent{type: :text_end, content_index: index}
    end
  end

  defp standardize_anthropic_event(%{"type" => "message_delta", "delta" => %{"stop_reason" => stop_reason}}) do
    %AssistantMessageEvent{type: :done, reason: parse_anthropic_stop_reason(stop_reason)}
  end

  defp standardize_anthropic_event(%{"type" => "message_stop"}), do: %AssistantMessageEvent{type: :done}

  defp standardize_anthropic_event(%{"type" => "error", "error" => error}) do
    %AssistantMessageEvent{type: :error, error: %{message: error["message"], type: error["type"]}}
  end

  defp standardize_anthropic_event(_), do: nil

  defp log_anthropic_event(%{"type" => type} = data) do
    summary = %{
      type: type,
      index: Map.get(data, "index"),
      delta_type: get_in(data, ["delta", "type"]),
      block_type: get_in(data, ["content_block", "type"]),
      stop_reason: get_in(data, ["delta", "stop_reason"])
    }

    Logger.debug("Anthropic stream event #{inspect(summary)}")
  end

  defp log_anthropic_event(_), do: :ok

  def standardize_event(event_data, "google"), do: standardize_google_event(event_data)
  def standardize_event(event_data, "ollama"), do: standardize_ollama_event(event_data)

  defp standardize_google_event(%{"candidates" => [candidate | _]}), do: standardize_google_candidate(candidate)

  defp standardize_google_event(%{"error" => error}) do
    %AssistantMessageEvent{type: :error, error: %{message: error["message"], code: error["code"]}}
  end

  defp standardize_google_event(_), do: nil

  defp standardize_google_candidate(%{"content" => %{"parts" => [%{"text" => text}]}}) do
    %AssistantMessageEvent{type: :text_delta, content_index: 0, delta: text}
  end

  defp standardize_google_candidate(%{"finishReason" => reason}) do
    %AssistantMessageEvent{type: :done, reason: parse_gemini_stop_reason(reason)}
  end

  defp standardize_google_candidate(_), do: nil

  defp standardize_ollama_event(%{"choices" => [choice | _]}), do: standardize_ollama_choice(choice)

  defp standardize_ollama_event(%{"error" => error}) do
    %AssistantMessageEvent{type: :error, error: %{message: error["message"], type: error["type"]}}
  end

  defp standardize_ollama_event(_), do: nil

  defp standardize_ollama_choice(%{"finish_reason" => reason}) when not is_nil(reason) do
    %AssistantMessageEvent{type: :done, reason: parse_ollama_stop_reason(reason)}
  end

  defp standardize_ollama_choice(%{"delta" => delta}), do: standardize_ollama_delta(delta)
  defp standardize_ollama_choice(_), do: nil

  defp standardize_ollama_delta(%{"content" => content}) when is_binary(content) do
    %AssistantMessageEvent{type: :text_delta, content_index: 0, delta: content}
  end

  defp standardize_ollama_delta(%{"tool_calls" => tool_calls}) do
    %AssistantMessageEvent{type: :toolcall_delta, content_index: 0, tool_call: parse_tool_call_delta(tool_calls)}
  end

  defp standardize_ollama_delta(_), do: nil

  # Helper functions for stop reason parsing
  defp parse_anthropic_stop_reason("end_turn"), do: :stop
  defp parse_anthropic_stop_reason("max_tokens"), do: :max_tokens
  defp parse_anthropic_stop_reason("tool_use"), do: :tool_use
  defp parse_anthropic_stop_reason(_), do: :unknown

  defp parse_gemini_stop_reason("STOP"), do: :stop
  defp parse_gemini_stop_reason("MAX_TOKENS"), do: :max_tokens
  defp parse_gemini_stop_reason("SAFETY"), do: :content_filter
  defp parse_gemini_stop_reason(_), do: :unknown

  defp parse_ollama_stop_reason("stop"), do: :stop
  defp parse_ollama_stop_reason("length"), do: :length
  defp parse_ollama_stop_reason("tool_calls"), do: :tool_use
  defp parse_ollama_stop_reason(_), do: :unknown

  defp parse_tool_call_delta([tool_call | _]) do
    %ToolCall{
      type: :tool_call,
      id: tool_call["id"],
      name: tool_call["function"]["name"],
      arguments: tool_call["function"]["arguments"]
    }
  end

  defp parse_tool_call_delta(_), do: nil

  @doc """
  Accumulates streaming events into a complete AssistantMessage.
  """
  @spec accumulate_message(AssistantMessage.t(), AssistantMessageEvent.t()) ::
          AssistantMessage.t()
  def accumulate_message(message, %AssistantMessageEvent{type: :start}) do
    message
  end

  def accumulate_message(message, %AssistantMessageEvent{type: :text_start, content_index: index}) do
    # Ensure we have enough content slots
    content = ensure_content_slots(message.content, index)
    text_content = %TextContent{type: :text, text: ""}
    new_content = List.replace_at(content, index, text_content)
    %{message | content: new_content}
  end

  def accumulate_message(message, %AssistantMessageEvent{
        type: :text_delta,
        content_index: index,
        delta: delta
      }) do
    content = message.content

    case Enum.at(content, index) do
      %TextContent{text: existing_text} = text_content ->
        updated_content = %{text_content | text: existing_text <> delta}
        new_content = List.replace_at(content, index, updated_content)
        %{message | content: new_content}

      _ ->
        # Create new text content if it doesn't exist
        text_content = %TextContent{type: :text, text: delta}
        content = ensure_content_slots(content, index)
        new_content = List.replace_at(content, index, text_content)
        %{message | content: new_content}
    end
  end

  def accumulate_message(message, %AssistantMessageEvent{
        type: :thinking_start,
        content_index: index
      }) do
    content = ensure_content_slots(message.content, index)
    thinking_content = %ThinkingContent{type: :thinking, thinking: ""}
    new_content = List.replace_at(content, index, thinking_content)
    %{message | content: new_content}
  end

  def accumulate_message(message, %AssistantMessageEvent{
        type: :thinking_delta,
        content_index: index,
        delta: delta
      }) do
    content = message.content

    case Enum.at(content, index) do
      %ThinkingContent{thinking: existing_thinking} = thinking_content ->
        updated_content = %{thinking_content | thinking: existing_thinking <> delta}
        new_content = List.replace_at(content, index, updated_content)
        %{message | content: new_content}

      _ ->
        # Create new thinking content if it doesn't exist
        thinking_content = %ThinkingContent{type: :thinking, thinking: delta}
        content = ensure_content_slots(content, index)
        new_content = List.replace_at(content, index, thinking_content)
        %{message | content: new_content}
    end
  end

  def accumulate_message(message, %AssistantMessageEvent{type: :done, reason: reason}) do
    %{message | stop_reason: reason, timestamp: System.system_time(:millisecond)}
  end

  def accumulate_message(message, %AssistantMessageEvent{type: :error, error: error}) do
    %{message | error_message: error.message, timestamp: System.system_time(:millisecond)}
  end

  def accumulate_message(message, _event) do
    # Ignore unknown events
    message
  end

  # Helper to ensure content list has enough slots
  defp ensure_content_slots(content, target_index) do
    current_length = length(content)

    if target_index >= current_length do
      content ++ List.duplicate(nil, target_index - current_length + 1)
    else
      content
    end
  end

  # Production streaming helper functions

  # Converts SSE event data to AssistantMessageEvent format.
  @spec convert_sse_to_assistant_event(map(), String.t(), String.t()) ::
          AssistantMessageEvent.t() | nil
  defp convert_sse_to_assistant_event(%{"event" => "start"}, provider, model_id) do
    %AssistantMessageEvent{
      type: :start,
      content_index: 0,
      delta: nil,
      message: create_initial_message(provider, model_id, System.system_time(:millisecond))
    }
  end

  defp convert_sse_to_assistant_event(%{"event" => "content_block_start", "data" => data}, _provider, _model_id),
    do: convert_content_block_start(data)

  defp convert_sse_to_assistant_event(%{"event" => "content_block_delta", "data" => data}, _provider, _model_id),
    do: convert_content_block_delta(data)

  defp convert_sse_to_assistant_event(%{"event" => "message_delta", "data" => data}, provider, _model_id),
    do: convert_message_delta(data, provider)

  defp convert_sse_to_assistant_event(%{"event" => "message_stop"}, _provider, _model_id) do
    %AssistantMessageEvent{type: :done, content_index: 0, delta: nil, reason: :stop, message: nil}
  end

  defp convert_sse_to_assistant_event(%{"event" => "error", "data" => error_data}, _provider, _model_id) do
    %AssistantMessageEvent{
      type: :error,
      content_index: 0,
      delta: nil,
      error: %{message: error_data["message"], type: error_data["type"]},
      message: nil
    }
  end

  defp convert_sse_to_assistant_event(_, _provider, _model_id), do: nil

  defp convert_content_block_start(%{"content_block" => %{"type" => "text"}} = data) do
    %AssistantMessageEvent{type: :text_start, content_index: data["index"] || 0, delta: nil, message: nil}
  end

  defp convert_content_block_start(%{"content_block" => %{"type" => "tool_use"}} = data) do
    %AssistantMessageEvent{type: :toolcall_start, content_index: data["index"] || 0, delta: nil, message: nil}
  end

  defp convert_content_block_start(_), do: nil

  defp convert_content_block_delta(%{"delta" => %{"type" => "text_delta", "text" => text}} = data) do
    %AssistantMessageEvent{type: :text_delta, content_index: data["index"] || 0, delta: text, message: nil}
  end

  defp convert_content_block_delta(%{"delta" => %{"type" => "input_json_delta", "partial_json" => partial}} = data) do
    %AssistantMessageEvent{type: :toolcall_delta, content_index: data["index"] || 0, delta: partial, message: nil}
  end

  defp convert_content_block_delta(_), do: nil

  defp convert_message_delta(%{"delta" => %{"stop_reason" => stop_reason}}, provider) when not is_nil(stop_reason) do
    %AssistantMessageEvent{
      type: :done,
      content_index: 0,
      delta: nil,
      reason: parse_stop_reason(stop_reason, provider),
      message: nil
    }
  end

  defp convert_message_delta(_, _provider), do: nil

  defp create_initial_message(provider, model_id, _timestamp) do
    %AssistantMessage{
      role: :assistant,
      content: [],
      api: "streaming",
      provider: provider,
      model: model_id,
      usage: %Expi.Types.Usage{
        input: 0,
        output: 0,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 0,
        cost: %Expi.Types.Cost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0}
      },
      stop_reason: nil,
      error_message: nil
    }
  end

  defp parse_stop_reason(reason, provider) do
    case provider do
      "anthropic" -> parse_anthropic_stop_reason(reason)
      "google" -> parse_gemini_stop_reason(reason)
      "ollama" -> parse_ollama_stop_reason(reason)
      _ -> :unknown
    end
  end

  # Adds telemetry tracking to the event stream.
  @spec add_telemetry_tracking(Enumerable.t(), String.t(), String.t()) :: Enumerable.t()
  defp add_telemetry_tracking(stream, provider, model_id) do
    start_time = System.monotonic_time(:millisecond)

    stream
    |> Stream.map(fn event ->
      # Emit telemetry for each event
      Expi.AI.Telemetry.emit_stream_event(provider, model_id, event.type)
      event
    end)
    |> Stream.with_index()
    |> Stream.map(fn {event, index} ->
      # Track final session metrics on last event
      if event.type == :done or event.type == :error do
        duration = System.monotonic_time(:millisecond) - start_time
        Expi.AI.Telemetry.emit_stream_session(provider, model_id, duration, index + 1)
      end

      event
    end)
  end
end
