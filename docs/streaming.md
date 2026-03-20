# ExpiAI Streaming Guide

This guide covers ExpiAI's comprehensive streaming capabilities, including Server-Sent Events (SSE), event types, and real-time processing patterns.

## Table of Contents

1. [Streaming Overview](#streaming-overview)
2. [Event System](#event-system)
3. [Basic Streaming Usage](#basic-streaming-usage)
4. [Advanced Streaming Patterns](#advanced-streaming-patterns)
5. [Provider-Specific Streaming](#provider-specific-streaming)
6. [Error Handling](#error-handling)
7. [Performance Optimization](#performance-optimization)

## Streaming Overview

ExpiAI provides real-time streaming for AI responses using Server-Sent Events (SSE). This enables:

- **Real-time feedback**: See responses as they're generated
- **Better UX**: Progressive loading for long responses
- **Interactive experiences**: Build chat interfaces with typing indicators
- **Reasoning transparency**: See model thinking process (Claude)

### Streaming vs Synchronous

| Aspect | Synchronous | Streaming |
|--------|-------------|-----------|
| **Response Time** | Wait for complete response | Immediate feedback |
| **User Experience** | Loading spinner | Progressive text |
| **Memory Usage** | Full response in memory | Process incrementally |
| **Error Handling** | Single point of failure | Partial response on errors |
| **Complexity** | Simple | More complex event handling |

## Event System

ExpiAI uses a standardized event system across all providers with 12 event types:

### Lifecycle Events

- `start` - Stream begins, includes initial message structure
- `done` - Stream completes, includes final message with usage/cost
- `error` - Stream fails, includes error details

### Text Generation Events

- `text_start` - Text content block starts
- `text_delta` - Incremental text content
- `text_end` - Text content block ends

### Reasoning Events (Claude only)

- `thinking_start` - Reasoning content starts
- `thinking_delta` - Incremental reasoning content  
- `thinking_end` - Reasoning content ends

### Tool Calling Events

- `toolcall_start` - Tool call begins
- `toolcall_delta` - Incremental tool call data
- `toolcall_end` - Tool call completes

## Basic Streaming Usage

### Simple Streaming

```elixir
alias Expi.AI
alias Expi.Types.{Context, UserMessage}

# Setup model and context
{:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")

context = %Context{
  system_prompt: "You are a helpful assistant.",
  messages: [
    %UserMessage{
      role: :user,
      content: "Tell me a story about a brave knight",
      timestamp: System.system_time(:millisecond)
    }
  ]
}

# Start streaming
{:ok, stream} = AI.stream_simple(model, context)

# Process events
stream
|> Stream.each(fn event ->
  case event.type do
    :start ->
      IO.puts("🎯 Starting story generation...")
    
    :text_start ->
      IO.puts("\n📖 Story:")
    
    :text_delta ->
      IO.write(event.delta)
    
    :text_end ->
      IO.puts("\n")
    
    :done ->
      IO.puts("✅ Story complete!")
      IO.puts("Tokens used: #{event.message.usage.input + event.message.usage.output}")
      IO.puts("Cost: $#{event.message.usage.cost.input + event.message.usage.cost.output}")
    
    :error ->
      IO.puts("❌ Error: #{event.error.message}")
  end
end)
|> Stream.run()
```

### Accumulating Content

```elixir
defmodule MyApp.StreamAccumulator do
  alias Expi.Types.{AssistantMessage, TextContent}

  def accumulate_stream(stream) do
    stream
    |> Stream.scan(%{content: "", message: nil}, fn event, acc ->
      case event.type do
        :start ->
          %{acc | message: event.message}
        
        :text_delta ->
          %{acc | content: acc.content <> event.delta}
        
        :done ->
          final_message = %{event.message | 
            content: [%TextContent{type: :text, text: acc.content}]
          }
          %{acc | message: final_message}
        
        _ ->
          acc
      end
    end)
    |> Stream.drop_while(fn acc -> is_nil(acc.message) end)
  end
end

# Usage
{:ok, stream} = AI.stream_simple(model, context)

accumulated_stream = MyApp.StreamAccumulator.accumulate_stream(stream)

# Get final result
final_state = accumulated_stream |> Enum.to_list() |> List.last()
IO.puts("Final content: #{final_state.content}")
IO.puts("Final message: #{inspect(final_state.message)}")
```

## Advanced Streaming Patterns

### Phoenix LiveView Integration

```elixir
defmodule MyAppWeb.ChatLive do
  use MyAppWeb, :live_view
  
  alias Expi.AI
  alias Expi.Types.{Context, UserMessage}

  def mount(_params, _session, socket) do
    {:ok, model} = AI.get_model("anthropic", "claude-sonnet-3-6")
    
    socket = assign(socket,
      model: model,
      messages: [],
      current_response: "",
      streaming: false
    )
    
    {:ok, socket}
  end

  def handle_event("send_message", %{"message" => message}, socket) do
    if socket.assigns.streaming do
      {:noreply, socket}
    else
      # Add user message
      user_message = %UserMessage{
        role: :user,
        content: message,
        timestamp: System.system_time(:millisecond)
      }
      
      messages = socket.assigns.messages ++ [user_message]
      
      # Start streaming
      context = %Context{messages: messages}
      Task.async(fn -> stream_response(socket.assigns.model, context) end)
      
      socket = assign(socket,
        messages: messages,
        current_response: "",
        streaming: true
      )
      
      {:noreply, socket}
    end
  end

  def handle_info({:stream_event, event}, socket) do
    case event.type do
      :text_delta ->
        current = socket.assigns.current_response
        socket = assign(socket, current_response: current <> event.delta)
        {:noreply, socket}
      
      :done ->
        # Add complete assistant message
        assistant_message = event.message
        messages = socket.assigns.messages ++ [assistant_message]
        
        socket = assign(socket,
          messages: messages,
          current_response: "",
          streaming: false
        )
        
        {:noreply, socket}
      
      :error ->
        socket = assign(socket,
          current_response: "Error: #{event.error.message}",
          streaming: false
        )
        
        {:noreply, socket}
      
      _ ->
        {:noreply, socket}
    end
  end

  defp stream_response(model, context) do
    case AI.stream_simple(model, context) do
      {:ok, stream} ->
        stream
        |> Stream.each(fn event ->
          send(self(), {:stream_event, event})
        end)
        |> Stream.run()
      
      {:error, reason} ->
        error_event = %{type: :error, error: %{message: "#{reason}"}}
        send(self(), {:stream_event, error_event})
    end
  end

  def render(assigns) do
    ~H"""
    <div id="chat-container">
      <div id="messages">
        <%= for message <- @messages do %>
          <div class="message <%= message.role %>">
            <%= render_message_content(message.content) %>
          </div>
        <% end %>
        
        <%= if @streaming and @current_response != "" do %>
          <div class="message assistant streaming">
            <%= @current_response %>
            <span class="cursor">|</span>
          </div>
        <% end %>
      </div>
      
      <form phx-submit="send_message">
        <input 
          type="text" 
          name="message" 
          placeholder="Type a message..."
          disabled={@streaming}
        />
        <button type="submit" disabled={@streaming}>
          <%= if @streaming, do: "Generating...", else: "Send" %>
        </button>
      </form>
    </div>
    """
  end

  defp render_message_content(content) when is_binary(content), do: content
  defp render_message_content([%{text: text}]), do: text
  defp render_message_content(_), do: ""
end
```

### GenServer Streaming Handler

```elixir
defmodule MyApp.StreamingService do
  use GenServer
  
  alias Expi.AI
  alias Expi.Types.{Context, UserMessage}

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def stream_request(provider, model_id, message, callback_pid) do
    GenServer.cast(__MODULE__, {:stream_request, provider, model_id, message, callback_pid})
  end

  def cancel_stream do
    GenServer.cast(__MODULE__, :cancel_stream)
  end

  # Server Implementation

  def init(_opts) do
    {:ok, %{current_task: nil, callback_pid: nil}}
  end

  def handle_cast({:stream_request, provider, model_id, message, callback_pid}, state) do
    # Cancel existing stream if any
    if state.current_task do
      Task.shutdown(state.current_task, :brutal_kill)
    end

    # Start new streaming task
    task = Task.async(fn ->
      with {:ok, model} <- AI.get_model(provider, model_id),
           context <- build_context(message),
           {:ok, stream} <- AI.stream_simple(model, context) do
        
        process_stream(stream, callback_pid)
      else
        {:error, reason} ->
          send(callback_pid, {:stream_error, reason})
      end
    end)

    new_state = %{state | current_task: task, callback_pid: callback_pid}
    {:noreply, new_state}
  end

  def handle_cast(:cancel_stream, state) do
    if state.current_task do
      Task.shutdown(state.current_task, :brutal_kill)
      send(state.callback_pid, :stream_cancelled)
    end

    new_state = %{state | current_task: nil, callback_pid: nil}
    {:noreply, new_state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Task completed or crashed
    new_state = %{state | current_task: nil, callback_pid: nil}
    {:noreply, new_state}
  end

  # Private functions

  defp build_context(message) do
    %Context{
      messages: [
        %UserMessage{
          role: :user,
          content: message,
          timestamp: System.system_time(:millisecond)
        }
      ]
    }
  end

  defp process_stream(stream, callback_pid) do
    try do
      stream
      |> Stream.each(fn event ->
        send(callback_pid, {:stream_event, event})
        
        # Add small delay to prevent overwhelming the callback
        Process.sleep(10)
      end)
      |> Stream.run()
      
      send(callback_pid, :stream_complete)
    rescue
      error ->
        send(callback_pid, {:stream_error, error})
    end
  end
end

# Usage
{:ok, _pid} = MyApp.StreamingService.start_link([])

# Start streaming
MyApp.StreamingService.stream_request(
  "anthropic", 
  "claude-opus-4-5",
  "Explain quantum physics",
  self()
)

# Handle events
receive do
  {:stream_event, event} -> 
    handle_stream_event(event)
    
  {:stream_error, reason} ->
    IO.puts("Stream failed: #{inspect(reason)}")
    
  :stream_complete ->
    IO.puts("Stream completed successfully")
    
  :stream_cancelled ->
    IO.puts("Stream was cancelled")
end
```

### Streaming with Backpressure

```elixir
defmodule MyApp.BackpressureStreaming do
  def stream_with_backpressure(model, context, opts \\ []) do
    buffer_size = Keyword.get(opts, :buffer_size, 100)
    demand_threshold = Keyword.get(opts, :demand_threshold, 50)
    
    with {:ok, stream} <- AI.stream_simple(model, context) do
      stream
      |> Stream.chunk_every(buffer_size)
      |> Stream.map(fn chunk ->
        # Process chunk
        process_chunk(chunk)
        
        # Check if we need to slow down
        if length(chunk) > demand_threshold do
          Process.sleep(100)  # Brief pause
        end
        
        chunk
      end)
      |> Stream.flat_map(&(&1))
    end
  end

  defp process_chunk(events) do
    # Aggregate events for efficient processing
    text_deltas = 
      events
      |> Enum.filter(& &1.type == :text_delta)
      |> Enum.map(& &1.delta)
      |> Enum.join("")
    
    if text_deltas != "" do
      IO.write(text_deltas)
    end
    
    # Process other event types
    events
    |> Enum.filter(& &1.type != :text_delta)
    |> Enum.each(&handle_non_text_event/1)
  end

  defp handle_non_text_event(%{type: :start}), do: IO.puts("🎯 Starting...")
  defp handle_non_text_event(%{type: :done}), do: IO.puts("\n✅ Complete!")
  defp handle_non_text_event(%{type: :error} = event), do: IO.puts("❌ #{event.error.message}")
  defp handle_non_text_event(_), do: :ok
end
```

## Provider-Specific Streaming

### Anthropic Claude Streaming

Claude supports reasoning/thinking mode in streaming:

```elixir
{:ok, model} = AI.get_model("anthropic", "claude-opus-4-5")

context = %Context{
  messages: [
    %UserMessage{
      role: :user,
      content: "Solve this complex problem step by step: How would you design a distributed caching system?",
      timestamp: System.system_time(:millisecond)
    }
  ]
}

# Enable thinking mode
{:ok, stream} = AI.stream_simple(model, context, %{thinking: true})

stream
|> Stream.each(fn event ->
  case event.type do
    :thinking_start ->
      IO.puts("\n🤔 Claude is thinking...")
      IO.puts("=" |> String.duplicate(50))
    
    :thinking_delta ->
      IO.write(event.delta)
    
    :thinking_end ->
      IO.puts("\n" <> "=" |> String.duplicate(50))
      IO.puts("💡 Claude's response:")
    
    :text_delta ->
      IO.write(event.delta)
    
    :done ->
      IO.puts("\n✅ Analysis complete!")
  end
end)
|> Stream.run()
```

### Google Gemini Streaming

Gemini streaming with safety monitoring:

```elixir
{:ok, model} = AI.get_model("google", "gemini-pro")

{:ok, stream} = AI.stream_simple(model, context, %{
  safety_settings: [
    %{category: "HARM_CATEGORY_HARASSMENT", threshold: "BLOCK_MEDIUM_AND_ABOVE"}
  ]
})

stream
|> Stream.each(fn event ->
  case event.type do
    :text_delta ->
      IO.write(event.delta)
    
    :error ->
      case event.error.type do
        "SAFETY_FILTER" ->
          IO.puts("\n🚫 Content blocked by safety filter")
        _ ->
          IO.puts("\n❌ Error: #{event.error.message}")
      end
    
    :done ->
      IO.puts("\n✅ Gemini response complete!")
  end
end)
|> Stream.run()
```

### Ollama Streaming

Local model streaming:

```elixir
{:ok, model} = AI.get_model("ollama", "llama3.1:8b")

{:ok, stream} = AI.stream_simple(model, context)

# Monitor local resource usage during streaming
stream
|> Stream.with_index()
|> Stream.each(fn {event, index} ->
  case event.type do
    :text_delta ->
      IO.write(event.delta)
      
      # Monitor every 100 events
      if rem(index, 100) == 0 do
        memory_mb = :erlang.memory(:total) |> div(1024 * 1024)
        IO.puts("[Memory: #{memory_mb}MB]")
      end
    
    :done ->
      IO.puts("\n🏠 Local completion finished!")
  end
end)
|> Stream.run()
```

## Error Handling

### Resilient Streaming

```elixir
defmodule MyApp.ResilientStreaming do
  def safe_stream(model, context, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, 3)
    retry_delay = Keyword.get(opts, :retry_delay, 1000)
    
    attempt_stream(model, context, max_retries, retry_delay)
  end

  defp attempt_stream(model, context, retries_left, retry_delay) do
    case AI.stream_simple(model, context) do
      {:ok, stream} ->
        # Wrap stream with error handling
        safe_stream = create_safe_stream(stream, model, context, retries_left, retry_delay)
        {:ok, safe_stream}
      
      {:error, reason} when retries_left > 0 ->
        IO.puts("Stream failed, retrying in #{retry_delay}ms: #{inspect(reason)}")
        Process.sleep(retry_delay)
        attempt_stream(model, context, retries_left - 1, retry_delay * 2)
      
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_safe_stream(stream, model, context, retries_left, retry_delay) do
    Stream.flat_map(stream, fn event ->
      case event.type do
        :error ->
          if retries_left > 0 do
            IO.puts("Stream error, attempting recovery...")
            
            case attempt_stream(model, context, retries_left - 1, retry_delay) do
              {:ok, new_stream} ->
                new_stream
              
              {:error, _} ->
                [event]  # Return original error
            end
          else
            [event]
          end
        
        _ ->
          [event]
      end
    end)
  end
end

# Usage
case MyApp.ResilientStreaming.safe_stream(model, context, max_retries: 3) do
  {:ok, stream} ->
    stream
    |> Stream.each(&handle_stream_event/1)
    |> Stream.run()
  
  {:error, reason} ->
    IO.puts("Streaming failed permanently: #{inspect(reason)}")
end
```

### Network Interruption Handling

```elixir
defmodule MyApp.NetworkAwareStreaming do
  def stream_with_network_recovery(model, context) do
    with {:ok, stream} <- AI.stream_simple(model, context) do
      stream
      |> Stream.transform(
        fn -> %{last_event: nil, buffer: []} end,
        fn event, acc ->
          case event.type do
            :error ->
              case event.error.type do
                :network_error ->
                  # Attempt to reconnect and resume
                  case resume_stream(model, context, acc.last_event) do
                    {:ok, resumed_stream} ->
                      {acc.buffer, %{acc | buffer: []}}
                    
                    {:error, _} ->
                      {[event], acc}
                  end
                
                _ ->
                  {[event], acc}
              end
            
            _ ->
              new_acc = %{acc | last_event: event}
              {[event], new_acc}
          end
        end,
        fn _acc -> [] end
      )
    end
  end

  defp resume_stream(model, context, last_event) do
    # Wait before attempting to resume
    Process.sleep(2000)
    
    # Try to resume from where we left off
    # (This is a simplified example - real implementation would need
    # to track position in the stream)
    AI.stream_simple(model, context)
  end
end
```

## Performance Optimization

### Streaming Buffer Management

```elixir
defmodule MyApp.OptimizedStreaming do
  def optimized_stream(model, context, opts \\ []) do
    buffer_size = Keyword.get(opts, :buffer_size, 50)
    flush_interval = Keyword.get(opts, :flush_interval, 100)
    
    with {:ok, stream} <- AI.stream_simple(model, context) do
      stream
      |> Stream.chunk_every(buffer_size)
      |> Stream.map(&process_buffer(&1, flush_interval))
      |> Stream.flat_map(&(&1))
    end
  end

  defp process_buffer(events, flush_interval) do
    start_time = System.monotonic_time(:millisecond)
    
    # Group similar events
    grouped = Enum.group_by(events, & &1.type)
    
    # Process text deltas efficiently
    text_deltas = Map.get(grouped, :text_delta, [])
    if length(text_deltas) > 0 do
      combined_text = 
        text_deltas
        |> Enum.map(& &1.delta)
        |> Enum.join("")
      
      IO.write(combined_text)
    end
    
    # Process other events
    other_events = 
      grouped
      |> Map.drop([:text_delta])
      |> Map.values()
      |> List.flatten()
    
    Enum.each(other_events, &handle_event/1)
    
    # Maintain consistent timing
    elapsed = System.monotonic_time(:millisecond) - start_time
    if elapsed < flush_interval do
      Process.sleep(flush_interval - elapsed)
    end
    
    events
  end

  defp handle_event(%{type: :start}), do: IO.puts("🎯 Started")
  defp handle_event(%{type: :done}), do: IO.puts("\n✅ Done")
  defp handle_event(%{type: :error} = event), do: IO.puts("❌ #{event.error.message}")
  defp handle_event(_), do: :ok
end
```

### Concurrent Streaming

```elixir
defmodule MyApp.ConcurrentStreaming do
  def stream_multiple(requests) do
    requests
    |> Task.async_stream(
      fn {model, context, id} ->
        case AI.stream_simple(model, context) do
          {:ok, stream} ->
            events = Enum.to_list(stream)
            {:ok, id, events}
          
          {:error, reason} ->
            {:error, id, reason}
        end
      end,
      max_concurrency: 5,
      timeout: 60_000
    )
    |> Stream.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, :timeout, reason}
    end)
  end
end

# Usage
requests = [
  {model1, context1, :request_1},
  {model2, context2, :request_2},
  {model3, context3, :request_3}
]

MyApp.ConcurrentStreaming.stream_multiple(requests)
|> Enum.each(fn
  {:ok, id, events} ->
    IO.puts("✅ #{id}: #{length(events)} events")
  
  {:error, id, reason} ->
    IO.puts("❌ #{id}: #{inspect(reason)}")
end)
```

This streaming guide provides comprehensive coverage of ExpiAI's streaming capabilities, from basic usage to advanced patterns suitable for production applications.